"""
[INPUT]: 完整控制台静态资源、两家独立模型服务的隔离 HTTP 替身与 Playwright。
[OUTPUT]: 验证服务商切换/持久列表、仅保存与保存启用、凭证身份隔离、草稿/移除保护和窄屏双主题。
[POS]: 多服务商模型配置的真实 DOM 与布局回归；所有请求截留，不读取生产配置、不调用真实模型或修改电脑设置。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
"""
import base64
from copy import deepcopy
import mimetypes
import os
from pathlib import Path
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = Path(os.environ.get('POCKETDESK_MODEL_SCREENSHOTS', '/tmp/pocketdesk-provider-switch'))
ARTIFACTS.mkdir(parents=True, exist_ok=True)
PROVIDERS = [
    {'id': 'legacy-api', 'name': 'DeepSeek', 'baseURL': 'https://api.deepseek.com',
     'model': 'deepseek-flash', 'hasKey': True, 'keyHint': 'sk-…0000', 'configured': True},
    {'id': 'openai-test', 'name': 'OpenAI', 'baseURL': 'https://api.openai.com/v1',
     'model': 'gpt-fixture', 'hasKey': True, 'keyHint': 'sk-…2222', 'configured': True},
]
INITIAL = {'backend': 'api', 'activeProviderID': 'legacy-api', 'providers': deepcopy(PROVIDERS)}


def origin(value):
    parsed = urlparse(value)
    port = parsed.port or (443 if parsed.scheme == 'https' else 80)
    return parsed.scheme, parsed.hostname, port


