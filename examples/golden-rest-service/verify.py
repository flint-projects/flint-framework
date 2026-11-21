"""Check migration startup, DI dispatch and persisted data over real HTTP."""

import argparse
import http.client
import json
from pathlib import Path
import socket
import sqlite3
import subprocess
import tempfile
import time


def json_request(connection, method, path, expected, body=None):
    headers = {"Content-Type": "application/json"} if body is not None else {}
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    contents = response.read()
    assert response.status == expected, (method, path, response.status, contents)
    assert response.headers.get_content_type() == "application/json"
    return json.loads(contents)


def ready(process, client, endpoint):
    until = time.monotonic() + 10
    while process.poll() is None and time.monotonic() < until:
        try:
            # A terminated server's listener can still be reachable during kernel cleanup.
            json_request(client, "GET", f"{endpoint}/0", 404)
            return
        except OSError:
            client.close()
            time.sleep(0.02)
    raise AssertionError(f"HTTP endpoint unavailable, exit status {process.poll()}")


def exercise(executable, directory, port, existing=None):
    process = subprocess.Popen([executable, str(port)], cwd=directory)
    try:
        client = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            endpoint = "/api/users"
            ready(process, client, endpoint)
            if existing is not None:
                fetched = json_request(client, "GET", f"{endpoint}/{existing['id']}", 200)
                assert fetched == existing
                return existing
            json_request(client, "GET", f"{endpoint}/1", 404)
            json_request(client, "GET", f"{endpoint}/invalid", 400)
            json_request(client, "POST", endpoint, 400, b'{"displayName":')
            json_request(client, "POST", endpoint, 400, b'{"displayName":"  "}')
            created = json_request(client, "POST", endpoint, 201, '{"displayName":"Ada O\'Connor"}')
            assert created["id"] > 0 and created["displayName"] == "Ada O'Connor"
            found = json_request(client, "GET", f"{endpoint}/{created['id']}", 200)
            assert found == created
            return created
        finally:
            client.close()
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=4)


def check(executable):
    with tempfile.TemporaryDirectory(prefix="flint-golden-rest-") as directory:
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        user = exercise(executable, directory, port)
        exercise(executable, directory, port, user)
        with sqlite3.connect(Path(directory) / "users.db") as db:
            assert db.execute("SELECT id, display_name FROM users").fetchall() == [
                (user["id"], user["displayName"])
            ]
            db.execute("UPDATE flint_schema_history SET sha256 = ?", ("0" * 64,))
        rejected = subprocess.run([executable, str(port)], cwd=directory, timeout=5)
        assert rejected.returncode == 2, rejected.returncode
    print("invalid requests, persisted user, restart, and migration drift verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    check(str(args.executable.resolve(strict=True)))
