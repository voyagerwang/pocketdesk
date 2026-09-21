"""
[INPUT]: Swift fixture 二进制参数；Python 标准库真实 HTTP/socket 客户端。
[OUTPUT]: 验证生产文件路由鉴权、附件字节/文件名、换票/拒绝、断流重试、三路上限和超时后回收。
[POS]: 临时目录 + loopback 随机端口集成测试；不启动生产应用，不接触真实用户数据。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import http.client
import json
import socket
import subprocess
import sys
import tempfile
import time

with tempfile.TemporaryDirectory(prefix='pd-http-test-') as root:
    process = subprocess.Popen([sys.argv[1], root], stdout=subprocess.PIPE, text=True)
    sockets = []
    try:
        port = int(process.stdout.readline())
        base = '/api/v1/phone-files'
        def request(path=base, method='GET', token='fixture-token'):
            client = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            headers = {} if token is None else {'Authorization': 'Bearer ' + token}
            client.request(method, path, headers=headers)
            response = client.getresponse()
            result = response.status, dict(response.getheaders()), response.read()
            client.close()
            return result
        def accept(file):
            status, _, body = request(base + '/' + file['id'] + '/accept', 'POST')
            assert status == 200
            return json.loads(body)['url']
        for token in [None, 'wrong']:
            assert request(token=token)[0] == 401
        files = json.loads(request()[2])['files']
        small = next(f for f in files if f['name'].startswith('测试'))
        empty = next(f for f in files if f['name'] == 'empty.txt')
        large = next(f for f in files if f['name'] == 'large.bin')
        for action in ['accept', 'dismiss']:
            assert request(base + '/' + small['id'] + '/' + action, 'POST', None)[0] == 401
        assert request(base + '/download/forged', token=None)[0] == 422
        assert request(base + '/download/../../etc/passwd', token=None)[0] == 422
        url = accept(small)
        head_status, head_headers, head_body = request(url, method='HEAD', token=None)
        assert head_status == 200 and head_body == b'' and int(head_headers['Content-Length']) > 0
        status, headers, body = request(url, token=None)
        assert status == 200 and body == 'hello 手机\n'.encode()
        assert "filename*=UTF-8''%E6%B5%8B%E8%AF%95%20" in headers['Content-Disposition']
        assert headers['Cache-Control'] == 'no-store' and headers['X-Content-Type-Options'] == 'nosniff'
        assert request(accept(empty), token=None)[2] == b''
        new_url = accept(small)
        assert request(url, token=None)[0] == 422
        assert request(new_url, token=None)[0] == 200
        assert request(base + '/' + small['id'] + '/dismiss', 'POST')[0] == 200
        assert request(new_url, token=None)[0] == 422
        large_url = accept(large)
        def slow():
            sock = socket.socket()
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            sock.settimeout(5); sock.connect(('127.0.0.1', port))
            sock.sendall(('GET ' + large_url + ' HTTP/1.1\r\nHost: localhost\r\n\r\n').encode())
            assert sock.recv(512).startswith(b'HTTP/1.1 200')
            return sock
        aborted = slow(); aborted.close()
        time.sleep(.15)
        # 断流后可重试；三条慢流保持在途，第四条立即拒绝，列表仍可响应。
        sockets = [slow() for _ in range(3)]
        assert request(large_url, token=None)[0] == 503
        start = time.monotonic(); assert request()[0] == 200
        assert time.monotonic() - start < 1
        time.sleep(2.3)
        assert request(large_url, token=None)[0] == 200
        print('HTTP integration PASS: auth, bytes, Unicode, empty, rotation, dismiss, disconnect, 3-stream limit, timeout recovery')
    finally:
        for sock in sockets: sock.close()
        process.terminate(); process.wait(timeout=5)
