/**
 * [INPUT]: Web/app.js 的真实连接编排与徽标函数，虚拟时钟和可暂停/迟到的 HTTP 响应。
 * [OUTPUT]: 验证首次失败自动补齐初始化、单请求在途、响应体截止、停止/超时代际隔离、草稿保护及控制通道真实状态。
 * [POS]: 手机连接恢复的隔离行为回归；不访问网络、不读生产配对、不向桌面输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../Web/app.js'), 'utf8');
const badge = source.slice(source.indexOf('function refreshConnectionBadge()'), source.indexOf('// 全屏可见编辑框'));
const connection = source.slice(source.indexOf('const HEARTBEAT_MS ='), source.indexOf('/* ---------- 主题跟随'));
const status = (name = 'current') => ({ targets: [{ id: name, name }], shortcuts: [], accessibility: true, theme: name, frontmostId: name });
function harness({ draft = '', control = 'ready', recoverPending = false } = {}) {
  let now = 1000, timerId = 0, currentControl = control;
  const timers = new Map(), requests = [], events = {}, ws = [], messages = [], themes = [];
  const calls = { render: 0, frontmost: 0, init: 0, recover: 0, page: 0, live: 0 };
  const classNames = new Set();
  const element = { textContent: '', classList: { add: (...names) => names.forEach(n => classNames.add(n)), remove: (...names) => names.forEach(n => classNames.delete(n)) } };
  const timer = (callback, delay, repeat = false) => { const id = ++timerId; timers.set(id, { callback, at: now + delay, delay, repeat }); return id; };
  const context = vm.createContext({
    AbortController, Promise, Date: { now: () => now }, navigator: { onLine: true, userAgent: 'fixture' },
    window: { addEventListener: (name, fn) => { events[name] = fn; }, pocketdeskControlState: () => currentControl,
      pocketdeskOnWSMessage: fn => ws.push(fn), pocketdeskAgentPanel: { init: () => calls.init++ },
      pocketdeskAgent: { recoverActive: () => { calls.recover++; return recoverPending ? new Promise(() => {}) : Promise.resolve(); }, fetchPage: () => calls.page++ } },
    document: { hidden: false, addEventListener: (name, fn) => { events[name] = fn; } },
    messageEl: { addEventListener: (name, fn) => { events['message:' + name] = fn; } },
    connectionEl: element, httpDown: false, lastAccessibility: true,
    authHeaders: () => ({ Authorization: 'Bearer fixture' }),
    fetch: (url, init) => new Promise((resolve, reject) => {
      const request = { url, init, resolve, reject, aborted: false };
      init.signal.addEventListener('abort', () => { request.aborted = true; });
      requests.push(request);
    }),
    setTimeout: (fn, delay) => timer(fn, delay), clearTimeout: id => timers.delete(id),
    setInterval: (fn, delay) => timer(fn, delay, true), clearInterval: id => timers.delete(id),
    targets: [], globalShortcuts: [], recipientOrder: [], selected: null, SPRITE_ID: '__sprite__', textEl: { value: draft },
    syncShortcuts: list => { context.globalShortcuts = list; }, syncShortcutsForSelected: () => {},
    renderTargets: () => calls.render++, applyTheme: theme => themes.push(theme),
    applyFrontmost: value => { calls.frontmost++; context.selected = value.frontmostId || null; },
    followFrontmost: () => {}, hasRecipientDraft: () => Boolean(context.textEl.value), markSelected: () => {},
    scheduleLive: () => calls.live++, localStorage: { getItem: () => null },
    message: (text, tone) => messages.push({ text, tone })
  });
  vm.runInContext(badge + '\n' + connection, context, { filename: 'app-connection.js' });
  async function flush() { for (let i = 0; i < 30; i++) await Promise.resolve(); }
  async function advance(ms) {
    const end = now + ms;
    for (;;) {
      const next = [...timers].filter(([, item]) => item.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      const [id, item] = next; now = item.at;
      if (item.repeat) item.at += item.delay; else timers.delete(id);
      item.callback(); await flush();
    }
    now = end; await flush();
  }
  async function answer(index, body = {}, code = 200) {
    assert.ok(requests[index], 'expected request ' + index);
    requests[index].resolve({ ok: code >= 200 && code < 300, status: code, json: async () => body }); await flush();
  }
  async function healthy() { context.boot(); await flush(); await answer(0, status()); await answer(1); await answer(2, { order: ['__sprite__', 'current'] }); }
  return { context, requests, events, messages, calls, themes, ws, element, classNames, timers, flush, advance, answer, healthy,
    control: value => { currentControl = value; }, state: name => vm.runInContext(name, context) };
}
let passed = 0;
async function check(name, fn) { await fn(); passed++; console.log('PASS ' + name); }
(async () => {
  await check('首次 HTTP 失败后自动重试，补齐接收者和任务初始化，保留草稿', async () => {
    const h = harness({ draft: '还没发出的原文' }); h.context.boot(); await h.answer(0, {}, 503);
    assert.match(h.messages.at(-1).text, /HTTP 503.*自动重试/); assert.equal(h.calls.init, 0);
    await h.advance(1200); assert.equal(h.requests[1].url, '/api/status');
    await h.answer(1, status()); await h.answer(2); await h.answer(3, { order: ['current', '__sprite__'] });
    assert.equal(h.state('connectionInitialized'), true); assert.equal(h.calls.frontmost, 0); assert.equal(h.calls.init, 1); assert.equal(h.context.selected, null);
    assert.equal(h.calls.recover, 1); assert.equal(h.calls.page, 1); assert.equal(h.calls.live, 0);
    assert.equal(h.context.textEl.value, '还没发出的原文'); assert.deepEqual([...h.context.recipientOrder], ['current', '__sprite__']);
    assert.match(h.messages.at(-1).text, /已重新连接.*草稿已保留.*选择接收者/); assert.equal(h.element.textContent, '已就绪');
    h.context.heartbeatTick(); await h.answer(4); await h.answer(5, status());
    assert.equal(h.calls.init, 1); assert.equal(h.calls.frontmost, 0); assert.equal(h.calls.live, 0);
    assert.ok(h.requests.every(request => request.init.headers.Authorization === 'Bearer fixture'));
    assert.ok(h.requests.every(request => ['/api/status', '/api/recipients', '/api/pair'].includes(request.url)));
  });
  await check('首次 HTTP 未成功时，WS 先认证不能宣称就绪', async () => {
    const h = harness(); h.context.boot(); h.ws[0]({ t: 'auth_ok' });
    assert.equal(h.element.textContent, '连接中'); assert.equal(h.state('connectionInitialized'), false);
    await h.answer(0, {}, 503); h.ws[0]({ t: 'auth_ok' }); assert.equal(h.element.textContent, '未连接');
  });
  await check('首次 401 如实要求重新扫码', async () => {
    const h = harness(); h.context.boot(); await h.answer(0, {}, 401);
    assert.match(h.messages.at(-1).text, /配对已失效.*重新扫码/); assert.equal(h.state('connectionInitialized'), false);
  });
  await check('网络和点击同时触发仍只有一个在途请求；挂起请求到期中止', async () => {
    const h = harness(); const first = h.context.boot();
    for (let i = 0; i < 10; i++) {
      assert.equal(h.context.heartbeatTick(), first); h.events.online(); h.events.offline(); h.events.visibilitychange();
    }
    assert.equal(h.requests.length, 1); await h.advance(4500);
    assert.equal(h.requests[0].aborted, true); assert.equal(h.state('connectionFlight'), null);
    assert.match(h.messages.at(-1).text, /自动重试/);
    await h.advance(500); assert.equal(h.requests.length, 2);
    await h.answer(1, status('new')); await h.answer(2); await h.answer(3, { order: ['new'] });
    await h.answer(0, status('stale'));
    assert.equal(h.context.targets[0].id, 'new'); assert.ok(!h.themes.includes('stale'));
  });
  await check('响应头成功但 JSON 响应体挂起也有截止，迟到正文不复活旧状态', async () => {
    const h = harness(); h.context.boot(); let finishBody;
    h.requests[0].resolve({ ok: true, json: () => new Promise(resolve => { finishBody = resolve; }) }); await h.flush();
    await h.advance(4500); assert.equal(h.requests[0].aborted, true); assert.equal(h.calls.init, 0);
    await h.advance(500); await h.answer(1, status('fresh')); await h.answer(2); await h.answer(3);
    finishBody(status('old-body')); await h.flush(); assert.equal(h.context.targets[0].id, 'fresh');
  });
  await check('接收者配置挂起有界降级，迟到顺序不能覆盖已恢复页面', async () => {
    const h = harness(); h.context.boot(); await h.answer(0, status()); await h.answer(1); await h.advance(4500);
    assert.equal(h.state('connectionInitialized'), true); assert.equal(h.requests[2].aborted, true);
    assert.deepEqual([...h.context.recipientOrder], []); await h.answer(2, { order: ['stale'] });
    assert.deepEqual([...h.context.recipientOrder], []); assert.equal(h.calls.init, 1);
  });
  await check('停止使在途初始化失效，重启后旧状态和旧回包都不落地', async () => {
    const h = harness(); h.context.boot(); await h.answer(0, status('stopped')); await h.answer(1);
    h.context.stopHeartbeat(); h.context.boot(); await h.flush();
    assert.equal(h.requests[2].aborted, true); assert.equal(h.calls.init, 0);
    await h.answer(3, status('restarted')); await h.answer(4); await h.answer(5, { order: ['restarted'] });
    await h.answer(2, { order: ['stopped'] });
    assert.equal(h.context.targets[0].id, 'restarted'); assert.deepEqual([...h.context.recipientOrder], ['restarted']);
    assert.equal(h.calls.init, 1); assert.equal(h.ws.length, 1);
  });
  await check('控制连接未认证和关闭均不显示就绪，认证后即时恢复', async () => {
    const h = harness({ control: 'connecting' }); await h.healthy();
    assert.equal(h.element.textContent, '控制连接中'); assert.equal(h.classNames.has('ready'), false);
    h.control('ready'); h.ws[0]({ t: 'auth_ok' }); assert.equal(h.element.textContent, '已就绪');
    h.control('connecting'); h.ws[0]({ t: 'closed' }); assert.equal(h.element.textContent, '控制连接中');
    h.control('viewer'); h.ws[0]({ t: 'control' }); assert.equal(h.element.textContent, '需接管');
  });
  await check('任务恢复请求挂起不阻塞基础连接心跳', async () => {
    const h = harness({ recoverPending: true }); await h.healthy(); assert.equal(h.state('connectionFlight'), null);
    await h.advance(5000); assert.equal(h.requests[3].url, '/api/pair');
    await h.answer(3); await h.answer(4, status()); assert.equal(h.calls.recover, 1);
  });
  await check('首次持续不可达升级为明确时长，恢复后不会重跑初始化或输入同步', async () => {
    const h = harness(); h.context.boot(); await h.answer(0, {}, 503);
    for (let i = 0; i < 14; i++) { await h.advance(1200); await h.answer(h.requests.length - 1, {}, 503); }
    assert.equal(h.messages.at(-1).tone, true); assert.match(h.messages.at(-1).text, /已中断.*轻点此处立即重试/);
    h.events['message:click'](); await h.answer(h.requests.length - 1, status()); await h.answer(h.requests.length - 1); await h.answer(h.requests.length - 1);
    assert.match(h.messages.at(-1).text, /已重新连接.*中断/); assert.equal(h.calls.init, 1); assert.equal(h.calls.live, 0);
  });
  console.log(`connection recovery: ${passed} behavioral scenarios passed`);
})().catch(error => { console.error(error); process.exitCode = 1; });
