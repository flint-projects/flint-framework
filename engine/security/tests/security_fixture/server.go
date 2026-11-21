// Ephemeral signing keys and loopback HTTPS endpoints for JWT/JWKS verification.
package main

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

var raw64 = base64.RawURLEncoding

func require(err error) {
	if err != nil {
		panic(err)
	}
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(value)
}

func cert(caPath string) tls.Certificate {
	pub, rootKey, err := ed25519.GenerateKey(rand.Reader)
	require(err)
	leafPub, leafKey, err := ed25519.GenerateKey(rand.Reader)
	require(err)
	now := time.Now()
	root := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Flint JWKS fixture"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour),
		BasicConstraintsValid: true, IsCA: true, KeyUsage: x509.KeyUsageCertSign,
	}
	bundle, err := x509.CreateCertificate(rand.Reader, root, root, pub, rootKey)
	require(err)
	require(os.WriteFile(caPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: bundle}), 0o600))
	leaf := &x509.Certificate{
		SerialNumber: big.NewInt(2), DNSNames: []string{"localhost"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, leaf, root, leafPub, rootKey)
	require(err)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: leafKey}
}

func sign(key crypto.Signer, header, claims string) string {
	input := raw64.EncodeToString([]byte(header)) + "." + raw64.EncodeToString([]byte(claims))
	hash := sha256.Sum256([]byte(input))
	var signature []byte
	switch cast := key.(type) {
	case *rsa.PrivateKey:
		var err error
		signature, err = rsa.SignPKCS1v15(rand.Reader, cast, crypto.SHA256, hash[:])
		require(err)
	case *ecdsa.PrivateKey:
		r, s, err := ecdsa.Sign(rand.Reader, cast, hash[:])
		require(err)
		width := (cast.Curve.Params().BitSize + 7) / 8
		signature = make([]byte, 2*width)
		r.FillBytes(signature[:width])
		s.FillBytes(signature[width:])
	case ed25519.PrivateKey:
		signature = ed25519.Sign(cast, []byte(input))
	}
	return input + "." + raw64.EncodeToString(signature)
}

func jwtWith(key crypto.Signer, alg, id, claims string) string {
	return sign(key, fmt.Sprintf("{\"alg\":%q,\"kid\":%q}", alg, id), claims)
}

func jwk(material crypto.Signer, id string) map[string]string {
	switch key := material.Public().(type) {
	case *rsa.PublicKey:
		exp := big.NewInt(int64(key.E))
		return map[string]string{"kid": id, "use": "sig", "kty": "RSA", "alg": "RS256",
			"n": raw64.EncodeToString(key.N.Bytes()), "e": raw64.EncodeToString(exp.Bytes())}
	case *ecdsa.PublicKey:
		return map[string]string{"kid": id, "use": "sig", "kty": "EC", "alg": "ES256", "crv": "P-256",
			"x": raw64.EncodeToString(key.X.FillBytes(make([]byte, 32))),
			"y": raw64.EncodeToString(key.Y.FillBytes(make([]byte, 32)))}
	case ed25519.PublicKey:
		return map[string]string{"kid": id, "use": "sig", "kty": "OKP", "alg": "EdDSA", "crv": "Ed25519",
			"x": raw64.EncodeToString(key)}
	}
	panic("unrecognized fixture key")
}

