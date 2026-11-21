#!/usr/bin/env python3
"""Run the storage suite against a disposable, loopback-only MinIO process."""
from datetime import datetime, timezone
from http.client import HTTPConnection
import os
from pathlib import Path
import socket
import subprocess
import sys
from tempfile import TemporaryDirectory
from time import monotonic, sleep

from local_peer import EMPTY_HASH, signature


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def create_bucket(number, process):
    connection = HTTPConnection("127.0.0.1", number, timeout=2)
    try:
        deadline = monotonic() + 20
        while monotonic() < deadline and process.poll() is None:
            try:
                connection.request("GET", "/minio/health/ready")
                response = connection.getresponse()
                response.read()
                if response.status == 200:
                    break
            except OSError:
                connection.close()
            sleep(0.1)
        else:
            raise RuntimeError("MinIO did not become ready")
        path = "/flint-test"
        date = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        scope = date[:8] + "/us-east-1/s3/aws4_request"
        headers = {
            "host": f"127.0.0.1:{number}", "x-amz-content-sha256": EMPTY_HASH, "x-amz-date": date,
        }
        names = ";".join(headers)
        canonical = "".join(f"{name}:{value}\n" for name, value in headers.items())
        digest = signature(date, scope, "\n".join(("PUT", path, "", canonical, names, EMPTY_HASH)))
        headers["Authorization"] = (
            f"AWS4-HMAC-SHA256 Credential=fixture-access/{scope},SignedHeaders={names},Signature={digest}"
        )
        while monotonic() < deadline and process.poll() is None:
            connection.request("PUT", path, body=b"", headers=headers)
            response = connection.getresponse()
            payload = response.read()
            if response.status == 200:
                return
            if response.status != 503 or b"XMinioServerNotInitialized" not in payload:
                raise RuntimeError(f"MinIO fixture bucket creation returned {response.status}: {payload!r}")
            sleep(0.1)
        raise RuntimeError("MinIO did not initialize its object store")
    finally:
        connection.close()


def main():
    binary, *command = sys.argv[1:]
    number, console = port(), port()
    while console == number:
        console = port()
    with TemporaryDirectory(prefix="flint-minio-") as directory:
        root = Path(directory)
        (root / "certs").mkdir()
        with (root / "server.log").open("w+") as log:
            process = subprocess.Popen([
                binary, "server", "--address", f"127.0.0.1:{number}", "--console-address", f"127.0.0.1:{console}",
                "--certs-dir", str(root / "certs"), str(root / "data"),
            ], stdout=log, stderr=subprocess.STDOUT, env={
                **os.environ, "MINIO_ROOT_USER": "fixture-access", "MINIO_ROOT_PASSWORD": "fixture-secret",
                "MINIO_BROWSER": "off", "MINIO_UPDATE": "off",
            })
            try:
                create_bucket(number, process)
                subprocess.run(command, check=True, timeout=180, env={
                    **os.environ, "FLINT_S3_MINIO_URL": f"http://127.0.0.1:{number}",
                })
            except Exception:
                log.seek(0)
                print(log.read(), file=sys.stderr)
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    print("The MinIO fixture command completed successfully")


if __name__ == "__main__":
    main()
