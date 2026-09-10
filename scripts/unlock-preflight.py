#!/usr/bin/env python3
# [INPUT]: 依赖 Python 标准库与本机 TCP 5900 的 RFB 握手，不读取配置或凭据。
# [OUTPUT]: 输出 JSON 检测结果；只报告协议可达性，永不宣称已经解锁。
# [POS]: scripts 的一次性解锁通道探针；与应用、输入注入和密码处理隔离。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""用法：python3 scripts/unlock-preflight.py；不登录、不采集画面、不发按键。"""

import errno
import json
import re
import socket
import struct
import time


def receive(sock, count, deadline):
    """TCP 可分片；所有读取共用一个总期限，避免慢连接无限延长探测。"""
    data = bytearray()
    while len(data) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError()
        sock.settimeout(remaining)
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)


def handshake(sock):
    deadline = time.monotonic() + 3
    banner = receive(sock, 12, deadline)
    if not re.fullmatch(rb"RFB [0-9]{3}\.[0-9]{3}\n", banner):
        return {"status": "not_rfb"}
    version = banner[4:11].decode("ascii")
    major, minor = int(banner[4:7]), int(banner[8:11])
    if major != 3 or minor < 3:
        return {"status": "unsupported_version", "server_version": version}
    # Apple 可广播 3.889；探针只请求标准 3.8，不能据此断言支持 Apple 认证。
    negotiated = 8 if minor >= 8 else 7 if minor >= 7 else 3
    sock.sendall(f"RFB 003.{negotiated:03d}\n".encode("ascii"))
    if negotiated == 3:
        security_type = struct.unpack("!I", receive(sock, 4, deadline))[0]
        types = [security_type] if security_type else []
    else:
        count = receive(sock, 1, deadline)[0]
        types = list(receive(sock, count, deadline)) if count else []
    # 不选择认证类型；不读服务器自由文本，避免把不受控内容带进日志。
    return {
        "status": "rfb_advertised" if types else "server_rejected",
        "server_version": version,
        "security_types": types,
    }


def probe(host):
    result = {"host": host, "port": 5900, "unlock_verified": False}
    try:
        with socket.create_connection((host, 5900), timeout=3) as sock:
            result.update(handshake(sock))
    except ConnectionRefusedError:
        result["status"] = "connection_refused"
    except (TimeoutError, socket.timeout):
        result["status"] = "timeout"
    except EOFError:
        result["status"] = "incomplete_handshake"
    except OSError as error:
        result["status"] = "permission_denied" if error.errno in (errno.EPERM, errno.EACCES) else "network_error"
        result["errno"] = error.errno
    return result


if __name__ == "__main__":
    # 只连固定回环地址，不接受任意主机，不扫描网络。
    results = [probe(host) for host in ("127.0.0.1", "::1")]
    print(json.dumps({"checks": results, "unlock_verified": False}, ensure_ascii=False, indent=2))
    raise SystemExit(0 if any(item["status"] == "rfb_advertised" for item in results) else 1)
