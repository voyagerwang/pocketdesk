/**
 * [INPUT]: 读取真实 console-agent.js，在 Node vm 中注入动态 DOM 与多服务商配置/测试 HTTP 替身。
 * [OUTPUT]: 验证 A→B→A 切换、保存但不启用、持久重载、安全文本、记录密钥隔离与编辑草稿保护。
 * [POS]: 控制台模型配置事务的无副作用回归；仅持有合成凭据，不连接真实服务或发模型请求。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const source = fs.readFileSync(path.join(__dirname, '../Web/console-agent.js'), 'utf8');
const ids = ['agentState', 'mBackend', 'mCurrent', 'mApiConfig', 'mApiFields', 'mProvider',
  'mProviders', 'mCodexStatus', 'mEmpty', 'mAdd', 'mUseCodex', 'mEditorTitle',
  'mName', 'mBase', 'mModel', 'mKey', 'mKeyLabel', 'mKeyToggle', 'mTest', 'mSave',
  'mSaveOnly', 'mCancel', 'mClear', 'mState', 'mKeyHint', 'mOut'];
const controls = ['mBackend', 'mProvider', 'mName', 'mBase', 'mModel', 'mKey',
  'mKeyToggle', 'mTest', 'mSave', 'mSaveOnly', 'mCancel', 'mClear', 'mAdd', 'mUseCodex'];
const a = { id: 'provider-a', name: '日常 DeepSeek', baseURL: 'https://api.deepseek.com',
  model: 'deepseek-flash', hasKey: true, keyHint: 'sk-…aaa1', configured: true };
const b = { id: 'provider-b', name: '备用服务', baseURL: 'https://api.backup.example/v1',
  model: 'backup-model', hasKey: true, keyHint: 'sk-…bbb2', configured: true };
const baseConfig = { backend: 'codex', activeProviderID: a.id, providers: [a, b],
  activeModel: 'gpt-6-luna', authMode: 'chatgpt', configured: true,
  ...Object.fromEntries(['baseURL', 'model', 'hasKey', 'keyHint'].map(key => [key, a[key]])) };
const apiConfig = { ...baseConfig, backend: 'api', activeModel: a.model, authMode: 'api-key' };
const clone = value => JSON.parse(JSON.stringify(value));
const origin = value => { try { return new URL(value).origin; } catch (_) { return ''; } };

// ---------- 动态 DOM 不接受 HTML 字符串 ----------
function tree(node) { return [node, ...node.children.flatMap(tree)]; }
function matches(node, selector) {
  const tag = selector.match(/^[a-z][a-z0-9-]*/i);
  if (tag && node.tagName !== tag[0].toUpperCase()) return false;
  const className = selector.match(/\.([\w-]+)/);
  if (className && !node.className.split(/\s+/).includes(className[1])) return false;
  for (const [, name, value] of selector.matchAll(/\[([\w-]+)(?:=['"]?([^'"\]]+)['"]?)?\]/g)) {
    if (!node.hasAttribute(name) || (value !== undefined && node.getAttribute(name) !== value)) return false;
  }
  return true;
}

