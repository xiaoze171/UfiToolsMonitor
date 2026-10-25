#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""MU5120 datad webshell 最小 WS 客户端
用法: python datad_ws.py "<命令>" [超时秒]
协议: WebSocket, 子协议 datad-auth.<token>, 端点 /api/webshell (9461)
"""
import base64, json, os, socket, struct, sys, urllib.request

HOST, PORT = "192.168.0.1", 9461

def get_token():
    req = urllib.request.Request(
        f"http://{HOST}:{PORT}/auth/login", method="POST",
        headers={"Authorization": "Basic " + base64.b64encode(b"admin:111111").decode()})
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.load(r)["access_token"]

def ws_connect(token, path="/webshell"):
    key = base64.b64encode(os.urandom(16)).decode()
    req = (f"GET {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n"
           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Authorization: Bearer {token}\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
           f"Sec-WebSocket-Protocol: datad-auth.{token}\r\n\r\n")
    s = socket.create_connection((HOST, PORT), timeout=10)
    s.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(4096)
        if not chunk:
            raise RuntimeError("连接被关闭: " + resp.decode(errors="replace"))
        resp += chunk
    head, _, rest = resp.partition(b"\r\n\r\n")
    status = head.split(b"\r\n")[0].decode()
    if "101" not in status:
        raise RuntimeError(f"握手失败: {status} | {head.decode(errors='replace')[:300]}")
    return s, rest

def send_text(s, text):
    payload = text.encode()
    mask = os.urandom(4)
    header = b"\x81"
    n = len(payload)
    if n < 126:
        header += struct.pack("!B", 0x80 | n)
    elif n < 65536:
        header += struct.pack("!BH", 0x80 | 126, n)
    else:
        header += struct.pack("!BHQ", 0x80 | 127, n)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    s.sendall(header + mask + masked)

def recv_frame(s, timeout=10):
    s.settimeout(timeout)
    def rd(n):
        buf = b""
        while len(buf) < n:
            c = s.recv(n - len(buf))
            if not c:
                raise ConnectionError("closed")
            buf += c
        return buf
    h = rd(2)
    opcode = h[0] & 0x0F
    ln = h[1] & 0x7F
    if ln == 126:
        ln = struct.unpack("!H", rd(2))[0]
    elif ln == 127:
        ln = struct.unpack("!Q", rd(8))[0]
    payload = rd(ln) if ln else b""
    if opcode == 8:
        raise ConnectionError("server closed")
    return opcode, payload

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "echo ok"
    timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    token = get_token()
    s, rest = ws_connect(token)
    # 可能握手响应附带首帧
    for attempt, msg in enumerate([json.dumps({"cmd": cmd, "timeout": timeout}),
                                   cmd]):
        try:
            send_text(s, msg)
            out = b""
            while True:
                op, pl = recv_frame(s, timeout=timeout)
                out += pl
                if len(out) > 60000:
                    break
                # 简单启发：收到数据后短等待再判定空闲
                s.settimeout(3)
                try:
                    op2, pl2 = recv_frame(s, 3)
                    out += pl2
                except (socket.timeout, TimeoutError):
                    break
            text = out.decode(errors="replace").strip()
            if text:
                print(text)
                return
        except (ConnectionError, socket.timeout, TimeoutError) as e:
            print(f"[尝试{attempt+1} 失败: {e}]", file=sys.stderr)
            try:
                s, rest = ws_connect(token)
            except Exception as e2:
                print(f"[重连失败: {e2}]", file=sys.stderr)
                return
    print("[无输出]")

if __name__ == "__main__":
    main()
