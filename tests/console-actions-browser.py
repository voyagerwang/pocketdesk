"""
[INPUT]: 完整控制台与隔离文件/解锁接口替身。
[OUTPUT]: 网页选择文件、原地密码保存、开关、配对核对、撤销与错误恢复的真实点击验证。
[POS]: 不接触真实密码/设备配置，网络请求严格截留在测试页。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import mimetypes
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True)
 page=browser.new_page(viewport={'width':1100,'height':900});page.set_default_timeout(7000)
 state={'configured':True,'enabled':False,'hasPassword':False,'credentials':[]};files=[];errors=[];writes=[];uploads={}
 page.on('pageerror',lambda e:errors.append(str(e)))
 def route(r):
  path=urlparse(r.request.url).path
  if path.startswith('/api/console/') and r.request.method=='POST':
   assert r.request.headers['x-pocketdesk-console']=='1';writes.append(path)
   if path.endswith('/files/pick'):
    files.append({'name':'测试文件.pdf','size':1048576,'accepted':False});return r.fulfill(json={'message':'已准备好，等待手机接收。'})
   if path.endswith('/files/upload/start'):
    uploads['meta']=r.request.post_data_json['files'];uploads['chunks']=[];return r.fulfill(json={'uploadId':'drop-1','chunkBytes':3})
   if path.endswith('/files/upload/chunk'):
    uploads['chunks'].append(r.request.post_data_json);return r.fulfill(json={'received':3})
   if path.endswith('/files/upload/finish'):
    files.append({'name':'PocketDesk-2个文件.zip','size':5,'accepted':False});return r.fulfill(json={'message':'已准备好，等待手机下载。'})
   if path.endswith('/files/upload/cancel'):return r.fulfill(json={'ok':True})
   data=r.request.post_data_json
   if path.endswith('/password'):assert data['password']=='fixture-password';state['hasPassword']=True
   if path.endswith('/enabled'):state['enabled']=data['enabled']
   if path.endswith('/pair'):state['pair']={'pairId':'test','code':'123456','link':'pocketdesk://pair#test','qr':'data:image/png;base64,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'}
   if path.endswith('/confirm'):state.pop('pair',None);state['credentials']=[{'id':'phone','label':'我的手机'}]
   if path.endswith('/revoke'):state['credentials']=[]
   return r.fulfill(json=state)
  if path=='/api/console/files':return r.fulfill(json={'files':files})
  if path=='/api/console/unlock':return r.fulfill(json=state)
  if path=='/api/status':return r.fulfill(json={'targets':[],'shortcuts':[],'actions':[],'log':[],'accessibility':True,'theme':'classic','workspaceURL':'http://192.168.1.2:46387/?token=fixture','secureURL':'https://192.168.1.2:46487/'})
  if path.startswith('/api/'):return r.fulfill(json={'ok':True,'devices':[]})
  f=ROOT/'Web'/path.lstrip('/')
  if f.is_file():return r.fulfill(body=f.read_bytes(),content_type=mimetypes.guess_type(str(f))[0] or 'text/plain')
  r.fulfill(status=404,body='')
 page.route('**/*',route);page.goto('http://127.0.0.1:47899/console.html',wait_until='networkidle')
 assert page.locator('#connect img').count()==1
 assert page.locator('#secureQrItem').count()==0
 assert page.get_by_text('手机连接 · App 和浏览器通用',exact=True).is_visible()
 assert page.locator('#ipUrl').get_attribute('href')=='http://192.168.1.2:46387/?token=fixture'
 page.locator('#sendFilePick').click();page.wait_for_function('document.querySelector("#sendFileList").textContent.includes("测试文件")')
 page.evaluate("""() => {
   const transfer=new DataTransfer();transfer.items.add(new File(['hello'],'甲.txt'));transfer.items.add(new File([],'空.txt'));
   document.querySelector('#sendFileDrop').dispatchEvent(new DragEvent('drop',{dataTransfer:transfer,bubbles:true,cancelable:true}));
 }""")
 page.wait_for_function('document.querySelector("#sendFileList").textContent.includes("2个文件")')
 assert uploads['meta']==[{'name':'甲.txt','size':5},{'name':'空.txt','size':0}]
 assert [(c['index'],c['offset']) for c in uploads['chunks']]==[(0,0),(0,3),(1,0)]
 assert page.locator('#quEnabled').is_disabled()
 page.locator('#quPassword').fill('fixture-password');page.locator('#quPasswordForm button').click()
 page.wait_for_function('!document.querySelector("#quEnabled").disabled');assert page.locator('#quPassword').input_value()==''
 page.locator('#quEnabled').check();page.wait_for_function('!document.querySelector("#quPairStart").disabled')
 page.locator('#quPairStart').click();page.wait_for_function('!document.querySelector("#quPairConfirm").hidden')
 assert page.get_by_text('解锁授权专用 · 仅用 PocketDesk App 扫描',exact=True).is_visible()
 assert page.locator('#quPairCode').inner_text()=='核对码 123456'
 page.locator('#quick-unlock-card').screenshot(path='/tmp/pd-web-unlock-config.png')
 page.locator('#quPairConfirm').click();page.wait_for_function('document.querySelector("#quDevices").textContent.includes("我的手机")')
 page.once('dialog',lambda d:d.accept());page.locator('#quDevices button').click();page.wait_for_function('document.querySelector("#quDevices").textContent.includes("尚未")')
 assert page.locator('#quOpen').count()==0
 page.locator('#phone-files-card').screenshot(path='/tmp/pd-web-send-files.png')
 page.set_viewport_size({'width':390,'height':844});assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
 assert not errors,errors;browser.close()
print('PASS: file picker and chunked drop, password not retained, enable, single QR/code confirmation, revoke, responsive layout')
