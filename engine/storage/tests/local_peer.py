#!/usr/bin/env python3
"""Check S3 wire bytes with an independent SigV4 verifier and a disposable local peer."""
from collections import Counter
from hashlib import sha256
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import subprocess
import sys
from threading import Event, Lock, Thread
from urllib.parse import parse_qsl, quote, unquote, urlsplit
from xml.etree import ElementTree as ET


EMPTY_HASH = sha256(b"").hexdigest()
REMOTE_ID = "upload/with+space ="
PATH = "/flint-test/a//../white%20space%2B%25%F0%9F%A6%8A.json"
ETAG = '"obj&&etag"'


def escaped(text):
    return quote(text, safe="-_.~")


def mac(key, value):
    return hmac.digest(key, value.encode(), "sha256")


def signature(date, scope, canonical):
    day, region, service, terminal = scope.split("/")
    assert terminal == "aws4_request" and service == "s3"
    key = mac(mac(mac(mac(b"AWS4fixture-secret", day), region), service), terminal)
    return mac(key, "AWS4-HMAC-SHA256\n" + date + "\n" + scope + "\n" + sha256(canonical.encode()).hexdigest()).hex()


class Peer(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    objects = {}
    uploads = {}
    errors = []
    requests = Counter()
    lock = Lock()
    retry = Counter()
    held = 0
    release = Event()

    def log_message(self, *_):
        pass

    def check(self, payload):
        parts = urlsplit(self.path)
        assert parts.path == "/".join(escaped(unquote(segment)) for segment in parts.path.split("/"))
        assert parts.path == PATH or parts.path.startswith("/flint-test/")
        # Python 3.9 rejects an empty query under strict parsing; 3.10 and later return no fields.
        params = parse_qsl(parts.query, keep_blank_values=True, strict_parsing=True) if parts.query else []
        criteria = dict(params)
        signed = self.headers.get("Authorization")
        if signed:
            algorithm, fields = signed.split(" ", 1)
            assert algorithm == "AWS4-HMAC-SHA256"
            auth = dict(part.split("=", 1) for part in fields.split(","))
            credential, names, claimed = auth["Credential"], auth["SignedHeaders"], auth["Signature"]
            assert self.headers["X-Amz-Security-Token"] == "fixture-session"
            date = self.headers["X-Amz-Date"]
            digest = sha256(payload).hexdigest() if payload else EMPTY_HASH
            assert self.headers["X-Amz-Content-Sha256"] == digest
        else:
            claimed = criteria["X-Amz-Signature"]
            credential = criteria["X-Amz-Credential"]
            date = criteria["X-Amz-Date"]
            names = criteria["X-Amz-SignedHeaders"]
            assert criteria["X-Amz-Expires"] == "60" and criteria["X-Amz-Security-Token"] == "fixture-session"
            params = [pair for pair in params if pair[0] != "X-Amz-Signature"]
            digest = "UNSIGNED-PAYLOAD"
        access, scope = credential.split("/", 1)
        assert access == "fixture-access" and date.startswith(scope.split("/", 1)[0])
        header_names = names.split(";")
        assert header_names == sorted(set(header_names))
        canonical_headers = "".join(f"{name}:{' '.join(self.headers[name].split())}\n" for name in header_names)
        query = "&".join(name + "=" + value for name, value in sorted((escaped(k), escaped(v)) for k, v in params))
        canonical = "\n".join((self.command, parts.path, query, canonical_headers, names, digest))
        assert hmac.compare_digest(signature(date, scope, canonical), claimed), (self.command, parts.path)
        return parts.path, criteria

    def respond(self, status, payload=b"", **headers):
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name, value)
        content_length = headers.get("Content-Length")
        if content_length is None:
            self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    def handle_operation(self, owner, args, payload):
        if self.command == "HEAD" or self.command == "GET":
            if owner == "/flint-test/hold-status":
                return self.respond(200, **{"Content-Length": str(type(self).held), "ETag": ETAG})
            with self.lock:
                value = self.objects.get(owner)
            if value is None:
                return self.respond(404)
            if self.headers.get("Range"):
                assert self.headers["Range"] == "bytes=7-29"
                assert self.headers["If-Match"] == ETAG and args["versionId"] == "rev/1+"
                return self.respond(206, value[7:30], ETag=ETAG)
            return self.respond(200, value, **{"ETag": ETAG, "x-amz-version-id": "rev/1+"})
        if self.command == "DELETE":
            with self.lock:
                if "uploadId" in args:
                    assert args["uploadId"] == REMOTE_ID
                    if owner.endswith("/abort-race"):
                        if self.requests["DELETE", owner] == 1:
                            return self.respond(503)
                        self.release.set()
                    self.uploads.pop(owner)
                else:
                    self.objects.pop(owner)
            return self.respond(204)
        if self.command == "PUT":
            if "partNumber" in args:
                assert args["uploadId"] == REMOTE_ID
                part = int(args["partNumber"])
                if owner.endswith("/abort-race"):
                    with self.lock:
                        type(self).held += 1
                    assert self.release.wait(12)
                    return self.respond(200, ETag=f'"local-{part}"')
                with self.lock:
                    self.retry[owner, part] += 1
                    if owner == PATH and part == 1 and self.retry[owner, part] == 1:
                        return self.respond(503)
                    self.uploads[owner][part] = payload
                return self.respond(200, ETag=f'"local-{part}"')
            with self.lock:
                self.objects[owner] = payload
            return self.respond(200, ETag=ETAG)
        assert self.command == "POST"
        if "uploads" in args:
            with self.lock:
                assert owner not in self.uploads
                self.uploads[owner] = {}
            return self.respond(
                200, f"<InitiateMultipartUploadResult><UploadId>{REMOTE_ID}</UploadId></InitiateMultipartUploadResult>".encode(),
            )
        assert args["uploadId"] == REMOTE_ID and self.headers["Content-Type"] == "application/xml"
        root = ET.fromstring(payload)
        part_numbers = [int(item[0].text) for item in root]
        assert part_numbers == list(range(1, len(root) + 1))
        assert [item[1].text for item in root] == [f'"local-{p}"' for p in part_numbers]
        if owner.endswith("/finish-fails"):
            return self.respond(200, b"\r\n<Error><Code>InternalError</Code></Error>")
        if owner.endswith("/finish-malformed"):
            # A truncated success envelope on HTTP 200 must not be treated as a completed upload.
            return self.respond(200, b"<CompleteMultipartUploadResult><ETag>&quot;x&quot;</ETag>")
        with self.lock:
            data = self.uploads.pop(owner)
            assert all(len(data[number]) >= 5 * 1024 * 1024 for number in part_numbers[:-1])
            self.objects[owner] = b"".join(data[number] for number in part_numbers)
        return self.respond(
            200, b"<CompleteMultipartUploadResult><ETag>&quot;obj&amp;&amp;etag&quot;</ETag></CompleteMultipartUploadResult>",
            **{"x-amz-version-id": "rev/1+"},
        )

    def serve_request(self):
        try:
            payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            owner, args = self.check(payload)
            if args.get("X-Amz-Signature"):
                self.requests["presign"] += 1
            self.requests[self.command, owner] += 1
            self.handle_operation(owner, args, payload)
        except Exception as error:
            if isinstance(error, (BrokenPipeError, ConnectionResetError)) and "/abort-race?" in self.path:
                return
            self.errors.append(repr(error))
            self.respond(400)

    do_GET = do_HEAD = do_PUT = do_POST = do_DELETE = serve_request


