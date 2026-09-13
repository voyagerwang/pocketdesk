"""
[INPUT]: 依赖 Playwright、Pillow 与本地 Web 文件，以模拟 HTTP/WS 隔离真实桌面。
[OUTPUT]: 切换取消排队快照不冻结同步、Android 长按输入框保持原生焦点且不靠额外粘贴按钮、回车提交清空、历史存储异常不阻断收尾、旧 IME 迟到事件隔离、启动时已有正文同步、暂停后删空保持 ID、电脑原文不反填、已有草稿聚焦/全屏带入全文同步、候选完成失焦保留、点击/滚动合一与放大精确落点、触控板激活隔离与右缘防抖、锁屏/断屏恢复与重认证序号、原生输入法入口与自绘键盘移除、快捷切屏画面匹配、滚动入口、小屏布局、始终可见输入栏、模拟键盘视口偏移/缩小与首页隔离、首页/全屏 IME 重建、失焦探针取消与首页/全屏失败保留与原 ID 重试、全屏操作回归断言与 /tmp 下的浏览器截图。
[POS]: tests 的浏览器集成验证；手机软键盘和实际捕获性能仍需真机验证。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import io
import base64
import json
import mimetypes
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
fixture = Image.new('RGB', (1600, 900), '#dce5f2')
draw = ImageDraw.Draw(fixture)
draw.rectangle((80, 60, 1520, 840), fill='#ffffff')
draw.text((120, 100), 'PocketDesk test desktop - no real input', fill='#223344')
for x in range(200, 1500, 200):
    draw.line((x, 150, x, 800), fill='#dce5f2', width=2)
for y in range(200, 850, 200):
    draw.line((120, y, 1480, y), fill='#dce5f2', width=2)
buffer = io.BytesIO(); fixture.save(buffer, format='JPEG'); jpeg = buffer.getvalue()
second = io.BytesIO(); Image.new('RGB', (900, 1600), '#f6dbaf').save(second, format='JPEG')
jpeg2 = second.getvalue()
frame_displays = []

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    # 明确使用 Android UA，才能真正覆盖下方 Gboard 专属的编辑会话自愈路径。
    page = browser.new_page(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True, device_scale_factor=2, user_agent='Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130.0.0.0 Mobile Safari/537.36')
    errors, writes, key_writes = [], [], []
    flags = {"frame_failed": False, "locked": False, "fail_submit": False, "fail_live": False, "mode": "selection"}
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.add_init_script('window.testJpeg = ' + json.dumps(base64.b64encode(jpeg).decode()) + ';')
    page.add_init_script("document.addEventListener('DOMContentLoaded', () => { document.querySelector('#text').value = '启动时已有手机正文'; })")
    page.add_init_script('''
      window.sentControls = [];
      class FakeSocket {
        static OPEN = 1;
        constructor(url) { this.url = url; this.readyState = 0; this.bufferedAmount = 0;
          if (url.endsWith(':46389')) {
            if (!window.mockStream) { setTimeout(() => this.onerror?.({}), 100); return; }
            window.frameSocket = this;
            setTimeout(() => { this.readyState = 1; this.onopen?.({}); }, 10); return;
          }
          window.controlSocket = this;
          setTimeout(() => { this.readyState = 1; this.onopen?.({}); }, 10);
        }
        send(raw) { const m = JSON.parse(raw); window.sentControls.push(m);
          if (m.t === 'watch') { this.display = m.display; this.frame(); }
          if (m.t === 'presented') { window.presentedFrames = (window.presentedFrames || 0) + 1; setTimeout(() => this.frame(), 100); }
          if (m.t === 'auth') setTimeout(() => this.onmessage?.({data: JSON.stringify({t:'auth_ok',session:'test',controller:window.testControlOwner !== false,absolutePointerV1:true,doubleClickMs:350})}), 0);
        }
        frame() {
          if (this.readyState !== 1 || window.stallStream) return;
          const meta = new TextEncoder().encode(JSON.stringify({frameId: (this.seq = (this.seq || 0) + 1), epoch:'test-frame', display:this.display, cursorIncluded:false, ageMs:0}));
          const jpeg = Uint8Array.from(atob(window.testJpeg), c => c.charCodeAt(0));
          const packet = new Uint8Array(4 + meta.length + jpeg.length);
          new DataView(packet.buffer).setUint32(0, meta.length); packet.set(meta, 4); packet.set(jpeg, 4 + meta.length);
          this.onmessage?.({data: packet.buffer});
        }
        close() { this.readyState = 3; this.onclose?.({}); }
      }
      window.WebSocket = FakeSocket;
      Element.prototype.requestFullscreen = () => Promise.reject(new Error('testing CSS fallback'));
    ''')
    def route(r):
        path = urlparse(r.request.url).path
        if path == '/api/screen/state':
            r.fulfill(json={'locked':flags['locked']}); return
        if path == '/api/screen/frame':
            if flags['frame_failed']:
                r.fulfill(status=422,json={'error':'显示器已断开'}); return
            display_id = parse_qs(urlparse(r.request.url).query)['display'][0]
            frame_displays.append(display_id)
            r.fulfill(body=jpeg2 if display_id == '2' else jpeg, content_type='image/jpeg'); return
        if path.startswith('/api/'):
            data = {'ok': True}
            if path == '/api/status':
                data = {'targets': [], 'shortcuts': [], 'accessibility': True, 'frontmostName': 'Test editor', 'theme': 'classic'}
            elif path == '/api/screen/displays':
                data = {'displays': [{'id': 1, 'name': 'Display 1', 'width': 1600, 'height': 900}, {'id': 2, 'name': 'Display 2', 'width': 900, 'height': 1600}], 'streamPort': 46389}
            elif path == '/api/input-context': data = {'context': 'editor-1', 'name': 'Test editor', 'scope': 'element', 'text': '电脑原文，不属于手机草稿'}
            elif path == '/api/shortcut-trigger':
                key_writes.append(r.request.post_data_json)
                data = {'ok': True, 'outcome': 'sent'}
            elif path == '/api/live-input':
                writes.append(r.request.post_data_json)
                if flags['fail_live']:
                    r.fulfill(status=422, json={'error': 'test original input mismatch'}); return
                if flags['fail_submit'] and r.request.post_data_json.get('submit'):
                    r.fulfill(status=409, json={'error': 'test submit failed, draft retained'}); return
                submitted = r.request.post_data_json.get('submit', False)
                data = {'outcome': 'sent' if submitted or flags['mode'] == 'selection' else ('buffered' if flags['mode'] == 'deferred' else 'delivered'),
                        'detail': 'test write complete', 'mode': flags['mode'], 'committed': submitted}
            r.fulfill(json=data); return
        file = ROOT / 'Web' / (path.lstrip('/') or 'index.html')
        r.fulfill(body=file.read_bytes(), content_type=mimetypes.guess_type(file)[0] or 'text/plain')
    page.route('**/*', route)
    page.goto('http://pocketdesk.test/')
    page.wait_for_load_state('networkidle')
    assert not errors, errors
    assert writes[-1]['text'] == '启动时已有手机正文', '目标就绪后应同步恢复的全文，不必再手敲一个字'
    # 回车快捷键有草稿时也必须先提交全文、确认后清空；空草稿保持普通回车。
    page.evaluate("syncShortcuts([{id:'return-test',hotkey:'Return',label:'↵'}])")
    page.locator('#text').fill('快捷回车提交全文')
    page.evaluate('window.submittedHome = textEl; window.submittedProxy = kbProxy')
    before_keys = len(key_writes)
    page.locator('#shortcut-bar button').click()
    page.wait_for_timeout(250)
    assert page.locator('#text').input_value() == '', '回车快捷键不能只发电脑回车而留下手机草稿'
    assert writes[-1]['text'] == '快捷回车提交全文' and writes[-1]['submit']
    assert len(key_writes) == before_keys, '完整提交不能再额外触发一次回车'
    count = len(writes)
    page.evaluate("""() => {
      for (const old of [submittedHome, submittedProxy]) {
        old.value = '输入法迟到的已发送文字';
        old.dispatchEvent(new InputEvent('input', {data:old.value}));
        old.dispatchEvent(new CompositionEvent('compositionend', {data:old.value}));
      }
    }""")
    page.wait_for_timeout(160)
    assert page.locator('#text').input_value() == '' and page.locator('#kb-proxy').input_value() == ''
    assert len(writes) == count, '上一轮输入法事件不能回填并重新发送已提交文字'
    page.locator('#shortcut-bar button').click()
    page.wait_for_timeout(100)
    assert len(key_writes) == before_keys + 1, '空草稿仍允许普通回车'
    # 提交已确认但历史写入失败，仍要清空；不能落到发送失败分支引导重复发送。
    page.locator('#text').fill('历史配额不足也已提交')
    page.evaluate("""() => {
      window.originalSetItem = Storage.prototype.setItem;
      Storage.prototype.setItem = function(key, value) {
        if (key === 'pd-history') throw new DOMException('quota full', 'QuotaExceededError');
        return originalSetItem.call(this, key, value);
      };
    }""")
    page.locator('#send').click()
    page.wait_for_function('!submittingDraft')
    assert page.locator('#text').input_value() == '', '历史写入异常不能阻止提交后清空'
    assert writes[-1]['submit'] and writes[-1]['text'] == '历史配额不足也已提交'
    page.evaluate('() => { Storage.prototype.setItem = originalSetItem; }')
    # 已有正文聚焦即同步，不必再输入一个字；后续追加仍携带全文及同一个草稿身份。
    page.evaluate("textEl.value='已有正文'; textEl.focus()")
    page.wait_for_timeout(220)
    assert writes[-1]['text'] == '已有正文' and not writes[-1]['submit']
    existing_id = writes[-1]['draftId']
    page.locator('#text').fill('已有正文后续输入')
    page.wait_for_timeout(220)
    assert writes[-1]['text'] == '已有正文后续输入' and writes[-1]['draftId'] == existing_id
    page.locator('#send').click()
    page.wait_for_function('textEl.value === "" && !submittingDraft')
    # 首页整段清空后必须替换元素，保留焦点及事件绑定；覆盖无 compositionend 的键盘手势。
    for draft in ['上滑清空测试', '再次输入']:
        page.locator('#text').fill(draft)
        page.evaluate("window.oldHome = document.querySelector('#text')")
        page.locator('#text').fill('')
        assert page.evaluate("!oldHome.isConnected && document.activeElement === document.querySelector('#text')")
    # 代码回填也须由 beforeinput 捕获原长度。
    page.evaluate("textEl.value = '历史回填'; textEl.dispatchEvent(new InputEvent('beforeinput', {inputType:'deleteContentBackward'})); textEl.value = ''; textEl.dispatchEvent(new InputEvent('input', {inputType:'deleteContentBackward'}))")
    page.locator('#text').fill('恢复后的草稿')
    # 缺失 input 的探针在失焦后不得抢回焦点。
    page.evaluate("window.oldHome = textEl; textEl.dispatchEvent(new InputEvent('beforeinput')); textEl.blur()")
    page.wait_for_timeout(800)
    assert page.evaluate("oldHome === textEl && document.activeElement !== textEl")
    page.locator('#text').fill('')
    # 首页同步失败后，显式发送仍携带原草稿 ID 请求核验，不能锁死或重置全文。
    flags['fail_live'] = True
    page.locator('#text').fill('首页失败后保留')
    page.wait_for_function('livePaused')
    failed_id = writes[-1]['draftId']
    count = len(writes)
    page.locator('#text').fill('首页修订后保留')
    page.wait_for_timeout(160)
    assert len(writes) == count, '暂停期间不自动重放'
    flags['fail_live'] = False
    page.locator('#send').click()
    page.wait_for_function('!submittingDraft && !livePaused && textEl.value === ""')
    assert writes[-1]['retry'] and writes[-1]['draftId'] == failed_id
    assert writes[-1]['text'] == '首页修订后保留' and writes[-1]['submit']
    # 同步暂停后删除仍属于原草稿：核验后同步空串，不得偷偷换 ID 留下电脑残文。
    page.locator('#text').fill('需要删净的手机段落')
    page.wait_for_timeout(220)
    deletion_id = writes[-1]['draftId']
    flags['fail_live'] = True
    page.locator('#text').fill('需要删净的手机段落修订')
    page.wait_for_function('livePaused')
    flags['fail_live'] = False
    count = len(writes)
    page.locator('#text').fill('')
    page.wait_for_timeout(240)
    assert len(writes) > count, '暂停后删空必须核验原草稿并上传空串，不能只清手机'
    assert writes[-1]['text'] == '' and writes[-1]['draftId'] == deletion_id
    assert writes[-1]['retry'] and not writes[-1]['submit'], '删除不能触发电脑回车'
    assert page.evaluate('liveDraftId') == deletion_id
    page.locator('#text').fill('删空后继续')
    page.wait_for_timeout(220)
    assert writes[-1]['text'] == '删空后继续' and writes[-1]['draftId'] == deletion_id
    page.locator('#send').click()
    page.wait_for_function('textEl.value === "" && !submittingDraft')
    # 收起时划过不激活，轻点只展开；右缘微小抖动不发滚动或点击。
    page.evaluate("exitPadMode(); window.padCommandsStart = sentControls.length")
    assert page.locator('#pad').evaluate("e => getComputedStyle(e).touchAction") == 'pan-y'
    page.evaluate("""() => {
      const r = pad.getBoundingClientRect();
      for (const [type,y] of [['pointerdown',r.y+20],['pointermove',r.y+50],['pointerup',r.y+50],['click',r.y+50]])
        pad.dispatchEvent(new PointerEvent(type,{bubbles:true,pointerId:99,clientX:r.x+30,clientY:y,button:0}));
    }""")
    assert not page.locator('main').evaluate("e => e.classList.contains('pad-mode')")
    page.locator('#pad').click()
    assert page.locator('main').evaluate("e => e.classList.contains('pad-mode')")
    assert not page.evaluate("sentControls.slice(padCommandsStart).some(m=>['click','move','scroll','down'].includes(m.t))")
    page.evaluate("""() => {
      const r = pad.getBoundingClientRect();
      for (const [type,y] of [['pointerdown',r.y+20],['pointermove',r.y+23],['pointerup',r.y+23]])
        pad.dispatchEvent(new PointerEvent(type,{bubbles:true,pointerId:99,clientX:r.right-15,clientY:y,button:0}));
    }""")
    assert not page.evaluate("sentControls.slice(padCommandsStart).some(m=>['click','scroll','down'].includes(m.t))")
    page.evaluate('exitPadMode()')
    page.locator('#screen-open').click()
    page.locator('#screen-image').wait_for(state='visible')
    pip_displays = page.locator('#screen-pip-displays')
    assert pip_displays.locator('button').all_text_contents() == ['屏幕 1', '屏幕 2']
    pip_displays.get_by_role('button', name='屏幕 2').click()
    page.wait_for_function("document.querySelector('#screen-image').naturalWidth === 900 && !document.querySelector('#screen-image').hidden")
    assert pip_displays.get_by_role('button', name='屏幕 2').get_attribute('aria-pressed') == 'true'
    pip_displays.get_by_role('button', name='屏幕 1').click()
    page.wait_for_function("document.querySelector('#screen-image').naturalWidth === 1600 && !document.querySelector('#screen-image').hidden")
    assert page.locator('#screen-fullscreen').bounding_box()['width'] == 28
    assert pip_displays.locator('button').first.bounding_box()['height'] == 26
    page.screenshot(path='/tmp/pocketdesk-pip-displays.png')
    page.locator('#screen-fullscreen').click()
    assert not pip_displays.is_visible()
    page.wait_for_function("document.querySelector('#screen-view').classList.contains('fullscreen') && !document.querySelector('#kb-toggle').disabled")
    page.wait_for_function("document.querySelector('.screen-viewport').classList.contains('rotated')")
    page.screenshot(path='/tmp/pocketdesk-portrait.png')
    # 黑边不触发点击；图中央点击归一化后落在中心。
    rect = page.locator('.screen-viewport').bounding_box()
    page.touchscreen.tap(rect['x'] + rect['width']/2, rect['y'] + 2)
    before = page.evaluate("sentControls.filter(m => m.t === 'pointer' && m.action === 'click').length")
    page.touchscreen.tap(rect['x'] + rect['width']/2, rect['y'] + rect['height']/2)
    page.wait_for_timeout(50)
    click = page.evaluate("sentControls.filter(m => m.t === 'pointer' && m.action === 'click').at(-1)")
    assert abs(click['rx'] - .5) < .02 and abs(click['ry'] - .5) < .02, click
    assert page.evaluate("sentControls.filter(m => m.t === 'pointer' && m.action === 'click').length") == before + 1
    # 旋转回退的非中心点击也必须准确。
    scale = min(rect['height']/1600, rect['width']/900)
    local_x = (rect['height']-1600*scale)/2 + .25*1600*scale
    local_y = (rect['width']-900*scale)/2 + .3*900*scale
    page.touchscreen.tap(rect['x']+rect['width']-local_y, rect['y']+local_x)
    click = page.evaluate("sentControls.filter(m => m.t === 'pointer' && m.action === 'click').at(-1)")
    assert abs(click['rx']-.25)<.01 and abs(click['ry']-.3)<.01, click
    # 打开全屏输入栏时同步带入的旧正文；候选结束无额外 input 且失焦也不能丢最后一段。
    page.evaluate("textEl.value='全屏已有正文'")
    page.locator('#kb-toggle').click()
    page.wait_for_timeout(220)
    assert writes[-1]['text'] == '全屏已有正文' and not writes[-1]['submit']
    assert page.locator('#kb-proxy').input_value() == '全屏已有正文', '电脑原文不得覆盖手机已有正文'
    # 全屏长按期间即使浏览器为系统菜单派发临时 blur，也不能收起输入栏或强行重聚焦。
    page.locator('#kb-proxy').evaluate("e => e.setSelectionRange(0, 2)")
    page.locator('#kb-proxy').dispatch_event('pointerdown', {
        'pointerType': 'touch', 'pointerId': 6, 'clientX': 30, 'clientY': 18
    })
    page.wait_for_timeout(380)
    page.locator('#kb-proxy').evaluate('e => e.blur()')
    assert page.evaluate('kbActive && !document.querySelector("#screen-compose").hidden')
    page.locator('#kb-proxy').focus()
    page.locator('#kb-proxy').dispatch_event('pointerup', {
        'pointerType': 'touch', 'pointerId': 6, 'clientX': 30, 'clientY': 18
    })
    existing_id = writes[-1]['draftId']
    page.evaluate("kbProxy.value='全屏已有正文候选确认'; kbProxy.dispatchEvent(new CompositionEvent('compositionend')); kbProxy.blur()")
    page.wait_for_timeout(220)
    assert writes[-1]['text'] == '全屏已有正文候选确认' and writes[-1]['draftId'] == existing_id
    assert page.locator('#text').input_value() == '全屏已有正文候选确认'
    page.locator('#screen-send').click()
    page.wait_for_function('textEl.value === "" && document.querySelector("#screen-compose").hidden')
    assert writes[-1]['text'] == '全屏已有正文候选确认' and writes[-1]['submit']
    # 可见编辑与独立提交结果。
    page.locator('#kb-toggle').click()
    assert page.locator('#screen-input-expand').count() == 0
    assert page.locator('#screen-input-target').count() == 0
    assert page.locator('.screen-compose-bar').bounding_box()['height'] <= 48
    assert page.locator('#keyboard-ime').count() == 0
    assert page.locator('#kb-proxy').bounding_box()['height'] == 44
    assert page.locator('body > main').evaluate('e => e.inert && getComputedStyle(e).visibility === "hidden"')
    # 模拟 Safari 只缩小/移动可见视口，布局视口仍保持原高度。
    page.evaluate("""() => {
      window.testVisual = {height:420, offsetTop:65, width:390, offsetLeft:0};
      for (const key of ['height','offsetTop','width','offsetLeft']) {
        Object.defineProperty(visualViewport,key,{configurable:true,get:()=>testVisual[key]});
      }
      visualViewport.dispatchEvent(new Event('resize'));
    }""")
    page.wait_for_timeout(120)
    def assert_editor_in_view():
        box=page.locator('#kb-proxy').bounding_box()
        visual=page.evaluate('testVisual')
        assert box and box['height'] >= 44 and box['y'] >= visual['offsetTop']
        assert box['y']+box['height'] <= visual['offsetTop']+visual['height'], (box,visual)
        assert page.locator('#screen-compose').bounding_box()['height'] <= 130
    assert_editor_in_view()
    page.locator('#kb-proxy').fill('键盘上方可见的文字')
    page.evaluate("liveMode='replace'; syncKeyboardDraft()")
    assert_editor_in_view()
    page.screenshot(path='/tmp/pocketdesk-visible-input.png')
    page.locator('#kb-proxy').fill('')
    assert_editor_in_view()
    for height, top in [(310,120),(230,0),(420,65)]:
        page.evaluate('([height,top])=>{testVisual.height=height;testVisual.offsetTop=top;visualViewport.dispatchEvent(new Event("scroll"));}',[height,top])
        page.wait_for_timeout(60)
        assert_editor_in_view()
    page.evaluate("for (const key of ['height','offsetTop','width','offsetLeft']) delete visualViewport[key]; visualViewport.dispatchEvent(new Event('resize'))")
    page.wait_for_timeout(100)
    assert page.locator('#kb-proxy').get_attribute('enterkeyhint') == 'enter'
    page.locator('#kb-proxy').fill('全屏清空测试')
    page.evaluate('window.oldProxy = kbProxy')
    page.locator('#kb-proxy').fill('')
    assert page.evaluate('!oldProxy.isConnected && document.activeElement === kbProxy')
    page.locator('#kb-proxy').fill('中文 draft 🧪')
    assert page.locator('#text').input_value() == '中文 draft 🧪'
    page.wait_for_timeout(160)
    first_live_id = writes[-1]['draftId']
    page.locator('#kb-proxy').fill('中文修订 draft 🧪')
    page.wait_for_timeout(160)
    assert writes[-1]['text'] == '中文修订 draft 🧪' and not writes[-1]['submit']
    assert writes[-1]['draftId'] == first_live_id, '通用模式必须连续实时同步，而非等待发送'
    assert not page.locator('#screen-input-status').is_visible()
    page.screenshot(path='/tmp/pocketdesk-compose.png')
    page.locator('#screen-send').click()
    page.wait_for_function("document.querySelector('#text').value === ''")
    assert writes[-1]['submit'] is True and writes[-1]['context'] == 'editor-1', writes
    assert writes[-1]['text'] == '中文修订 draft 🧪'
    assert page.locator('#text').input_value() == '', '提交动作确认后结束本轮，不能因 sent 回执重复输入'
    # 自绘电脑键盘及入口已移除，原生输入法仍可唤起和收起。
    page.evaluate('showKeyboard()')
    page.wait_for_timeout(150)
    assert page.locator('#kb-proxy').input_value() == '', '手机空框也不能反填电脑原文，否则再次同步会重复追加'
    assert page.locator('#computer-keys').count() == 0
    assert page.locator('#keyboard-computer').count() == 0
    page.locator('#kb-proxy').click()
    assert page.evaluate('document.activeElement === kbProxy')
    page.screenshot(path='/tmp/pocketdesk-native-only.png')
    page.locator('#screen-keyboard-close').click()
    # 不支持替换：只探测一次，连续语音纠正留在手机，发送时带最新完整快照。
    flags['mode'] = 'deferred'
    page.evaluate('showKeyboard()')
    start = len(writes)
    page.locator('#kb-proxy').fill('明天三点')
    page.wait_for_timeout(200)
    assert page.locator('#kb-proxy').bounding_box()['height'] >= 44
    draft_id = writes[-1]['draftId']
    for text in ['明天下午三点', '明天下午三点继续说', '  最终全文 👨‍👩‍👧‍👦\n第二行  ']:
        page.locator('#kb-proxy').fill(text)
        page.wait_for_timeout(120)
    assert len(writes) == start + 1, '暂存期间不把输入法中间纠正发到电脑'
    # 组合态选区也不能被误当成候选并从全文剔除。
    page.evaluate("kbProxy.setSelectionRange(2, 5); kbProxy.dispatchEvent(new CompositionEvent('compositionstart'))")
    assert page.evaluate('liveValue()') == text
    page.evaluate('send()')
    assert len(writes) == start + 1, '组合态不能提前提交'
    page.evaluate("kbProxy.dispatchEvent(new CompositionEvent('compositionend'))")
    page.locator('#screen-send').click()
    page.wait_for_function("document.querySelector('#text').value === ''")
    assert writes[-1]['text'] == text and writes[-1]['draftId'] == draft_id
    assert writes[-1]['submit'] and len(writes) == start + 2
    # 图文也只提交一次；deferred 模式不能漏掉全文，也不能另外调用旧发送接口重复输入。
    page.evaluate('showKeyboard()')
    page.locator('#kb-proxy').fill('图文一起发送')
    page.wait_for_timeout(160)
    page.evaluate('pendingImages = [{id: "test-image", dataUrl: "data:image/jpeg;base64,AA==", uploaded: true}]')
    page.locator('#screen-send').click()
    page.wait_for_function("document.querySelector('#text').value === ''")
    assert writes[-1]['usePendingImage'] and writes[-1]['text'] == '图文一起发送'
    assert writes[-1]['draftId'] != draft_id
    flags['mode'] = 'selection'
    if page.locator('#screen-keyboard-close').is_visible():
        page.locator('#screen-keyboard-close').click()
    # 横屏工具栏在画面右侧，按钮保持正立。
    page.set_viewport_size({'width': 844, 'height': 390})
    page.wait_for_timeout(100)
    assert not page.locator('.screen-viewport').evaluate("e => e.classList.contains('rotated')")
    rail = page.locator('.screen-toolbar').bounding_box()
    view = page.locator('.screen-viewport').bounding_box()
    assert rail['x'] >= view['x'] + view['width'] - 1, (rail, view)
    assert page.locator('.screen-toolbar').evaluate("e => getComputedStyle(e).transform") == 'none'
    page.screenshot(path='/tmp/pocketdesk-landscape.png')
    # 持续画面仅在 decode 完成后确认，独立光标投影；卡流后自动回退。
    page.evaluate('window.mockStream = true')
    page.locator('#screen-more').click()
    page.locator('#screen-quality').select_option('1920')
    page.locator('#screen-menu-close').click()
    page.wait_for_function('window.presentedFrames >= 3')
    page.evaluate("controlSocket.onmessage({data: JSON.stringify({t:'cursor',displayId:1,rx:.5,ry:.5})})")
    page.locator('#screen-cursor').wait_for(state='visible')
    page.evaluate('window.stallStream = true')
    page.wait_for_function('frameSocket.readyState === 3')
    page.wait_for_function("!document.querySelector('#kb-toggle').disabled")
    # 提交失败保留草稿；失去控制权时取消手势并关闭键盘。
    page.locator('#kb-toggle').click()
    page.locator('#kb-proxy').fill('保留这份草稿')
    page.wait_for_timeout(160)
    flags['fail_submit'] = True
    page.locator('#screen-send').click()
    page.wait_for_function("document.querySelector('#screen-input-status').textContent.includes('failed')")
    assert page.locator('#kb-proxy').input_value() == '保留这份草稿'
    assert page.locator('#screen-send').is_enabled()
    retry_id = writes[-1]['draftId']
    # 核验仍失败时保持原文/原因，不要求清空；随后恢复成功时只提交一次。
    page.locator('#screen-send').click()
    page.wait_for_function('!submittingDraft')
    assert writes[-1]['retry'] and writes[-1]['draftId'] == retry_id
    assert page.locator('#kb-proxy').input_value() == '保留这份草稿'
    flags['fail_submit'] = False
    page.locator('#screen-send').click()
    page.wait_for_function('!submittingDraft && !livePaused && textEl.value === ""')
    assert writes[-1]['retry'] and writes[-1]['draftId'] == retry_id
    page.evaluate('showKeyboard()')
    page.evaluate("window.testControlOwner = false; controlSocket.onmessage({data: JSON.stringify({t:'control',controller:false})})")
    page.wait_for_function("document.querySelector('#screen-compose').hidden && document.querySelector('#kb-toggle').disabled")
    page.evaluate("window.testControlOwner = true; controlSocket.onmessage({data: JSON.stringify({t:'control',controller:true})})")
    page.wait_for_function("!document.querySelector('#kb-toggle').disabled")
    # 指针模式切换，显示器切换不能继续操作旧图。
    page.locator('#screen-more').click()
    page.locator('#screen-mode').click()
    assert page.locator('#screen-mode').inner_text() == '指针'
    page.locator('#screen-more').click()
    page.locator('#screen-display').select_option('2')
    page.wait_for_timeout(200)
    page.wait_for_function("document.querySelector('#screen-image').naturalWidth === 900")
    assert frame_displays[-1] == '2'
    assert page.locator('#screen-switch').inner_text() == '屏幕 2'
    page.locator('#screen-switch').click()
    page.wait_for_function("document.querySelector('#screen-display').value === '1' && !document.querySelector('#kb-toggle').disabled")
    page.wait_for_function("document.querySelector('#screen-image').naturalWidth === 1600")
    assert frame_displays[-1] == '1'
    assert page.locator('#screen-switch').inner_text() == '屏幕 1'
    assert page.locator('#screen-scroll').count() == 0
    page.locator('#screen-more').click()
    page.locator('#screen-mode').click()
    rect = page.locator('.screen-viewport').bounding_box()
    x, y = rect['x'] + rect['width']/2, rect['y'] + rect['height']/2
    page.mouse.move(x, y); page.mouse.down(); page.mouse.move(x, y-60, steps=5); page.mouse.up()
    page.wait_for_timeout(100)
    assert page.evaluate("sentControls.some(m => m.t === 'scroll' && m.dy < 0 && m.dx === 0)")
    assert page.evaluate("sentControls.some(m => m.t === 'scrollEnd')")
    for width, height in [(320,568),(844,220),(844,390)]:
        page.set_viewport_size({'width':width,'height':height}); page.wait_for_timeout(100)
        for button in page.locator('.screen-toolbar button').all():
            b = button.bounding_box()
            assert b['x'] >= 0 and b['y'] >= 0 and b['x']+b['width'] <= width+1 and b['y']+b['height'] <= height+1, b
    page.screenshot(path='/tmp/pocketdesk-screen-controls.png')
    # 同一模式可连续滚动和点击；按住放大瞄准时不提前触发电脑点击。
    rect = page.locator('.screen-viewport').bounding_box()
    x, y = rect['x'] + rect['width']/2, rect['y'] + rect['height']/2
    before_aim = page.evaluate("sentControls.filter(m=>m.t==='pointer' && m.action==='click').length")
    page.mouse.move(x, y); page.mouse.down(); page.wait_for_timeout(550)
    assert page.locator('#screen-aim').is_visible()
    page.mouse.move(x+30, y+12)
    assert page.evaluate("sentControls.filter(m=>m.t==='pointer' && m.action==='click').length") == before_aim
    page.screenshot(path='/tmp/pocketdesk-precise-aim.png')
    page.mouse.up(); page.wait_for_timeout(100)
    assert not page.locator('#screen-aim').is_visible()
    assert page.evaluate("sentControls.filter(m=>m.t==='pointer' && m.action==='click').length") == before_aim + 1
    click = page.evaluate("sentControls.filter(m=>m.t==='pointer' && m.action==='click').at(-1)")
    scale = min(rect['width']/1600, rect['height']/900)
    assert abs(click['rx'] - (.5 + 10/(1600*scale))) < .005
    assert abs(click['ry'] - (.5 + 4/(900*scale))) < .005
    # 重认证不能重置现有 session 的命令序号，避免恢复后操作被服务端静默丢弃。
    before_sequence = page.evaluate('controlSequence')
    page.evaluate("controlSocket.onmessage({data:JSON.stringify({t:'auth_ok',session:'test',controller:true,absolutePointerV1:true})})")
    assert page.evaluate('controlSequence') >= before_sequence
    # 暂时没有画面时保留具体错误；锁屏与解锁可恢复，不需要刷新页面。
    flags['frame_failed'] = True
    flags['locked'] = True
    page.wait_for_function("document.querySelector('#screen-notice').textContent.includes('电脑已锁屏')", timeout=12000)
    page.wait_for_function("document.querySelector('#kb-toggle').disabled")
    flags['frame_failed'] = False
    flags['locked'] = False
    try:
        page.wait_for_function("!document.querySelector('#kb-toggle').disabled", timeout=12000)
    except Exception:
        print(page.evaluate("({notice:document.querySelector('#screen-notice').textContent,control:pocketdeskControlState(),open:document.querySelector('#screen-view').open,frames:window.presentedFrames,errors:window.sentControls.slice(-4)})"))
        raise
    assert '尚未就绪' not in page.locator('#screen-notice').inner_text()

    page.locator('#screen-back').click()
    page.wait_for_function("document.querySelector('#screen-view').classList.contains('pip')")
    page.locator('#screen-pip-close').click()
    page.wait_for_function("!document.querySelector('#screen-view').open")
    assert page.locator('body > main').evaluate('e => !e.inert && getComputedStyle(e).visibility === "visible"')
    assert not page.evaluate('document.documentElement.classList.contains("screen-fullscreen-open")')
    # 请求在途时切回首页：取消排队快照不能冒充远端失败、冻结后续输入。
    result = page.evaluate("""async () => {
      clearTimeout(liveTimer); stopRecovery();
      livePaused = false; liveFailure = ''; liveMode = null;
      const originalQueue = liveQueue;
      let release;
      liveQueue = new ComposeQueue(() => new Promise(resolve => { release = resolve; }));
      const first = pushLive('在途正文');
      const pending = pushLive('切换前最后一句').catch(error => error.name);
      hideKeyboard();
      const cancellation = await pending;
      const paused = livePaused;
      release({ mode: 'selection' }); await first;
      liveQueue = originalQueue;
      stopRecovery(); livePaused = false; liveFailure = '';
      return { cancellation, paused };
    }""")
    assert not result['paused'], '切换取消未发送快照不得冻结同步: ' + str(result)
    assert result['cancellation'] == 'ComposeCancelledError', result
    page.locator('#text').fill('回到首页继续同步')
    page.wait_for_timeout(250)
    assert writes[-1]['text'] == '回到首页继续同步'
    # Android 悬浮键盘不一定缩小 VisualViewport。长按期间仍须保持原生编辑焦点，
    # 不能在 pointerdown 就按“键盘已收起”误判而 blur，系统选区/粘贴菜单才有机会出现。
    page.locator('#text').focus()
    page.locator('#text').evaluate("e => e.setSelectionRange(0, 2)")
    page.locator('#text').dispatch_event('pointerdown', {
        'pointerType': 'touch', 'pointerId': 7, 'clientX': 40, 'clientY': 20
    })
    page.wait_for_timeout(420)
    assert page.evaluate("document.activeElement === textEl"), '长按尚未结束时不得主动 blur 输入框'
    page.locator('#text').dispatch_event('contextmenu')
    assert page.evaluate("document.activeElement === textEl"), '原生菜单阶段不得重建或抢夺输入焦点'
    page.locator('#text').dispatch_event('pointerup', {
        'pointerType': 'touch', 'pointerId': 7, 'clientX': 40, 'clientY': 20
    })
    assert page.evaluate("document.activeElement === textEl")
    assert page.locator('#paste-btn').count() == 0 and page.locator('#screen-paste-btn').count() == 0
    assert not errors, errors
    print(json.dumps({'result': 'passed', 'writes': len(writes), 'screenshots': 3, 'presentedFrames': page.evaluate('window.presentedFrames')}, ensure_ascii=False))
    browser.close()
