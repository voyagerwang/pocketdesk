"""
[INPUT]: Playwright 与本地原版球体资源；使用隔离页面，不连接 PocketDesk 服务。
[OUTPUT]: 验证真实 SVG 动画、开心唤醒、输入抢占、轮询不重播、隐藏/减少动态停帧和安全隔离。
[POS]: 桌面表情适配器的浏览器集成回归；截图只写 /tmp。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
from pathlib import Path
from urllib.parse import urlparse
import mimetypes
from playwright.sync_api import sync_playwright

root = Path(__file__).resolve().parents[1] / 'Web'
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={'width': 176, 'height': 176}, device_scale_factor=2)
    errors = []
    page.on('pageerror', lambda error: errors.append(str(error)))
    def serve(route):
        path = root / Path(urlparse(route.request.url).path).name
        if not path.is_file():
            route.abort()
            return
        route.fulfill(body=path.read_bytes(), content_type=mimetypes.guess_type(str(path))[0] or 'text/plain')
    page.route('**/*', serve)
    page.goto('http://orb.test/orb-desktop.html')
    def update(**kwargs):
        model = dict(visible=True, revision=1, emotion='02', reduced=False)
        model.update(kwargs)
        page.evaluate('(model) => pocketdeskDesktopOrb.update(model)', model)
    def state():
        return page.evaluate('pocketdeskDesktopOrb.state()')
    update()
    assert state() == dict(emotion='10', active=True, greeting=True)
    page.wait_for_timeout(600)
    a = page.locator('#orb svg').inner_html()
    page.wait_for_timeout(180)
    assert page.locator('#orb svg').inner_html() != a, '必须运行原版眼环/身体动画'
    page.screenshot(path='/tmp/pocketdesk-desktop-happy.png', omit_background=True)
    update()  # 普通轮询不延长唤醒。
    page.wait_for_timeout(1200)
    assert state()['emotion'] == '02' and not state()['greeting']
    update(revision=2)
    assert state()['emotion'] == '10'
    update(revision=2, emotion='35')
    assert state()['emotion'] == '35' and not state()['greeting']
    page.wait_for_timeout(600)
    page.screenshot(path='/tmp/pocketdesk-desktop-listening.png', omit_background=True)
    update(revision=2, emotion='32')
    assert state()['emotion'] == '32'
    update(revision=3, emotion='32')
    assert state()['emotion'] == '32' and not state()['greeting'], '执行中重选不播放欢迎'
    update(revision=2, emotion='11')
    assert state()['emotion'] == '11'
    update(revision=2, emotion='11', visible=False)
    assert not state()['active']
    a = page.locator('#orb svg').inner_html()
    page.wait_for_timeout(250)
    assert page.locator('#orb svg').inner_html() == a
    update(revision=3, emotion='35', reduced=True)
    assert state() == dict(emotion='35', active=False, greeting=False)
    a = page.locator('#orb svg').inner_html()
    page.wait_for_timeout(250)
    assert page.locator('#orb svg').inner_html() == a
    update(revision=4, emotion='33', taskId='done-1')
    assert state()['emotion'] == '33' and not state()['greeting']
    page.wait_for_timeout(800)
    update(revision=4, emotion='33', taskId='done-1')
    page.wait_for_timeout(1300)
    assert state()['emotion'] == '19', '庆祝结束满意停留，不因轮询延长'
    update(revision=5, emotion='33', taskId='done-1')
    assert state()['emotion'] == '19', '重选已完成任务不反复撒花'
    update(revision=5, emotion='33', taskId='done-2')
    assert state()['emotion'] == '33', '连续下一任务独立庆祝'
    update(revision=5, emotion='35')
    assert state()['emotion'] == '35', '新输入立即抢占庆祝'
    update(revision=5, emotion='19', taskId='handoff-1')
    assert state()['emotion'] == '19', '交给外部应用不庆祝外部任务完成'
    update(revision=6, emotion='33', taskId='done-3', reduced=True)
    assert state()['emotion'] == '19' and not state()['active'], '减少动态不撒花'
    assert not page.locator('button, input, textarea').count()
    assert page.locator('body > :not(script):not(#orb)').count() == 0
    assert not errors, errors
    browser.close()
print('desktop orb: 原版动画/唤醒/状态/停帧/无常驻文字 全部通过')
