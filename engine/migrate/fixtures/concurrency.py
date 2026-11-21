#!/usr/bin/env python3
"""Exercise two independent startup processes against the same native database."""
import argparse
import hashlib
import selectors
import subprocess
import tempfile
import time
from pathlib import Path


def run(command, mode, *, success=True):
    result = subprocess.run([*command, mode], check=False, capture_output=True, text=True, timeout=15)
    assert (result.returncode == 0) == success, result
    return result.stdout.strip()


def concurrent(command):
    processes = [
        subprocess.Popen([*command, "apply"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        for _ in range(2)
    ]
    try:
        results = []
        for process in processes:
            output, errors = process.communicate(timeout=15)
            assert process.returncode == 0, (output, errors)
            results.append(output.strip())
        assert sorted(results) == ["applied=0 current=3", "applied=2 current=3"], results
        assert run(command, "check") == "4"
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.communicate()


def timeout(command):
    with subprocess.Popen([*command, "hold"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True) as holder:
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(holder.stdout, selectors.EVENT_READ)
                assert selector.select(8), "lock holder did not become ready"
            assert holder.stdout.readline().strip() == "locked"
            assert run(command, "short") == "timeout-cleanup"
        finally:
            holder.communicate("\n", timeout=8)
        assert holder.returncode == 0
    assert run(command, "apply") == "applied=0 current=3"


def crash(command):
    with subprocess.Popen([*command, "crash"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as worker:
        try:
            end = time.monotonic() + 3
            while run(command, "observe") != "1":
                assert worker.poll() is None and time.monotonic() < end, "durable marker not published"
                time.sleep(0.02)
            assert worker.poll() is None
        finally:
            worker.kill()
            worker.communicate()
    message = run(command, "crash", success=False)
    digest = hashlib.sha256(b"SELECT pg_sleep(4)").hexdigest()
    assert f"version 4 checksum {digest}" in message and "reconcile its history" in message, message
    assert run(command, "observe") == "1"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("worker", type=Path)
    parser.add_argument("--postgres", help="DSN for a disposable, empty PostgreSQL database")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="flint-migrate-") as temp:
        worker = str(args.worker.resolve())
        sqlite = [worker, "sqlite", str(Path(temp) / "current.sqlite")]
        failing = [worker, "sqlite", str(Path(temp) / "rollback.sqlite")]
        assert "migration version 2 failed" in run(failing, "fail", success=False)
        assert run(failing, "apply") == "applied=2 current=3"
        concurrent(sqlite)
        timeout(sqlite)
        print("sqlite: cross-process once, lock timeout, rollback passed")
        if args.postgres is not None:
            postgres = [worker, "postgres", args.postgres]
            concurrent(postgres)
            timeout(postgres)
            crash(postgres)
            print("postgres: cross-process once, lock timeout, crash marker passed")


if __name__ == "__main__":
    main()
