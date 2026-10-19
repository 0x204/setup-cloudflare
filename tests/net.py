#!/usr/bin/env python3
"""Socket helpers for tests/run.sh.

    net.py listen tcp:443 udp:443 ...      serve until killed (UDP echoes)
    net.py probe tcp|udp SRC DST PORT      exit 0 if reachable, 1 on timeout, 2 if refused

Listeners accept IPv4 and IPv6 when the kernel has IPv6, IPv4 otherwise.
"""
import socket
import sys
import threading

DUAL_STACK = socket.has_dualstack_ipv6()


def serve_tcp(port):
    if DUAL_STACK:
        server = socket.create_server(("::", port), family=socket.AF_INET6, dualstack_ipv6=True)
    else:
        server = socket.create_server(("0.0.0.0", port))
    while True:
        conn, _ = server.accept()
        conn.close()


def serve_udp(port):
    if DUAL_STACK:
        server = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        server.bind(("::", port))
    else:
        server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        server.bind(("0.0.0.0", port))
    while True:
        data, peer = server.recvfrom(64)
        server.sendto(data, peer)


def listen(specs):
    serve = {"tcp": serve_tcp, "udp": serve_udp}
    for spec in specs:
        proto, port = spec.split(":")
        threading.Thread(target=serve[proto], args=(int(port),), daemon=True).start()
    threading.Event().wait()


def probe(proto, src, dst, port):
    family = socket.AF_INET6 if ":" in dst else socket.AF_INET
    kind = socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM
    with socket.socket(family, kind) as sock:
        sock.settimeout(1)
        sock.bind((src, 0))
        try:
            sock.connect((dst, int(port)))
            if proto == "udp":
                sock.send(b"ping")
                sock.recv(64)
        except socket.timeout:
            return 1
        except OSError:
            return 2
    return 0


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    if command == "listen":
        listen(args)
    else:
        sys.exit(probe(*args))
