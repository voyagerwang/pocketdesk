"""
[INPUT]: 依赖 Playwright、Pillow 与本地 Web 文件，以模拟 HTTP/WS 隔离真实桌面。
[OUTPUT]: 另验证启动前台跟随、草稿/IME/提交保护、小精灵往返无桌面写入和迟到识别隔离； 验证小精灵甩送入口、连续任务、简短呈现、接续切换与迟到回执保护；发送历史覆盖成功、拒绝及存储失败。
[POS]: tests 的浏览器集成验证；手机软键盘和实际捕获性能仍需真机验证。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import io
import base64
import json
import mimetypes
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
jpeg = jpeg2 = b''
frame_displays = []

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    # 明确使用 Android UA，才能真正覆盖下方 Gboard 专属的编辑会话自愈路径。
    page = browser.new_page(viewport={'width': 390, 'height': 844}, is_mobile=True, has_touch=True, device_scale_factor=2, user_agent='Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130.0.0.0 Mobile Safari/537.36')
    errors, writes, key_writes = [], [], []
    flags = {"frame_failed": False, "locked": False, "fail_submit": False, "fail_live": False, "mode": "selection"}
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.add_init_script('window.testJpeg = ' + json.dumps(base64.b64encode(jpeg).decode()) + ';')
    page.add_init_script("document.addEventListener('DOMContentLoaded', () => {  })")
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
            if path == '/api/recipients':
                data = {'order':['__sprite__','wb']}
            elif path == '/api/v1/tasks' and r.request.method == 'POST':
                writes.append(r.request.post_data_json)
                data = {'task':{'id':'task-'+str(len(writes)), 'status':'succeeded','statusText':'已完成','text':r.request.post_data_json['text'],'result':'完成详细内容'*30}}
            elif path == '/api/status':
                data = {'targets': [{'id':'wb','name':'WorkBuddy'}], 'shortcuts': [], 'accessibility': True, 'frontmostName': 'Test editor', 'theme': 'classic'}
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

    assert page.locator('#compose-recipient').inner_text() == '发给 Test editor'
    page.evaluate("followFrontmost({frontmostId:'wb',frontmostName:'WorkBuddy'})")
    assert page.locator('#compose-recipient').inner_text() == '发给 WorkBuddy'
    page.locator('#text').fill('未发送正文')
    page.evaluate("followFrontmost({frontmostName:'Other editor'})")
    assert page.locator('#compose-recipient').inner_text() == '发给 WorkBuddy'
    page.locator('#text').fill('')
    page.evaluate("liveComposing = true; followFrontmost({frontmostName:'Other editor'})")
    assert page.locator('#compose-recipient').inner_text() == '发给 WorkBuddy'
    page.evaluate("liveComposing = false; submittingDraft = true; followFrontmost({frontmostName:'Other editor'})")
    assert page.locator('#compose-recipient').inner_text() == '发给 WorkBuddy'
    page.evaluate("submittingDraft = false; followFrontmost({frontmostName:'Other editor'})")
    assert page.locator('#compose-recipient').inner_text() == '发给 Other editor'
    before = page.evaluate('liveDraftId')
    page.evaluate("followFrontmost({frontmostName:'Another editor'})")
    assert page.evaluate('liveDraftId') != before, '未配置应用之间也必须隔离绑定'
    page.locator('[data-recipient-toggle]').first.click()
    assert page.locator('#compose-recipient').inner_text() == '发给 小精灵'
    page.evaluate("followFrontmost({frontmostId:'wb',frontmostName:'WorkBuddy'})")
    assert page.locator('#compose-recipient').inner_text() == '发给 小精灵'
    page.locator('#text').fill('保留的小精灵指令')
    count = len(writes)
    page.locator('[data-recipient-toggle]').first.click()
    assert page.locator('#compose-recipient').inner_text() == '发给 小精灵'
    assert page.locator('#text').input_value() == '保留的小精灵指令'
    page.locator('#text').fill('')
    page.locator('[data-recipient-toggle]').first.click()
    page.wait_for_timeout(200)
    assert page.locator('#compose-recipient').inner_text() == '发给 Test editor'
    assert len(writes) == count, '往返入口不得注入桌面文字'
    page.locator('[data-recipient-toggle]').first.click()
    # 前台请求晚到，不能覆盖用户再次选小精灵的动作。
    page.evaluate("""() => {
      window.realFetch = window.fetch;
      window.fetch = () => new Promise(resolve => { window.finishFrontQuery = resolve; });
      window.pendingFrontQuery = resumeFrontmost();
      selectSprite();
      finishFrontQuery({ok:true,json:async()=>({frontmostName:'Late editor'})});
      window.fetch = realFetch;
    }""")
    page.evaluate('pendingFrontQuery')
    assert page.locator('#compose-recipient').inner_text() == '发给 小精灵'
    page.locator('#text').fill('整理需求')
    page.wait_for_timeout(350)
    assert page.evaluate('pocketdeskCanMotionSend()'), '小精灵支持甩送'
    page.evaluate('livePaused = true; liveProbing = true')
    assert page.evaluate('pocketdeskCanMotionSend()'), '应用同步状态不能挡住小精灵'
    page.evaluate('pocketdeskComposeSend()')
    page.wait_for_timeout(200)
    assert page.locator('#text').input_value() == ''
    assert page.locator('#agent-status').inner_text() == '已完成'
    assert page.locator('#agent-result .agent-brief').inner_text() == '整理需求'
    assert not page.locator('#agent-result details').evaluate('(el)=>el.open')
    page.locator('#text').fill('第二件事')
    page.evaluate('pocketdeskComposeSend()')
    page.wait_for_timeout(200)
    task_writes = [entry for entry in writes if 'requestId' in entry]
    assert len(task_writes) == 2 and task_writes[0]['requestId'] != task_writes[1]['requestId'], writes
    history = page.evaluate('loadHistory()')
    assert [(item['text'], item['target']) for item in history] == [('第二件事', '小精灵'), ('整理需求', '小精灵')]
    page.locator('#history-btn').click()
    assert page.locator('#history-list .hist-text').first.inner_text() == '第二件事'
    assert '小精灵' in page.locator('#history-list small').first.inner_text()
    page.locator('#history-collapse').click()
    # 拒绝接收时保留草稿且不记成功历史。
    page.evaluate("() => { window.originalAgentSend = pocketdeskAgent.send; pocketdeskAgent.send = async () => { throw new Error('测试拒绝接收'); }; }")
    page.locator('#text').fill('未接收的任务')
    page.evaluate('pocketdeskComposeSend()')
    assert page.locator('#text').input_value() == '未接收的任务'
    assert page.evaluate('loadHistory().length') == 2
    # 浏览器历史配额异常不能把已经接收的任务变成发送失败或留下可误重发草稿。
    page.evaluate("() => { pocketdeskAgent.send = originalAgentSend; window.originalStorageSet = Storage.prototype.setItem; Storage.prototype.setItem = function(k,v) { if (k === 'pd-history') throw new Error('QuotaExceeded'); return originalStorageSet.call(this,k,v); }; }")
    page.locator('#text').fill('接收成功但历史存储失败')
    page.evaluate('pocketdeskComposeSend()')
    assert page.locator('#text').input_value() == ''
    assert page.evaluate('loadHistory().length') == 2
    page.evaluate('() => { Storage.prototype.setItem = originalStorageSet; }')
    page.evaluate("""() => {
      window.taskFixture = {id:'handoff',status:'succeeded',statusText:'已完成',text:'让 WorkBuddy 整理需求',handoffTargetId:'wb',handoffTargetName:'WorkBuddy'};
      pocketdeskAgent.current = () => taskFixture;
      pocketdeskAgentPanel.render();
    }""")
    assert page.locator('#agent-status').inner_text() == '已交给 WorkBuddy'
    assert page.locator('#compose-recipient').inner_text() == '发给 小精灵'
    page.screenshot(path='/tmp/pocketdesk-sprite-handoff.png')
    page.locator('#agent-continue').click()
    page.wait_for_timeout(100)
    assert page.locator('#compose-recipient').inner_text() == '发给 WorkBuddy'
    page.evaluate('selectSprite()')
    page.evaluate("taskFixture = {...taskFixture,id:'auto',handoffRequested:true}; pocketdeskAgentPanel.render()")
    page.wait_for_timeout(100)
    assert page.locator('#compose-recipient').inner_text() == '发给 WorkBuddy'
    page.evaluate('selectSprite()')
    page.locator('#text').fill('尚未发送的新任务')
    page.evaluate("taskFixture = {...taskFixture,id:'late'}; pocketdeskAgentPanel.render()")
    assert page.locator('#compose-recipient').inner_text() == '发给 小精灵'
    assert page.locator('#text').input_value() == '尚未发送的新任务'
    assert page.locator('.sprite-icon img').evaluate('(el)=>el.complete && el.naturalWidth > 0')
    page.evaluate("selectTarget({dataset:{targetId:'wb'}})")
    page.wait_for_timeout(700)
    assert page.locator('#text').input_value() == '尚未发送的新任务'
    assert any(item.get('targetId') == 'wb' and item.get('text') == '尚未发送的新任务' for item in writes), writes
    page.evaluate('selectSprite()')
    assert page.locator('#text').input_value() == '尚未发送的新任务'
    count = len(writes)
    page.locator('#text').fill('只给小精灵的新文字')
    page.wait_for_timeout(600)
    assert len(writes) == count, '小精灵输入不得同步到桌面'
    assert page.locator('.sprite-icon img').evaluate('(el)=>getComputedStyle(el).animationName') == 'sprite-idle'
    page.wait_for_timeout(1500)
    page.evaluate("taskFixture = {...taskFixture,status:'running'}; pocketdeskAgentPanel.render()")
    assert page.locator('.sprite-icon img').evaluate('(el)=>getComputedStyle(el).animationName') == 'sprite-working'
    assert page.locator('.sprite-gaze, .sprite-blink').count() == 0
    page.locator('#text').fill('')
    for width, height in [(320,568),(390,844),(1024,768)]:
        page.set_viewport_size({'width':width,'height':height})
        toggle = page.locator('[data-recipient-toggle]').first
        assert toggle.bounding_box()['height'] >= 44
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
        page.screenshot(path=f'/tmp/pocketdesk-recipient-{width}.png')
    page.set_viewport_size({'width':390,'height':844})
    page.evaluate("""() => {
      const dialog = document.querySelector('#screen');
      window.testScreenDialog = document.querySelector('dialog:has(#screen-compose)');
      testScreenDialog.showModal();
      testScreenDialog.classList.add('fullscreen');
      document.querySelector('#screen-compose').hidden = false;
    }""")
    assert page.locator('#screen-compose [data-recipient-toggle]').is_visible()
    page.screenshot(path='/tmp/pocketdesk-recipient-fullscreen.png')
    page.evaluate("testScreenDialog.close(); document.querySelector('#screen-compose').hidden = true")
    page.screenshot(path='/tmp/pocketdesk-orb-restored.png')
    page.emulate_media(reduced_motion='reduce')
    assert page.locator('.sprite-icon img').evaluate('(el)=>getComputedStyle(el).animationName') == 'none'
    assert not errors, errors
    browser.close()
    print('sprite flow: 甩送入口 / 连续派单 / 简短状态 / 手动接续 / 自动接续 / 迟到保护 / 球球图标 passed')
