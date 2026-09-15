/**
 * [INPUT]: 依赖 /api/v1/model-config 的读写与 /api/v1/model-test 的实测回执。
 * [OUTPUT]: 控制台「小精灵 · 模型服务」卡片：Base URL / 模型名 / API Key 三格配置、
 *           保存，以及一次真实连通性实测（文本 + 工具调用闭环）并原样展示服务端证据。
 * [POS]: Web 的电脑端模型服务配置面板；只在本机控制台运行，手机页不加载它、
 *        也不接收任何模型配置字段。
 * [PROTOCOL]: 变更时更新此头部，然后检查 Web/CLAUDE.md
 *
 * 红线：API Key 只在用户键入时离开键盘，页面不缓存、不写 localStorage、不进任何提示文案。
 * 服务端只回脱敏提示（hasKey/keyHint），输入框永远拿不回已保存的完整 Key。
 */
'use strict';

const agentState = document.getElementById('agentState');
const elBase = document.getElementById('mBase');
const elModel = document.getElementById('mModel');
const elKey = document.getElementById('mKey');
const elTest = document.getElementById('mTest');
const elSave = document.getElementById('mSave');
const elClear = document.getElementById('mClear');
const elState = document.getElementById('mState');
const elKeyHint = document.getElementById('mKeyHint');
const elOut = document.getElementById('mOut');

function setState(text, kind) {
  elState.textContent = text || '';
  elState.className = 'hint' + (kind ? ' ' + kind : '');
}

function setPill(text, kind) {
  agentState.textContent = text;
  agentState.className = 'pill' + (kind ? ' ' + kind : '');
}

async function readConfig() {
  const data = await fetch('/api/v1/model-config').then(r => r.json()).catch(() => null);
  const config = data && data.config;
  if (!config) { setPill('读取失败', 'bad'); return; }
  elBase.value = config.baseURL || '';
  elModel.value = config.model || '';
  elKey.value = '';
  // 已保存过就明确告诉用户「留空=沿用」，否则他不知道为什么 Key 框是空的却能用。
  elKeyHint.textContent = config.hasKey
    ? `已保存 Key（${config.keyHint}），留空表示继续用它；要更换就填新的。`
    : '还没有配置 Key。';
  setPill(config.configured ? '已配置 · 未验证' : '未配置', config.configured ? '' : 'bad');
}

// 清空走的是「三项全空」这条服务端语义：整份 model.json 落空，不留残留 Key。
async function clear() {
  elClear.disabled = true;
  setState('清空中…');
  try {
    const response = await fetch('/api/v1/model-config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ baseURL: '', model: '', apiKey: '' }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '清空失败');
    elBase.value = ''; elModel.value = ''; elKey.value = '';
    elKeyHint.textContent = '还没有配置 Key。';
    elOut.hidden = true;
    setPill('未配置', 'bad');
    setState('已清空这台 Mac 上的模型服务配置。', 'ok');
  } catch (error) {
    setState(error.message, 'bad');
  } finally {
    elClear.disabled = false;
  }
}

async function save() {
  elSave.disabled = true;
  setState('保存中…');
  try {
    // Key 留空 = 沿用旧值（服务端语义）；要彻底清掉请点「清空」。
    const response = await fetch('/api/v1/model-config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ baseURL: elBase.value, model: elModel.value, apiKey: elKey.value }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '保存失败');
    elKey.value = '';
    elKeyHint.textContent = result.config.hasKey
      ? `已保存 Key（${result.config.keyHint}），留空表示继续用它；要更换就填新的。`
      : '还没有配置 Key。';
    setState('已保存到这台 Mac。', 'ok');
    setPill(result.config.configured ? '已配置 · 未验证' : '未配置', result.config.configured ? '' : 'bad');
  } catch (error) {
    setState(error.message, 'bad');
  } finally {
    elSave.disabled = false;
  }
}

function render(result) {
  const lines = [];
  const usage = result.usage && Object.keys(result.usage).length
    ? Object.entries(result.usage).map(([k, v]) => `${k}=${v}`).join(' ')
    : '服务端未返回用量（unknown）';
  lines.push(`服务主机      ${result.host || '—'}`);
  lines.push(`模型          ${result.model || '—'}`);
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
  elOut.hidden = false;
  elOut.textContent = lines.join('\n');
  elOut.className = 'probe-out ' + (result.ok ? 'ok' : 'bad');
}

async function test() {
  elTest.disabled = true;
  setState('正在实测…');
  elOut.hidden = true;
  try {
    const response = await fetch('/api/v1/model-test', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      // 用当前输入框的值试跑：没保存也能先验证，填错不会污染已保存配置。
      body: JSON.stringify({ baseURL: elBase.value, model: elModel.value, apiKey: elKey.value }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '测试失败');
    render(result);
    if (result.ok) {
      setPill('可用', 'ok');
      const toolNote = result.tool && result.tool.supported ? '，工具调用可用' : '，工具调用未验证';
      setState('连接成功' + toolNote + '。', 'ok');
    } else {
      setPill('不可用', 'bad');
      setState(result.error || '连接失败', 'bad');
    }
  } catch (error) {
    setPill('不可用', 'bad');
    setState(error.message, 'bad');
  } finally {
    elTest.disabled = false;
  }
}

elSave.addEventListener('click', save);
elTest.addEventListener('click', test);
elClear.addEventListener('click', clear);
readConfig();
