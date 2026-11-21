#!/usr/bin/env python3
"""Exercise the outbound client over h2c loopback and TLS with a pinned grpc-go peer."""
from pathlib import Path
import subprocess
import sys


def check(peer, descriptor, client, certificate, key):
    for secure in (False, True):
        identity = [certificate, key] if secure else []
        with subprocess.Popen([peer, descriptor, *identity], stdout=subprocess.PIPE, text=True) as server:
            try:
                address = server.stdout.readline().strip()
                assert address.startswith("127.0.0.1:"), address
                origin = f"{'https' if secure else 'http'}://{address}"
                client_args = [client, origin, *identity[:1]]
                print(f"{'TLS ALPN h2' if secure else 'loopback h2c'} {address}", flush=True)
                subprocess.run(client_args, check=True, timeout=32)
                if secure:
                    subprocess.run([client, origin, "--reject-untrusted"], check=True, timeout=8)
            finally:
                server.terminate()


if __name__ == "__main__":
    check(*(Path(arg).resolve() for arg in sys.argv[1:]))
