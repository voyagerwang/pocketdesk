"""
[INPUT]: 依赖 Playwright、Pillow 与仓库 Web 静态资源；用模拟 HTTP 接口记录逐图上传和草稿提交。
[OUTPUT]: 验证多选删除保序、上传失败重试、正文/纯图等待压缩、满额删除追加和横向布局。
[POS]: tests 的多图浏览器集成回归；不连接真实服务、不注入桌面输入，截图仅写入 /tmp。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import io, json, mimetypes
from pathlib import Path
from urllib.parse import urlparse
from PIL import Image
from playwright.sync_api import sync_playwright
ROOT = Path(__file__).resolve().parents[1]
def picture(name, color):
    b=io.BytesIO(); Image.new('RGB',(120,90),color).save(b,format='PNG')
    return {'name':name,'mimeType':'image/png','buffer':b.getvalue()}
with sync_playwright() as p:
    browser=p.chromium.launch(headless=True)
    page=browser.new_page(viewport={'width':390,'height':844},is_mobile=True,has_touch=True)
    uploads=[]; commits=[]; errors=[]; fail={'upload':False,'submit':False}; held=[]
    page.on('pageerror',lambda e: errors.append(str(e)))
    def route(r):
        path=urlparse(r.request.url).path
        if path.startswith('/api/'):
            data={'ok':True}
            if path=='/api/status': data={'targets':[{'id':'feishu','name':'飞书'},{'id':'chrome','name':'Chrome'}],'shortcuts':[],'accessibility':True,'frontmostId':'feishu','frontmostName':'飞书','theme':'classic'}
            elif path=='/api/image':
                uploads.append(r.request.post_data_json)
                if fail['upload']:
                    r.fulfill(status=422,json={'error':'测试上传失败，图片保留'}); return
            elif path=='/api/live-input':
                body=r.request.post_data_json
                if body.get('submit'): commits.append(body)
                if body.get('submit') and fail['submit']:
                    r.fulfill(status=409,json={'error':'图片发送已开始过，请检查电脑内容并新建草稿，避免重复发送。'}); return
                data={'outcome':'sent','mode':'selection','committed':bool(body.get('submit')),'detail':'测试提交'}
            elif path=='/api/screen/state': data={'locked':False}
            elif path=='/api/input-context': data={'context':'test','scope':'element','name':'Test editor'}
            r.fulfill(json=data); return
        f=ROOT/'Web'/(path.lstrip('/') or 'index.html')
        if not f.is_file(): r.fulfill(status=404); return
        r.fulfill(body=f.read_bytes(),content_type=mimetypes.guess_type(f)[0] or 'text/plain')
    page.route('**/*',route)
    page.goto('http://pocketdesk.test/'); page.wait_for_load_state('networkidle')
    initial_draft=page.evaluate('liveDraftId')
    page.locator('.target[data-target-id="feishu"]').click()
    page.wait_for_timeout(100)
    assert page.evaluate('liveDraftId')==initial_draft
    assert page.evaluate('liveTarget') is None
    assert page.locator('#image-file').get_attribute('multiple') is not None
    files=[picture('red.png','red'),picture('green.png','green'),picture('blue.png','blue')]
    page.locator('#image-file').set_input_files(files)
    page.wait_for_function("document.querySelectorAll('#image-preview img').length === 3")
    page.wait_for_timeout(300)
    page.screenshot(path='/tmp/pocketdesk-multi-image-selected.png',full_page=True)
    thumbs=page.locator('#image-preview img').evaluate_all('(els)=>els.map(e=>e.src)')
    assert len(set(thumbs))==3
    page.locator('#image-preview button').nth(1).click()
    assert page.locator('#image-preview img').count()==2
    assert page.locator('#image-preview img').evaluate_all('(els)=>els.map(e=>e.src)')==[thumbs[0],thumbs[2]]
    page.locator('#text').fill('三张选两张'); page.locator('#send').click()
    page.wait_for_function("document.querySelector('#text').value === '' && !submittingDraft")
    assert len(commits)==1 and commits[0]['text']=='三张选两张'
    assert page.locator('#image-preview img').count()==0 or page.locator('#image-preview').is_hidden()
    print(json.dumps({'phase':'multi-select-remove-send','commit':{k:v for k,v in commits[0].items() if k!='text'},'uploads':len(uploads)},ensure_ascii=False))
    fail['upload']=True
    page.locator('#image-file').set_input_files(files[:2])
    page.wait_for_function("document.querySelectorAll('#image-preview img').length === 2")
    page.locator('#text').fill('上传失败保留'); page.locator('#send').click(); page.wait_for_timeout(600)
    assert len(commits)==1 and page.locator('#text').input_value()=='上传失败保留'
    assert page.locator('#image-preview img').count()==2
    fail['upload']=False; page.locator('#send').click()
    page.wait_for_function("document.querySelector('#text').value === '' && !submittingDraft")
    assert len(commits)==2
    page.evaluate("() => { window.savedCompress = compressImage; compressImage = file => new Promise(resolve => { window.releaseCompression = () => savedCompress(file).then(resolve); }); }")
    page.locator('#image-file').set_input_files(files[:1]); page.locator('#text').fill('等待图片处理'); page.locator('#send').click(); page.wait_for_timeout(150)
    assert len(commits)==2
    page.evaluate('releaseCompression()'); page.wait_for_function("document.querySelector('#text').value === '' && !submittingDraft")
    assert len(commits)==3 and len(commits[-1].get('imageIds',[]))==1
    page.evaluate('() => { compressImage = savedCompress; }')
    page.locator('#image-file').set_input_files(files[:1])
    page.wait_for_function("document.querySelectorAll('#image-preview img').length === 1")
    page.locator('#image-file').set_input_files([{'name':'broken.png','mimeType':'image/png','buffer':b'broken'}]); page.wait_for_timeout(250)
    assert page.locator('#image-preview img').count()==1
    page.evaluate("() => { clearCompose(); window.savedCompress = compressImage; compressImage = file => new Promise(resolve => { window.releaseCompression = () => savedCompress(file).then(resolve); }); }")
    page.locator('#image-file').set_input_files(files[:1]); page.locator('#send').click(); page.wait_for_timeout(150)
    assert len(commits)==3
    page.evaluate('releaseCompression()'); page.wait_for_function("!submittingDraft && document.querySelector('#image-preview').hidden")
    assert len(commits)==4 and len(commits[-1]['imageIds'])==1 and commits[-1]['text']==''
    page.evaluate('() => { compressImage = savedCompress; }')
    eight=[picture(f'{i}.png', 'red' if i%2 else 'blue') for i in range(8)]
    page.locator('#image-file').set_input_files(eight)
    page.wait_for_function("document.querySelectorAll('#image-preview img').length === 8")
    page.locator('#image-preview button').nth(3).click(); page.locator('#image-file').set_input_files(files[:1])
    page.wait_for_function("document.querySelectorAll('#image-preview img').length === 8")
    assert page.evaluate('document.documentElement.scrollWidth <= innerWidth')
    page.locator('#send').click(); page.wait_for_function("!submittingDraft && document.querySelector('#image-preview').hidden")
    assert len(commits)==5 and len(commits[-1]['imageIds'])==8

    # 服务端已经开始执行图片后会拒绝同 draft 重放；用户显式切换目标必须新开一轮，
    # 同时保留眼前正文和附件，旧目标身份/失败态/队列不能穿越到 Chrome。
    page.locator('#image-file').set_input_files(files[:2])
    page.wait_for_function("document.querySelectorAll('#image-preview img').length === 2")
    page.locator('#text').fill('切换目标后继续发送')
    fail['submit']=True
    page.locator('#send').click()
    page.wait_for_function("!submittingDraft && livePaused")
    old_draft=page.evaluate('liveDraftId')
    old_batch=page.evaluate('imageBatchId')
    page.evaluate('window.failedTargetQueue = liveQueue')
    page.locator('.target[data-target-id="feishu"]').click()
    page.wait_for_function("selected === 'feishu' && livePaused === false")
    same_target_draft=page.evaluate('liveDraftId')
    assert same_target_draft != old_draft
    assert page.evaluate('liveQueue !== window.failedTargetQueue')
    assert page.locator('#text').input_value()=='切换目标后继续发送'
    assert page.locator('#image-preview img').count()==2
    page.locator('#send').click()
    page.wait_for_function("!submittingDraft && livePaused")
    switching_draft=page.evaluate('liveDraftId')
    page.evaluate('window.switchingTargetQueue = liveQueue')
    page.locator('.target[data-target-id="chrome"]').click()
    page.wait_for_function("selected === 'chrome' && livePaused === false")
    new_draft=page.evaluate('liveDraftId')
    assert new_draft != switching_draft
    assert page.evaluate('liveQueue !== window.switchingTargetQueue')
    assert page.locator('#text').input_value()=='切换目标后继续发送'
    assert page.locator('#image-preview img').count()==2
    assert page.evaluate('imageBatchId')==old_batch
    assert page.evaluate("({mode:liveMode,target:liveTarget,context:inputContext})")=={'mode':None,'target':None,'context':None}
    fail['submit']=False
    page.locator('#send').click()
    page.wait_for_function("!submittingDraft && document.querySelector('#image-preview').hidden")
    assert commits[-1]['draftId']==new_draft and commits[-1]['targetId']=='chrome'
    assert commits[-1]['text']=='切换目标后继续发送' and len(commits[-1]['imageIds'])==2
    assert not errors,errors
    page.screenshot(path='/tmp/pocketdesk-multi-image-review.png',full_page=True)
    print(json.dumps({'result':'passed','commits':len(commits),'uploads':len(uploads),'pageErrors':errors}))
    browser.close()
