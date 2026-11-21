// Loopback RESP3 and TLS fixtures for failure modes, separate from the real Valkey peer.
package main

import (
	"bufio"
	"bytes"
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
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

const responseLimit = 16 * 1024 * 1024

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func bulk(p []byte) []byte {
	return fmt.Appendf(nil, "$%d\r\n%s\r\n", len(p), p)
}

func argv(input *bufio.Reader) ([][]byte, error) {
	line, err := input.ReadString('\n')
	if err != nil {
		return nil, err
	}
	count, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(line, "*"), "\r\n"))
	if err != nil || count < 1 || count > 513 {
		return nil, fmt.Errorf("unexpected command shape")
	}
	result := make([][]byte, count)
	for i := range result {
		head, err := input.ReadString('\n')
		if err != nil {
			return nil, err
		}
		n, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(head, "$"), "\r\n"))
		if err != nil || n < 0 || n > responseLimit {
			return nil, fmt.Errorf("unexpected argument length")
		}
		payload := make([]byte, n+2)
		if _, err := io.ReadFull(input, payload); err != nil {
			return nil, err
		}
		if !bytes.Equal(payload[n:], []byte("\r\n")) {
			return nil, fmt.Errorf("unexpected argument delimiter")
		}
		result[i] = payload[:n]
	}
	return result, nil
}

func respond(connection net.Conn, mode string, drops *atomic.Uint32, receipt string) {
	defer connection.Close()
	input := bufio.NewReader(connection)
	hello, err := argv(input)
	if err != nil || len(hello) < 2 || string(hello[0]) != "HELLO" || string(hello[1]) != "3" {
		return
	}
	if mode == "tls" && (len(hello) != 5 || string(hello[2]) != "AUTH" || string(hello[3]) != "client" ||
		!bytes.Equal(hello[4], []byte{'p', '@', 's', 's', 0, 'x'})) {
		_, _ = io.WriteString(connection, "-WRONGPASS invalid credentials\r\n")
		return
	}
	if _, err := io.WriteString(connection, "%1\r\n$5\r\nproto\r\n:3\r\n"); err != nil {
		return
	}

	for {
		args, err := argv(input)
		if err != nil {
			return
		}
		switch mode {
		case "drop":
			if string(args[0]) == "SET" {
				observed := drops.Add(1)
				must(os.WriteFile(receipt, []byte(strconv.FormatUint(uint64(observed), 10)), 0o600))
			}
			return
		case "stall":
			// Drain incoming requests while deliberately leaving their replies pending.
			continue
		case "depth":
			_, _ = io.WriteString(connection, strings.Repeat("*1\r\n", 33)+"$1\r\nx\r\n")
			return
		case "oversize":
			if _, err := fmt.Fprintf(connection, "$%d\r\n", responseLimit+1); err != nil {
				return
			}
			part := make([]byte, 8192)
			for remaining := responseLimit + 1; remaining > 0; remaining -= len(part) {
				if _, err := connection.Write(part[:min(len(part), remaining)]); err != nil {
					return
				}
			}
			_, _ = io.WriteString(connection, "\r\n")
			return
		case "unknown":
			_, _ = io.WriteString(connection, "^0\r\n")
			return
		case "truncated":
			_, _ = io.WriteString(connection, "$5\r\nabc")
			return
		case "cross":
			if string(args[0]) == "SCAN" {
				_, _ = io.WriteString(connection, "*2\r\n$1\r\n0\r\n*1\r\n$13\r\noutside-cache\r\n")
			} else if string(args[0]) == "DEL" {
				must(os.WriteFile(receipt+"-outside-deletes", []byte("1"), 0o600))
				_, _ = io.WriteString(connection, ":0\r\n")
			} else {
				return
			}
		case "push":
			if string(args[0]) != "GET" || len(args) != 2 {
				return
			}
			key := args[1]
			if bytes.HasSuffix(key, []byte(":moved")) {
				_, _ = io.WriteString(connection, "-MOVED 7 127.0.0.1:1\r\n")
				continue
			}
			if bytes.HasSuffix(key, []byte(":ask")) {
				_, _ = io.WriteString(connection, "-ASK 7 127.0.0.1:1\r\n")
				continue
			}
			_, _ = io.WriteString(connection, ">2\r\n$10\r\ninvalidate\r\n*1\r\n$1\r\nk\r\n")
			_, _ = io.WriteString(connection, ">3\r\n$7\r\nmessage\r\n$1\r\nc\r\n$1\r\np\r\n")
			_, _ = connection.Write(bulk(key))
		case "tls":
			if string(args[0]) != "GET" || len(args) != 2 {
				return
			}
			_, _ = connection.Write(bulk([]byte("verified")))
		}
	}
}

