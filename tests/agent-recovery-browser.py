"""
[INPUT]: 真实手机 Web 资源、Playwright 与内存 HTTP/WS 替身，所有请求均被拦截。
[OUTPUT]: 验证启动/心跳状态鉴权、恢复主动作、双输入上下文/草稿保护、同任务重试；批量导出320/390/1024及横屏全屏、经典/米白截图并检查44px命中区与溢出。
[POS]: tests 的任务恢复浏览器验收；不连接真实服务、不请求模型、不操作桌面或米家设备，软键盘手感仍需真机确认。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import json
import mimetypes
import sys
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
LONG_GOAL = '关闭时光家里客厅靠窗的落地灯，并保留卧室的夜灯'
tasks = {
    'retry': {'id': 'retry', 'status': 'failed', 'revision': 2, 'text': LONG_GOAL,
              'error': '暂时没有连接上米家。', 'recovery': {'kind': 'executionFailure',
              'headline': '暂时没完成', 'primaryAction': {'kind': 'retry', 'title': '再试一次'}, 'inputLabel': '补充说明'}},
    'question': {'id': 'question', 'status': 'needsInput', 'revision': 3, 'text': '关闭客厅的灯',
                 'result': '客厅有两盏灯，要关哪一盏？', 'recovery': {'kind': 'clarification',
                 'headline': '需要你补充', 'primaryAction': {'kind': 'input', 'title': '补充信息'}}},
    'unknown': {'id': 'unknown', 'status': 'submitted', 'revision': 4, 'text': '发给工作台整理一下',
                'result': '请求已发出，还没有收到确认。', 'recovery': {'kind': 'unconfirmed',
                'headline': '还没确认结果', 'primaryAction': {'kind': 'input', 'title': '核对结果'}}},
}
tasks['pending'] = {**tasks['retry'], 'id': 'pending'}

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True,
                            reduced_motion='reduce')
    errors, posts, desktop_writes, screenshots = [], [], [], []
    flags = {'theme': 'classic', 'lookup_confirmed': False}
    page.on('pageerror', lambda error: errors.append(error.stack or str(error)))
    page.add_init_script("""
      localStorage.setItem('voicedeck.pair-token', 'fixture-only');
      class FakeSocket {
        static OPEN = 1;
        constructor(url) { this.readyState = 0; this.bufferedAmount = 0;
          setTimeout(() => { this.readyState = 1; this.onopen?.({}); }, 0); }
        send(raw) { const m = JSON.parse(raw);
          if (m.t === 'auth') setTimeout(() => this.onmessage?.({data: JSON.stringify({
            t:'auth_ok', session:'fixture', controller:true, absolutePointerV1:true, doubleClickMs:350})}), 0); }
        close() { this.readyState = 3; this.onclose?.({}); }
      }
      window.WebSocket = FakeSocket;
      Element.prototype.requestFullscreen = () => Promise.reject(new Error('fixture uses page fullscreen'));
    """)

    def route(r):
        path = urlparse(r.request.url).path
        if path.startswith('/api/'):
            data = {'ok': True}
            if path == '/api/screen/frame':
                r.fulfill(content_type='image/svg+xml', body='<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900"><rect width="1600" height="900" fill="#20252c"/><text x="800" y="450" fill="#ffffff" text-anchor="middle" font-family="sans-serif" font-size="36">模拟电脑画面 · 无真实桌面内容</text></svg>')
                return
            elif path == '/api/status':
                assert r.request.headers.get('authorization') == 'Bearer fixture-only', '启动和心跳必须携带配对凭证'
                data = {'targets': [{'id': 'wb', 'name': 'WorkBuddy'}], 'shortcuts': [],
                        'accessibility': True, 'frontmostName': 'Test editor', 'theme': flags['theme']}
            elif path == '/api/recipients':
                data = {'order': ['__sprite__', 'wb']}
            elif path == '/api/v1/phone-files':
                data = {'files': []}
            elif path == '/api/screen/state':
                data = {'locked': False}
            elif path == '/api/screen/displays':
                data = {'displays': [{'id': 1, 'name': 'Display', 'width': 1600, 'height': 900}]}
            elif path == '/api/input-context':
                data = {'context': 'editor-1', 'name': 'Test editor', 'scope': 'element', 'text': ''}
            elif path in ['/api/live-input', '/api/activate']:
                desktop_writes.append(path)
            elif path == '/api/v1/tasks':
                if r.request.method == 'POST':
                    posts.append({'path': path, 'body': r.request.post_data_json})
                    data = {'task': {'id': 'new', 'status': 'succeeded', 'revision': 1, 'text': r.request.post_data_json['text'], 'result': '已完成'}}
                else:
                    data = {'tasks': []}
            elif path.startswith('/api/v1/tasks/'):
                if path.endswith('/actions'):
                    posts.append({'path': path, 'body': r.request.post_data_json})
                    if path == '/api/v1/tasks/pending/actions':
                        r.fulfill(status=503, json={'error': '连接暂时中断'})
                        return
                    data = {'task': {'id': path.split('/')[-2], 'status': 'running', 'revision': 5}}
                elif '/by-request/' in path:
                    if not flags['lookup_confirmed']:
                        r.fulfill(status=503, json={'error': '暂时无法核对'})
                        return
                    data = {'task': {'id': 'pending', 'status': 'running', 'revision': 3}}
                elif path.endswith('/events'):
                    data = {'events': []}
                else:
                    data = {'task': tasks.get(path.split('/')[-1])}
            r.fulfill(json=data)
            return
        file = ROOT / 'Web' / (path.lstrip('/') or 'index.html')
        if file.is_file():
            r.fulfill(body=file.read_bytes(), content_type=mimetypes.guess_type(file)[0] or 'text/plain')
        else:
            r.fulfill(status=404, body='fixture missing resource')

    page.route('**/*', route)
    page.goto('http://pocketdesk.test/')
    page.wait_for_load_state('networkidle')
    page.evaluate('() => heartbeatTick()')
    page.locator('[data-target-id="__sprite__"]').click()
    desktop_writes.clear()

    def resume(name):
        page.evaluate('(id) => pocketdeskAgent.resume(id)', name)

    def capture(name):
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), name + ': page overflow'
        for node in page.locator('.agent-actions button:visible, .agent-input-context button:visible').all():
            assert node.bounding_box()['height'] >= 44, name + ': undersized target'
        output = '/tmp/pocketdesk-recovery-' + name + '.png'
        if '--no-screenshots' not in sys.argv and ('--resume-visual' not in sys.argv or not Path(output).exists()):
            page.screenshot(path=output, full_page=False)
        screenshots.append(output)

    # 一轮批量视觉覆盖，不在脚本中反复微调。
    for theme in ['classic', 'muji']:
        flags['theme'] = theme
        page.evaluate('(theme) => document.documentElement.dataset.theme = theme', theme)
        for width, height in [(320, 740), (390, 844), (1024, 768)]:
            page.set_viewport_size({'width': width, 'height': height})
            page.locator('#text').fill('')
            resume('retry')
            page.evaluate('pocketdeskAgent.restoreInput()')
            assert page.locator('#agent-primary').inner_text() == '再试一次'
            assert page.locator('.agent-next-step').count() == 0
            page.evaluate('scrollTo(0, 0)')
            capture(f'{theme}-{width}-failed')
            page.locator('#agent-new').click()
            assert page.locator('#agent-panel').is_hidden()
            assert page.locator('#agent-compose-label').inner_text() == '说件新事情'
            page.locator('#agent-compose-switch').click()
            assert page.locator('#agent-primary').is_visible(), '空草稿返回恢复主动作'

        page.set_viewport_size({'width': 390, 'height': 844})
        page.locator('#text').fill('我想关的是靠窗那一盏')
        page.locator('#agent-compose-switch').click()
        assert page.locator('#text').input_value() == '我想关的是靠窗那一盏'
        capture(theme + '-390-new')
        page.locator('#agent-compose-switch').click()
        assert page.locator('#agent-panel').evaluate('(el) => el.classList.contains("is-editing")')
        assert page.locator('#text').input_value() == '我想关的是靠窗那一盏'
        capture(theme + '-390-supplement')

        # 使用生产全屏与编辑器结构；焦点不把输入归属挤出可见编辑区。
        page.set_viewport_size({'width': 844, 'height': 390})
        page.locator('#screen-open').click()
        page.locator('#screen-fullscreen').click()
        page.wait_for_function('pocketdeskScreenCanInput()')
        page.locator('#kb-toggle').click()
        assert page.locator('#kb-proxy').evaluate('(el) => document.activeElement === el')
        assert page.locator('#agent-screen-context').is_visible()
        rect = page.locator('#agent-screen-context').bounding_box()
        assert rect['y'] >= 0 and rect['y'] + rect['height'] <= 390, '全屏焦点后输入归属须在视口内'
        page.locator('#agent-screen-switch').click()
        assert page.locator('#agent-screen-label').inner_text() == '说件新事情'
        assert page.locator('#kb-proxy').input_value() == '我想关的是靠窗那一盏'
        capture(theme + '-landscape-workbench')
        page.locator('#screen-keyboard-close').click()
        page.locator('#screen-back').click()
        page.wait_for_function('!document.querySelector("#screen-view").classList.contains("fullscreen")')
        page.locator('#screen-pip-close').click()
        page.wait_for_function('!document.querySelector("#screen-view").open')

    page.set_viewport_size({'width': 390, 'height': 844})
    page.locator('#text').fill('')
    resume('retry')
    page.evaluate('pocketdeskAgent.restoreInput()')
    page.locator('#agent-primary').click()
    page.wait_for_function('pocketdeskAgent.current().status === "running"')
    assert posts[-1]['path'] == '/api/v1/tasks/retry/actions'
    assert posts[-1]['body']['text'] == '继续处理刚才的请求'
    assert posts[-1]['body']['requestId']
    resume('pending')
    page.locator('#agent-primary').click()
    page.wait_for_function('pocketdeskAgent.hasPendingRetry() && !pocketdeskAgent.isRetrying()')
    page.locator('#text').fill('刚才的目标是卧室灯，请保留这句话')
    assert page.locator('#agent-compose-recover').is_visible()
    assert page.locator('#agent-compose-switch').is_hidden()
    capture('muji-390-pending-with-draft')
    before = len(posts)
    flags['lookup_confirmed'] = True
    page.locator('#agent-compose-recover').click()
    page.wait_for_function('pocketdeskAgent.current().status === "running"')
    assert len(posts) == before, '核对确认已接收后只读返回，不再POST'
    assert page.locator('#text').input_value() == '刚才的目标是卧室灯，请保留这句话'
    page.locator('#text').fill('')
    resume('unknown')
    capture('muji-390-unconfirmed')
    before = len(posts)
    page.locator('#agent-primary').click()
    assert len(posts) == before, '结果未核实的主动作只进入输入'
    assert page.locator('#text').evaluate('(el) => document.activeElement === el')
    resume('question')
    page.locator('#agent-primary').click()
    assert page.locator('.agent-recovery-detail').is_visible(), '进入补充后问题仍可参照'
    capture('muji-390-question-input')
    assert not desktop_writes, desktop_writes
    assert not errors, errors
    print(json.dumps({'passed': True, 'screenshots': screenshots, 'taskPosts': len(posts), 'desktopWrites': len(desktop_writes)}, ensure_ascii=False))
    browser.close()
