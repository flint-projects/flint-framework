// Local SMTP exercise peer. No connection or message leaves this process.
package main

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"mime"
	"mime/multipart"
	"net"
	"net/mail"
	"net/textproto"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

func require(err error) {
	if err != nil {
		panic(err)
	}
}

func certificates(out string) (*tls.Config, *tls.Config) {
	now := time.Now()
	parent := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Flint SMTP fixture CA"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true,
		KeyUsage: x509.KeyUsageCertSign}
	root, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	require(err)
	der, err := x509.CreateCertificate(rand.Reader, parent, parent, &root.PublicKey, root)
	require(err)
	require(os.WriteFile(out, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0o600))
	leaf := func(host string, serial int64) *tls.Config {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		require(err)
		cert := &x509.Certificate{SerialNumber: big.NewInt(serial), DNSNames: []string{host},
			NotBefore: parent.NotBefore, NotAfter: parent.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature,
			ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
		body, err := x509.CreateCertificate(rand.Reader, cert, parent, &key.PublicKey, root)
		require(err)
		return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{{Certificate: [][]byte{body}, PrivateKey: key}}}
	}
	return leaf("localhost", 2), leaf("wrong.invalid", 3)
}

type metrics struct {
	Connections int      `json:"connections"`
	ClearAuth   int      `json:"clear_auth"`
	TLSAuth     int      `json:"tls_auth"`
	Envelopes   int      `json:"envelopes"`
	Messages    int      `json:"messages"`
	Recipients  []string `json:"recipients"`
}

type fixture struct {
	mode, path string
	tls        *tls.Config
	lock       sync.Mutex
	values     metrics
}

func (f *fixture) change(apply func(*metrics)) metrics {
	f.lock.Lock()
	defer f.lock.Unlock()
	apply(&f.values)
	body, err := json.Marshal(f.values)
	require(err)
	name := f.path + ".json"
	require(os.WriteFile(name+".tmp", body, 0o600))
	require(os.Rename(name+".tmp", name))
	return f.values
}

func send(w io.Writer, text string, fragmented bool) bool {
	if !fragmented {
		_, err := io.WriteString(w, text)
		return err == nil
	}
	for start := 0; start < len(text); start += 3 {
		end := min(start+3, len(text))
		if _, err := io.WriteString(w, text[start:end]); err != nil {
			return false
		}
	}
	return true
}

func (f *fixture) receive(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(7 * time.Second))
	index := f.change(func(m *metrics) { m.Connections++ }).Connections
	if f.mode == "STALL" {
		_, _ = io.Copy(io.Discard, conn)
		return
	}
	secured := f.mode == "IMPLICIT"
	if secured {
		securedConn := tls.Server(conn, f.tls)
		if securedConn.Handshake() != nil {
			return
		}
		conn = securedConn
	}
	input := bufio.NewReader(conn)
	if !send(conn, "220 loopback-sink ESMTP\r\n", true) {
		return
	}
	for {
		command, err := input.ReadString('\n')
		if err != nil {
			return
		}
		command = strings.TrimSpace(command)
		switch {
		case strings.HasPrefix(command, "EHLO "):
			var response string
			switch {
			case f.mode == "BAD_EHLO":
				response = "221 invalid greeting order\r\n"
			case f.mode == "MALFORMED":
				response = "250-loopback-sink\r\n251 SIZE 67108864\r\n"
			case !secured && f.mode != "MISSING" && f.mode != "CLEAR":
				response = "250-loopback-sink\r\n250-STARTTLS\r\n250 SIZE 67108864\r\n"
			case f.mode == "SMALL":
				response = "250-loopback-sink\r\n250-AUTH PLAIN\r\n250 SIZE 64\r\n"
			case f.mode != "DOWNGRADE" && f.mode != "CLEAR":
				response = "250-loopback-sink\r\n250-AUTH PLAIN\r\n250 SIZE 67108864\r\n"
			default:
				response = "250-loopback-sink\r\n250 SIZE 67108864\r\n"
			}
			if !send(conn, response, true) {
				return
			}
		case command == "STARTTLS":
			if !send(conn, "220 Start TLS\r\n", false) {
				return
			}
			securedConn := tls.Server(conn, f.tls)
			if securedConn.Handshake() != nil {
				return
			}
			conn, secured = securedConn, true
			input = bufio.NewReader(conn)
		case strings.HasPrefix(command, "AUTH "):
			f.change(func(m *metrics) {
				if secured {
					m.TLSAuth++
				} else {
					m.ClearAuth++
				}
			})
			if command == "AUTH PLAIN" {
				if !send(conn, "334 \r\n", false) {
					return
				}
				if _, err := input.ReadString('\n'); err != nil {
					return
				}
			}
			if !send(conn, "235 Authentication successful\r\n", false) {
				return
			}
		case strings.HasPrefix(command, "MAIL FROM:"):
			f.change(func(m *metrics) { m.Envelopes++ })
			if f.mode == "TRANSIENT" && index == 1 {
				_ = send(conn, "451 Please retry\r\n", false)
				return
			}
			if !send(conn, "250 Sender accepted\r\n", false) {
				return
			}
		case strings.HasPrefix(command, "RCPT TO:"):
			f.change(func(m *metrics) { m.Recipients = append(m.Recipients, command) })
			if f.mode == "DENIED" {
				_ = send(conn, "550 Recipient rejected\r\n", false)
				return
			}
			if !send(conn, "250 Recipient accepted\r\n", false) {
				return
			}
		case command == "DATA":
			if f.mode == "ORDER" {
				_ = send(conn, "250 Wrong reply for DATA\r\n", false)
				return
			}
			if !send(conn, "354 Send message\r\n", false) {
				return
			}
			if !f.message(conn, input) {
				return
			}
		case command == "QUIT":
			_ = send(conn, "221 Closing\r\n", false)
			return
		default:
			_ = send(conn, "500 Unrecognized command\r\n", false)
			return
		}
	}
}

