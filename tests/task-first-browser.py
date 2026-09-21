# coding: utf-8
"""
[INPUT]: 完整手机工作台、可控锁定状态和App 0.4 UA。
[OUTPUT]: 首页锁定入口、未知/断线禁止解锁、顶部应用栏与主题入口、普通浏览器隔离。
[POS]: 无真实解锁或桌面输入的产品路径回归。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
from pathlib import Path
from urllib.parse import urlparse
import mimetypes
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
with sync_playwright() as p:
 browser=p.chromium.launch()
 for width,theme in [(390,'muji'),(320,'classic')]:
  state={'value':'locked'}; writes=[]
  def route(r):
   path=urlparse(r.request.url).path
   if r.request.method=='POST':writes.append(path)
   if path=='/api/status':return r.fulfill(json={'targets':[{'id':'chat','name':'ChatGPT','bundleId':'com.fixture.chat'},{'id':'work','name':'飞书','bundleId':'com.fixture.work'},{'id':'browser','name':'浏览器','bundleId':'com.fixture.browser'}],'shortcuts':[],'actions':[],'log':[],'theme':theme,'accessibility':True})
   if path=='/api/screen/state':return r.fulfill(json={'state':state['value'],'locked':state['value']=='locked'})
   if path.startswith('/api/'):return r.fulfill(json={'ok':True,'devices':[],'files':[]})
   f=ROOT/'Web'/('index.html' if path=='/' else path.lstrip('/'))
   if f.is_file():return r.fulfill(body=f.read_bytes(),content_type=mimetypes.guess_type(str(f))[0] or 'text/plain')
   r.fulfill(status=404,body='')
  page=browser.new_page(viewport={'width':width,'height':844},user_agent='Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/130 Mobile Safari/537.36 PocketDeskAndroid/0.4.0')
  page.route('**/*',route);page.goto('http://localhost:47899/?token=abcdefghijklmnopqrstuvwxyz',wait_until='networkidle')
  page.locator('#quick-unlock-open').wait_for(state='visible')
  assert page.locator('#quick-unlock-entry').bounding_box()['y']<160
  deck=page.locator('.deck')
  assert deck.evaluate('(e)=>getComputedStyle(e).position')=='sticky'
  assert deck.bounding_box()['y']<page.locator('#pad-card').bounding_box()['y']
  assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
  assert not any('unlock' in w for w in writes)
  page.screenshot(path='/tmp/pd-task-first-'+str(width)+'.png')
  state['value']='unknown';page.evaluate("window.dispatchEvent(new Event('online'))");page.wait_for_function('document.querySelector("#quick-unlock-open").hidden')
  assert page.locator('#quick-unlock-entry').is_visible()
  state['value']='unlocked';page.evaluate("window.dispatchEvent(new Event('online'))");page.locator('#quick-unlock-entry').wait_for(state='hidden')
  page.locator('#phone-settings-open').click()
  assert page.locator('a[href^="pocketdesk://files"]').is_visible()
  assert page.locator('a[href^="pocketdesk://settings"]').get_attribute('href').endswith('theme='+theme)
  page.close()
 browser.close()
print('PASS: lock entry, unknown guard, unlocked dismissal, application dock, theme, no automatic unlock')