def main():
    with ThreadingHTTPServer(("127.0.0.1", 0), Peer) as server:
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.run(sys.argv[1:], check=False, timeout=180, env={
                **os.environ, "FLINT_S3_TEST_URL": f"http://127.0.0.1:{server.server_port}",
                "FLINT_S3_TEST_ABORT": "1",
            })
        finally:
            server.shutdown()
            thread.join()
    if result.returncode or Peer.errors:
        raise SystemExit(f"linked S3 fixture failed: exit={result.returncode}, peer={Peer.errors}")
    assert Peer.retry[PATH, 1] == 2
    assert Peer.requests["DELETE", "/flint-test/finish-fails"] == 1
    assert Peer.requests["POST", "/flint-test/finish-malformed"] == 2
    assert Peer.requests["DELETE", "/flint-test/finish-malformed"] == 1
    assert Peer.requests["PUT", "/flint-test/empty"] == 1
    assert Peer.requests["POST", "/flint-test/empty"] == 0
    assert Peer.requests["presign"] == 1
    assert Peer.held == 4 and Peer.requests["DELETE", "/flint-test/abort-race"] == 2
    assert not Peer.uploads
    print("Verified SigV4, exact key encoding, retry, ordered completion, range, embedded errors, empty PUT and four-part abort")


if __name__ == "__main__":
    main()
