"""
[INPUT]: 依赖 Playwright 与已安装的本机 PocketDesk HTTP/WS 服务。
[OUTPUT]: 验证真实 JPEG 解码、全屏布局及关闭回收，不保存屏幕截图。
[POS]: tests 的只读真实浏览器检查；拦截所有文本/指针注入，页面只观看。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import json
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True)
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.add_init_script('''
      const NativeSocket = window.WebSocket;
      window.runtimeFrames = 0; window.blockedInput = 0;
      window.WebSocket = class extends NativeSocket {
        send(data) {
          if (typeof data === 'string') {
            const m = JSON.parse(data);
            if (!['auth','heartbeat','cursor-subscribe','watch','presented'].includes(m.t)) { window.blockedInput++; return; }
            if (m.t === 'presented') window.runtimeFrames++;
          }
          return super.send(data);
        }
      };
      Element.prototype.requestFullscreen = () => Promise.reject(new Error('test CSS fullscreen'));
    ''')
    def gate(route):
        if route.request.method != 'GET' and route.request.url.split('?')[0].split('/')[-1] not in ['pair','wake']:
            route.abort(); return
        route.continue_()
    page.route('**/api/**', gate)
    page.goto('http://127.0.0.1:46387/')
    page.wait_for_load_state('networkidle')
    page.locator('#screen-open').click()
    page.locator('#screen-image').wait_for(state='visible')
    page.locator('#screen-fullscreen').click()
    page.wait_for_function('runtimeFrames >= 3', timeout=15000)
    assert page.locator('#screen-image').evaluate('i=>i.naturalWidth>0 && i.complete')
    for width, height in [(320,568),(390,844),(844,390),(844,220)]:
        page.set_viewport_size({'width':width,'height':height})
        page.wait_for_timeout(150)
        for id in ['screen-back','kb-toggle','screen-switch','screen-more']:
            box=page.locator('#'+id).bounding_box()
            assert box and box['x']>=-1 and box['y']>=-1 and box['x']+box['width']<=width+1 and box['y']+box['height']<=height+1,(id,box,width,height)
    page.locator('#screen-back').click()
    page.wait_for_function("document.querySelector('#screen-view').classList.contains('pip')")
    page.locator('#screen-pip-close').click()
    page.wait_for_function("!document.querySelector('#screen-view').open")
    count=page.evaluate('runtimeFrames')
    page.wait_for_timeout(1200)
    assert page.evaluate('runtimeFrames')==count
    assert not errors,errors
    print(json.dumps({'result':'passed','realFramesDecoded':count,'viewportCases':4,'closedStopsFrames':True}))
    browser.close()
