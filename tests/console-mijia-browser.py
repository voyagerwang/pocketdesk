"""
[INPUT]: 完整控制台、米家 HTTP/图片/单户与双户家庭替身与 Playwright 浏览器。
[OUTPUT]: 真实点击核验连接/取消/重连/过期/检查、家庭显式保存与失败保留/换账号重选，图片与网络失败恢复及双主题窄屏截图。
[POS]: 米家控制台浏览器回归；全部请求严格截留，二维码为不可登录的合成图，不接触真实凭证或设备。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import mimetypes
import struct
import time
import zlib
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]


def fixture_image():
    """生成仅供版式验证的黑白矩阵，不编码任何账号、网址或授权。"""
    size, scale, quiet = 29, 8, 4
    modules = [[(x * 13 + y * 17 + x * y) % 5 < 2 for x in range(size)] for y in range(size)]
    for left, top in [(0, 0), (size - 7, 0), (0, size - 7)]:
        for y in range(-1, 8):
            for x in range(-1, 8):
                if 0 <= top + y < size and 0 <= left + x < size:
                    modules[top + y][left + x] = (0 <= x < 7 and 0 <= y < 7 and
                        (x in [0, 6] or y in [0, 6] or (2 <= x <= 4 and 2 <= y <= 4)))
    width = (size + quiet * 2) * scale
    rows = []
    for y in range(width):
        row = bytearray([0])
        for x in range(width):
            mx, my = x // scale - quiet, y // scale - quiet
            row.append(0 if 0 <= mx < size and 0 <= my < size and modules[my][mx] else 255)
        rows.append(bytes(row))
    def chunk(name, data):
        return struct.pack('!I', len(data)) + name + data + struct.pack('!I', zlib.crc32(name + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', width, width, 8, 0, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b'')


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 1100, 'height': 900})
    page.set_default_timeout(7000)
    errors, writes, qr_requests = [], [], []
    state = {'state': 'unconfigured', 'hasCredentials': False, 'qrReady': False, 'revision': 0}
    switches = {'image404': False, 'offline': False, 'theme': 'classic', 'sessions': 0, 'homeSaveFailure': False}
    scope = {'homes': [{'id': 'home-a', 'name': '上海的家'}, {'id': 'home-b', 'name': '杭州的家'}],
             'selectedHomeId': None, 'selectedHomeName': None, 'selectionRequired': True}
    image_bytes = fixture_image()
    page.on('pageerror', lambda error: errors.append(str(error)))

    def connected(message='米家账号已连接，请确认下方允许控制的家庭。'):
        state.clear()
        state.update(state='connected', message=message, hasCredentials=True, qrReady=False,
                     checkedAt=time.time(), deviceCount=20, revision=10)

    def route(request_route):
        request = request_route.request
        parsed = urlparse(request.url)
        path = parsed.path
        if path.startswith('/api/console/mijia/'):
            if path in ['/api/console/mijia/homes', '/api/console/mijia/home']:
                assert request.headers.get('x-pocketdesk-console') == '1'
                if path.endswith('/home'):
                    assert request.method == 'POST'
                    writes.append((path, request.post_data_json))
                    selected = next((home for home in scope['homes'] if home['id'] == request.post_data_json['homeId']), None)
                    assert selected, '不能保存清单以外的家庭'
                    if switches['homeSaveFailure']:
                        return request_route.fulfill(status=409, json={'error': '测试保存失败，请重试。'})
                    scope.update(selectedHomeId=selected['id'], selectedHomeName=selected['name'], selectionRequired=False)
                else:
                    assert request.method == 'GET'
                return request_route.fulfill(json=scope)
            if path.endswith('/qr'):
                qr_requests.append(request.url)
                assert parse_qs(parsed.query)['sessionId'][0] == state.get('sessionId')
                if switches['image404']:
                    return request_route.fulfill(status=404, body='expired')
                return request_route.fulfill(body=image_bytes, content_type='image/png', headers={'Cache-Control': 'no-store'})
            assert request.headers.get('x-pocketdesk-console') == '1'
            if switches['offline']:
                return request_route.fulfill(status=503, json={'error': '测试连接中断，请重试。'})
            if request.method == 'POST':
                writes.append((path, request.post_data_json))
                if path.endswith('/connect'):
                    saved = state['hasCredentials']
                    switches['sessions'] += 1
                    state.clear()
                    state.update(state='waiting', message='测试二维码，仅用于界面验证。',
                                 hasCredentials=saved, qrReady=True, revision=switches['sessions'],
                                 sessionId=f'fixture-session-{switches["sessions"]}', expiresAt=time.time() + 120)
                elif path.endswith('/cancel'):
                    assert request.post_data_json == {'sessionId': state['sessionId']}
                    if state['hasCredentials']:
                        connected('已取消这次连接，原有授权仍然保留。')
                    else:
                        state.clear()
                        state.update(state='unconfigured', hasCredentials=False, qrReady=False, revision=9,
                                     message='已取消这次连接。')
                elif path.endswith('/check'):
                    connected()
                else:
                    raise AssertionError(f'未声明米家写请求: {path}')
            else:
                assert path.endswith('/status')
            return request_route.fulfill(json=state)
        if path == '/api/status':
            return request_route.fulfill(json={'targets': [], 'shortcuts': [], 'actions': [], 'log': [],
                'accessibility': True, 'theme': switches['theme'],
                'workspaceURL': 'http://192.168.1.2:46387/?token=fixture-phone-token',
                'ipWorkspaceURL': 'http://192.168.1.2:46387/?token=fixture-phone-token'})
        if path == '/api/v1/model-config':
            return request_route.fulfill(json={'backend': 'api', 'providers': [], 'configured': False})
        if path == '/api/console/files':
            return request_route.fulfill(json={'files': []})
        if path == '/api/console/unlock':
            return request_route.fulfill(json={'configured': True, 'hasPassword': False, 'enabled': False, 'credentials': []})
        if path == '/api/qr':
            return request_route.fulfill(body=image_bytes, content_type='image/png')
        if path == '/api/theme':
            switches['theme'] = request.post_data_json['theme']
            return request_route.fulfill(json={'theme': switches['theme']})
        if path.startswith('/api/'):
            assert request.method == 'GET', f'未声明写请求: {path}'
            return request_route.fulfill(json={'ok': True, 'devices': [], 'order': []})
        source = ROOT / 'Web' / path.lstrip('/')
        if source.is_file():
            return request_route.fulfill(body=source.read_bytes(), content_type=mimetypes.guess_type(str(source))[0] or 'text/plain')
        return request_route.fulfill(status=404, body='')

    def wait_state(name):
        page.wait_for_function('(name) => document.querySelector("#mijia-state").dataset.state === name', arg=name)

    def reread():
        page.evaluate('document.dispatchEvent(new Event("visibilitychange"))')

    def no_qr():
        assert not page.locator('#mijia-qr').is_visible()
        assert page.locator('#mijia-qr').get_attribute('src') is None
        assert not page.locator('#mijia-qr-panel').is_visible()

    def screenshot(name):
        page.locator('#mijia-card').screenshot(path=f'/tmp/pocketdesk-mijia-{name}.png')

    page.route('**/*', route)
    page.goto('http://127.0.0.1:47899/console.html', wait_until='networkidle')
    wait_state('unconfigured')
    assert writes == [], '初次打开不能自动建立登录会话'
    page.locator('a[href="#mijia-card"]').click()
    assert page.locator('#mijia-connect').is_visible()
    no_qr()
    screenshot('desktop-unconfigured')

    page.locator('#mijia-connect').click()
    wait_state('waiting')
    page.locator('#mijia-qr').wait_for(state='visible')
    assert page.get_by_text('用米家 App 扫码，并在手机上确认', exact=True).is_visible()
    assert '有效期剩余' in page.locator('#mijia-countdown').inner_text()
    assert page.locator('#mijia-cancel').is_visible()
    assert page.locator('#mijia-qr').evaluate('(node) => getComputedStyle(node).backgroundColor') == 'rgb(255, 255, 255)'
    screenshot('desktop-waiting')
    page.set_viewport_size({'width': 390, 'height': 844})
    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
    screenshot('mobile-waiting')
    page.locator('[data-theme-choice="muji"]').click()
    page.wait_for_function('document.documentElement.dataset.theme === "muji"')
    screenshot('mobile-muji-waiting')
    page.set_viewport_size({'width': 320, 'height': 740})
    assert page.locator('#mijia-card').evaluate('(node) => node.scrollWidth <= node.clientWidth')
    assert page.locator('#mijia-card').evaluate('(node) => node.getBoundingClientRect().right <= innerWidth')

    # 服务端过期后撤下图片；再次连接必须建立新会话。
    state.update(state='expired', qrReady=False, message='二维码已过期，请重新生成后扫码。')
    reread(); wait_state('expired'); no_qr()
    screenshot('mobile-expired')
    assert page.locator('#mijia-connect').inner_text() == '重新生成二维码'
    page.locator('#mijia-connect').click(); page.locator('#mijia-qr').wait_for(state='visible')
    assert switches['sessions'] == 2
    page.locator('#mijia-cancel').click(); wait_state('unconfigured'); no_qr()
    assert writes[-1] == ('/api/console/mijia/cancel', {'sessionId': 'fixture-session-2'})

    page.locator('#mijia-connect').click(); page.locator('#mijia-qr').wait_for(state='visible')
    connected(); reread(); wait_state('connected'); no_qr()
    assert '20 个设备' in page.locator('#mijia-verified').inner_text()
    assert page.locator('#mijia-check').is_visible()
    assert page.locator('#mijia-connect').inner_text() == '重新连接'
    screenshot('mobile-connected')
    page.wait_for_function('!document.querySelector("#mijia-home").disabled')
    assert page.locator('#mijia-home').input_value() == ''
    assert page.locator('#mijia-home-save').is_disabled()
    assert '还需选择' in page.locator('#mijia-scope-current').inner_text()
    assert page.locator('#mijia-home option').count() == 3
    assert '所有家庭' not in page.locator('#mijia-home').inner_text()
    screenshot('scope-mobile-unselected')
    page.locator('#mijia-home').select_option('home-a')
    assert '尚未保存' in page.locator('#mijia-scope-message').inner_text()
    assert '当前生效' not in page.locator('#mijia-scope-current').inner_text()
    page.locator('#mijia-home-save').click()
    page.wait_for_function('document.querySelector("#mijia-scope-current").textContent === "当前生效：上海的家"')
    assert writes[-1] == ('/api/console/mijia/home', {'homeId': 'home-a'})
    page.set_viewport_size({'width': 1100, 'height': 900})
    screenshot('desktop-connected')
    page.locator('#mijia-home').select_option('home-b')
    assert '上海的家' in page.locator('#mijia-scope-current').inner_text()
    page.locator('#mijia-home-refresh').click()
    page.wait_for_function('!document.querySelector("#mijia-home").disabled')
    assert page.locator('#mijia-home').input_value() == 'home-b'
    assert '尚未保存' in page.locator('#mijia-scope-message').inner_text()
    switches['homeSaveFailure'] = True
    page.locator('#mijia-home-save').click()
    page.wait_for_function('document.querySelector("#mijia-scope-message").textContent.includes("保存失败")')
    assert page.locator('#mijia-home').input_value() == 'home-b'
    assert page.locator('#mijia-scope-current').inner_text() == '当前生效：上海的家'
    screenshot('scope-desktop-save-failed')
    switches['homeSaveFailure'] = False
    page.locator('#mijia-home-save').click()
    page.wait_for_function('document.querySelector("#mijia-scope-current").textContent === "当前生效：杭州的家"')
    screenshot('scope-desktop-saved')
    page.locator('#mijia-check').click(); wait_state('connected')
    assert writes[-1][0] == '/api/console/mijia/check'
    page.locator('#mijia-connect').click(); page.locator('#mijia-qr').wait_for(state='visible')
    assert page.locator('#mijia-retained').is_visible()
    page.locator('#mijia-cancel').click(); wait_state('connected')
    assert '原有授权' in page.locator('#mijia-message').inner_text()
    page.wait_for_function('document.querySelector("#mijia-scope-current").textContent === "当前生效：杭州的家"')

    # 新账号即使只有一户，也不继承旧账号的选择或自动允许这一户。
    page.locator('#mijia-connect').click(); page.locator('#mijia-qr').wait_for(state='visible')
    scope.update(homes=[{'id': 'new-account-home', 'name': '另一个账号的家'}], selectedHomeId=None,
                 selectedHomeName=None, selectionRequired=True)
    connected(); reread(); wait_state('connected')
    page.wait_for_function('!document.querySelector("#mijia-home").disabled')
    assert page.locator('#mijia-home').input_value() == ''
    assert page.locator('#mijia-home option').count() == 2
    assert page.locator('#mijia-home-save').is_disabled()
    assert '杭州的家' not in page.locator('#mijia-scope-current').inner_text()
    page.set_viewport_size({'width': 390, 'height': 844})
    assert page.locator('#mijia-card').evaluate('(node) => node.scrollWidth <= node.clientWidth')
    screenshot('scope-mobile-new-account')
    page.locator('[data-theme-choice="classic"]').click()
    screenshot('scope-mobile-classic')

    # 404 与网络错误都撤下旧码；用户显式重试后恢复。
    switches['image404'] = True
    page.locator('#mijia-connect').click(); wait_state('failed'); no_qr()
    assert '二维码加载失败' in page.locator('#mijia-message').inner_text()
    switches['image404'] = False
    page.locator('#mijia-connect').click(); page.locator('#mijia-qr').wait_for(state='visible')
    switches['offline'] = True
    reread(); wait_state('failed'); no_qr()
    assert '测试连接中断' in page.locator('#mijia-message').inner_text()
    switches['offline'] = False
    page.locator('#mijia-check').click(); wait_state('connected'); no_qr()
    assert not errors, errors
    browser.close()

print('PASS: 全页面米家扫码与恢复、双户/单户显式选择、草稿与已保存范围、保存失败保留、换账号重选，以及双主题320/390窄屏和桌面截图通过；所有请求使用隔离替身。')
