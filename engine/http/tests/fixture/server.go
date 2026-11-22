// Local HTTPS, HTTP/2, and protocol test peers. All sockets bind to loopback.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const exchangeAddress = "127.0.0.1:43719"

type connectionKey struct{}

// endlessTransfer records how much of an unbounded entity a handler wrote before the client stopped it.
type endlessTransfer struct {
	written atomic.Int64
	aborted atomic.Bool
	done    chan struct{}
}

// flushWriter sends every handler write as its own chunk instead of coalescing it in the server buffer.
type flushWriter struct {
	http.ResponseWriter
}

func (writer flushWriter) Write(data []byte) (int, error) {
	n, err := writer.ResponseWriter.Write(data)
	writer.ResponseWriter.(http.Flusher).Flush()
	return n, err
}

type multiplexGroup struct {
	arrived atomic.Int32
	proceed chan struct{}
}

func checked(err error) {
	if err != nil {
		panic(err)
	}
}

func payloadByte(index int) byte {
	return byte((index*17 + index/11) % 251)
}

func payload(w http.ResponseWriter, length, first, last int) {
	var data [4096]byte
	if length >= 0 {
		w.Header().Set("Content-Length", strconv.Itoa(length))
	}
	index := 0
	for n := first; n <= last && (length < 0 || index < length); n++ {
		size := n
		if length >= 0 {
			size = min(n, length-index)
			n--
		}
		for i := range size {
			data[i] = payloadByte(index + i)
		}
		if _, err := w.Write(data[:size]); err != nil {
			return
		}
		index += size
	}
}

func certificate(
	serial int64, label string, issuer *x509.Certificate, issuerKey ed25519.PrivateKey, expired bool,
) (*x509.Certificate, ed25519.PrivateKey, []byte) {
	publicKey, key, err := ed25519.GenerateKey(rand.Reader)
	checked(err)
	now := time.Now()
	cert := &x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      pkix.Name{CommonName: label},
		NotBefore:    now.Add(-48 * time.Hour),
		NotAfter:     now.Add(24 * time.Hour),
	}
	if expired {
		cert.NotAfter = now.Add(-24 * time.Hour)
	}
	if issuer == nil {
		cert.IsCA = true
		cert.BasicConstraintsValid = true
		cert.KeyUsage = x509.KeyUsageCertSign | x509.KeyUsageCRLSign
		issuer, issuerKey = cert, key
	} else {
		cert.DNSNames = []string{"localhost"}
		cert.KeyUsage = x509.KeyUsageDigitalSignature
		cert.ExtKeyUsage = []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}
	}
	raw, err := x509.CreateCertificate(rand.Reader, cert, issuer, publicKey, issuerKey)
	checked(err)
	parsed, err := x509.ParseCertificate(raw)
	checked(err)
	return parsed, key, raw
}

func tlsServer(handler http.Handler, cert []byte, key ed25519.PrivateKey) *httptest.Server {
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = true
	server.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{cert}, PrivateKey: key}}}
	var sequence atomic.Uint32
	server.Config.ConnContext = func(ctx context.Context, _ net.Conn) context.Context {
		return context.WithValue(ctx, connectionKey{}, sequence.Add(1))
	}
	server.StartTLS()
	return server
}

