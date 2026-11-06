/**
 * [INPUT]: console-voice真实脚本与内存DOM/请求/时钟替身。
 * [OUTPUT]: 验证配置草稿保留、应答池与音色/语速保存、神经与系统音色分组渲染、试听、显式启用/重连、未发送与较早未发送正文的处理、保存失败不丢选择、输入源与键盘能力展示及并发门禁。
 * [POS]: 自动语音控制台隔离回归；不连接生产服务、不申请权限或执行任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const vm = require('node:vm'), fs = require('node:fs'), assert = require('node:assert/strict');
const nodes = new Map();
const buttons = () => ['save', 'voiceRetry', 'voiceSendDraft', 'voiceDiscardDraft', 'voicePreview', 'voiceSendParked', 'voiceDiscardParked'].map(node);
function element(tag) {
  return { tag, value: '', textContent: '', label: '', children: [],
    addEventListener(t, f) { this.events = this.events || {}; this.events[t] = f; },
    appendChild(child) { this.children.push(child); return child; } };
}
function node(id) {
  if (!nodes.has(id)) {
    const target = element('div');
    target.checked = false; target.hidden = false; target.disabled = false; target.dataset = {}; target.events = {};
    target.addEventListener = function (t, f) { this.events[t] = f; };
    target.appendChild = function (child) { this.children.push(child); return child; };
    target.querySelectorAll = buttons;
    Object.defineProperty(target, 'textContent', { get() { return this._text || ''; }, set(value) { this._text = value; this.children = []; } });
    nodes.set(id, target);
  }
  return nodes.get(id);
}
const flatten = list => list.flatMap(item => item.tag === 'optgroup' ? item.children : [item]);
let poll, fail = false, calls = [];
const state = { wakeWord: '小E', enabled: false, allowLocked: true, ackEnabled: true, ackPhrase: '嗯，我在|在呢', voice: '',
  ttsEngine: 'neural', ttsVoice: 'zh-CN-XiaoxiaoNeural', ttsRate: 4,
  voices: [{ id: 'zh-CN-XiaoxiaoNeural', name: '温柔姐姐', hint: '温暖、稳', kind: 'neural' },
    { id: 'com.apple.voice.compact.zh-CN.Tingting', name: 'Tingting', quality: 1, kind: 'system' }],
  status: '未启用', source: 'EasyInput AI', bound: false, draft: '', parked: '' };
const window = { pocketdeskConsoleRequest: async (path, body) => {
  calls.push({ path, body });
  if (fail) throw Error('保存失败');
  if (body?.action === 'save') Object.assign(state, body);
  return { ...state };
} };
const document = { hidden: false, getElementById: node, createElement: element };
vm.runInNewContext(fs.readFileSync('Web/console-voice.js', 'utf8'), { window, document, setInterval: f => { poll = f; }, Number, Array });
const flush = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  await flush();
  assert.equal(node('voiceWake').value, '小E'); assert.equal(node('voiceEnabled').checked, false);
  assert.equal(node('voiceAckPhrase').value, '嗯，我在|在呢'); assert.equal(node('voiceAck').checked, true);
  assert.equal(node('voiceRate').value, 4); assert.equal(node('voiceRateLabel').textContent, '偏快 +4%');
  assert.equal(calls.filter(x => x.body).length, 0);

  state.parked='之前未发送';state.parkedCount=3;await poll();
  assert.equal(node('voiceParkedBox').hidden,false);assert.match(node('voiceParkedTitle').textContent,/3/);
  state.parked='';state.parkedCount=0;await poll();
  // 音色下拉按来源分组：神经音色在前，本机音色在后；当前音色选中温柔姐姐。
  const groups = node('voiceTone').children;
  assert.equal(groups.length, 2); assert.match(groups[0].label, /神经音色/); assert.match(groups[1].label, /本机音色/);
  const options = flatten(groups);
  assert.equal(options.length, 2);
  assert.equal(options[0].value, 'neural:zh-CN-XiaoxiaoNeural'); assert.match(options[0].textContent, /温柔姐姐/);
  assert.equal(options[1].value, 'system:com.apple.voice.compact.zh-CN.Tingting');
  assert.equal(node('voiceTone').value, 'neural:zh-CN-XiaoxiaoNeural');
  assert.match(node('voiceToneHint').textContent, /温柔姐姐/);

  node('voiceWake').value = '小伊'; node('voiceForm').events.input(); await poll(); await flush(); assert.equal(node('voiceWake').value, '小伊');
  node('voiceRetry').onclick(); await flush(); assert.equal(node('voiceStatus').textContent, '请先保存配置。'); assert.equal(calls.filter(x => x.body).length, 0);

  node('voiceEnabled').checked = true; node('voiceAckPhrase').value = '嗯|诶'; node('voiceAck').checked = false;
  node('voiceRate').value = '-6'; node('voiceTone').value = 'system:com.apple.voice.compact.zh-CN.Tingting';
  node('voiceForm').events.submit({ preventDefault() {} }); await flush();
  const saved = calls.filter(x => x.body?.action === 'save').pop().body;
  assert.equal(saved.enabled, true); assert.equal(saved.wakeWord, '小伊'); assert.equal(saved.ackPhrase, '嗯|诶'); assert.equal(saved.ackEnabled, false);
  assert.equal(saved.ttsEngine, 'system'); assert.equal(saved.ttsVoice, ''); assert.equal(saved.voice, 'com.apple.voice.compact.zh-CN.Tingting');
  assert.equal(saved.ttsRate, -6);
  assert.equal(saved.followUp, true, '连续对话开关随保存提交');
  assert.equal(node('voiceAckPhrase').disabled, true);

  node('voicePreview').onclick(); await flush(); assert.equal(calls.filter(x => x.body?.action === 'preview').length, 1);
  state.draft = '<img src=x onerror=evil()>未发送'; state.parked = '较早的一条';
  await poll(); await flush();
  assert.equal(node('voiceDraft').value, state.draft); assert.equal(node('voiceDraftBox').hidden, false);
  assert.equal(node('voiceParked').value, '较早的一条'); assert.equal(node('voiceParkedBox').hidden, false);
  node('voiceSendDraft').onclick(); node('voiceSendDraft').onclick(); await flush(); assert.equal(calls.filter(x => x.body?.action === 'sendDraft').length, 1);
  node('voiceSendParked').onclick(); await flush(); assert.equal(calls.filter(x => x.body?.action === 'sendParked').length, 1);

  // 保存失败时保留用户刚选的声音与正文，不回滚成服务端状态。
  fail = true;
  node('voiceWake').value = '零号'; node('voiceTone').value = 'neural:zh-CN-XiaoyiNeural';
  node('voiceForm').events.input(); node('voiceForm').events.submit({ preventDefault() {} }); await flush();
  assert.equal(node('voiceWake').value, '零号'); assert.equal(node('voiceTone').value, 'neural:zh-CN-XiaoyiNeural');
  assert.equal(node('voiceStatus').textContent, '保存失败');
  // 输入源与键盘能力：键盘掉了要说清楚在用电脑麦克风，扬声器能力只转述设备自报，不替它承诺。
  fail = false; state.fallback = true; state.bound = true; state.deviceCapabilities = {}; state.deviceFirmware = '';
  await poll(); await flush();
  assert.match(node('voiceBinding').textContent, /电脑麦克风/);
  assert.match(node('voiceDevice').textContent, /未上报/);
  state.deviceCapabilities = { speaker_playback: true }; state.deviceFirmware = '0.1.60';
  await poll(); await flush();
  assert.match(node('voiceDevice').textContent, /0\.1\.60/); assert.match(node('voiceDevice').textContent, /自称支持扬声器/);
  state.deviceCapabilities = { speaker_playback: false }; await poll(); await flush();
  assert.match(node('voiceDevice').textContent, /未声明扬声器播放/);

  console.log('Console voice: grouped tones, ack pool, rate, preview, preserved drafts, XSS, failure, source and dedupe checks passed');
})().catch(e => { console.error(e); process.exit(1); });
