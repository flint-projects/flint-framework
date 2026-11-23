// Local HTTPS, HTTP/2, and protocol test peers. All sockets bind to loopback.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
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

// h2Frame writes one HTTP/2 frame header and payload.
func h2Frame(conn net.Conn, kind, flags byte, stream uint32, payload []byte) error {
	var header [9]byte
	header[0], header[1], header[2] = byte(len(payload)>>16), byte(len(payload)>>8), byte(len(payload))
	header[3], header[4] = kind, flags
	binary.BigEndian.PutUint32(header[5:], stream&0x7fffffff)
	_, err := conn.Write(append(header[:], payload...))
	return err
}

// hpackLiteral encodes a short field as an HPACK literal without indexing and without Huffman coding.
func hpackLiteral(block []byte, name, value string) []byte {
	block = append(block, 0, byte(len(name)))
	block = append(block, name...)
	block = append(block, byte(len(value)))
	return append(block, value...)
}

// serveOpenEnded answers each prior-knowledge HTTP/2 stream with a complete response (head, five body
// bytes and trailers with END_STREAM) as soon as the request headers arrive. Unlike net/http it never
// sends RST_STREAM, so the client's request side stays open: RFC 9113 section 8.1 lets the client keep
// sending. Request DATA is discarded and its flow-control credit returned.
func serveOpenEnded(conn net.Conn) {
	defer conn.Close()
	preface := make([]byte, 24)
	if _, err := io.ReadFull(conn, preface); err != nil || string(preface) != "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" {
		return
	}
	head := hpackLiteral([]byte{0x88}, "x-early", "yes") // 0x88 is the static :status 200
	trailers := hpackLiteral(nil, "x-outcome", "done")
	if h2Frame(conn, 0x4, 0, 0, nil) != nil {
		return
	}
	var header [9]byte
	for {
		if _, err := io.ReadFull(conn, header[:]); err != nil {
			return
		}
		length := int(header[0])<<16 | int(header[1])<<8 | int(header[2])
		kind, flags := header[3], header[4]
		stream := binary.BigEndian.Uint32(header[5:]) & 0x7fffffff
		frame := make([]byte, length)
		if _, err := io.ReadFull(conn, frame); err != nil {
			return
		}
		var err error
		switch {
		case kind == 0x4 && flags&0x1 == 0: // SETTINGS
			err = h2Frame(conn, 0x4, 0x1, 0, nil)
		case kind == 0x6 && flags&0x1 == 0: // PING
			err = h2Frame(conn, 0x6, 0x1, 0, frame)
		case kind == 0x1 && flags&0x4 != 0 && flags&0x1 == 0: // request HEADERS, upload still open
			if err = h2Frame(conn, 0x1, 0x4, stream, head); err == nil {
				if err = h2Frame(conn, 0x0, 0, stream, []byte("early")); err == nil {
					err = h2Frame(conn, 0x1, 0x5, stream, trailers)
				}
			}
		case kind == 0x0 && length > 0: // DATA
			credit := binary.BigEndian.AppendUint32(nil, uint32(length))
			if err = h2Frame(conn, 0x8, 0, 0, credit); err == nil {
				err = h2Frame(conn, 0x8, 0, stream, credit)
			}
		}
		if err != nil {
			return
		}
	}
}

func tlsServer(handler http.Handler, cert []byte, key ed25519.PrivateKey) *httptest.Server {
	return tlsProtocols(handler, cert, key, true)
}

func tlsProtocols(handler http.Handler, cert []byte, key ed25519.PrivateKey, h2 bool) *httptest.Server {
	server := httptest.NewUnstartedServer(handler)
	server.EnableHTTP2 = h2
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
	// An origin whose replies take longer than a loopback round trip, as across a LAN or the internet.
	// An idle Go runtime rounds a short sleep up to a millisecond, so wait on the clock instead.
	mux.HandleFunc("/delayed", func(w http.ResponseWriter, _ *http.Request) {
		for started := time.Now(); time.Since(started) < 300*time.Microsecond; {
		}
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
	// A complete response with trailers that never reads the request body. HTTP/2 ends the stream and
	// then sends RST_STREAM(NO_ERROR); HTTP/1.1 sends the chunked response while the upload is open.
	mux.HandleFunc("/duplex-early", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Trailer", "X-Outcome")
		w.Header().Set("X-Early", "yes")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "early")
		w.Header().Set("X-Outcome", "done")
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
	h1tls := tlsProtocols(handler, goodRaw, goodKey, false)
	defer h1tls.Close()
	openEnded, err := net.Listen("tcp", "127.0.0.1:0")
	checked(err)
	defer openEnded.Close()
	go func() {
		for {
			conn, err := openEnded.Accept()
			if err != nil {
				return
			}
			go serveOpenEnded(conn)
		}
	}()

	// An ephemeral port, so concurrent runs on one machine cannot collide; the test binds to it at run time.
	exchange, err := net.Listen("tcp", "127.0.0.1:0")
	checked(err)
	go http.Serve(exchange, mux)

	output := map[string]string{
		"HTTP":       h1.URL,
		"HTTPS":      strings.Replace(h2.URL, "127.0.0.1", "localhost", 1),
		"MISMATCH":   h2.URL,
		"EXPIRED":    strings.Replace(expired.URL, "127.0.0.1", "localhost", 1),
		"CONNECTING": "https://" + stall.Addr().String(),
		"OTHER":      other.URL,
		"HTTPS1":     strings.Replace(h1tls.URL, "127.0.0.1", "localhost", 1),
		"H2OPEN":     "http://" + openEnded.Addr().String(),
		"EXCHANGE":   "http://" + exchange.Addr().String(),
		"CA":         bundle,
	}
	checked(json.NewEncoder(os.Stdout).Encode(output))
	_, _ = io.Copy(io.Discard, os.Stdin)
}