func main() {
	if len(os.Args) != 2 {
		panic("test output directory required")
	}
	ca, caKey, caRaw := certificate(1, "Flint HTTP test authority", nil, nil, false)
	_, goodKey, goodRaw := certificate(2, "localhost", ca, caKey, false)
	_, oldKey, oldRaw := certificate(3, "localhost", ca, caKey, true)
	bundle := filepath.Join(os.Args[1], "ca.pem")
	checked(os.WriteFile(bundle, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caRaw}), 0600))

	var handshakeAccepted atomic.Int32
	stall, err := net.Listen("tcp", "127.0.0.1:0")
	checked(err)
	go func() {
		for {
			conn, err := stall.Accept()
			if err != nil {
				return
			}
			handshakeAccepted.Add(1)
			go func() {
				defer conn.Close()
				_, _ = io.Copy(io.Discard, conn)
			}()
		}
	}()

	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" ||
			r.Header.Get("Proxy-Authorization") != "" || r.Header.Get("Cookie2") != "" {
			w.WriteHeader(http.StatusConflict)
			return
		}
		_, _ = io.WriteString(w, r.Header.Get("X-Probe"))
	}))
	defer other.Close()

	var groups sync.Map
	mux := http.NewServeMux()
	mux.HandleFunc("/zero", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/bytes", func(w http.ResponseWriter, r *http.Request) {
		n, err := strconv.Atoi(r.URL.Query().Get("n"))
		if err != nil || n < 0 {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		payload(w, n, 4096, 4096)
	})
	var benchmarkConnection atomic.Uint32
	mux.HandleFunc("/bench", func(w http.ResponseWriter, r *http.Request) {
		id, valid := r.Context().Value(connectionKey{}).(uint32)
		if !valid || r.ProtoMajor != 2 {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		benchmarkConnection.CompareAndSwap(0, id)
		if benchmarkConnection.Load() != id {
			w.WriteHeader(http.StatusConflict)
			return
		}
		n, err := strconv.Atoi(r.URL.Query().Get("n"))
		if err != nil || (n != 1024 && n != 65536) {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		payload(w, n, 4096, 4096)
	})
	mux.HandleFunc("/chunks", func(w http.ResponseWriter, r *http.Request) {
		minimum, _ := strconv.Atoi(r.URL.Query().Get("min"))
		maximum, _ := strconv.Atoi(r.URL.Query().Get("max"))
		if minimum < 1 || maximum > 4096 || minimum > maximum {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if r.URL.Query().Get("flush") == "1" {
			payload(flushWriter{w}, -1, minimum, maximum)
			return
		}
		payload(w, -1, minimum, maximum)
	})
	var endless sync.Map
	mux.HandleFunc("/endless", func(w http.ResponseWriter, r *http.Request) {
		transfer := &endlessTransfer{done: make(chan struct{})}
		defer close(transfer.done)
		if _, loaded := endless.LoadOrStore(r.URL.Query().Get("id"), transfer); loaded {
			w.WriteHeader(http.StatusConflict)
			return
		}
		var data [4096]byte
		for index := 0; index < 256<<20; index += len(data) {
			for i := range data {
				data[i] = payloadByte(index + i)
			}
			if _, err := w.Write(data[:]); err != nil {
				transfer.aborted.Store(true)
				return
			}
			transfer.written.Add(int64(len(data)))
		}
	})
	mux.HandleFunc("/written", func(w http.ResponseWriter, r *http.Request) {
		value, found := endless.Load(r.URL.Query().Get("id"))
		if !found {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		transfer := value.(*endlessTransfer)
		select {
		case <-transfer.done:
		case <-time.After(5 * time.Second):
		}
		_, _ = fmt.Fprintf(w, "%d %t", transfer.written.Load(), transfer.aborted.Load())
	})
	mux.HandleFunc("/utf", func(w http.ResponseWriter, r *http.Request) {
		split, _ := strconv.Atoi(r.URL.Query().Get("split"))
		data := []byte("é")
		_, _ = w.Write(data[:split])
		w.(http.Flusher).Flush()
		time.Sleep(4 * time.Millisecond)
		_, _ = w.Write(data[split:])
	})
	mux.HandleFunc("/location", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/", http.StatusFound)
	})
	mux.HandleFunc("/same", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/headers", http.StatusTemporaryRedirect)
	})
	mux.HandleFunc("/blocked-target", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+"/banned", http.StatusFound)
	})
	mux.HandleFunc("/repeat-upload", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/echo", http.StatusTemporaryRedirect)
	})
	mux.HandleFunc("/drop-upload", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/verify-get", http.StatusSeeOther)
	})
	mux.HandleFunc("/verify-get", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.ContentLength != 0 || r.Header.Get("Content-Type") != "" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/headers", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Final", "checked")
		_, _ = io.WriteString(w, r.Header.Get("Authorization")+";"+r.Header.Get("Cookie"))
	})
	mux.HandleFunc("/again", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(r.URL.Query().Get("n"))
		if n == 0 {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		http.Redirect(w, r, "/again?n="+strconv.Itoa(n-1), http.StatusTemporaryRedirect)
	})
	mux.HandleFunc("/late", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Receiving", "yes")
		_, _ = io.WriteString(w, "!")
		w.(http.Flusher).Flush()
		select {
		case <-r.Context().Done():
		case <-time.After(5 * time.Second):
		}
	})
	mux.HandleFunc("/handshakes", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = fmt.Fprintf(w, "%d", handshakeAccepted.Load())
	})
	mux.HandleFunc("/h2/", func(w http.ResponseWriter, r *http.Request) {
		id := strings.TrimPrefix(r.URL.Path, "/h2/")
		if r.ProtoMajor != 2 || r.Header.Get("X-Id") != id {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		key := r.URL.Query().Get("group")
		value, _ := groups.LoadOrStore(key, &multiplexGroup{proceed: make(chan struct{})})
		group := value.(*multiplexGroup)
		if group.arrived.Add(1) == 64 {
			close(group.proceed)
		}
		select {
		case <-group.proceed:
		case <-r.Context().Done():
			return
		}
		w.Header().Set("X-Id", id)
		w.Header().Set("X-Connection", fmt.Sprint(r.Context().Value(connectionKey{})))
		_, _ = io.WriteString(w, "reply-"+id)
	})
	mux.HandleFunc("/exchange/", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, r.URL.EscapedPath()+";"+r.Header.Get("X-Trace"))
	})
	mux.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.Header.Get("Content-Type") != "application/json" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		_, _ = io.Copy(w, r.Body)
	})
	mux.HandleFunc("/stream-rejected", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = io.WriteString(w, "data: unexpected\n\n")
	})
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.RequestURI, "/view-signed/") {
			mux.ServeHTTP(w, r)
			return
		}
		if r.Method != "PUT" || r.RequestURI != "/view-signed/leaf/../%E2%98%83?mode=a%2Fb" ||
			r.Header.Get("X-Probe") != "scoped" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		_, _ = io.Copy(w, r.Body)
	})

	h1 := httptest.NewServer(handler)
	defer h1.Close()
	h2 := tlsServer(handler, goodRaw, goodKey)
	defer h2.Close()
	expired := tlsServer(mux, oldRaw, oldKey)
	defer expired.Close()

	exchange, err := net.Listen("tcp", exchangeAddress)
	checked(err)
	go http.Serve(exchange, mux)

	output := map[string]string{
		"HTTP":       h1.URL,
		"HTTPS":      strings.Replace(h2.URL, "127.0.0.1", "localhost", 1),
		"MISMATCH":   h2.URL,
		"EXPIRED":    strings.Replace(expired.URL, "127.0.0.1", "localhost", 1),
		"CONNECTING": "https://" + stall.Addr().String(),
		"OTHER":      other.URL,
		"CA":         bundle,
	}
	checked(json.NewEncoder(os.Stdout).Encode(output))
	_, _ = io.Copy(io.Discard, os.Stdin)
}
