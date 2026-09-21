"""
[INPUT]: 真实手机页面、Android App UA 与隔离的无桌面副作用接口替身。
[OUTPUT]: 单顶栏密度、内置连接设置入口、普通浏览器隔离和窄屏不横溢的运行时验证。
[POS]: Web 与原生壳边界回归；截图不代表安卓真机。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import mimetypes
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True)
 def route(r):
  path=urlparse(r.request.url).path
  if path=='/api/status':return r.fulfill(json={'targets':[],'shortcuts':[],'actions':[],'log':[],'theme':'classic','accessibility':True,'phoneLastSeen':0})
  if path.startswith('/api/'):return r.fulfill(json={'ok':True,'devices':[],'files':[]})
  f=ROOT/'Web'/('index.html' if path=='/' else path.lstrip('/'))
  if f.is_file():return r.fulfill(body=f.read_bytes(),content_type=mimetypes.guess_type(str(f))[0] or 'text/plain')
  return r.fulfill(status=404,body='')
 for width in [390,320]:
  page=browser.new_page(viewport={'width':width,'height':844},user_agent='Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/130.0.0.0 Mobile Safari/537.36 PocketDeskAndroid/0.2.1')
  page.route('**/*',route);page.goto('http://localhost:47899/',wait_until='networkidle')
  assert page.locator('header').count()==1
  assert page.locator('header').bounding_box()['y']<=12
  assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
  page.screenshot(path=f'/tmp/pd-app-connected-{width}.png')
  page.locator('#phone-settings-open').click()
  link=page.locator('#native-connection-group a[href="pocketdesk://settings"]');assert link.is_visible()
  assert link.get_attribute('href')=='pocketdesk://settings'
  assert link.bounding_box()['height']>=48
  if width==390:page.screenshot(path='/tmp/pd-app-settings.png')
  page.close()
 page=browser.new_page(viewport={'width':390,'height':844})
 page.route('**/*',route);page.goto('http://localhost:47899/',wait_until='networkidle')
 page.locator('#phone-settings-open').click();assert not page.locator('#native-connection-group').is_visible()
 browser.close()
print('PASS: one header, compact top spacing, settings entry, 320/390 widths, browser isolation')
