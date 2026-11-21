#!/usr/bin/env python3
"""Provision ephemeral durable pull consumers and verify broker-side results."""
import json
import socket
import ssl
import subprocess
import sys


class Admin:
    def __init__(self, address, cert):
        self.peer = socket.create_connection(address, timeout=5)
        greeting = b""
        while not greeting.endswith(b"\r\n"):
            field = self.peer.recv(1)
            assert field
            greeting += field
        assert greeting.startswith(b"INFO ")
        assert json.loads(greeting[5:])["jetstream"]
        if cert:
            self.peer = ssl.create_default_context(cafile=cert).wrap_socket(self.peer, server_hostname=address[0])
        self.input = self.peer.makefile("rb")
        self.peer.sendall(b'CONNECT {"verbose":false,"headers":true,"no_responders":true}\r\nPING\r\n')
        assert self.input.readline() == b"PONG\r\n"
        self.serial = 0

    def request(self, subject, params):
        self.serial += 1
        inbox = f"_INBOX.FLINT.ADMIN.{self.serial}".encode()
        sid = str(self.serial).encode()
        subject = subject.encode()
        data = json.dumps(params).encode()
        self.peer.sendall(b"SUB " + inbox + b" " + sid + b"\r\nUNSUB " + sid + b" 1\r\nPUB " + subject
                          + b" " + inbox + b" " + str(len(data)).encode() + b"\r\n" + data + b"\r\n")
        for _ in range(10):
            line = self.input.readline()
            if line == b"PING\r\n":
                self.peer.sendall(b"PONG\r\n")
                continue
            parts = line.split()
            assert parts[0] == b"MSG" and parts[1] == inbox and parts[2] == sid, line
            payload = self.input.read(int(parts[-1]))
            assert self.input.read(2) == b"\r\n"
            decoded = json.loads(payload)
            assert "error" not in decoded, decoded
            return decoded
        raise AssertionError("broker omitted the API response")

    def close(self):
        self.input.close()
        self.peer.close()


def verify(client, port, certificate):
    daemon = Admin(("127.0.0.1", port), certificate)
    try:
        for stream, subject in (("ORDERS", "flint.orders"), ("DEAD", "flint.dead"), ("TYPES", "flint.types")):
            daemon.request(f"$JS.API.STREAM.CREATE.{stream}",
                           {"name": stream, "subjects": [subject], "storage": "file", "num_replicas": 1})
        daemon.request("$JS.API.CONSUMER.DURABLE.CREATE.ORDERS.flint",
                       {"stream_name": "ORDERS", "config": {"durable_name": "flint", "ack_policy": "explicit",
                        "ack_wait": 500_000_000, "max_ack_pending": 1}})
        daemon.request("$JS.API.CONSUMER.DURABLE.CREATE.TYPES.typed",
                       {"stream_name": "TYPES", "config": {"durable_name": "typed", "ack_policy": "explicit"}})
        address = f"{'tls' if certificate else 'nats'}://127.0.0.1:{port}"
        subprocess.run([client, address, *([certificate] if certificate else [])], check=True, timeout=25)
        if certificate:
            subprocess.run([client, address, "--untrusted"], check=True, timeout=8)
        delivery = daemon.request("$JS.API.CONSUMER.INFO.ORDERS.flint", {})
        assert delivery["ack_floor"]["stream_seq"] == 2 and delivery["num_ack_pending"] == 0, delivery
        typed = daemon.request("$JS.API.CONSUMER.INFO.TYPES.typed", {})
        assert typed["ack_floor"]["stream_seq"] == 1, typed
        dead_letters = daemon.request("$JS.API.STREAM.INFO.DEAD", {})
        orders = daemon.request("$JS.API.STREAM.INFO.ORDERS", {})
        assert dead_letters["state"]["messages"] == 1 and orders["state"]["messages"] == 2
        print(f"JetStream {'verified TLS' if certificate else 'loopback'} ack_floor=2 ack_pending=0 orders=2 dead_letters=1")
    finally:
        daemon.close()


if __name__ == "__main__":
    verify(sys.argv[1], int(sys.argv[2]), sys.argv[3] if len(sys.argv) == 4 else None)