with sync_playwright() as playwright:
    browser = playwright.chromium.launch(headless=True)
    page = browser.new_page(viewport={'width': 1100, 'height': 1100})
    page.set_default_timeout(7000)
    state = deepcopy(INITIAL)
    requests, errors = [], []

    def provider(identifier):
        return next((item for item in state['providers'] if item['id'] == identifier), None)

    def sync_compatibility():
        active = provider(state['activeProviderID'])
        state.update({
            'baseURL': active['baseURL'] if active else '',
            'model': active['model'] if active else '',
            'hasKey': active['hasKey'] if active else False,
            'keyHint': active['keyHint'] if active else '',
            'activeModel': 'gpt-6-luna' if state['backend'] == 'codex' else (active['model'] if active else ''),
            'configured': state['backend'] == 'codex' or bool(active and active['configured']),
            'backupConfigured': any(item['configured'] for item in state['providers']),
        })

    def validate_fields(fields, previous=None):
        target = fields.get('baseURL', previous['baseURL'] if previous else '').strip()
        model = fields.get('model', previous['model'] if previous else '').strip()
        key = fields.get('apiKey', '').strip()
        if urlparse(target).scheme not in ['http', 'https'] or not urlparse(target).hostname:
            return '请填写有效的 API 地址。'
        if not model:
            return '请填写模型 ID。'
        if not key and not (previous and previous['hasKey'] and origin(target) == origin(previous['baseURL'])):
            return '请填写此服务商对应的密钥。'
        return None

    sync_compatibility()
    page.on('pageerror', lambda error: errors.append(str(error)))

    def route(request_route):
        request = request_route.request
        path = urlparse(request.url).path
        if path == '/api/v1/model-config':
            if request.method == 'POST':
                body = request.post_data_json
                requests.append((path, body))
                action = body.get('action')
                if action == 'save-provider':
                    fields = body['provider']
                    previous = provider(fields.get('id'))
                    issue = validate_fields(fields, previous)
                    if issue:
                        return request_route.fulfill(status=400, json={'error': issue})
                    item = deepcopy(previous) if previous else {'id': f'fixture-provider-{len(state["providers"]) + 1}'}
                    item.update({key: fields[key].strip() for key in ['name', 'baseURL', 'model']})
                    if 'apiKey' in fields:
                        item.update({'hasKey': bool(fields['apiKey']), 'keyHint': 'sk-…NEW3'})
                    item['configured'] = bool(item['baseURL'] and item['model'] and item['hasKey'])
                    if previous:
                        state['providers'][state['providers'].index(previous)] = item
                    else:
                        state['providers'].append(item)
                    if body['activate']:
                        state.update({'backend': 'api', 'activeProviderID': item['id']})
                elif action == 'activate-provider':
                    assert provider(body['providerId']), '只能启用已保存服务商'
                    state.update({'backend': 'api', 'activeProviderID': body['providerId']})
                elif action == 'remove-provider':
                    state['providers'] = [item for item in state['providers'] if item['id'] != body['providerId']]
                    if state['activeProviderID'] == body['providerId']:
                        state['activeProviderID'] = ''
                elif body == {'backend': 'codex'}:
                    state['backend'] = 'codex'
                else:
                    raise AssertionError('模型保存接口收到未知事务')
                sync_compatibility()
            return request_route.fulfill(json={'config': deepcopy(state)})
        if path == '/api/v1/model-test':
            body = request.post_data_json
            requests.append((path, body))
            if body.get('backend') == 'codex':
                return request_route.fulfill(json={
                    'ok': True, 'host': 'codex', 'activeModel': 'gpt-6-luna',
                    'tool': {'supported': True, 'name': 'read_page', 'final': '模拟工具通过'},
                })
            previous = provider(body.get('providerId'))
            issue = validate_fields(body, previous)
            if issue:
                return request_route.fulfill(status=400, json={'error': issue})
            return request_route.fulfill(json={
                'ok': True, 'host': urlparse(body.get('baseURL', previous['baseURL'] if previous else '')).hostname,
                'model': body.get('model', previous['model'] if previous else ''),
                'tool': {'supported': True, 'name': 'read_page', 'final': '模拟工具通过'},
            })
        if path == '/api/status':
            return request_route.fulfill(json={
                'targets': [], 'shortcuts': [], 'actions': [], 'log': [],
                'accessibility': True, 'theme': 'classic',
                'ipWorkspaceURL': 'http://192.0.2.1:46387/?token=fixture-token',
            })
        if path == '/api/qr':
            return request_route.fulfill(body=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='), content_type='image/png')
        if path.startswith('/api/'):
            return request_route.fulfill(json={'ok': True, 'devices': [], 'files': [], 'order': []})
        file = ROOT / 'Web' / path.lstrip('/')
        if file.is_file():
            return request_route.fulfill(body=file.read_bytes(), content_type=mimetypes.guess_type(str(file))[0] or 'text/plain')
        request_route.fulfill(status=404, body='')

    def row(identifier):
        return page.locator(f'#mProviders .model-service[data-provider-id="{identifier}"]')

    def action(identifier, name):
        return row(identifier).locator(f'button[data-model-action="{name}"]')

    def wait_active(identifier):
        page.wait_for_function('''(id) => {
            const row = document.querySelector(`#mProviders .model-service[data-provider-id="${id}"]`);
            return row && !row.querySelector('button[data-model-action="activate"]');
        }''', arg=identifier)
        assert state['backend'] == 'api'
        assert state['activeProviderID'] == identifier

    def wait_closed():
        page.wait_for_function('document.querySelector("#mApiConfig").hidden')

    def assert_key_required():
        message = page.locator('#mState').inner_text()
        assert '密钥' in message or 'API Key' in message, message

    def assert_profiles(expected):
        assert state['providers'] == expected
        for item in expected:
            text = row(item['id']).inner_text()
            for field in ['name', 'baseURL', 'model', 'keyHint']:
                assert item[field] in text, field

    page.route('**/*', route)
    page.goto('http://127.0.0.1:47899/console.html', wait_until='networkidle')
    assert page.locator('#mProviders .model-service').count() == 2
    assert_profiles(PROVIDERS)
    assert not page.locator('#mApiConfig').is_visible()
    assert action('legacy-api', 'activate').count() == 0
    page.locator('#modelSettings').screenshot(path=str(ARTIFACTS / 'desktop-saved.png'))

    # 服务身份携带自己已保存的字段，来回切换不改另一家的配置。
    for identifier in ['openai-test', 'legacy-api']:
        action(identifier, 'activate').click()
        wait_active(identifier)
        assert requests[-1][1] == {'action': 'activate-provider', 'providerId': identifier}
        assert_profiles(PROVIDERS)
    action('openai-test', 'test').click()
    page.locator('#mOut').wait_for(state='visible')
    assert requests[-1][1] == {'backend': 'api', 'providerId': 'openai-test'}
    assert state['activeProviderID'] == 'legacy-api'

    # 非活动服务仅保存，不偷换小精灵当前来源；Enter 走保存并使用事务。
    action('openai-test', 'edit').click()
    assert page.locator('#mKey').input_value() == ''
    assert '留空保留' in page.locator('#mKey').get_attribute('placeholder')
    page.locator('#mModel').fill('gpt-fixture-edited')
    page.locator('#mSaveOnly').click()
    wait_closed()
    assert requests[-1][1] == {
        'action': 'save-provider', 'activate': False,
        'provider': {'id': 'openai-test', 'name': 'OpenAI', 'baseURL': PROVIDERS[1]['baseURL'], 'model': 'gpt-fixture-edited'},
    }
    assert state['activeProviderID'] == 'legacy-api'
    saved_pair = deepcopy(state['providers'])
    page.reload(wait_until='networkidle')
    assert_profiles(saved_pair)
    assert len(state['providers']) == 2
    wait_active('legacy-api')

    # 新服务即使地址碰巧与另一服务同源，也不能借用它的密钥。
    page.locator('#mAdd').click()
    page.locator('#mName').fill('第三家 API')
    page.locator('#mBase').fill(PROVIDERS[0]['baseURL'])
    page.locator('#mModel').fill('fixture-new-model')
    assert page.locator('#mKey').input_value() == ''
    count = len(requests)
    for selector in ['#mTest', '#mSaveOnly', '#mSave']:
        page.locator(selector).click()
        assert_key_required()
        assert len(requests) == count
    page.locator('#mKey').fill('fixture-new-provider-key')
    page.locator('#mSaveOnly').click()
    wait_closed()
    added = next(item for item in state['providers'] if item['name'] == '第三家 API')
    added_id = added['id']
    assert state['activeProviderID'] == 'legacy-api'
    assert len(state['providers']) == 3
    assert requests[-1][1] == {
        'action': 'save-provider', 'activate': False,
        'provider': {'name': '第三家 API', 'baseURL': PROVIDERS[0]['baseURL'], 'model': 'fixture-new-model', 'apiKey': 'fixture-new-provider-key'},
    }
    assert 'fixture-new-provider-key' not in row(added_id).inner_text()
    action(added_id, 'edit').click()
    page.locator('#mModel').fill('fixture-enabled-model')
    page.locator('#mModel').press('Enter')
    wait_closed()
    wait_active(added_id)
    assert requests[-1][1]['activate'] is True
    assert requests[-1][1]['provider']['id'] == added_id
    assert 'apiKey' not in requests[-1][1]['provider']
    saved_three = deepcopy(state['providers'])
    page.reload(wait_until='networkidle')
    assert_profiles(saved_three)
    wait_active(added_id)

    # 编辑现有服务换 origin 必须显式填新 Key，测试和两种保存都零请求。
    action('openai-test', 'edit').click()
    page.locator('#mBase').fill('https://different.example/v1')
    count = len(requests)
    for selector in ['#mTest', '#mSaveOnly', '#mSave']:
        page.locator(selector).click()
        assert_key_required()
        assert len(requests) == count
    page.locator('#mCancel').click()
    assert action('openai-test', 'edit').evaluate('(node) => node === document.activeElement')
    assert_profiles(saved_three)

    # 编辑期间冻结所有摘要入口；迟到或跨服务编辑事件只能保留同一草稿。
    action('openai-test', 'edit').click()
    page.locator('#mTest').click()
    page.locator('#mOut').wait_for(state='visible')
    assert requests[-1][1]['providerId'] == 'openai-test'
    page.locator('#mBase').fill('https://draft.example/v1')
    page.locator('#mModel').fill('fixture-unsaved-model')
    page.locator('#mKey').fill('fixture-unsaved-key')
    assert not page.locator('#mOut').is_visible()
    assert page.locator('#mAdd').is_disabled()
    assert page.locator('#mUseCodex').is_disabled()
    for button in page.locator('#mProviders button[data-model-action]').all():
        assert button.is_disabled()
    count = len(requests)
    for button in [action('openai-test', 'edit'), action('legacy-api', 'edit'), page.locator('#mAdd'), page.locator('#mUseCodex')]:
        button.dispatch_event('click')
        assert page.locator('#mBase').input_value() == 'https://draft.example/v1'
        assert page.locator('#mModel').input_value() == 'fixture-unsaved-model'
        assert page.locator('#mKey').input_value() == 'fixture-unsaved-key'
        assert len(requests) == count
    page.locator('#mKeyToggle').click()
    assert page.locator('#mKey').get_attribute('type') == 'text'
    page.locator('#mKeyToggle').click()
    page.locator('#modelSettings').screenshot(path=str(ARTIFACTS / 'desktop-editor.png'))
    page.locator('#mCancel').click()
    wait_closed()
    for selector in ['#mName', '#mBase', '#mModel', '#mKey']:
        assert page.locator(selector).input_value() == ''
    assert page.locator('#mKey').get_attribute('type') == 'password'
    assert not page.locator('#mOut').is_visible()
    assert action('openai-test', 'edit').evaluate('(node) => node === document.activeElement')
    assert_profiles(saved_three)

    # 移除第一下只解释影响，修改或取消撤销确认；第二下只删除该服务。
    action('openai-test', 'edit').click()
    count = len(requests)
    page.locator('#mClear').click()
    assert len(requests) == count
    assert len(state['providers']) == 3
    page.locator('#mModel').fill('fixture-cancel-removal')
    assert '确认' not in page.locator('#mClear').inner_text()
    page.locator('#mClear').click()
    assert len(requests) == count
    page.locator('#mCancel').click()
    assert_profiles(saved_three)
    action('openai-test', 'edit').click()
    page.locator('#mClear').click()
    page.locator('#mClear').click()
    wait_closed()
    assert requests[-1][1] == {'action': 'remove-provider', 'providerId': 'openai-test'}
    assert len(state['providers']) == 2
    assert row('openai-test').count() == 0
    wait_active(added_id)
    assert provider('legacy-api') == PROVIDERS[0]

    # Codex 是独立入口，切换不修改任一 API 服务，切回保留服务身份。
    remaining = deepcopy(state['providers'])
    page.locator('#mUseCodex').click()
    assert not page.locator('#mApiFields').is_visible()
    page.locator('#mSave').click()
    wait_closed()
    assert requests[-1][1] == {'backend': 'codex'}
    assert state['backend'] == 'codex'
    assert_profiles(remaining)
    action('legacy-api', 'activate').click()
    wait_active('legacy-api')
    assert_profiles(remaining)

    # 同批截图覆盖两种主题及窄屏，主题只改测试 DOM，不请求设备设置。
    page.locator('#modelSettings').screenshot(path=str(ARTIFACTS / 'desktop-provider-list.png'))
    for width in [390, 320]:
        page.set_viewport_size({'width': width, 'height': 844})
        page.evaluate('document.documentElement.dataset.theme = "classic"')
        page.locator('#modelSettings').screenshot(path=str(ARTIFACTS / f'mobile-{width}-saved.png'))
        action(added_id, 'edit').click()
        page.evaluate('document.documentElement.dataset.theme = "muji"')
        page.locator('#modelSettings').screenshot(path=str(ARTIFACTS / f'mobile-{width}-editor-muji.png'))
        # 只验本次模型区；整页其它控制台区块的旧最小宽约束不由本回归承诺。
        assert page.locator('#modelSettings').evaluate('''(section) => {
            const bounds = section.getBoundingClientRect();
            return bounds.left >= 0 && bounds.right <= window.innerWidth
                && section.scrollWidth <= section.clientWidth;
        }''')
        assert page.locator('#mSave').bounding_box()['height'] >= 44
        assert page.locator('#mSaveOnly').bounding_box()['height'] >= 44
        assert page.locator('#mKeyToggle').bounding_box()['height'] >= 44
        page.locator('#mCancel').click()
    assert not errors, errors
    browser.close()
print('PASS: provider switching, independent persistence, save/activate separation, key isolation, draft/removal guards, responsive themes')
print(f'Screenshots: {ARTIFACTS}')
