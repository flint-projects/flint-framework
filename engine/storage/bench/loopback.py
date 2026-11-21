#!/usr/bin/env python3
"""Serve one signed 1 GiB object with bounded memory and record the client RSS."""
from argparse import ArgumentParser
from hashlib import sha256
from hmac import compare_digest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
from traceback import extract_tb
from threading import Barrier, BrokenBarrierError, Event, Lock, Thread
from urllib.parse import parse_qsl, urlsplit
from xml.etree import ElementTree

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from local_peer import escaped, signature

STRIPE = 64 * 1024
PART = 8 * 1024 * 1024
COUNT = 128
OBJECT = PART * COUNT
CONCURRENT = 4
ROUNDS = PART // STRIPE
PATH = "/flint-test/storage-probe"
UPLOAD = "storage-fixture-upload"
S3 = "{http://s3.amazonaws.com/doc/2006-03-01/}"
ETAG = '"storage-fixture-object"'
PATTERN = bytes(range(256)) * 256


def pattern(part):
    return bytes([part]) + PATTERN[1:]


def part_tag(part):
    return f'"fixture-part-{part}"'


class Object:
    def __init__(self):
        self.lock = Lock()
        self.first_wave = Barrier(CONCURRENT, timeout=10)
        self.received = {}
        self.errors = []
        self.action = []
        self.active = 0
        self.peak = 0
        self.uploaded = 0
        self.downloaded = 0
        self.complete = False
        self.download_done = Event()