func tlsIdentity(path string) tls.Certificate {
	caPublic, caKey, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	public, key, err := ed25519.GenerateKey(rand.Reader)
	must(err)
	now := time.Now()
	root := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Flint cache test authority"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour),
		IsCA: true, KeyUsage: x509.KeyUsageCertSign, BasicConstraintsValid: true,
	}
	server := &x509.Certificate{
		SerialNumber: big.NewInt(2), DNSNames: []string{"localhost"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	ca, err := x509.CreateCertificate(rand.Reader, root, root, caPublic, caKey)
	must(err)
	cert, err := x509.CreateCertificate(rand.Reader, server, root, public, caKey)
	must(err)
	must(os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: ca}), 0o600))
	return tls.Certificate{Certificate: [][]byte{cert}, PrivateKey: key}
}

func tlsForward(listener net.Listener, endpoint string) {
	for {
		client, err := listener.Accept()
		if err != nil {
			return
		}
		go func() {
			defer client.Close()
			upstream, err := net.Dial("tcp", endpoint)
			if err != nil {
				return
			}
			defer upstream.Close()
			done := make(chan struct{})
			go func() {
				defer close(done)
				_, _ = io.Copy(upstream, client)
				upstream.Close()
			}()
			_, _ = io.Copy(client, upstream)
			client.Close()
			<-done
		}()
	}
}

func main() {
	if len(os.Args) != 3 {
		panic("fixture output directory and Valkey endpoint required")
	}
	upstream := os.Args[2]
	if !strings.HasPrefix(upstream, "127.0.0.1:") {
		panic("Valkey fixture endpoint must be loopback")
	}
	ca := filepath.Join(os.Args[1], "ca.pem")
	receipt := filepath.Join(os.Args[1], "dropped-mutations")
	var counts atomic.Uint32
	tlsConfig := &tls.Config{Certificates: []tls.Certificate{tlsIdentity(ca)}}
	benchmark, err := tls.Listen("tcp", "127.0.0.1:0", tlsConfig)
	must(err)
	go tlsForward(benchmark, upstream)
	port := benchmark.Addr().(*net.TCPAddr).Port
	env := map[string]string{"CA": ca, "DROPS": receipt, "OUTSIDE_DELETES": receipt + "-outside-deletes"}
	env["REAL_TLS"] = fmt.Sprintf("rediss://:flint-cache-fixture@localhost:%d", port)
	env["REAL_TLS_PORT"] = strconv.Itoa(port)
	for _, mode := range []string{"push", "stall", "drop", "depth", "oversize", "unknown", "truncated", "cross", "tls"} {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		must(err)
		host := listener.Addr().String()
		if mode == "tls" {
			listener = tls.NewListener(listener, tlsConfig)
			env["MISMATCH"] = "rediss://client:p%40ss%00x@" + host
			env["WRONGPASS"] = "rediss://client:wrong@" + strings.Replace(host, "127.0.0.1", "localhost", 1)
			env["TLS"] = "rediss://client:p%40ss%00x@" + strings.Replace(host, "127.0.0.1", "localhost", 1)
		} else {
			env[strings.ToUpper(mode)] = "redis://" + host
		}
		go func() {
			for {
				connection, err := listener.Accept()
				if err != nil {
					return
				}
				go respond(connection, mode, &counts, receipt)
			}
		}()
	}
	must(json.NewEncoder(os.Stdout).Encode(env))
	_, _ = io.Copy(io.Discard, os.Stdin)
}
