"""
[INPUT]: 完整手机 Web 页面、Playwright 与隔离 HTTP/WebSocket 替身。
[OUTPUT]: 验证首次状态失败后无需刷新即恢复接收者/任务初始化，既有草稿保留，后续断线恢复不重放输入，WS 关闭不虚报就绪。
[POS]: 手机连接编排的真实浏览器回归；所有网络截留，不连接生产服务或操控桌面。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import mimetypes
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
flags = {'initial_failure': True, 'down': False}
requests, writes, errors = [], [], []

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True)
    page.on('pageerror', lambda error: errors.append(str(error)))
    page.add_init_script("""
      localStorage.setItem('voicedeck.pair-token', 'connection-fixture');
      class FixtureSocket {
        constructor() { this.readyState = 0; this.bufferedAmount = 0; window.fixtureSocket = this;
          setTimeout(() => { this.readyState = 1; this.onopen?.({}); }, 0); }
        send() {}
        close() { this.readyState = 3; this.onclose?.({}); }
        authenticate() { this.onmessage?.({data: JSON.stringify({t:'auth_ok',session:'fixture',controller:true})}); }
      }
      window.WebSocket = FixtureSocket;
    """)

    def route(r):
        path = urlparse(r.request.url).path
        if path.startswith('/api/'):
            requests.append(path)
            if r.request.method != 'GET' and path not in ['/api/pair', '/api/v1/sprite/session']:
                writes.append(path)
            if path == '/api/status':
                assert r.request.headers.get('authorization') == 'Bearer connection-fixture'
                if flags['initial_failure'] or flags['down']:
                    return r.fulfill(status=503, json={'error': 'fixture service waking'})
                return r.fulfill(json={'targets': [{'id': 'editor', 'name': '编辑器'}], 'shortcuts': [],
                                      'accessibility': True, 'theme': 'classic', 'frontmostId': 'editor', 'frontmostName': '编辑器'})
            if path == '/api/recipients':
                return r.fulfill(json={'order': ['__sprite__', 'editor']})
            if path == '/api/v1/tasks':
                return r.fulfill(json={'tasks': []})
            if path == '/api/v1/phone-files':
                return r.fulfill(json={'files': []})
            return r.fulfill(json={'ok': True, 'locked': False})
        target = ROOT / 'Web' / (path.lstrip('/') or 'index.html')
        if target.is_file():
            return r.fulfill(body=target.read_bytes(), content_type=mimetypes.guess_type(target)[0] or 'text/plain')
        r.fulfill(status=404, body='fixture missing')

    page.route('**/*', route)
    page.goto('http://pocketdesk.test/', wait_until='domcontentloaded')
    page.wait_for_function('heartbeatFailures > 0')
    assert 'HTTP 503' in page.locator('#message').inner_text()
    page.locator('#text').fill('断线时保留的草稿')
    flags['initial_failure'] = False
    page.wait_for_function('connectionInitialized === true')
    page.locator('[data-target-id="editor"]').wait_for()
    page.wait_for_function('typeof pocketdeskAgent?.recoverActive === "function"')
    assert '/api/recipients' in requests and '/api/v1/tasks' in requests
    assert page.locator('#text').input_value() == '断线时保留的草稿'
    assert page.locator('#connection').inner_text() == '控制连接中'
    assert page.evaluate('selected') is None, '首次失败期间新增草稿不得被自动绑定到恢复时的电脑前台'
    assert '/api/pair' in requests, '首次恢复应即时登记手机在线'
    page.evaluate('fixtureSocket.authenticate()')
    assert page.locator('#connection').inner_text() == '已就绪'

    page.locator('[data-target-id="__sprite__"]').click()
    flags['down'] = True
    page.evaluate('() => { heartbeatTick(); }')
    page.wait_for_function('heartbeatFailures >= 2')
    assert page.locator('#text').input_value() == '断线时保留的草稿'
    flags['down'] = False
    page.locator('#message').click()
    page.wait_for_function('heartbeatFailures === 0 && httpDown === false')
    assert page.locator('#text').input_value() == '断线时保留的草稿'
    assert page.evaluate('selected') == '__sprite__'
    page.evaluate('fixtureSocket.close()')
    assert page.locator('#connection').inner_text() == '控制连接中'
    assert not writes, '连接恢复不得发桌面输入或提交任务：' + str(writes)
    assert not errors, '完整页面不得出现脚本错误：' + str(errors)
    browser.close()
print('connection browser: first failure recovery, complete initialization, draft preservation, zero input replay, truthful WS state passed')
