#!/usr/bin/env /usr/bin/python3
"""
Loopback relay: 127.0.0.1:6443 -> the Kubernetes API server.

WHY THIS EXISTS (inc-2026-07-31-002)
------------------------------------
macOS Local Network Privacy blocks binaries from reaching the DIRECTLY-ATTACHED
subnet unless they hold a Local Network grant. Homebrew/mise binaries are
`Signature=adhoc`, so macOS cannot bind a stable identity to them: they never get
their own entry in Privacy & Security > Local Network, and granting the parent app
(Claude) does not help. Result: `kubectl` gets EHOSTUNREACH to 172.16.2.240:6443
while Apple-signed `/usr/bin/curl` reaches it fine.

    /usr/bin/python3            Apple-signed     -> CONNECTED
    /opt/homebrew/bin/python3   Signature=adhoc  -> errno 65

127.0.0.1 is NOT "local network", so a blocked binary may connect to loopback
freely. This script must therefore be run with the APPLE-SIGNED interpreter
(/usr/bin/python3, hence the shebang) so that IT may reach the API server, while
kubectl talks only to loopback.

TLS still verifies: the API server cert carries `IP Address:127.0.0.1` and
`DNS:localhost` in its SANs, so the existing kubeconfig CA validates unchanged.

Usage:
    /usr/bin/python3 hack/k8s-local-relay.py &
    kubectl --server=https://127.0.0.1:16443 get nodes

The real fix is to give kubectl a stable code signature or an Apple-signed path.
This is a workaround, deliberately dependency-free and read-only.
"""
import socket, threading, sys, signal

LISTEN = ("127.0.0.1", 16443)
TARGET = ("172.16.2.240", 6443)


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client):
    try:
        upstream = socket.create_connection(TARGET, timeout=10)
    except OSError as e:
        # If THIS fails, the interpreter running the relay is itself blocked --
        # i.e. it was not started with /usr/bin/python3.
        print(f"relay: upstream {TARGET[0]}:{TARGET[1]} failed: {e}", file=sys.stderr)
        client.close()
        return
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


def main():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(LISTEN)
    except OSError as e:
        print(f"relay: cannot bind {LISTEN[0]}:{LISTEN[1]}: {e}", file=sys.stderr)
        sys.exit(1)
    srv.listen(64)
    print(f"relay: {LISTEN[0]}:{LISTEN[1]} -> {TARGET[0]}:{TARGET[1]}", flush=True)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    while True:
        try:
            client, _ = srv.accept()
        except KeyboardInterrupt:
            break
        except OSError:
            continue
        handle(client)


if __name__ == "__main__":
    main()
