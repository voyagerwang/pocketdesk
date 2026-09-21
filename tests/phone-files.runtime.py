"""
[INPUT]: Playwright Chromium、生产 phone-files.js/css 与可控异步 fetch 替身。
[OUTPUT]: 安卓尺寸下真实 DOM 点击、并行接收乱序、双击、迟到列表、断网重试、刷新恢复、XSS/URL 与下载手势验证。
[POS]: 无桌面副作用的浏览器运行时测试；模拟 Android 视口，不代替安卓真机下载验证。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
from pathlib import Path
from playwright.sync_api import sync_playwright
ROOT = Path(__file__).resolve().parents[1]
BASE = '/api/v1/phone-files'
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    for width in [320, 390]:
        page = browser.new_page(viewport={'width': width, 'height': 844}, is_mobile=True, has_touch=True)
        def serve(route):
            if '/api/v1/phone-files/download/' in route.request.url:
                return route.fulfill(body=b'fixture',headers={'Content-Type':'application/octet-stream','Content-Disposition':'attachment; filename="fixture.txt"'})
            route.fulfill(body='<meta name="viewport" content="width=device-width,initial-scale=1"><section class="phone-files" id="phone-files"><p id="phone-files-notice"></p><div id="phone-files-list"></div></section>', content_type='text/html')
        page.route('https://192.168.31.196:46487/**', serve)
        page.goto('https://192.168.31.196:46487/')
        page.add_style_tag(path=str(ROOT/'Web/style.css'))
        page.add_style_tag(content=':root{--screen-hit:44px;--accent:blue;--accent-ink:white}*{box-sizing:border-box}body{margin:8px}')
        page.add_style_tag(path=str(ROOT/'Web/phone-files.css'))
        page.evaluate('''() => {
          window.pending=[]; window.authHeaders=()=>({Authorization:'Bearer fake'}); window.pairToken=()=> 'fake';
          window.fetch=(url,options)=>new Promise((resolve,reject)=>pending.push({url,options,resolve,reject}));
          window.answer=(index,body,status=200)=>pending[index].resolve({ok:status===200,json:async()=>body});
        }''')
        page.add_script_tag(path=str(ROOT/'Web/phone-files.js'))
        files=[dict(id=str(i), name=('<img src=x onerror=alert(1)>' if i==1 else '长文件名'*20+'.txt'),size=0,expiresAt=2000000000,accepted=False) for i in [1,2]]
        page.evaluate('(files)=>answer(0,{files})',files)
        page.wait_for_function('document.querySelectorAll("article").length===2')
        assert page.locator('img').count()==0
        assert page.evaluate('innerWidth') == width
        assert page.get_by_role('button',name='下载',exact=True).first.bounding_box()['height'] >= 44
        assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
        buttons=page.get_by_role('button',name='下载',exact=True)
        buttons.nth(0).click(); page.get_by_role('button',name='下载',exact=True).click()
        assert page.evaluate('pending.filter(x=>x.options.method==="POST").length')==2
        with page.expect_download(): page.evaluate("answer(2,{url:'/api/v1/phone-files/download/b'})")
        with page.expect_download(): page.evaluate("answer(1,{url:'/api/v1/phone-files/download/a'})")
        assert page.locator('a').count()==0
        assert page.get_by_role('button',name='下载',exact=True).count()==2
        assert page.get_by_text('HTTPS 下载',exact=True).count()==0
        assert page.get_by_text('局域网兼容下载（未加密）',exact=True).count()==0
        # 旧列表在拒绝后迟到，不得复活收件。
        page.evaluate("window.dispatchEvent(new Event('online'))")
        page.wait_for_function('pending.length===4')
        page.get_by_role('button',name='移除',exact=True).first.click()
        page.evaluate('answer(4,{ok:true})')
        page.wait_for_function('document.querySelectorAll("article").length===1')
        page.evaluate('(files)=>answer(3,{files})', files)
        page.wait_for_timeout(30)
        assert page.locator('article').count()==1
        # 非同源地址拒绝；网络错误可原地重试，同项忙碌时不能重复操作。
        page.get_by_role('button',name='下载',exact=True).click()
        assert page.get_by_role('button',name='请稍候…',exact=True).is_disabled()
        page.evaluate("answer(5,{url:'https://evil.test/file'})")
        page.get_by_text('下载地址无效，请重试。').wait_for()
        page.get_by_role('button',name='下载',exact=True).click()
        page.evaluate("pending[6].reject(new Error('offline'))")
        page.get_by_text('offline',exact=True).wait_for()
        page.get_by_role('button',name='下载',exact=True).click()
        with page.expect_download(): page.evaluate("answer(7,{url:'/api/v1/phone-files/download/fresh'})")
        page.get_by_text('点击下载后保存到手机。').wait_for()
        page.screenshot(path=f'/tmp/pd-phone-files-{width}.png')
        # 刷新相当于新脚本实例，从已接受的服务器记录恢复并允许换票。
        page.reload()
        page.evaluate("window.authHeaders=()=>({}); window.pairToken=()=> 'fake'; window.fetch=async()=>({ok:true,json:async()=>({files:[{id:'2',name:'恢复.txt',size:0,expiresAt:2000000000,accepted:true}]})})")
        page.add_script_tag(path=str(ROOT/'Web/phone-files.js'))
        page.get_by_role('button',name='下载',exact=True).wait_for()
        assert page.locator('a').count()==0
        page.close()
    browser.close()
print('Browser runtime PASS: 320/390px, one-click downloads, stale poll, XSS, URL, offline retry, refresh')
