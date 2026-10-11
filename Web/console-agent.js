/**
 * [INPUT]: 依赖 /api/v1/model-config 的服务商脱敏列表、活动来源及增改删/启用事务，消费 /api/v1/model-test 的模拟工具回执。
 * [OUTPUT]: 每家 API 独立配置与显式切换、按需编辑、仅保存/保存并使用；凭证只从同记录同源沿用，测试不改变活动来源。
 * [POS]: Web 的本机模型管理边界；服务端记录是唯一事实，输入草稿与测试结果独立，动态列表一律用 textContent，不共享其他控制台保存事务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 *
 * 红线：完整 Key 只存在输入框与显式请求，不回填或缓存；新增服务商不能借用其他记录的密钥，编辑期间不允许切换丢失草稿。
 */
(function () {
'use strict';

const ids = ['agentState', 'mBackend', 'mCurrent', 'mApiConfig', 'mApiFields', 'mProvider',
  'mProviders', 'mCodexStatus', 'mEmpty', 'mAdd', 'mUseCodex', 'mEditorTitle',
  'mName', 'mBase', 'mModel', 'mKey', 'mKeyLabel', 'mKeyToggle', 'mTest', 'mSave',
  'mSaveOnly', 'mCancel', 'mClear', 'mState', 'mKeyHint', 'mOut'];
const el = Object.fromEntries(ids.map(id => [id, document.getElementById(id)]));
const controlIds = ['mBackend', 'mProvider', 'mName', 'mBase', 'mModel', 'mKey',
  'mKeyToggle', 'mTest', 'mSave', 'mSaveOnly', 'mCancel', 'mClear', 'mAdd', 'mUseCodex'];
const presets = {
  deepseek: { name: 'DeepSeek', baseURL: 'https://api.deepseek.com', model: 'deepseek-flash' },
  openai: { name: 'OpenAI', baseURL: 'https://api.openai.com/v1', model: '' },
  custom: { name: '自定义 API', baseURL: '', model: '' },
};
const rowControls = new Map();
let saved = null;
let busy = false;
let editingId = null;
let focusOrigin = null;
let removing = false;

// ---------- 服务端事实与独立草稿 ----------
function origin(value) {
  try { return new URL(value).origin; } catch (_) { return ''; }
}

function presetFor(value) {
  const host = origin(value);
  if (host === origin(presets.deepseek.baseURL)) return 'deepseek';
  if (host === origin(presets.openai.baseURL)) return 'openai';
  return 'custom';
}

function profile(id) {
  return saved && saved.providers.find(item => item.id === id);
}

function configured(item) {
  return Boolean(item && item.configured !== false && item.baseURL && item.model && item.hasKey);
}

function setState(text, kind) {
  el.mState.textContent = text || '';
  el.mState.className = 'hint' + (kind ? ' ' + kind : '');
}

function setPill(text, kind) {
  el.agentState.textContent = text;
  el.agentState.className = 'pill' + (kind ? ' ' + kind : '');
}

function setBusy(value) {
  busy = value;
  const editing = !el.mApiConfig.hidden;
  controlIds.forEach(id => {
    el[id].disabled = busy || !saved || (editing && ['mAdd', 'mUseCodex'].includes(id));
  });
  rowControls.forEach(controls => Object.values(controls).forEach(button => {
    button.disabled = busy || editing;
  }));
  el.mProviders.setAttribute('aria-busy', String(busy));
}

function hideKey() {
  el.mKey.type = 'password';
  el.mKeyToggle.textContent = '显示';
  el.mKeyToggle.setAttribute('aria-pressed', 'false');
}

function resetRemoval() {
  removing = false;
  el.mClear.textContent = '移除此服务商';
}

function syncKeyHint() {
  const item = profile(editingId);
  const canReuse = item && item.hasKey && origin(el.mBase.value.trim()) === origin(item.baseURL);
  el.mKeyLabel.textContent = canReuse ? '更换 API Key（可选）' : 'API Key';
  el.mKey.placeholder = canReuse ? '留空保留此服务商的密钥' : '粘贴此服务商的 API Key';
  el.mKeyHint.textContent = canReuse
    ? `此配置已保存 ${item.keyHint || '密钥'}；无需重复填写。`
    : (item && item.hasKey ? 'API 地址已更换，请填写对应服务商的密钥。' : '请填写这家服务商的密钥，每份配置独立保存。');
}

function syncSelection() {
  const api = el.mBackend.value === 'api';
  el.mApiFields.hidden = !api;
  el.mEditorTitle.textContent = api ? (editingId ? '编辑服务商' : '添加服务商') : '使用 Codex 登录额度（试验）';
  el.mSave.textContent = api ? '保存并使用' : '使用 Codex 额度';
  el.mSaveOnly.hidden = !api || (saved.backend === 'api' && editingId === saved.activeProviderID);
  el.mTest.textContent = api ? '测试此配置' : '测试 Codex';
  el.mClear.hidden = !api || !editingId;
  syncKeyHint();
}

function closeEditor() {
  el.mApiConfig.hidden = true;
  editingId = null;
  ['mName', 'mBase', 'mModel', 'mKey'].forEach(id => { el[id].value = ''; });
  hideKey();
  resetRemoval();
  setBusy(busy);
}

function restoreFocus() {
  const controls = rowControls.get(focusOrigin);
  (controls ? controls.edit : el.mAdd).focus();
}

function openEditor(id = null, backend = 'api') {
  if (!saved || busy) return;
  if (!el.mApiConfig.hidden) {
    (el.mBackend.value === 'api' ? el.mProvider : el.mSave).focus();
    return;
  }
  const item = id ? profile(id) : null;
  if (id && !item) { setState('此服务商配置已不存在，请刷新后重试。', 'bad'); return; }
  editingId = item ? item.id : null;
  focusOrigin = editingId;
  el.mBackend.value = backend;
  el.mProvider.value = item ? presetFor(item.baseURL) : 'deepseek';
  const initial = item || presets.deepseek;
  el.mName.value = initial.name || '';
  el.mBase.value = initial.baseURL || '';
  el.mModel.value = initial.model || '';
  el.mKey.value = '';
  hideKey();
  resetRemoval();
  syncSelection();
  el.mApiConfig.hidden = false;
  el.mOut.hidden = true;
  setState('');
  setBusy(false);
  (backend === 'api' ? el.mProvider : el.mSave).focus();
}

// ---------- 列表只呈现脱敏值 ----------
function node(tag, className, text) {
  const result = document.createElement(tag);
  if (className) result.className = className;
  if (text !== undefined) result.textContent = text;
  return result;
}

function fact(label, value, wide) {
  const group = node('div', wide ? 'wide' : '');
  group.append(node('dt', '', label), node('dd', wide ? 'mono' : '', value));
  return group;
}

function providerButton(item, action, label, primary) {
  const button = node('button', 'btn' + (primary ? ' primary' : ''), label);
  button.type = 'button';
  button.dataset.modelAction = action;
  button.dataset.providerId = item.id;
  button.setAttribute('aria-label', `${label} ${item.name}`);
  if (action === 'edit') button.setAttribute('aria-controls', 'mApiConfig');
  button.addEventListener('click', () => providerAction(action, item.id));
  return button;
}

function renderProviders() {
  el.mProviders.replaceChildren();
  rowControls.clear();
  saved.providers.forEach(item => {
    const active = saved.backend === 'api' && saved.activeProviderID === item.id;
    const row = node('div', 'model-service');
    row.dataset.providerId = item.id;
    const head = node('div', 'model-service-head');
    const status = active ? (configured(item) ? '当前使用' : '当前选择 · 配置未完成') : (configured(item) ? '已保存' : '配置未完成');
    head.append(node('h3', '', item.name), node('span', 'model-tag' + (active && configured(item) ? ' active' : ''), status));
    const keyHint = item.hasKey
      ? (item.keyHint && item.keyHint !== '已保存' ? `${item.keyHint} · 已保存` : '已保存') : '未保存';
    const facts = node('dl', 'model-facts');
    facts.append(fact('模型', item.model || '未填写'), fact('API Key', keyHint), fact('API 地址', item.baseURL || '未填写', true));
    const actions = node('div', 'row model-actions');
    const buttons = { edit: providerButton(item, 'edit', '编辑') };
    if (!active && configured(item)) {
      buttons.activate = providerButton(item, 'activate', '使用', true);
      actions.append(buttons.activate);
    }
    actions.append(buttons.edit);
    if (configured(item)) {
      buttons.test = providerButton(item, 'test', '测试连接');
      actions.append(buttons.test);
    }
    row.append(head, facts, actions);
    el.mProviders.append(row);
    rowControls.set(item.id, buttons);
  });
  el.mEmpty.hidden = saved.providers.length > 0;
}

function applyConfig(config) {
  // 读取旧版脱敏响应也可呈现；生产旧配置由服务端解码迁移，不在网页猜测或保存密钥。
  const legacy = config.baseURL || config.model || config.hasKey;
  const providers = Array.isArray(config.providers) ? config.providers : (legacy ? [{
    id: 'legacy-api', name: presets[presetFor(config.baseURL)].name, baseURL: config.baseURL,
    model: config.model, hasKey: config.hasKey, keyHint: config.keyHint,
  }] : []);
  saved = { ...config, providers, backend: config.backend === 'codex' ? 'codex' : 'api',
    activeProviderID: typeof config.activeProviderID === 'string' ? config.activeProviderID : (legacy ? 'legacy-api' : '') };
  const active = profile(saved.activeProviderID);
  const usingApi = saved.backend === 'api';
  const ready = !usingApi || configured(active);
  el.mCurrent.textContent = usingApi
    ? (configured(active) ? `当前使用：${active.name} · ${active.model}` : '尚未选择可用的 API 服务商，请添加或点击「使用」。')
    : '当前使用：Codex 额度 · GPT-6 Luna（试验）';
  setPill(ready ? (usingApi ? '使用 API' : '使用 Codex') : '未配置', ready ? '' : 'bad');
  el.mCodexStatus.textContent = usingApi ? '试验' : '当前使用 · 试验';
  el.mCodexStatus.className = 'model-tag' + (usingApi ? '' : ' active');
  el.mUseCodex.textContent = usingApi ? '使用 Codex' : '测试 Codex';
  renderProviders();
  closeEditor();
}

async function readConfig() {
  setBusy(true);
  try {
    const response = await fetch('/api/v1/model-config');
    const data = await response.json();
    if (!response.ok || !data.config) throw new Error(data.error || '读取服务商配置失败，请刷新后重试。');
    applyConfig(data.config);
  } catch (error) {
    el.mCurrent.textContent = '服务商配置读取失败，请刷新后重试。';
    setPill('读取失败', 'bad');
    setState(error.message, 'bad');
  } finally { setBusy(false); }
}

// ---------- 每个请求绑定一个服务商身份 ----------
function apiDraft() {
  const item = profile(editingId);
  const body = { baseURL: el.mBase.value.trim(), model: el.mModel.value.trim() };
  const key = el.mKey.value.trim();
  const targetOrigin = origin(body.baseURL);
  if (!targetOrigin || !/^https?:\/\//i.test(body.baseURL)) throw new Error('请填写以 http:// 或 https:// 开头的 API 地址。');
  if (!body.model) throw new Error('请填写服务商提供的模型 ID。');
  if (!key && (!item || !item.hasKey || targetOrigin !== origin(item.baseURL))) throw new Error('请填写这家服务商对应的密钥（API Key）。');
  if (key) body.apiKey = key;
  return body;
}

function testDraft() {
  return el.mBackend.value === 'codex' ? { backend: 'codex' }
    : { backend: 'api', providerId: editingId || '', ...apiDraft() };
}

async function saveBody(body, message) {
  if (busy || !saved) return;
  setBusy(true);
  setState('保存中…');
  let succeeded = false;
  try {
    const response = await fetch('/api/v1/model-config', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    const result = await response.json();
    if (!response.ok || !result.config) throw new Error(result.error || '保存失败，请重试。');
    applyConfig(result.config);
    el.mOut.hidden = true;
    setState(message || '已切换，下一次任务使用此服务商。', 'ok');
    succeeded = true;
  } catch (error) { setState(error.message, 'bad'); }
  finally { setBusy(false); }
  if (succeeded) restoreFocus();
}

async function save(event, activate = true) {
  if (event) event.preventDefault();
  if (busy || !saved) return;
  try {
    if (el.mBackend.value === 'codex') { await saveBody({ backend: 'codex' }, '已选择 Codex，下一次任务生效。'); return; }
    const name = el.mName.value.trim();
    if (!name) throw new Error('请填写一个便于区分的配置名称。');
    if (name.length > 80) throw new Error('配置名称请保持在 80 个字符以内。');
    const provider = { name, ...apiDraft() };
    if (editingId) provider.id = editingId;
    await saveBody({ action: 'save-provider', provider, activate }, activate
      ? '已保存并启用，下一次任务使用此服务商。' : '已保存此服务商的配置。');
  } catch (error) { setState(error.message, 'bad'); }
}

function providerAction(action, id) {
  if (!saved || busy || !el.mApiConfig.hidden) return;
  const item = profile(id);
  if (!item) return;
  focusOrigin = id;
  if (action === 'edit') return openEditor(id);
  if (action === 'test') return test({ backend: 'api', providerId: id });
  if (action === 'activate') return saveBody({ action: 'activate-provider', providerId: id });
}

async function clear() {
  if (busy || !saved || !editingId) return;
  if (!removing) {
    removing = true;
    el.mClear.textContent = '确认移除';
    const active = saved.backend === 'api' && saved.activeProviderID === editingId;
    setState(active ? '将移除当前服务商，小精灵需选择其它配置后才能使用。再次点击确认移除。' : '再次点击确认移除此服务商。');
    return;
  }
  await saveBody({ action: 'remove-provider', providerId: editingId }, '已移除此服务商。');
}

function render(result) {
  const lines = [];
  const usage = result.usage && Object.keys(result.usage).length
    ? Object.entries(result.usage).map(([k, v]) => `${k}=${v}`).join(' ') : '服务端未返回用量';
  lines.push(`模型来源      ${result.host === 'codex' ? 'Codex 登录额度' : (result.host || '—')}`);
  lines.push(`模型          ${result.activeModel || result.model || '—'}`);
  if (result.latencyMs != null) lines.push(`耗时          ${result.latencyMs} ms`);
  lines.push(`用量          ${usage}`);
  if (result.error) lines.push(`失败原因      ${result.error}`);
  if (result.content) lines.push(`文本回答      ${result.content}`);
  const tool = result.tool || {};
  if (tool.supported === true) {
    lines.push(`工具调用      支持（发起 ${tool.name || '未知工具'}）`);
    if (tool.final) lines.push(`工具结果回传  ${tool.final}`);
    if (tool.error) lines.push(`工具结果阶段  ${tool.error}`);
  } else if (tool.supported === false) {
    lines.push(`工具调用      ${tool.error ? '验证失败：' + tool.error : (tool.note || '未验证')}`);
  }
  el.mOut.hidden = false;
  el.mOut.textContent = lines.join('\n');
  const complete = result.ok && tool.supported === true && !tool.error;
  el.mOut.className = 'probe-out' + (complete ? ' ok' : (result.ok ? '' : ' bad'));
}

async function test(body) {
  if (busy || !saved) return;
  let request;
  try { request = body || testDraft(); }
  catch (error) { setState(error.message, 'bad'); return; }
  setBusy(true);
  setState('正在测试文本与模拟工具调用…');
  el.mOut.hidden = true;
  try {
    const response = await fetch('/api/v1/model-test', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(request),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '测试失败');
    render(result);
    if (result.ok && result.tool && result.tool.supported === true && !result.tool.error) {
      setState('文本与工具调用测试通过。' + (el.mApiConfig.hidden ? '' : '保存后使用此配置。'), 'ok');
    } else if (result.ok) { setState('文本可用，工具调用尚未通过验证，请查看测试结果。'); }
    else { setState(result.error || '模型测试失败，请查看测试结果。', 'bad'); }
  } catch (error) { setState(error.message, 'bad'); }
  finally { setBusy(false); }
}

function edited() {
  resetRemoval();
  el.mOut.hidden = true;
  syncKeyHint();
  setState('修改尚未保存，当前服务继续使用已保存的配置。');
}

el.mBackend.addEventListener('change', () => { syncSelection(); edited(); });
el.mProvider.addEventListener('change', () => {
  const preset = presets[el.mProvider.value];
  const autoName = Object.values(presets).some(item => item.name === el.mName.value.trim());
  if (!el.mName.value.trim() || autoName) el.mName.value = preset.name;
  if (preset.baseURL) { el.mBase.value = preset.baseURL; el.mModel.value = preset.model; }
  el.mKey.value = '';
  hideKey();
  edited();
});
['mName', 'mBase', 'mModel', 'mKey'].forEach(id => el[id].addEventListener('input', () => {
  if (id === 'mBase') el.mProvider.value = presetFor(el.mBase.value);
  edited();
}));
el.mKeyToggle.addEventListener('click', () => {
  const show = el.mKey.type === 'password';
  el.mKey.type = show ? 'text' : 'password';
  el.mKeyToggle.textContent = show ? '隐藏' : '显示';
  el.mKeyToggle.setAttribute('aria-pressed', String(show));
});
el.mAdd.addEventListener('click', () => openEditor());
el.mApiConfig.addEventListener('submit', event => save(event, true));
el.mSaveOnly.addEventListener('click', () => save(null, false));
el.mCancel.addEventListener('click', () => { closeEditor(); el.mOut.hidden = true; setState(''); restoreFocus(); });
el.mTest.addEventListener('click', () => test());
el.mUseCodex.addEventListener('click', () => saved && saved.backend === 'codex' ? test({ backend: 'codex' }) : openEditor(null, 'codex'));
el.mClear.addEventListener('click', clear);
readConfig();

})();
