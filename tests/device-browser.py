"""Device presentation and heartbeat integration with isolated HTTP fixtures; no desktop input."""
import json
import mimetypes
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright
ROOT = Path(__file__).resolve().parents[1]
with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page(viewport={"width": 1100, "height": 850})
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    devices = [{"id":"abcdef12-0000-4000-8000-000000000000", "name":"<img src=x onerror=alert(1)>", "model":"Pixel 8", "platform":"Android", "browser":"Chrome", "started":100, "online":True,"controlling":True}, {"id":"12345678-0000-4000-8000-000000000000","name":"旧手机", "platform":"iOS", "browser":"Safari", "started":10,"ended":50,"online":False}]
    writes = []
    def route(r):
        path = urlparse(r.request.url).path
        if path == '/api/devices': return r.fulfill(json={"devices":devices})
        if path == '/api/devices/name':
            body = r.request.post_data_json
            for d in devices:
                if d['id'] == body['id']: d['name'] = body['name']
            return r.fulfill(json={"ok":True})
        if path == '/api/status': return r.fulfill(json={"targets":[],"shortcuts":[],"actions":[],"log":[],"theme":"classic","accessibility":False,"phoneLastSeen":0})
        if path.startswith('/api/'):
            if path == '/api/pair': writes.append({"headers": r.request.headers, "body":r.request.post_data_json})
            return r.fulfill(json={"ok": True})
        f = ROOT / 'Web' / ('index.html' if path == '/' else path.lstrip('/'))
        if f.is_file(): return r.fulfill(body=f.read_bytes(),content_type=mimetypes.guess_type(str(f))[0] or 'text/plain')
        r.fulfill(status=404,body='')
    page.route('**/*',route)
    page.goto('http://localhost:47899/console.html',wait_until='networkidle')
    page.get_by_text('1 台设备已连接',exact=True).click()
    assert page.locator('#device-current').inner_text().find('Pixel 8') >= 0
    assert page.locator('#device-current img').count() == 0
    page.get_by_text('连接记录',exact=True).click()
    assert page.locator('#device-history').inner_text().find('旧手机') >= 0
    page.locator('#device-current button').first.click()
    page.locator('#device-current input').fill('我的 Pixel')
    page.locator('#device-current').get_by_text('保存',exact=True).click()
    page.wait_for_function("document.querySelector('#device-current strong').textContent === '我的 Pixel'")
    assert '我的 Pixel' in page.locator('#device-history').inner_text()
    page.screenshot(path='/tmp/pocketdesk-device-popover.png')
    page.keyboard.press('Escape')
    assert not page.locator('#device-menu').evaluate('(e)=>e.open')
    devices.clear()
    page.evaluate('refreshDevices()')
    assert page.locator('#device-count').inner_text() == '暂无设备连接'
    page.add_init_script("Object.defineProperty(window, 'isSecureContext', {value: false});")
    page.goto('http://localhost:47899/?token=test-token',wait_until='networkidle')
    page.locator('#phone-settings-open').click()
    assert page.locator('#wrist-group').is_visible()
    assert page.locator('#wrist-group .wrist-main span').inner_text() == '甩送'
    assert page.locator('#wrist-sensitivity-row').is_hidden()
    page.evaluate("window.pocketdeskMotion.status = () => 'running'; updateWristUI();")
    assert page.locator('#wrist-sensitivity-row').is_visible()
    page.evaluate("window.pocketdeskMotion.status = () => 'unsupported'; updateWristUI();")
    assert page.locator('#wrist-sensitivity-row').is_hidden()
    assert page.locator('#wrist-toggle').is_enabled()
    page.locator('#wrist-toggle').click()
    assert not page.locator('#wrist-toggle').is_checked()
    assert '运动权限' in page.locator('#wrist-note').inner_text()
    assert page.locator('#wrist-note').inner_text()
    assert page.locator('#device-name').count() == 0
    assert page.locator('#device-description').inner_text()
    page.evaluate('heartbeatTick()')
    assert writes[-1]['headers']['authorization'] == 'Bearer test-token'
    assert writes[-1]['body']['name']
    identity = writes[-1]['body']['deviceId']
    page.reload(wait_until='networkidle')
    assert page.evaluate('window.pocketdeskDevice().deviceId') == identity
    assert not errors, errors
    permission_page = browser.new_page()
    permission_page.route('**/*', route)
    permission_page.add_init_script("""
      window.permissionCalls = [];
      window.DeviceMotionEvent = class { static requestPermission() { window.permissionCalls.push(['motion', navigator.userActivation.isActive]); return Promise.resolve('denied'); } };
      window.DeviceOrientationEvent = class { static requestPermission() { window.permissionCalls.push(['orientation', navigator.userActivation.isActive]); return Promise.resolve('denied'); } };
    """)
    permission_page.goto('http://localhost:47899/', wait_until='networkidle')
    permission_page.locator('#phone-settings-open').click()
    assert permission_page.evaluate('permissionCalls.length') == 0
    permission_page.locator('#wrist-toggle').click()
    permission_page.wait_for_function('permissionCalls.length === 2')
    assert permission_page.evaluate('permissionCalls.every(c => c[1])')
    assert not permission_page.locator('#wrist-toggle').is_checked()
    assert permission_page.locator('#wrist-sensitivity-row').is_hidden()
    styles = permission_page.evaluate("""() => {
      const a = getComputedStyle(document.querySelector('.wrist-main'));
      const b = getComputedStyle(document.querySelector('.sheet-group[aria-label="触控板"] h2'));
      return a.fontSize === b.fontSize && a.fontWeight === b.fontWeight && a.color === b.color;
    }""")
    assert styles
    browser.close()
    print('device-browser: passed')