func (f *fixture) message(conn net.Conn, input *bufio.Reader) bool {
	if f.mode == "BENCH" {
		return f.benchmark(conn, input)
	}
	var capture strings.Builder
	received := 0
	for {
		line, err := input.ReadString('\n')
		if err != nil {
			return false
		}
		if line == ".\r\n" {
			break
		}
		if strings.HasPrefix(line, "..") {
			line = line[1:]
		}
		received += len(line)
		if received <= 1_048_576 {
			capture.WriteString(line)
		}
		if received > 64*1024*1024 {
			return false
		}
	}
	f.change(func(m *metrics) { m.Messages++ })
	if received <= 1_048_576 {
		require(os.WriteFile(f.path+".mime", []byte(capture.String()), 0o600))
	}
	if f.mode == "AMBIGUOUS" {
		return false
	}
	return send(conn, "250 2.0.0 queued as local-receipt\r\n", true)
}

func (f *fixture) benchmark(conn net.Conn, input *bufio.Reader) bool {
	data := textproto.NewReader(input).DotReader()
	defer io.Copy(io.Discard, data)
	parsed, err := mail.ReadMessage(data)
	if err != nil {
		return false
	}
	kind, attrs, err := mime.ParseMediaType(parsed.Header.Get("Content-Type"))
	if err != nil || kind != "multipart/mixed" || parsed.Header.Get("Bcc") != "" {
		return false
	}
	parts := multipart.NewReader(parsed.Body, attrs["boundary"])
	part, err := parts.NextRawPart()
	if err != nil || !strings.HasPrefix(part.Header.Get("Content-Type"), "multipart/alternative;") {
		return false
	}
	part, err = parts.NextRawPart()
	if err != nil || part.FileName() != "attachment.bin" ||
		part.Header.Get("Content-Transfer-Encoding") != "base64" {
		return false
	}
	checksum := sha256.New()
	length, err := io.Copy(checksum, base64.NewDecoder(base64.StdEncoding, part))
	if err != nil || (length != 1_048_576 && length != 8_388_608) {
		return false
	}
	if _, err := parts.NextRawPart(); err != io.EOF {
		return false
	}
	if _, err := io.Copy(io.Discard, data); err != nil {
		return false
	}
	record := struct {
		Length int64  `json:"length"`
		Hash   string `json:"sha256"`
	}{length, strings.ToUpper(hex.EncodeToString(checksum.Sum(nil)))}
	wire, err := json.Marshal(record)
	require(err)
	require(os.WriteFile(f.path+".bytes.json", wire, 0o600))
	return send(conn, "250 2.0.0 queued as local-receipt\r\n", true)
}

func main() {
	if len(os.Args) != 2 {
		panic("expect fixture directory")
	}
	dir := os.Args[1]
	ca := filepath.Join(dir, "ca.pem")
	valid, invalid := certificates(ca)
	result := map[string]string{"CA": ca}
	for _, mode := range []string{"NORMAL", "IMPLICIT", "MISSING", "WRONG", "DOWNGRADE", "MALFORMED",
		"TRANSIENT", "DENIED", "ORDER", "AMBIGUOUS", "STALL", "CLEAR", "BENCH", "SMALL", "FIBER", "BAD_EHLO"} {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		require(err)
		defer listener.Close()
		path := filepath.Join(dir, strings.ToLower(mode))
		f := &fixture{mode: mode, path: path, tls: valid}
		if mode == "WRONG" {
			f.tls = invalid
		}
		f.change(func(*metrics) {})
		scheme, host := "smtp", "localhost"
		if mode == "IMPLICIT" {
			scheme = "smtps"
		}
		if mode == "CLEAR" {
			host = "127.0.0.1"
		}
		result[mode] = fmt.Sprintf("%s://%s:%d", scheme, host, listener.Addr().(*net.TCPAddr).Port)
		result[mode+"_PATH"] = path
		go func() {
			for {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				go f.receive(conn)
			}
		}()
	}
	providerFixtures(dir, valid, invalid, result)
	require(json.NewEncoder(os.Stdout).Encode(result))
	_, _ = io.Copy(io.Discard, os.Stdin)
}
