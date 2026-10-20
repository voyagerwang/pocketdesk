#!/usr/bin/env python3
"""
[INPUT]: 已安装本次加固版本的 PocketDesk HTTP/WS 端口；只读响应与固定错误凭证。
[OUTPUT]: HTTP鉴权/同源/响应头和错误WS凭证拒绝的状态断言，仅输出检查名与通过状态。
[POS]: 部署后的入口验收；不读配对文件、不输出页面/二维码/任务正文，不发正确凭证或控制命令。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import argparse
import base64
import json
import os
import socket
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description="仅在入口加固版本部署后运行；不对旧版进行畸形报文或画面认证探测。")
    parser.add_argument("--base-url", default="http://127.0.0.1:46387")
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    target = urllib.parse.urlsplit(base)
    assert target.scheme == "http" and target.hostname in ("127.0.0.1", "localhost", "::1") and target.port
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    count = 0

    def check(condition, name):
        nonlocal count
        assert condition, "FAIL " + name
        count += 1
        print("PASS " + name)

    def get(path, headers=None, url=base):
        try:
            response = opener.open(urllib.request.Request(url + path, headers=headers or {}), timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            return response.code, response.headers, response.read(1024 * 1024)

    code, headers, body = get("/api/status")
    check(code == 200, "trusted loopback status")
    status = json.loads(body)
    check(headers.get("X-Frame-Options") == "DENY"
          and "frame-ancestors 'none'" in headers.get("Content-Security-Policy", "")
          and headers.get("X-Content-Type-Options") == "nosniff"
          and headers.get("Cross-Origin-Resource-Policy") == "same-origin"
          and headers.get("Referrer-Policy") == "no-referrer", "browser response protections")
    check(get("/console")[0] == 200, "trusted console")
    check(get("/api/console/mijia/status")[0] == 200, "trusted mijia status")
    check(get("/api/status", {"Host": "audit.invalid:" + str(target.port), "Origin": "http://audit.invalid:" + str(target.port)})[0] == 403,
          "DNS rebind status denied")
    check(get("/api/status", {"Origin": "http://audit.invalid"})[0] == 403, "cross-origin status denied")
    check(get("/api/qr", {"Host": "audit.invalid:" + str(target.port)})[0] == 403, "unknown Host QR denied")
    check(get("/api/qr", {"Sec-Fetch-Site": "cross-site"})[0] == 403, "cross-site image QR denied without Origin")
    check(get("/api/v1/tasks")[0] == 401, "unpaired task read denied")
    lan = status.get("ipURL")
    check(isinstance(lan, str) and urllib.parse.urlsplit(lan).port == target.port, "LAN address available")
    check(get("/api/qr", url=lan)[0] == 403, "unpaired LAN QR denied")
    check(get("/api/status", url=lan)[0] == 401, "unpaired LAN status denied")
    check(get("/api/focus-probe", url=lan)[0] == 401, "unpaired LAN focus read denied")
    check(get("/api/icon?id=..%2F..%2Fsecurity-audit-missing", url=lan)[0] == 404, "icon path traversal denied")

    # 不发送有效请求体；检查已修复的分帧入口直接拒绝，不能触发任何业务写入。
    with socket.create_connection((target.hostname, target.port), timeout=5) as conn:
        conn.sendall(("POST /audit-invalid HTTP/1.1\r\nHost: " + target.netloc + "\r\nContent-Length: -1\r\n\r\n").encode())
        response = conn.recv(1024)
        check(response.startswith(b"HTTP/1.1 400 "), "negative request length rejected")

    def denied_ws(port, payload):
        with socket.create_connection((target.hostname, port), timeout=5) as conn:
            key = base64.b64encode(os.urandom(16)).decode()
            request = (f"GET / HTTP/1.1\r\nHost: {target.hostname}:{port}\r\nUpgrade: websocket\r\n"
                       f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                       "Origin: http://audit.invalid\r\n\r\n")
            conn.sendall(request.encode())
            response = b""
            while b"\r\n\r\n" not in response:
                block = conn.recv(4096)
                if not block:
                    return True
                response += block
            if not response.startswith(b"HTTP/1.1 101 "):
                return True
            body = json.dumps(payload, separators=(",", ":")).encode()
            assert len(body) < 126
            mask = os.urandom(4)
            frame = bytes((0x81, 0x80 | len(body))) + mask + bytes(x ^ mask[i % 4] for i, x in enumerate(body))
            conn.sendall(frame)
            try:
                reply = conn.recv(4096)
            except ConnectionResetError:
                return True
            return not reply or (reply[0] & 0x0f) == 8

    check(denied_ws(target.port + 1, {"t": "auth", "token": "invalid-security-audit-token", "v": 1}),
          "loopback control WS rejects invalid token")
    # 前一项若失败立即退出，避免对旧版继续发起画面请求；错误token必须先于采集校验。
    check(denied_ws(target.port + 2, {"t": "watch", "token": "invalid-security-audit-token", "display": 0}),
          "loopback frame WS rejects invalid token")
    print(f"Security entrypoints: {count} checks passed; no valid credential or device command sent")


if __name__ == "__main__":
    main()
