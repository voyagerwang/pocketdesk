"""
[INPUT]: 控制台真实页面与隔离 HTTP 存储替身、Playwright。
[OUTPUT]: 单击删除全局/专属快捷键、最后一项清空、刷新持久与失败恢复验证。
[POS]: 不修改用户配置或发送桌面按键的交互回归。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import json,mimetypes
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True)
 page=browser.new_page(viewport={'width':1100,'height':850});page.set_default_timeout(6000)
 state={'targets':[{'id':'fixture','name':'测试应用','shortcuts':[{'id':'local','label':'复制','hotkey':'Cmd+C'}]}], 'shortcuts':[{'id':'global','label':'撤销','hotkey':'Cmd+Z'}], 'actions':[], 'log':[], 'accessibility':True,'theme':'classic','phoneLastSeen':0}
 writes=[]; fail={'value':False}; errors=[]
 page.on('pageerror',lambda e:errors.append(str(e)))
 def route(r):
  path=urlparse(r.request.url).path
  if path=='/api/status':return r.fulfill(json=state)
  if path=='/api/recipients':return r.fulfill(json={'order':['fixture']})
  if path in ['/api/targets','/api/shortcuts'] and r.request.method=='POST':
   if fail['value']:return r.fulfill(status=500,json={'error':'测试存储失败'})
   body=r.request.post_data_json;writes.append(path);state[path.split('/')[-1]]=body;return r.fulfill(json={'ok':True})
  if path.startswith('/api/v1/model') and r.request.method=='POST':raise AssertionError('Shortcut change must not write model config')
  if path.startswith('/api/'):return r.fulfill(json={'ok':True,'devices':[]})
  f=ROOT/'Web'/path.lstrip('/')
  if f.is_file():return r.fulfill(body=f.read_bytes(),content_type=mimetypes.guess_type(str(f))[0] or 'text/plain')
  return r.fulfill(status=404,body='')
 page.route('**/*',route)
 page.goto('http://localhost:47899/console.html',wait_until='networkidle')
 page.locator('#scList [data-act="remove"]').click()
 page.wait_for_function('document.querySelector("#scList").children.length===0')
 assert state['shortcuts']==[] and writes.count('/api/shortcuts')==1
 page.locator('#current [data-act="settings"]').click()
 page.locator('[data-sc-list] [data-act="remove-sc"]').click()
 page.wait_for_function('document.querySelector("[data-sc-list]").children.length===0')
 assert 'shortcuts' not in state['targets'][0]
 page.reload(wait_until='networkidle');assert page.locator('#scList .target-row').count()==0
 state['shortcuts']=[{'id':'rollback','label':'撤销','hotkey':'Cmd+Z'}]
 state['targets'][0]['shortcuts']=[{'id':'local2','label':'复制','hotkey':'Cmd+C'}]
 page.reload(wait_until='networkidle');fail['value']=True
 page.locator('#scList [data-act="remove"]').click()
 page.wait_for_function('document.querySelector("#scSaveState").textContent.includes("保存失败")')
 assert page.locator('#scList .target-row').count()==1
 page.locator('#current [data-act="settings"]').click()
 page.locator('[data-sc-list] [data-act="remove-sc"]').click()
 page.wait_for_function('document.querySelector("#saveState").textContent.includes("保存失败")')
 assert page.locator('[data-sc-list] .target-row').count()==1
 page.locator('#current > .target-wrap > .target-row [data-act="remove"]').click()
 btn=page.locator('#current .armed');assert btn.locator('.confirm-text').is_visible()
 page.wait_for_function('(()=>{const el=document.querySelector("#current .armed");return el.scrollWidth<=el.clientWidth})()')
 page.locator('#current').screenshot(path='/tmp/pd-console-shortcuts.png')
 assert not errors,errors
 browser.close()
print('PASS: one-click deletion, last scoped item, reload persistence, both failure rollbacks, visible app confirmation')
