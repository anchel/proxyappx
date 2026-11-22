#!/usr/bin/env python3
"""开发用的最小 SOCKS5 服务器（只支持无认证 CONNECT），会打印每个经过它的连接。

用法：python3 scripts/dev-socks5.py [端口，默认 1080]

在 ProxyAppX 里添加服务器 127.0.0.1:1080（SOCKS5），给某个应用加代理规则，
就能在这里看到该应用的连接，用来验证分流是否生效。
"""
import select
import socket
import struct
import sys
import threading
import time


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("closed")
        buf += chunk
    return buf


def relay(a, b):
    socks = [a, b]
    while True:
        r, _, _ = select.select(socks, [], [], 300)
        if not r:
            return
        for s in r:
            data = s.recv(65536)
            if not data:
                return
            (b if s is a else a).sendall(data)


def handle(client, addr):
    upstream = None
    try:
        ver, n = recv_exact(client, 2)
        recv_exact(client, n)
        client.sendall(b"\x05\x00")
        ver, cmd, _, atyp = recv_exact(client, 4)
        if atyp == 1:
            host = socket.inet_ntop(socket.AF_INET, recv_exact(client, 4))
        elif atyp == 4:
            host = socket.inet_ntop(socket.AF_INET6, recv_exact(client, 16))
        else:
            host = recv_exact(client, recv_exact(client, 1)[0]).decode()
        port = struct.unpack("!H", recv_exact(client, 2))[0]
        if cmd != 1:
            client.sendall(b"\x05\x07\x00\x01" + b"\x00" * 6)
            log(f"拒绝命令 {cmd} -> {host}:{port}")
            return
        try:
            upstream = socket.create_connection((host, port), timeout=10)
            upstream.settimeout(None)
        except OSError as e:
            client.sendall(b"\x05\x05\x00\x01" + b"\x00" * 6)
            log(f"✗ {host}:{port} 连接失败：{e}")
            return
        client.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)
        log(f"✓ CONNECT {host}:{port}（来自 {addr[0]}:{addr[1]}）")
        relay(client, upstream)
    except Exception:
        pass
    finally:
        client.close()
        if upstream:
            upstream.close()


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 1080
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(128)
    log(f"SOCKS5 测试服务器监听 127.0.0.1:{port}")
    while True:
        c, a = srv.accept()
        threading.Thread(target=handle, args=(c, a), daemon=True).start()


if __name__ == "__main__":
    main()
