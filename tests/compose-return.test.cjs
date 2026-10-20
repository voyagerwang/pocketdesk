/**
 * [INPUT]: 依赖 Node vm/断言与真实 compose.js 的回车处理函数和共享编辑事件绑定，注入编辑框、提交锁与计时器替身。
 * [OUTPUT]: 验证首页/全屏回车提交、Android输入事件兜底、选区与多行保留、候选确认隔离、Shift换行、重复事件去重和失败草稿保留。
 * [POS]: tests 的原生输入法提交行为回归；运行实际事件绑定，不连接电脑、不发送网络或系统事件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../Web/compose.js'), 'utf8');
const returnStart = source.indexOf('/* ---------- 显式回车');
const returnEnd = source.indexOf("\ndocument.querySelector('#screen-compose')", returnStart);
const wireStart = source.indexOf('function wireComposeIME(');
const wireEnd = source.indexOf('\nwireHomeCompose(textEl);', wireStart);
assert.ok(returnStart >= 0 && returnEnd > returnStart && wireStart >= 0 && wireEnd > wireStart, '真实回车处理和编辑事件绑定必须可读取');
const functions = source.slice(returnStart, returnEnd) + '\n' + source.slice(wireStart, wireEnd);

function setup({ fullscreen = true, value = '待发送正文', start = value.length, end = start } = {}) {
  class Editor {
    constructor(value = '') { this.value = value; this.selectionStart = start; this.selectionEnd = end; this.isConnected = true; this.readOnly = false; this.listeners = new Map(); }
    addEventListener(type, fn) { if (!this.listeners.has(type)) this.listeners.set(type, []); this.listeners.get(type).push(fn); }
    setSelectionRange(start, end) { this.selectionStart = start; this.selectionEnd = end; }
    emit(type, properties = {}) {
      const event = { currentTarget: this, target: this, cancelable: true, key: '', keyCode: 0, inputType: '', isComposing: false,
        shiftKey: false, repeat: false, defaultPrevented: false, ...properties,
        preventDefault() { if (this.cancelable) this.defaultPrevented = true; } };
      for (const fn of this.listeners.get(type) || []) fn(event);
      return event;
    }
  }
  const editor = new Editor(value), other = new Editor(), submitted = [], timers = new Map();
  let timerID = 0, probes = 0;
  const context = vm.createContext({ liveComposing: false, submittingDraft: false,
    textEl: fullscreen ? other : editor, kbProxy: fullscreen ? editor : other,
    selected: 'editor', SPRITE_ID: 'sprite', sendEl: { disabled: false }, androidInputPatch: true,
    document: { activeElement: editor }, window: {}, fullComposeOpen: () => fullscreen,
    pocketdeskMarkInput() {}, syncSpriteExpression() {}, syncKeyboardDraft() {}, scheduleLive() {},
    flushLive: async () => ({}), recoverIME() { probes++; },
    setTimeout(fn) { timers.set(++timerID, fn); return timerID; }, clearTimeout(id) { timers.delete(id); } });
  function submit(route) {
    // 与生产send一致：第一次异步等待之前即持有提交锁；失败收尾保留原编辑内容。
    if (context.submittingDraft || context.sendEl.disabled) return Promise.resolve();
    const current = fullscreen ? context.kbProxy : context.textEl;
    context.submittingDraft = true; context.sendEl.disabled = true; current.readOnly = true;
    submitted.push({ route, value: current.value });
    return new Promise(() => {});
  }
  context.send = () => submit('home'); context.sendFromKeyboard = () => submit('fullscreen');
  context.endCompositionState = () => { context.liveComposing = false; };
  vm.runInContext('const imePrevLen = new WeakMap(); const composeReturnState = new WeakMap();\n' + functions, context);
  context.wireComposeIME(editor, fullscreen);
  return { editor, other, submitted, context, timers, probes: () => probes,
    emit: (type, properties) => editor.emit(type, properties),
    insertNewline(type = 'insertLineBreak', { beforeinput = true, cancelable = true, isComposing = false } = {}) {
      const before = beforeinput ? editor.emit('beforeinput', { inputType: type, cancelable, isComposing }) : null;
      if (before?.defaultPrevented) return before;
      const start = editor.selectionStart, end = editor.selectionEnd;
      editor.value = editor.value.slice(0, start) + '\n' + editor.value.slice(end);
      editor.setSelectionRange(start + 1, start + 1);
      editor.emit('input', { inputType: type, isComposing });
      return before;
    },
    fail() { context.submittingDraft = false; context.sendEl.disabled = false; editor.readOnly = false; },
    advance() { const callbacks = [...timers.values()]; timers.clear(); callbacks.forEach(fn => fn()); } };
}

let count = 0;
function check(name, run) { run(); count++; console.log(`ok ${count} - ${name}`); }

check('首页和全屏普通Enter走各自共用发送入口', () => {
  for (const fullscreen of [false, true]) {
    const h = setup({ fullscreen }), event = h.emit('keydown', { key: 'Enter', keyCode: 13 });
    assert.ok(event.defaultPrevented, '提交动作阻止输入换行');
    assert.deepEqual(h.submitted, [{ route: fullscreen ? 'fullscreen' : 'home', value: '待发送正文' }]);
  }
});

check('Android229键本身不提交，非组合beforeinput回车仍可提交', () => {
  for (const key of ['Enter', 'Unidentified']) {
    const h = setup(); h.emit('keydown', { key, keyCode: 229 }); assert.equal(h.submitted.length, 0);
    const event = h.insertNewline(); assert.ok(event.defaultPrevented);
    assert.deepEqual(h.submitted, [{ route: 'fullscreen', value: '待发送正文' }]);
  }
});

check('仅beforeinput的换行和段落动作提交，且不启动卡死探针', () => {
  for (const inputType of ['insertLineBreak', 'insertParagraph']) {
    const h = setup({ value: '第一行\n第二行' }); const event = h.emit('beforeinput', { inputType });
    assert.ok(event.defaultPrevented); assert.equal(h.submitted.length, 1);
    assert.equal(h.submitted[0].value, '第一行\n第二行');
    h.advance(); assert.equal(h.probes(), 0, '主动取消的换行没有input并非输入法卡死');
  }
});

check('不可取消beforeinput等待input后撤回动作换行并提交', () => {
  for (const inputType of ['insertLineBreak', 'insertParagraph']) {
    const h = setup({ value: '已有\n多行正文' });
    const event = h.emit('beforeinput', { inputType, cancelable: false });
    assert.equal(event.defaultPrevented, false); assert.equal(h.submitted.length, 0);
    h.insertNewline(inputType, { beforeinput: false });
    assert.deepEqual(h.submitted, [{ route: 'fullscreen', value: '已有\n多行正文' }]);
    assert.equal(h.editor.value, '已有\n多行正文'); h.advance(); assert.equal(h.probes(), 0);
  }
});

check('只有input的尾部换行提交，并保留此前所有正文换行', () => {
  for (const inputType of ['insertLineBreak', 'insertParagraph']) {
    const h = setup({ value: '第一行\n\n最后一行' }); h.insertNewline(inputType, { beforeinput: false });
    assert.equal(h.submitted.length, 1); assert.equal(h.submitted[0].value, '第一行\n\n最后一行');
    assert.equal(h.editor.selectionStart, h.editor.value.length);
  }
});

check('中间选区遇到不可取消换行恢复原选区正文再提交', () => {
  const h = setup({ value: '前缀候选词后缀\n第二行', start: 2, end: 5 });
  h.insertNewline('insertLineBreak', { cancelable: false });
  assert.equal(h.submitted.length, 1); assert.equal(h.submitted[0].value, '前缀候选词后缀\n第二行');
  assert.equal(h.editor.selectionStart, 2); assert.equal(h.editor.selectionEnd, 5);
});

check('只有input的中间换行只撤掉光标前本次插入的一个换行', () => {
  const h = setup({ value: '第一行\n第二行尾部', start: 7 }); h.insertNewline('insertLineBreak', { beforeinput: false });
  assert.equal(h.submitted.length, 1); assert.equal(h.submitted[0].value, '第一行\n第二行尾部');
  assert.equal(h.editor.selectionStart, 7);
});

check('Shift+Enter保留换行，松Shift后的手机回车仍可发送', () => {
  const h = setup(); const event = h.emit('keydown', { key: 'Enter', keyCode: 13, shiftKey: true });
  assert.equal(event.defaultPrevented, false); h.insertNewline();
  assert.equal(h.submitted.length, 0); assert.equal(h.editor.value, '待发送正文\n');
  h.emit('keyup', { key: 'Shift' }); const next = h.insertNewline();
  assert.ok(next.defaultPrevented); assert.equal(h.submitted.length, 1); assert.equal(h.submitted[0].value, '待发送正文\n');
});

check('组合态Enter只确认候选，compositionend后下一次Enter正常发送', () => {
  const h = setup(); h.emit('compositionstart');
  const event = h.emit('keydown', { key: 'Enter', keyCode: 229, isComposing: true });
  assert.equal(event.defaultPrevented, false); assert.equal(h.submitted.length, 0);
  h.emit('compositionend'); h.emit('keydown', { key: 'Enter', keyCode: 13 });
  assert.equal(h.submitted.length, 1);
});

check('候选确认仅由输入事件完成时不误发，之后纯IME回车可发送', () => {
  for (const key of [null, 'Unidentified']) {
    const h = setup(); h.emit('compositionstart');
    if (key) h.emit('keydown', { key, keyCode: 229 });
    h.insertNewline('insertLineBreak', { cancelable: false, isComposing: false });
    assert.equal(h.submitted.length, 0, '候选结束的非组合input不能被升级为发送动作');
    h.emit('compositionend'); const event = h.insertNewline();
    assert.ok(event.defaultPrevented); assert.equal(h.submitted.length, 1);
  }
});

check('组合Enter后只有compositionend没有input，也不吞下一次纯IME发送', () => {
  const h = setup(); h.emit('compositionstart'); h.emit('keydown', { key: 'Enter', keyCode: 229, isComposing: true });
  h.emit('compositionend'); const event = h.insertNewline('insertParagraph');
  assert.ok(event.defaultPrevented); assert.equal(h.submitted.length, 1);
});

check('仅input结束候选时保留此前组合证据，不自动提交', () => {
  const h = setup(); h.emit('compositionstart');
  h.insertNewline('insertLineBreak', { beforeinput: false, isComposing: false });
  assert.equal(h.submitted.length, 0, '无keydown/beforeinput的候选完成也不发送');
  h.emit('compositionend'); const event = h.insertNewline();
  assert.ok(event.defaultPrevented); assert.equal(h.submitted.length, 1);
});

check('长按Enter重复事件不重复提交，keydown和beforeinput共用发送锁', () => {
  const repeated = setup(); const repeat = repeated.emit('keydown', { key: 'Enter', keyCode: 13, repeat: true });
  assert.ok(repeat.defaultPrevented); assert.equal(repeated.submitted.length, 0);
  const h = setup(); h.emit('keydown', { key: 'Enter', keyCode: 13 });
  h.emit('keydown', { key: 'Enter', keyCode: 13, repeat: true }); h.emit('beforeinput', { inputType: 'insertLineBreak' });
  assert.equal(h.submitted.length, 1, '同一次用户回车的两类事件只提交一次');
});

check('普通文字、粘贴多行以及输入事件缺少动作证据不触发发送', () => {
  for (const inputType of ['insertText', 'insertFromPaste', 'insertCompositionText', '']) {
    const h = setup({ value: '保留正文\n' }); h.emit('beforeinput', { inputType }); h.emit('input', { inputType });
    assert.equal(h.submitted.length, 0); assert.equal(h.editor.value, '保留正文\n');
  }
  const h = setup(); h.emit('input', { inputType: 'insertLineBreak' });
  assert.equal(h.submitted.length, 0, '声明换行但没有本次插入的换行时保留正文');
});

check('发送失败保留正文和选区，下一次显式回车可以重试', () => {
  const h = setup({ value: '失败仍保留\n原文', start: 2, end: 4 });
  h.insertNewline('insertLineBreak', { cancelable: false }); h.fail();
  assert.equal(h.editor.value, '失败仍保留\n原文'); assert.equal(h.editor.selectionStart, 2); assert.equal(h.editor.selectionEnd, 4);
  h.emit('keydown', { key: 'Enter', keyCode: 13 });
  assert.equal(h.submitted.length, 2); assert.equal(h.submitted[1].value, '失败仍保留\n原文');
});

check('重建编辑框重新获得提交事件，旧输入法迟到事件失效', () => {
  const h = setup(); h.editor.isConnected = false;
  h.other.value = '新编辑会话'; h.other.setSelectionRange(h.other.value.length, h.other.value.length);
  h.context.kbProxy = h.other; h.context.wireComposeIME(h.other, true);
  h.emit('keydown', { key: 'Enter', keyCode: 13 }); h.emit('beforeinput', { inputType: 'insertLineBreak' });
  assert.equal(h.submitted.length, 0, '已移除编辑框不接受迟到发送');
  h.other.emit('keydown', { key: 'Enter', keyCode: 13 });
  assert.deepEqual(h.submitted, [{ route: 'fullscreen', value: '新编辑会话' }]);
});

console.log(`compose-return: ${count} behavior regressions passed`);
