// Disposable transactional mail peer. Every endpoint is bound to loopback.
package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

const fixtureAccess = "FLINTFIXTURE000000001"
const fixtureSecret = "fixture-aws-sigv4-key-unused-outside-loopback"
const fixtureToken = "fixture-session"

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func sign(key []byte, text string) []byte {
	mac := hmac.New(sha256.New, key)
	_, _ = io.WriteString(mac, text)
	return mac.Sum(nil)
}

func signedRequest(r *http.Request, body []byte) bool {
	certificate := r.Header.Get("X-Amz-Date")
	stamp, err := time.Parse("20060102T150405Z", certificate)
	if err != nil || time.Since(stamp).Abs() > 2*time.Minute ||
		r.Header.Get("X-Amz-Security-Token") != fixtureToken {
		return false
	}
	const kind = "AWS4-HMAC-SHA256"
	scope := certificate[:8] + "/us-east-1/ses/aws4_request"
	expected := kind + " Credential=" + fixtureAccess + "/" + scope + ", SignedHeaders="
	headers, present := strings.CutPrefix(r.Header.Get("Authorization"), expected)
	keyList, signature, split := strings.Cut(headers, ", Signature=")
	if !present || !split {
		return false
	}
	names := strings.Split(keyList, ";")
	if !slices.IsSorted(names) || !slices.Contains(names, "host") ||
		!slices.Contains(names, "x-amz-date") || !slices.Contains(names, "x-amz-security-token") {
		return false
	}
	var canonical strings.Builder
	canonical.WriteString(r.Method + "\n" + r.URL.EscapedPath() + "\n\n")
	for _, key := range names {
		values := r.Header.Values(key)
		if key == "host" {
			values = []string{r.Host}
		}
		if len(values) != 1 {
			return false
		}
		canonical.WriteString(key + ":" + strings.Join(strings.Fields(values[0]), " ") + "\n")
	}
	payload := digest(body)
	hash := r.Header.Get("X-Amz-Content-Sha256")
	if hash != "" && hash != payload {
		return false
	}
	canonical.WriteString("\n" + keyList + "\n" + payload)
	toSign := kind + "\n" + certificate + "\n" + scope + "\n" + digest([]byte(canonical.String()))
	key := sign([]byte("AWS4"+fixtureSecret), certificate[:8])
	for _, data := range []string{"us-east-1", "ses", "aws4_request"} {
		key = sign(key, data)
	}
	decoded, err := hex.DecodeString(signature)
	return err == nil && hmac.Equal(decoded, sign(key, toSign))
}

func expectedPayload(provider string, r *http.Request, raw []byte) bool {
	var body map[string]json.RawMessage
	if r.Method != "POST" || r.URL.RawQuery != "" || r.Header.Get("Content-Type") != "application/json" ||
		r.Header.Get("Accept") != "application/json" || json.Unmarshal(raw, &body) != nil {
		return false
	}
	switch provider {
	case "RESEND":
		return r.URL.Path == "/emails" && r.Header.Get("Authorization") == "Bearer fixture-resend" &&
			r.Header.Get("Idempotency-Key") == "fixture-message-1" &&
			string(body["subject"]) == `"Hello, 世界"` &&
			string(body["to"]) == `["visible@example.test"]` &&
			string(body["bcc"]) == `["blind@example.test"]` &&
			string(body["attachments"]) == `[{"filename":"bytes.bin","content":"AAEC/w==","content_type":"application/octet-stream"}]`
	case "POSTMARK":
		return r.URL.Path == "/email" && r.Header.Get("X-Postmark-Server-Token") == "fixture-postmark" &&
			string(body["Subject"]) == `"Hello, 世界"` &&
			string(body["To"]) == `"visible@example.test"` &&
			string(body["Bcc"]) == `"blind@example.test"` &&
			string(body["Attachments"]) == `[{"Name":"bytes.bin","Content":"AAEC/w==","ContentType":"application/octet-stream"}]`
	case "SES":
		var content struct{ Raw struct{ Data string } }
		if json.Unmarshal(body["Content"], &content) != nil {
			return false
		}
		mime, err := base64.StdEncoding.DecodeString(content.Raw.Data)
		return r.URL.Path == "/v2/email/outbound-emails" && signedRequest(r, raw) && err == nil &&
			string(body["FromEmailAddress"]) == `"sender@example.test"` &&
			string(body["Destination"]) == `{"ToAddresses":["visible@example.test"],"BccAddresses":["blind@example.test"]}` &&
			!bytes.Contains(mime, []byte("blind@example.test")) &&
			bytes.Contains(mime, []byte("multipart/alternative")) &&
			bytes.Contains(mime, []byte("AAEC/w==\r\n"))
	default:
		return false
	}
}

