#!/usr/bin/env python3
"""Drive the pinned Autobahn fuzzing server with Flint as the WebSocket client."""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import subprocess
import time

from websockets.sync.client import connect

IMAGE = "crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074"
AGENT = "FlintOut"


def verify(client, output):
    output.mkdir(parents=True, exist_ok=True)
    reports = output / "reports"
    reports.mkdir(exist_ok=True)
    with socket.socket() as temp:
        temp.bind(("127.0.0.1", 0))
        port = temp.getsockname()[1]
    origin = f"ws://127.0.0.1:{port}"
    spec = output / "spec.json"
    spec.write_text(json.dumps({"outdir": "/reports", "url": origin, "cases": ["*"],
                                "exclude-cases": ["9.*", "12.*", "13.*"], "exclude-agent-cases": {}}, indent=2))
    name = f"flint-autobahn-client-{port}"
    command = ["docker", "run", "--rm", "--name", name, "--network=host", "--pull=never",
               "--user", f"{os.getuid()}:{os.getgid()}", "-v", f"{spec}:/config/local.json:ro",
               "-v", f"{reports}:/reports", IMAGE, "wstest", "--mode", "fuzzingserver",
               "--spec", "/config/local.json"]
    with (output / "server.log").open("w") as server_log:
        with subprocess.Popen(command, stdout=server_log, stderr=subprocess.STDOUT) as server:
            try:
                run_suite(client, output, origin, server)
            finally:
                subprocess.run(["docker", "stop", "-t", "1", name], check=False, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=5)


def run_suite(client, output, origin, server):
    deadline = time.monotonic() + 10
    while True:
        try:
            with connect(f"{origin}/getCaseCount", open_timeout=.3) as peer:
                count = int(peer.recv(timeout=1))
                break
        except OSError:
            if server.poll() is not None or time.monotonic() > deadline:
                raise
            time.sleep(.05)
    print(f"Autobahn selected {count} cases", flush=True)

    def run_case(case):
        url = f"{origin}/runCase?case={case}&agent={AGENT}"
        result = subprocess.run([client, "ws-suite", url], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=14)
        return case, result.returncode, result.stdout

    with ThreadPoolExecutor(max_workers=5) as work:
        all_cases = list(work.map(run_case, range(1, count + 1)))
    (output / "client-cases.json").write_text(json.dumps(all_cases, indent=2) + "\n")
    def case_status(case):
        with connect(f"{origin}/getCaseInfo?case={case}", open_timeout=2) as peer:
            info = json.loads(peer.recv(timeout=3))
        with connect(f"{origin}/getCaseStatus?case={case}&agent={AGENT}", open_timeout=2) as peer:
            status = json.loads(peer.recv(timeout=3))
        return info["id"], status["behavior"]

    with ThreadPoolExecutor(max_workers=5) as work:
        observed = dict(work.map(case_status, range(1, count + 1)))
    (output / "case-status.json").write_text(json.dumps(observed, indent=2) + "\n")
    print(Counter(observed.values()))
    failures = {case: status for case, status in observed.items() if status not in ("OK", "INFORMATIONAL")}
    print(failures)
    assert len(observed) == count
    assert all(code == 0 for _, code, _ in all_cases)
    assert not failures


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("client", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    verify(args.client.resolve(), args.output.resolve())