class Peer(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def authenticate(self, path, query, digest):
        header = self.headers["Authorization"]
        algorithm, names = header.split(" ", 1)
        assert algorithm == "AWS4-HMAC-SHA256"
        fields = dict(field.strip().split("=", 1) for field in names.split(","))
        access, scope = fields["Credential"].split("/", 1)
        assert access == "fixture-access"
        date = self.headers["X-Amz-Date"]
        assert date.startswith(scope.split("/", 1)[0])
        assert scope.split("/")[1] == "us-east-1"
        assert self.headers["X-Amz-Security-Token"] == "fixture-session"
        assert self.headers["X-Amz-Content-Sha256"] == digest
        signed = fields["SignedHeaders"]
        headers = signed.split(";")
        assert headers == sorted(set(headers))
        assert {"host", "x-amz-date", "x-amz-security-token"}.issubset(headers)
        canonical_headers = "".join(f"{name}:{' '.join(self.headers[name].split())}\n" for name in headers)
        canonical_query = "&".join(key + "=" + value
                                  for key, value in sorted((escaped(k), escaped(v)) for k, v in query))
        canonical = "\n".join((self.command, path, canonical_query, canonical_headers, signed, digest))
        assert compare_digest(signature(date, scope, canonical), fields["Signature"]), "signature mismatch"

    def respond(self, code, body=b"", **headers):
        self.send_response(code)
        for name, value in headers.items():
            self.send_header(name, value)
        if "Content-Length" not in headers:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def transfer_part(self, query, args, length):
        state = self.server.object
        assert set(args) == {"partNumber", "uploadId"} and args["uploadId"] == UPLOAD
        assert length == PART
        part = int(args["partNumber"])
        assert 1 <= part <= COUNT
        with state.lock:
            assert state.action == ["begin"] and part not in state.received
            state.active += 1
            state.peak = max(state.peak, state.active)
            assert state.active <= CONCURRENT
        try:
            expected = pattern(part)
            digest = sha256()
            for _ in range(ROUNDS):
                stripe = self.rfile.read(STRIPE)
                assert stripe == expected
                digest.update(stripe)
            self.authenticate(PATH, query, digest.hexdigest())
            with state.lock:
                assert part not in state.received
                state.received[part] = digest.digest()
                state.uploaded += length
            if part <= CONCURRENT:
                state.first_wave.wait()
        finally:
            with state.lock:
                state.active -= 1
        self.respond(200, ETag=part_tag(part))

    def commit(self, payload):
        state = self.server.object
        assert state.action == ["begin"] and len(state.received) == COUNT
        document = ElementTree.fromstring(payload)
        assert document.tag == S3 + "CompleteMultipartUpload"
        assert [(int(item.findtext(S3 + "PartNumber")), item.findtext(S3 + "ETag")) for item in document] == [
            (part, part_tag(part)) for part in range(1, COUNT + 1)
        ]
        assert state.uploaded == OBJECT
        state.action.append("complete")
        state.complete = True
        self.respond(200, (f"<CompleteMultipartUploadResult><ETag>{ETAG}</ETag>"
                           "</CompleteMultipartUploadResult>").encode())

    def download(self):
        state = self.server.object
        assert state.action == ["begin", "complete"] and state.complete
        self.respond(200, **{"Content-Length": str(OBJECT), "ETag": ETAG})
        total = 0
        for part in range(1, COUNT + 1):
            block = pattern(part)
            digest = sha256()
            for _ in range(ROUNDS):
                self.wfile.write(block)
                digest.update(block)
                total += len(block)
            assert digest.digest() == state.received[part]
        state.downloaded = total
        state.action.append("download")
        state.download_done.set()

    def request_(self):
        state = self.server.object
        try:
            url = urlsplit(self.path)
            assert url.path == PATH and not url.fragment
            query = parse_qsl(url.query, keep_blank_values=True, strict_parsing=True)
            args = dict(query)
            assert len(query) == len(args)
            length = int(self.headers.get("Content-Length", "0"))
            if self.command == "PUT":
                self.transfer_part(query, args, length)
                return
            assert 0 <= length <= 64 * 1024
            payload = self.rfile.read(length)
            assert len(payload) == length
            self.authenticate(PATH, query, sha256(payload).hexdigest())
            if self.command == "POST" and args == {"uploads": ""}:
                assert not state.action
                state.action.append("begin")
                self.respond(200, (f"<InitiateMultipartUploadResult><UploadId>{UPLOAD}</UploadId>"
                                   "</InitiateMultipartUploadResult>").encode())
            elif self.command == "POST" and args == {"uploadId": UPLOAD}:
                self.commit(payload)
            elif self.command == "GET" and not args:
                self.download()
            elif self.command == "DELETE" and not args:
                assert state.download_done.wait(10), "response delivery did not finish"
                assert state.action == ["begin", "complete", "download"] and state.complete
                state.complete = False
                state.action.append("remove")
                self.respond(204)
            else:
                raise AssertionError("unexpected Storage request")
        except (AssertionError, ValueError, OSError, BrokenBarrierError) as error:
            failure = extract_tb(error.__traceback__)[-1]
            state.errors.append(f"{self.command}: {type(error).__name__} {failure.name}:{failure.lineno} {error}")
            self.close_connection = True
            self.respond(400, Connection="close")

    do_GET = do_DELETE = do_POST = do_PUT = request_


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    obj = Object()
    with ThreadingHTTPServer(("127.0.0.1", 0), Peer) as server:
        server.object = obj
        server_thread = Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            result = subprocess.run([args.binary.resolve()], check=False, timeout=150, env={
                **os.environ, "FLINT_STORAGE_BENCH_URL": f"http://127.0.0.1:{server.server_port}",
            })
        finally:
            server.shutdown()
            server_thread.join()
    assert result.returncode == 0, (result.returncode, obj.action, obj.uploaded, obj.errors)
    assert not obj.errors and not obj.complete
    assert obj.action == ["begin", "complete", "download", "remove"]
    assert len(obj.received) == COUNT and obj.uploaded == obj.downloaded == OBJECT
    assert obj.active == 0 and obj.peak == CONCURRENT
    print(json.dumps({"peer_bytes_uploaded": obj.uploaded, "peer_bytes_downloaded": obj.downloaded,
                      "peer_peak_parts": obj.peak, "client_peak_rss_kib": resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
                      "peer_peak_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}))


if __name__ == "__main__":
    main()