func secretEnv(values map[string]string, rsa1, rsa2 *rsa.PrivateKey, ec *ecdsa.PrivateKey, ed ed25519.PrivateKey,
	attacker string) {
	const normal = "{\"iss\":\"fixture-issuer\",\"aud\":[\"other\",\"api\"],\"sub\":\"atlas\",\"roles\":[\"read\",\"ops\"],\"exp\":1000}"
	values["RSA"] = jwtWith(rsa1, "RS256", "rsa1", normal)
	values["NEXT"] = jwtWith(rsa2, "RS256", "rsa2", normal)
	values["EC"] = jwtWith(ec, "ES256", "ec", normal)
	values["ED"] = jwtWith(ed, "EdDSA", "ed", normal)
	values["AUD_SINGLE"] = jwtWith(rsa1, "RS256", "rsa1", "{\"iss\":\"fixture-issuer\",\"aud\":\"api\",\"exp\":1000}")
	values["NBF"] = jwtWith(rsa1, "RS256", "rsa1",
		"{\"iss\":\"fixture-issuer\",\"aud\":\"api\",\"exp\":1700,\"nbf\":1100}")
	values["NO_EXP"] = jwtWith(rsa1, "RS256", "rsa1", "{\"iss\":\"fixture-issuer\",\"aud\":\"api\"}")
	values["OPTIONAL"] = jwtWith(rsa1, "RS256", "rsa1", "{\"iss\":\"fixture-optional\",\"aud\":\"api\"}")
	values["BAD_ISS"] = jwtWith(rsa1, "RS256", "rsa1", "{\"iss\":\"wrong\",\"aud\":\"api\",\"exp\":1000}")
	values["BAD_AUD"] = jwtWith(rsa1, "RS256", "rsa1", "{\"iss\":\"fixture-issuer\",\"aud\":[\"other\"],\"exp\":1000}")
	values["DUP_ISS"] = jwtWith(rsa1, "RS256", "rsa1",
		"{\"iss\":\"fixture-issuer\",\"i\\u0073s\":\"fixture-issuer\",\"aud\":\"api\",\"exp\":1000}")
	values["DUP_AUD"] = jwtWith(rsa1, "RS256", "rsa1",
		"{\"iss\":\"fixture-issuer\",\"aud\":\"api\",\"aud\":\"api\",\"exp\":1000}")
	values["DUP_ALG"] = sign(rsa1, "{\"alg\":\"RS256\",\"al\\u0067\":\"RS256\",\"kid\":\"rsa1\"}", normal)
	values["NONE"] = sign(rsa1, "{\"alg\":\"none\",\"kid\":\"rsa1\"}", normal)
	values["HMAC"] = sign(rsa1, "{\"alg\":\"HS256\",\"kid\":\"rsa1\"}", normal)
	values["CRIT"] = sign(rsa1, "{\"alg\":\"RS256\",\"kid\":\"rsa1\",\"crit\":[\"attempt\"]}", normal)
	values["JKU"] = sign(rsa1, fmt.Sprintf("{\"alg\":\"RS256\",\"kid\":\"rsa1\",\"jku\":%q}", attacker), normal)
	values["X5U"] = sign(rsa1, fmt.Sprintf("{\"alg\":\"RS256\",\"kid\":\"rsa1\",\"x5u\":%q}", attacker), normal)
	wrong, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	require(err)
	values["CURVE"] = jwtWith(wrong, "ES256", "ec", normal)
	values["MISSING"] = jwtWith(rsa1, "RS256", "missing", normal)
	parts := strings.Split(values["RSA"], ".")
	damaged, err := raw64.DecodeString(parts[2])
	require(err)
	damaged[0] ^= 1
	values["TAMPER"] = parts[0] + "." + parts[1] + "." + raw64.EncodeToString(damaged)

	for id, key := range map[string]crypto.Signer{"RSA": rsa1, "EC": ec, "ED": ed} {
		public, err := x509.MarshalPKIXPublicKey(key.Public())
		require(err)
		values[id+"_DER"] = raw64.EncodeToString(public)
	}
}

func launch(handler http.Handler, tlsCert tls.Certificate) *httptest.Server {
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{tlsCert}}
	server.StartTLS()
	return server
}

func main() {
	if len(os.Args) != 2 {
		panic("fixture directory required")
	}
	ca := filepath.Join(os.Args[1], "ca.pem")
	bundle := cert(ca)
	counter := filepath.Join(os.Args[1], "requests")
	targetCounter := filepath.Join(os.Args[1], "untrusted-requests")
	require(os.WriteFile(counter, []byte("0"), 0o600))
	require(os.WriteFile(targetCounter, []byte("0"), 0o600))
	var requests, untrusted atomic.Uint64
	rsa1, err := rsa.GenerateKey(rand.Reader, 2048)
	require(err)
	rsa2, err := rsa.GenerateKey(rand.Reader, 2048)
	require(err)
	ec, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require(err)
	_, ed, err := ed25519.GenerateKey(rand.Reader)
	require(err)

	normal := []map[string]string{jwk(rsa1, "rsa1"), jwk(ec, "ec"), jwk(ed, "ed")}
	rotated := []map[string]string{jwk(rsa2, "rsa2"), jwk(ec, "ec"), jwk(ed, "ed")}
	target := launch(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		n := untrusted.Add(1)
		require(os.WriteFile(targetCounter, []byte(strconv.FormatUint(n, 10)), 0o600))
		writeJSON(w, map[string]any{"keys": normal})
	}), bundle)
	defer target.Close()
	mux := http.NewServeMux()
	mux.HandleFunc("/keys", func(w http.ResponseWriter, _ *http.Request) {
		count := requests.Add(1)
		require(os.WriteFile(counter, []byte(strconv.FormatUint(count, 10)), 0o600))
		keys := normal
		if count > 1 {
			time.Sleep(75 * time.Millisecond)
			keys = rotated
		}
		writeJSON(w, map[string]any{"keys": keys})
	})
	mux.HandleFunc("/stable", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{"keys": normal})
	})
	mux.HandleFunc("/redirect", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, strings.Replace(target.URL, "127.0.0.1", "localhost", 1), http.StatusTemporaryRedirect)
	})
	mux.HandleFunc("/duplicate", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, map[string]any{"keys": []map[string]string{normal[0], normal[0]}})
	})
	mux.HandleFunc("/limit", func(w http.ResponseWriter, _ *http.Request) {
		keys := make([]map[string]string, 65)
		for i := range keys {
			keys[i] = jwk(ed, strconv.Itoa(i+1))
		}
		writeJSON(w, map[string]any{"keys": keys})
	})
	mux.HandleFunc("/large", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, strings.Repeat("x", 1_048_577))
	})
	server := launch(mux, bundle)
	defer server.Close()
	env := map[string]string{
		"ORIGIN": strings.Replace(server.URL, "127.0.0.1", "localhost", 1), "CA": ca,
		"COUNT": counter, "TARGET_COUNT": targetCounter,
	}
	secretEnv(env, rsa1, rsa2, ec, ed, target.URL)
	require(json.NewEncoder(os.Stdout).Encode(env))
	_, _ = io.Copy(io.Discard, os.Stdin)
}