async function panel({ config = baseConfig, keys, probe, failSave = false, failRead = false, failProbe = false } = {}) {
  const stored = clone(config);
  const secrets = new Map(keys || [[a.id, 'fixture-secret-a'], [b.id, 'fixture-secret-b']]);
  const requests = [], resolvedProbes = [];
  let focused = null, nextID = 1;
  class Element {
    constructor(tagName = 'div', id = '') {
      Object.assign(this, { tagName: tagName.toUpperCase(), id, value: '', className: '',
        disabled: false, hidden: false, type: '', placeholder: '', handlers: {}, attributes: {},
        dataset: {}, children: [], parentElement: null, _text: '' });
    }
    get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
    set textContent(value) { this._text = String(value ?? ''); this.children = []; }
    set innerHTML(_) { throw new Error('服务商列表必须使用安全文本 DOM，不可插入 HTML。'); }
    addEventListener(type, handler) { this.handlers[type] = handler; }
    setAttribute(name, value) {
      this.attributes[name] = String(value);
      if (name === 'class') this.className = String(value);
      if (name === 'id') this.id = String(value);
      if (name.startsWith('data-')) this.dataset[name.slice(5).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = String(value);
    }
    getAttribute(name) {
      if (name === 'id') return this.id || null;
      if (name === 'class') return this.className || null;
      if (name.startsWith('data-')) return this.dataset[name.slice(5).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] ?? null;
      return this.attributes[name] ?? null;
    }
    hasAttribute(name) { return this.getAttribute(name) !== null; }
    removeAttribute(name) { delete this.attributes[name]; }
    append(...nodes) {
      for (const node of nodes) { node.parentElement = this; this.children.push(node); }
    }
    appendChild(node) { this.append(node); return node; }
    replaceChildren(...nodes) { this.children = []; this._text = ''; this.append(...nodes); }
    querySelectorAll(selector) { return tree(this).slice(1).filter(node => matches(node, selector)); }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
    focus() { focused = this; }
  }
  const elements = Object.fromEntries(ids.map(id => [id, new Element(id === 'mApiConfig' ? 'form' : 'div', id)]));
  elements.mApiConfig.hidden = true;
  elements.mOut.hidden = true;
  function view() {
    const active = stored.providers.find(record => record.id === stored.activeProviderID);
    stored.providers.forEach(record => {
      record.hasKey = secrets.has(record.id);
      record.configured = Boolean(record.baseURL && record.model && record.hasKey);
    });
    Object.assign(stored, { baseURL: active?.baseURL || '', model: active?.model || '',
      hasKey: active?.hasKey || false, keyHint: active?.keyHint || '',
      activeModel: stored.backend === 'codex' ? 'gpt-6-luna' : (active?.model || ''),
      configured: stored.backend === 'codex' || Boolean(active?.configured),
      authMode: stored.backend === 'codex' ? 'chatgpt' : 'api-key' });
    return clone(stored);
  }
  function mutation(body) {
    if (body.action === 'save-provider') {
      const draft = body.provider;
      const existing = stored.providers.find(record => record.id === draft.id);
      assert.ok(draft.name && draft.baseURL && draft.model, '保存记录必须完整');
      if (!draft.apiKey && (!existing || !secrets.has(existing.id) || origin(existing.baseURL) !== origin(draft.baseURL))) {
        return { error: '此服务商需要对应的密钥。' };
      }
      const id = draft.id || `new-provider-${nextID++}`;
      const record = { ...existing, id, name: draft.name, baseURL: draft.baseURL, model: draft.model };
      if (draft.apiKey) { secrets.set(id, draft.apiKey); record.keyHint = `sk-…new${nextID}`; }
      if (existing) stored.providers[stored.providers.indexOf(existing)] = record;
      else stored.providers.push(record);
      if (body.activate) { stored.backend = 'api'; stored.activeProviderID = id; }
    } else if (body.action === 'activate-provider') {
      assert.ok(stored.providers.some(record => record.id === body.providerId && record.configured));
      stored.activeProviderID = body.providerId;
      stored.backend = 'api';
    } else if (body.action === 'remove-provider') {
      stored.providers = stored.providers.filter(record => record.id !== body.providerId);
      secrets.delete(body.providerId);
      if (stored.activeProviderID === body.providerId) stored.activeProviderID = '';
    } else {
      assert.deepEqual(body, { backend: 'codex' }, 'Codex 切换不可携带 API 草稿');
      stored.backend = 'codex';
    }
    return { config: view() };
  }
  const context = { URL, document: {
    getElementById(id) { return elements[id]; }, createElement(tag) { return new Element(tag); },
    get activeElement() { return focused; },
  }, async fetch(url, options = {}) {
    const body = options.body ? JSON.parse(options.body) : undefined;
    requests.push({ url, method: options.method || 'GET', body });
    if (url === '/api/v1/model-test') {
      const record = stored.providers.find(item => item.id === body.providerId);
      resolvedProbes.push({ providerId: body.providerId, key: body.apiKey || (body.providerId ? secrets.get(body.providerId) : undefined) });
      const result = probe || { ok: true, host: body.backend === 'codex' ? 'codex' : origin(body.baseURL || record?.baseURL),
        model: body.backend === 'codex' ? 'gpt-6-luna' : (body.model || record?.model),
        tool: { supported: true, name: 'read_page', final: '模拟工具通过' } };
      return { ok: !failProbe, async json() { return clone(result); } };
    }
    if (options.method === 'POST') {
      if (failSave) return { ok: false, async json() { return { error: '保存失败，原配置仍保留。' }; } };
      const result = mutation(body);
      return { ok: !result.error, async json() { return clone(result); } };
    }
    if (failRead) return { ok: false, async json() { return { error: '读取失败。' }; } };
    return { ok: true, async json() { return { config: view() }; } };
  } };
  vm.runInNewContext(source, context, { filename: 'console-agent.js' });
  await new Promise(resolve => setImmediate(resolve));
  function action(id, name) {
    return elements.mProviders.querySelectorAll('button').find(button => button.dataset.providerId === id && button.dataset.modelAction === name);
  }
  function row(id) { return tree(elements.mProviders).find(node => node.dataset.providerId === id && node.className.split(/\s+/).includes('model-service')); }
  async function click(target, forced = false) {
    const node = typeof target === 'string' ? elements[target] : target;
    assert.ok(node, `找不到操作控件 ${target}`);
    if (forced || !node.disabled) await node.handlers.click({ target: node, currentTarget: node, preventDefault() {} });
  }
  return { elements, requests, resolvedProbes, action, row, click,
    async submit() {
      let prevented = false;
      await elements.mApiConfig.handlers.submit({ preventDefault() { prevented = true; } });
      assert.equal(prevented, true);
    },
    select(backend) { elements.mBackend.value = backend; elements.mBackend.handlers.change(); },
    input(id, value) { elements[id].value = value; elements[id].handlers.input(); },
    preset(value) { elements.mProvider.value = value; elements.mProvider.handlers.change(); },
    get config() { return view(); }, get keys() { return Array.from(secrets); }, get focused() { return focused; },
  };
}

test('完整列表直显各家摘要，表单收起且不回填凭证', async () => {
  const p = await panel();
  assert.equal(p.elements.mApiConfig.hidden, true);
  assert.match(p.elements.mCurrent.textContent, /Codex/);
  for (const record of [a, b]) {
    const text = p.row(record.id).textContent;
    for (const value of [record.name, record.model, record.baseURL, record.keyHint]) assert.ok(text.includes(value), value);
    assert.match(text, /已保存/);
  }
  assert.equal(p.elements.mKey.value, '');
  assert.ok(!p.elements.mProviders.textContent.includes('fixture-secret'));
});

test('活动标记与空密钥框独立，当前来源取自已保存记录', async () => {
  const p = await panel({ config: apiConfig });
  assert.match(p.row(a.id).textContent, /当前使用/);
  assert.ok(!p.row(b.id).textContent.includes('当前使用'));
  assert.equal(p.elements.agentState.textContent, '使用 API');
  assert.match(p.elements.mCurrent.textContent, /日常 DeepSeek/);
  await p.click(p.action(a.id, 'edit'));
  assert.equal(p.elements.mKey.value, '');
  assert.match(p.elements.mKeyHint.textContent, /sk-…aaa1/);
  assert.equal(p.elements.mKey.type, 'password');
});

test('A→B→A 切换只传目标 ID，各自摘要与凭证独立', async () => {
  const p = await panel({ config: apiConfig });
  for (const record of [b, a]) {
    await p.click(p.action(record.id, 'activate'));
    assert.deepEqual(p.requests.at(-1).body, { action: 'activate-provider', providerId: record.id });
    assert.equal(p.config.activeProviderID, record.id);
    assert.equal(p.config.backend, 'api');
    assert.equal(p.config.model, record.model);
    assert.equal(p.config.keyHint, record.keyHint);
    assert.match(p.row(record.id).textContent, /当前使用/);
  }
  assert.deepEqual(p.config.providers, [a, b]);
  assert.deepEqual(p.keys, [[a.id, 'fixture-secret-a'], [b.id, 'fixture-secret-b']]);
});

test('首次添加预填地址与模型但不写配置，空 Key 不测试或保存', async () => {
  const p = await panel({ config: { ...baseConfig, providers: [], activeProviderID: '' }, keys: [] });
  assert.equal(p.elements.mEmpty.hidden, false);
  await p.click('mAdd');
  assert.match(p.elements.mEditorTitle.textContent, /添加/);
  assert.equal(p.elements.mProvider.value, 'deepseek');
  assert.equal(p.elements.mBase.value, a.baseURL);
  assert.equal(p.elements.mModel.value, a.model);
  const count = p.requests.length;
  await p.click('mTest');
  await p.submit();
  assert.equal(p.requests.length, count);
  assert.match(p.elements.mState.textContent, /密钥/);
});

test('添加同源新记录仍要求独立 Key，测试及两种保存零请求', async () => {
  const p = await panel({ config: apiConfig });
  await p.click('mAdd');
  p.input('mName', '第二个 DeepSeek');
  p.input('mBase', a.baseURL);
  p.input('mModel', a.model);
  const count = p.requests.length;
  await p.click('mTest');
  await p.click('mSaveOnly');
  await p.submit();
  assert.equal(p.requests.length, count);
  assert.equal(p.config.providers.length, 2);
  assert.equal(p.config.activeProviderID, a.id);
});

test('添加仅保存不启用，重载后列表及原活动来源仍存在', async () => {
  const p = await panel({ config: apiConfig });
  await p.click('mAdd');
  p.input('mName', '公司网关');
  p.input('mBase', 'https://gateway.example/v1');
  p.input('mModel', 'gateway-model');
  p.input('mKey', 'fixture-gateway-key');
  await p.click('mSaveOnly');
  assert.deepEqual(p.requests.at(-1).body, { action: 'save-provider', activate: false,
    provider: { name: '公司网关', baseURL: 'https://gateway.example/v1', model: 'gateway-model', apiKey: 'fixture-gateway-key' } });
  assert.equal(p.config.backend, 'api');
  assert.equal(p.config.activeProviderID, a.id);
  assert.equal(p.config.providers.length, 3);
  assert.equal(p.elements.mKey.value, '');
  const fresh = await panel({ config: p.config, keys: p.keys });
  assert.equal(fresh.config.activeProviderID, a.id);
  const added = fresh.config.providers.find(record => record.name === '公司网关');
  assert.ok(fresh.row(added.id).textContent.includes('gateway-model'));
  assert.ok(!fresh.elements.mProviders.textContent.includes('fixture-gateway-key'));
});

test('编辑非活动记录可仅保存，ID/Key 及活动记录保持不变', async () => {
  const p = await panel({ config: apiConfig });
  await p.click(p.action(b.id, 'edit'));
  assert.equal(p.elements.mName.value, b.name);
  assert.equal(p.elements.mBase.value, b.baseURL);
  assert.match(p.elements.mKeyHint.textContent, /sk-…bbb2/);
  p.input('mName', '备用网关');
  p.input('mModel', 'backup-model-v2');
  await p.click('mSaveOnly');
  assert.deepEqual(p.requests.at(-1).body, { action: 'save-provider', activate: false,
    provider: { id: b.id, name: '备用网关', baseURL: b.baseURL, model: 'backup-model-v2' } });
  assert.equal(p.config.activeProviderID, a.id);
  assert.equal(p.config.model, a.model);
  assert.equal(p.config.providers.find(record => record.id === b.id).model, 'backup-model-v2');
  assert.deepEqual(p.keys, [[a.id, 'fixture-secret-a'], [b.id, 'fixture-secret-b']]);
});

test('主保存显式保存并使用编辑记录，空 Key 不发空 apiKey', async () => {
  const p = await panel();
  await p.click(p.action(b.id, 'edit'));
  await p.submit();
  assert.deepEqual(p.requests.at(-1).body, { action: 'save-provider', activate: true,
    provider: { id: b.id, name: b.name, baseURL: b.baseURL, model: b.model } });
  assert.equal(p.config.activeProviderID, b.id);
  assert.equal(p.config.backend, 'api');
  assert.match(p.elements.mCurrent.textContent, /备用服务/);
  assert.equal(p.elements.mApiConfig.hidden, true);
});

test('同源路径变化允许空 Key 测试和保存，凭证仅取该记录', async () => {
  const p = await panel();
  await p.click(p.action(a.id, 'edit'));
  p.input('mBase', ' https://api.deepseek.com/v1/ ');
  p.input('mModel', ' deepseek-flash ');
  assert.match(p.elements.mKeyHint.textContent, /无需重复填写/);
  await p.click('mTest');
  assert.deepEqual(p.requests.at(-1).body, { backend: 'api', providerId: a.id, baseURL: 'https://api.deepseek.com/v1/', model: a.model });
  assert.equal(p.resolvedProbes.at(-1).key, 'fixture-secret-a');
  await p.submit();
  assert.equal(p.requests.at(-1).body.provider.apiKey, undefined);
  assert.equal(p.config.baseURL, 'https://api.deepseek.com/v1/');
});

test('跨源空 Key 拒绝保存和测试，不借用另条记录对应地址的凭证', async () => {
  const p = await panel();
  await p.click(p.action(a.id, 'edit'));
  p.input('mBase', b.baseURL);
  assert.match(p.elements.mKeyHint.textContent, /地址已更换/);
  const count = p.requests.length;
  await p.submit();
  await p.click('mSaveOnly');
  await p.click('mTest');
  assert.equal(p.requests.length, count);
  assert.match(p.elements.mState.textContent, /密钥/);
  assert.deepEqual(p.config.providers, [a, b]);
});

test('缺少本记录 Key 时即使同源也不可测试或保存', async () => {
  const p = await panel({ config: { ...baseConfig, providers: [{ ...a, hasKey: false, keyHint: '', configured: false }, b] }, keys: [[b.id, 'fixture-secret-b']] });
  await p.click(p.action(a.id, 'edit'));
  const count = p.requests.length;
  await p.click('mTest');
  await p.submit();
  assert.equal(p.requests.length, count);
  assert.match(p.row(a.id).textContent, /配置未完成/);
});

test('新 Key 只更换编辑记录，成功后掩码清空且不出现在摘要/文案', async () => {
  const p = await panel();
  await p.click(p.action(b.id, 'edit'));
  p.input('mKey', 'fixture-new-key');
  await p.click('mKeyToggle');
  assert.equal(p.elements.mKey.type, 'text');
  await p.submit();
  assert.equal(p.requests.at(-1).body.provider.apiKey, 'fixture-new-key');
  assert.equal(p.keys.find(([id]) => id === a.id)[1], 'fixture-secret-a');
  assert.equal(p.keys.find(([id]) => id === b.id)[1], 'fixture-new-key');
  assert.equal(p.elements.mKey.value, '');
  assert.equal(p.elements.mKey.type, 'password');
  assert.equal(p.elements.mKeyToggle.attributes['aria-pressed'], 'false');
  for (const id of ['mState', 'mKeyHint', 'mProviders']) assert.ok(!p.elements[id].textContent.includes('fixture-new-key'));
});

test('各家摘要测试只传各自 ID，模拟凭证解析不串用', async () => {
  const p = await panel();
  for (const record of [a, b]) {
    await p.click(p.action(record.id, 'test'));
    assert.deepEqual(p.requests.at(-1).body, { backend: 'api', providerId: record.id });
    assert.equal(p.resolvedProbes.at(-1).key, `fixture-secret-${record.id === a.id ? 'a' : 'b'}`);
  }
  assert.equal(p.config.backend, 'codex');
  assert.equal(p.config.activeProviderID, a.id);
});

test('新记录草稿测试显式空 providerId，只传新 Key 且不写列表/来源', async () => {
  const p = await panel({ config: apiConfig });
  await p.click('mAdd');
  p.input('mName', '草稿服务');
  p.input('mBase', a.baseURL);
  p.input('mModel', 'draft-model');
  p.input('mKey', 'fixture-draft-key');
  const count = p.requests.length;
  await p.click('mTest');
  assert.equal(p.requests.length, count + 1);
  assert.equal(p.requests.at(-1).url, '/api/v1/model-test');
  assert.deepEqual(p.requests.at(-1).body, { backend: 'api', providerId: '', baseURL: a.baseURL, model: 'draft-model', apiKey: 'fixture-draft-key' });
  assert.equal(p.config.activeProviderID, a.id);
  assert.equal(p.config.providers.length, 2);
  assert.equal(p.resolvedProbes.at(-1).key, 'fixture-draft-key');
  assert.match(p.elements.mOut.textContent, /draft-model/);
});

test('编辑期间全部列表操作、添加与切换冻结，取消后恢复且清草稿', async () => {
  const p = await panel();
  await p.click(p.action(a.id, 'edit'));
  p.input('mBase', 'https://draft.example/v1');
  p.input('mModel', 'draft-model');
  p.input('mKey', 'fixture-draft-key');
  const count = p.requests.length;
  for (const button of [...p.elements.mProviders.querySelectorAll('button'), p.elements.mAdd, p.elements.mUseCodex]) {
    assert.equal(button.disabled, true, button.textContent);
    await p.click(button);
  }
  assert.equal(p.requests.length, count);
  assert.equal(p.elements.mKey.value, 'fixture-draft-key');
  await p.click('mCancel');
  for (const id of ['mName', 'mBase', 'mModel', 'mKey']) assert.equal(p.elements[id].value, '');
  assert.equal(p.elements.mApiConfig.hidden, true);
  assert.equal(p.elements.mAdd.disabled, false);
  assert.equal(p.elements.mUseCodex.disabled, false);
  assert.equal(p.action(b.id, 'edit').disabled, false);
  assert.equal(p.focused, p.action(a.id, 'edit'));
});

test('直接重复派发记录编辑/添加/切换事件不丢草稿或发新请求', async () => {
  const p = await panel({ config: apiConfig });
  await p.click(p.action(a.id, 'edit'));
  p.input('mName', '当前草稿');
  p.input('mBase', 'https://draft.example/v1');
  p.input('mModel', 'draft-model');
  p.input('mKey', 'fixture-unsaved-key');
  const count = p.requests.length;
  for (const button of [p.action(b.id, 'edit'), p.action(b.id, 'activate'), p.elements.mAdd, p.elements.mUseCodex]) {
    await p.click(button, true);
    assert.equal(p.requests.length, count);
    assert.equal(p.elements.mApiConfig.hidden, false);
    assert.equal(p.elements.mBackend.value, 'api');
    assert.equal(p.elements.mName.value, '当前草稿');
    assert.equal(p.elements.mBase.value, 'https://draft.example/v1');
    assert.equal(p.elements.mModel.value, 'draft-model');
    assert.equal(p.elements.mKey.value, 'fixture-unsaved-key');
  }
});

test('Codex 切换先展开确认，提交仅 backend 并保留 API 列表', async () => {
  const p = await panel({ config: apiConfig });
  const count = p.requests.length;
  await p.click('mUseCodex');
  assert.equal(p.requests.length, count);
  assert.equal(p.elements.mBackend.value, 'codex');
  assert.equal(p.elements.mApiFields.hidden, true);
  p.elements.mKey.value = 'fixture-do-not-send';
  await p.submit();
  assert.deepEqual(p.requests.at(-1).body, { backend: 'codex' });
  assert.deepEqual(p.config.providers, [a, b]);
  assert.equal(p.config.activeProviderID, a.id);
  assert.equal(p.elements.mKey.value, '');
});

test('当前 Codex 直接测试，不开表单也不夹带 API 凭据', async () => {
  const p = await panel();
  p.elements.mKey.value = 'fixture-do-not-send';
  await p.click('mUseCodex');
  assert.deepEqual(p.requests.at(-1).body, { backend: 'codex' });
  assert.equal(p.elements.mApiConfig.hidden, true);
  assert.match(p.elements.mOut.textContent, /Codex 登录额度/);
  assert.match(p.elements.mOut.textContent, /gpt-6-luna/);
});

test('仅文本成功不标完整工具验证通过或覆盖来源', async () => {
  const p = await panel({ probe: { ok: true, host: 'codex', model: 'gpt-6-luna', tool: { supported: false, note: '未发起工具调用' } } });
  await p.click('mUseCodex');
  assert.equal(p.elements.agentState.textContent, '使用 Codex');
  assert.ok(!p.elements.mOut.className.includes('ok'));
  assert.match(p.elements.mState.textContent, /工具调用尚未通过/);
  assert.match(p.elements.mOut.textContent, /未发起工具调用/);
});

test('两次确认只删除所编辑记录，不撤销 Codex 或其他 Key', async () => {
  const p = await panel();
  await p.click(p.action(b.id, 'edit'));
  const count = p.requests.length;
  await p.click('mClear');
  assert.equal(p.requests.length, count);
  assert.match(p.elements.mClear.textContent, /确认移除/);
  await p.click('mClear');
  assert.deepEqual(p.requests.at(-1).body, { action: 'remove-provider', providerId: b.id });
  assert.equal(p.config.backend, 'codex');
  assert.equal(p.config.activeProviderID, a.id);
  assert.deepEqual(p.config.providers, [a]);
  assert.deepEqual(p.keys, [[a.id, 'fixture-secret-a']]);
  assert.equal(p.elements.mApiConfig.hidden, true);
});

test('移除活动 API 不擅自改用其他服务商或 Codex', async () => {
  const p = await panel({ config: apiConfig });
  await p.click(p.action(a.id, 'edit'));
  await p.click('mClear');
  await p.click('mClear');
  assert.equal(p.config.backend, 'api');
  assert.equal(p.config.activeProviderID, '');
  assert.equal(p.config.configured, false);
  assert.deepEqual(p.config.providers, [b]);
  assert.equal(p.elements.agentState.textContent, '未配置');
  assert.ok(!p.row(b.id).textContent.includes('当前使用'));
});

test('配置字段变更均撤下过时测试结果与移除确认', async () => {
  const p = await panel();
  await p.click(p.action(a.id, 'edit'));
  for (const id of ['mName', 'mBase', 'mModel', 'mKey']) {
    await p.click('mTest');
    assert.equal(p.elements.mOut.hidden, false);
    await p.click('mClear');
    p.input(id, p.elements[id].value);
    assert.equal(p.elements.mOut.hidden, true);
    assert.ok(!p.elements.mClear.textContent.includes('确认移除'));
    assert.match(p.elements.mState.textContent, /尚未保存/);
  }
});

test('更换预设撤下旧结果并清新 Key，不将旧凭据送到新地址', async () => {
  const p = await panel();
  await p.click(p.action(a.id, 'edit'));
  await p.click('mTest');
  p.input('mKey', 'fixture-unsaved-key');
  await p.click('mKeyToggle');
  p.preset('openai');
  assert.equal(p.elements.mBase.value, 'https://api.openai.com/v1');
  assert.equal(p.elements.mModel.value, '');
  assert.equal(p.elements.mKey.value, '');
  assert.equal(p.elements.mKey.type, 'password');
  assert.equal(p.elements.mOut.hidden, true);
});

test('任意配置名称作为纯文本呈现，不生成注入节点', async () => {
  const name = '<img src=x onerror="globalThis.pwned=true"> & 公司网关';
  const p = await panel({ config: { ...apiConfig, providers: [{ ...a, name }, b] } });
  assert.ok(p.row(a.id).textContent.includes(name));
  assert.equal(p.row(a.id).querySelectorAll('img').length, 0);
  assert.ok(p.elements.mCurrent.textContent.includes(name));
  await p.click(p.action(a.id, 'edit'));
  assert.equal(p.elements.mName.value, name);
});

test('保存失败保留列表/来源和输入草稿，绝不自动回退', async () => {
  const p = await panel({ failSave: true });
  await p.click(p.action(b.id, 'edit'));
  p.input('mName', '修改尚未保存');
  p.input('mKey', 'fixture-new-key');
  const count = p.requests.length;
  await p.submit();
  assert.equal(p.requests.length, count + 1);
  assert.deepEqual(p.config.providers, [a, b]);
  assert.equal(p.config.backend, 'codex');
  assert.equal(p.config.activeProviderID, a.id);
  assert.equal(p.elements.mName.value, '修改尚未保存');
  assert.equal(p.elements.mKey.value, 'fixture-new-key');
  assert.equal(p.elements.mApiConfig.hidden, false);
  assert.match(p.elements.mState.textContent, /保存失败/);
});

test('切换或移除失败保留列表和活动标记，每次只发一个请求', async () => {
  for (const operation of ['activate', 'remove']) {
    const p = await panel({ config: apiConfig, failSave: true });
    const current = p.elements.mCurrent.textContent;
    if (operation === 'remove') { await p.click(p.action(b.id, 'edit')); await p.click('mClear'); }
    const count = p.requests.length;
    await p.click(operation === 'activate' ? p.action(b.id, 'activate') : 'mClear');
    assert.equal(p.requests.length, count + 1);
    assert.deepEqual(p.config.providers, [a, b]);
    assert.equal(p.config.activeProviderID, a.id);
    assert.equal(p.elements.mCurrent.textContent, current);
    assert.match(p.row(a.id).textContent, /当前使用/);
  }
});

test('HTTP/模型测试失败保持来源和列表，不自动调用其他后端', async () => {
  for (const failProbe of [false, true]) {
    const p = await panel({ config: apiConfig, failProbe, probe: { ok: false, error: '服务暂不可用。' } });
    const current = p.elements.mCurrent.textContent;
    const count = p.requests.length;
    await p.click(p.action(b.id, 'test'));
    assert.equal(p.requests.length, count + 1);
    assert.equal(p.requests.at(-1).url, '/api/v1/model-test');
    assert.deepEqual(p.config.providers, [a, b]);
    assert.equal(p.config.activeProviderID, a.id);
    assert.equal(p.elements.mCurrent.textContent, current);
    assert.equal(p.elements.agentState.textContent, '使用 API');
    assert.match(p.elements.mState.textContent, /暂不可用/);
  }
});

test('读取失败禁用静态编辑/测试/切换控件，提交不请求', async () => {
  const p = await panel({ failRead: true });
  assert.equal(p.elements.agentState.textContent, '读取失败');
  assert.match(p.elements.mCurrent.textContent, /读取失败/);
  const count = p.requests.length;
  for (const id of controls) assert.equal(p.elements[id].disabled, true, id);
  for (const id of ['mAdd', 'mTest', 'mSaveOnly', 'mUseCodex', 'mClear', 'mCancel']) await p.click(id);
  await p.submit();
  assert.equal(p.requests.length, count);
  assert.equal(p.elements.mApiConfig.hidden, true);
});