type providerFixture struct {
	provider, mode, path, redirect string
	lock                           sync.Mutex
	count                          int
}

func (f *providerFixture) record() int {
	f.lock.Lock()
	defer f.lock.Unlock()
	f.count++
	require(os.WriteFile(f.path+".tmp", fmt.Appendf(nil, "%d", f.count), 0o600))
	require(os.Rename(f.path+".tmp", f.path))
	return f.count
}

func (f *providerFixture) serve(w http.ResponseWriter, r *http.Request) {
	attempt := f.record()
	if f.mode == "TARGET" {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64*1024))
	if err != nil || !expectedPayload(f.provider, r, body) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	switch f.mode {
	case "RATE":
		if attempt == 1 {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, "{}")
			return
		}
	case "DENIED":
		w.WriteHeader(http.StatusForbidden)
		_, _ = io.WriteString(w, "{}")
		return
	case "AMBIGUOUS":
		connection, _, err := w.(http.Hijacker).Hijack()
		if err == nil {
			_ = connection.Close()
		}
		return
	case "REDIRECT":
		w.Header().Set("Location", f.redirect)
		w.WriteHeader(http.StatusTemporaryRedirect)
		return
	case "INVALID_ID":
		_, _ = io.WriteString(w, `{"id":"one","id":"two"}`)
		return
	case "INVALID_JSON":
		_, _ = io.WriteString(w, `{"id":"one","bad":"\ud800"}`)
		return
	case "POSTMARK_ERROR":
		_, _ = io.WriteString(w, `{"ErrorCode":300,"Message":"Fixture rejected the message"}`)
		return
	}
	reply := map[string]string{
		"RESEND":   `{"id":"resend-fixture-id","metadata":{"empty":[null,true,1.2e3]}}`,
		"POSTMARK": `{"ErrorCode":0,"MessageID":"postmark-fixture-id"}`,
		"SES":      `{"MessageId":"ses-fixture-id"}`,
	}
	_, _ = io.WriteString(w, reply[f.provider])
}

func providerFixtures(dir string, valid, invalid *tls.Config, result map[string]string) {
	targets := map[string]string{"RESEND": "/emails", "POSTMARK": "/email", "SES": "/v2/email/outbound-emails"}
	entries := []struct{ provider, mode string }{{"SES", "TARGET"}}
	for _, provider := range []string{"RESEND", "POSTMARK", "SES"} {
		for _, mode := range []string{"OK", "RATE", "DENIED"} {
			entries = append(entries, struct{ provider, mode string }{provider, mode})
		}
	}
	entries = append(entries, struct{ provider, mode string }{"RESEND", "AMBIGUOUS"},
		struct{ provider, mode string }{"RESEND", "INVALID_ID"},
		struct{ provider, mode string }{"RESEND", "INVALID_JSON"},
		struct{ provider, mode string }{"POSTMARK", "POSTMARK_ERROR"},
		struct{ provider, mode string }{"SES", "REDIRECT"}, struct{ provider, mode string }{"SES", "WRONG_HOST"})
	for _, entry := range entries {
		id := "HTTP_" + entry.provider + "_" + entry.mode
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		require(err)
		config := valid
		if entry.mode == "WRONG_HOST" {
			config = invalid
		}
		record := filepath.Join(dir, strings.ToLower(id))
		require(os.WriteFile(record, []byte("0"), 0o600))
		result[id] = fmt.Sprintf("https://localhost:%d%s", listener.Addr().(*net.TCPAddr).Port, targets[entry.provider])
		result[id+"_PATH"] = record
		state := &providerFixture{provider: entry.provider, mode: entry.mode, path: record,
			redirect: result["HTTP_SES_TARGET"]}
		server := &http.Server{Handler: http.HandlerFunc(state.serve), ReadHeaderTimeout: 5 * time.Second}
		go server.Serve(tls.NewListener(listener, config))
	}
}
