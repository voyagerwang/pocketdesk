/**
 * [INPUT]: 真实米家控制台脚本、页面和样式，以及隔离 DOM、时钟、HTTP 与可取消请求替身。
 * [OUTPUT]: 验证显式连接/取消、截止时间撤码、串行轮询、迟到结果隔离、后台恢复与凭证保留语义。
 * [POS]: tests 的米家连接前端回归；不访问真实账号，不生成实际登录授权，不操作设备。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Web/console-mijia.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'Web/console.html'), 'utf8');
const css = fs.readFileSync(path.join(root, 'Web/console-mijia.css'), 'utf8');
const ids = ['mijia-card', 'mijia-state', 'mijia-message', 'mijia-verified', 'mijia-qr-panel',
  'mijia-qr', 'mijia-qr-loading', 'mijia-countdown', 'mijia-connect', 'mijia-check', 'mijia-cancel', 'mijia-retained'];
for (const id of ids) assert.equal((html.match(new RegExp(`id="${id}"`, 'g')) || []).length, 1, `真实页面必须唯一提供 ${id}`);
assert.match(html, /href="#mijia-card"/);
assert.match(html, /src="\/console-mijia\.js\?v=/);
assert.match(html, /href="\/console-mijia\.css\?v=/);
assert.match(css, /#mijia-qr\s*\{[^}]*background:#fff;[^}]*filter:none;/);
assert.match(css, /#mijia-card \[hidden\] \{ display:none; \}/);

class Events {
  constructor() { this.events = {}; }
  addEventListener(type, callback) { (this.events[type] ||= []).push(callback); }
  emit(type) { for (const callback of this.events[type] || []) callback({ target: this }); }
}
class Element extends Events {
  constructor() {
    super(); this.attributes = {}; this.dataset = {}; this.hidden = false; this.disabled = false;
    this.textContent = ''; this.classes = new Set(); this.srcWrites = 0;
    this.classList = { toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name),
      contains: name => this.classes.has(name) };
  }
  set src(value) { this.attributes.src = value; this.srcWrites += 1; }
  get src() { return this.attributes.src || ''; }
  set innerHTML(_) { throw new Error('米家返回的文本不得作为 HTML 解析'); }
  removeAttribute(name) { delete this.attributes[name]; }
  click() { if (!this.disabled && !this.hidden) this.onclick?.(); }
}
function harness() {
  const nodes = Object.fromEntries(ids.map(id => [id, new Element()]));
  const document = new Events(); document.hidden = false;
  document.getElementById = id => nodes[id] || null;
  const window = new Events();
  const requests = []; const timers = new Map();
  let now = 1800000000000, timerID = 0, liveRequests = 0, maxLiveRequests = 0;
  class ClockDate extends Date { constructor(...args) { super(...(args.length ? args : [now])); } static now() { return now; } }
  function fetch(url, options) {
    liveRequests += 1; maxLiveRequests = Math.max(maxLiveRequests, liveRequests);
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    const request = { url, options, settled: false,
      respond(result, ok = true) { assert.equal(this.settled, false); this.settled = true; liveRequests -= 1; resolve({ ok, json: async () => result }); },
      reject(error = new Error('连接中断')) { assert.equal(this.settled, false); this.settled = true; liveRequests -= 1; reject(error); },
      abort() { const error = new Error('aborted'); error.name = 'AbortError'; this.reject(error); }
    };
    requests.push(request);
    return promise;
  }
  const context = vm.createContext({ document, window, fetch, Date: ClockDate, AbortController,
    setTimeout: (callback, delay) => { const id = ++timerID; timers.set(id, { at: now + delay, callback }); return id; },
    clearTimeout: id => timers.delete(id) });
  vm.runInContext('const $ = "existing"; const snapshot = {}; const generation = 0;', context);
  vm.runInContext(source, context, { filename: 'console-mijia.js' });
  async function flush() { for (let index = 0; index < 8; index++) await Promise.resolve(); }
  async function advance(milliseconds) {
    const end = now + milliseconds;
    for (;;) {
      const next = Array.from(timers).filter(([, timer]) => timer.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
      if (!next) break;
      now = next[1].at; timers.delete(next[0]); next[1].callback(); await flush();
    }
    now = end; await flush();
  }
  async function answer(result, ok = true) { const request = requests.find(item => !item.settled); assert.ok(request); request.respond(result, ok); await flush(); return request; }
  async function visibility(hidden) { document.hidden = hidden; document.emit('visibilitychange'); await flush(); }
  const state = (name, extra = {}) => ({ state: name, hasCredentials: false, qrReady: false, revision: 1, ...extra });
  const waiting = (extra = {}) => state('waiting', { sessionId: 'fixture-session', expiresAt: now / 1000 + 120, qrReady: true, ...extra });
  return { nodes, requests, timers, window, document, flush, advance, answer, visibility, state, waiting,
    get now() { return now; }, get maxLiveRequests() { return maxLiveRequests; } };
}
function assertQRRemoved(h) {
  assert.equal(h.nodes['mijia-qr'].hidden, true);
  assert.equal(h.nodes['mijia-qr'].src, '');
  assert.equal(h.nodes['mijia-qr-panel'].hidden, true);
}
let passed = 0;
async function test(name, run) { await run(); passed += 1; console.log(`✓ ${name}`); }
(async () => {
  await test('初始化只读核验，未连接状态不自动登录', async () => {
    const h = harness();
    assert.equal(h.requests.length, 1); assert.match(h.requests[0].url, /\/status$/);
    assert.equal(h.requests[0].options.headers['X-PocketDesk-Console'], '1');
    assert.equal(h.requests[0].options.cache, 'no-store');
    await h.answer(h.state('unconfigured'));
    assert.equal(h.nodes['mijia-connect'].hidden, false);
    assert.equal(h.nodes['mijia-connect'].disabled, false);
    assert.equal(h.nodes['mijia-check'].hidden, true);
    await h.advance(10000); assert.equal(h.requests.length, 1); assertQRRemoved(h);
  });
  await test('显式连接携带本机头，二维码加载后显示且倒计时按服务器期限', async () => {
    const h = harness(); await h.answer(h.state('unconfigured'));
    h.nodes['mijia-connect'].click();
    assert.equal(h.requests.length, 2);
    assert.equal(h.requests[1].options.method, 'POST');
    assert.equal(h.requests[1].options.headers['Content-Type'], 'application/json');
    assert.deepEqual(JSON.parse(h.requests[1].options.body), {});
    await h.answer(h.waiting({ sessionId: 'fixture/space & session' }));
    assert.equal(h.nodes['mijia-qr'].hidden, true);
    assert.match(h.nodes['mijia-qr'].src, /sessionId=fixture%2Fspace%20%26%20session&revision=1$/);
    assert.equal(h.nodes['mijia-countdown'].textContent, '有效期剩余 2:00');
    h.nodes['mijia-qr'].onload(); assert.equal(h.nodes['mijia-qr'].hidden, false);
    await h.advance(1000); assert.equal(h.nodes['mijia-countdown'].textContent, '有效期剩余 1:59');
    await h.advance(1000); assert.equal(h.requests.length, 3, '倒计时不得不断推迟轮询');
    await h.advance(7000); assert.equal(h.requests.length, 3, '慢请求期间不重叠轮询');
    assert.equal(h.maxLiveRequests, 1);
  });
  await test('扫码后核验与成功状态不保留二维码，已保存凭证支持检查和重新连接', async () => {
    const h = harness(); await h.answer(h.waiting());
    await h.advance(2000); await h.answer(h.state('authorizing', { sessionId: 'fixture-session' }));
    assertQRRemoved(h); assert.equal(h.nodes['mijia-state'].textContent, '确认中…');
    await h.advance(2000); await h.answer(h.state('connected', { hasCredentials: true, checkedAt: h.now / 1000, deviceCount: 20 }));
    assertQRRemoved(h); assert.equal(h.nodes['mijia-state'].textContent, '已连接');
    assert.match(h.nodes['mijia-verified'].textContent, /20 个设备/);
    assert.equal(h.nodes['mijia-check'].hidden, false);
    assert.equal(h.nodes['mijia-check'].classList.contains('primary'), true);
    assert.equal(h.nodes['mijia-connect'].textContent, '重新连接');
    const count = h.requests.length; await h.advance(10000); assert.equal(h.requests.length, count);
    h.nodes['mijia-check'].click(); assert.match(h.requests.at(-1).url, /\/check$/);
  });
  await test('等待扫码时可一键刷新，旧二维码立即撤下且迟到图片不能覆盖新会话', async () => {
    const h = harness(); await h.answer(h.waiting());
    const staleLoad = h.nodes['mijia-qr'].onload;
    assert.equal(h.nodes['mijia-connect'].textContent, '刷新二维码');
    assert.equal(h.nodes['mijia-connect'].hidden, false);
    h.nodes['mijia-connect'].click(); assertQRRemoved(h);
    assert.match(h.requests[1].url, /\/connect$/);
    await h.answer(h.waiting({ sessionId: 'fresh-session' }));
    staleLoad(); assert.equal(h.nodes['mijia-qr'].hidden, true);
    h.nodes['mijia-qr'].onload(); assert.equal(h.nodes['mijia-qr'].hidden, false);
    assert.match(h.nodes['mijia-qr'].src, /sessionId=fresh-session/);
  });
  await test('挂起请求十二秒后中止并恢复重试，截止计时在收尾与后台清理', async () => {
    const h = harness();
    await h.advance(12000); assert.equal(h.requests[0].options.signal.aborted, true);
    h.requests[0].abort(); await h.flush();
    assert.equal(h.nodes['mijia-state'].textContent, '连接未完成');
    assert.match(h.nodes['mijia-message'].textContent, /请求超时/);
    assert.equal(h.nodes['mijia-connect'].disabled, false);
    assertQRRemoved(h); assert.equal(h.timers.size, 0);
    h.nodes['mijia-connect'].click(); assert.equal(h.timers.size, 1);
    await h.visibility(true); assert.equal(h.timers.size, 0);
    h.requests[1].abort(); await h.flush(); assert.equal(h.timers.size, 0);
  });
  await test('已经超过请求期限的迟到成功响应不能重新展示二维码', async () => {
    const h = harness(); await h.advance(12000);
    await h.answer(h.waiting()); assertQRRemoved(h);
    assert.equal(h.nodes['mijia-state'].textContent, '连接未完成');
    assert.match(h.nodes['mijia-message'].textContent, /请求超时/);
  });
  await test('到期立即撤码，迟到图片和轮询不能恢复过期二维码', async () => {
    const h = harness(); await h.answer(h.waiting({ expiresAt: h.now / 1000 + 3 }));
    const staleImageLoad = h.nodes['mijia-qr'].onload;
    await h.advance(3000); assertQRRemoved(h);
    assert.equal(h.nodes['mijia-state'].textContent, '二维码已过期');
    assert.equal(h.requests[1].options.signal.aborted, true);
    h.requests[1].respond(h.waiting({ expiresAt: h.now / 1000 + 120 })); await h.flush();
    staleImageLoad(); assertQRRemoved(h);
    assert.equal(h.nodes['mijia-connect'].textContent, '重新生成二维码');
    await h.advance(10000); assert.equal(h.requests.length, 2);
  });
  await test('收到已到期的服务端状态时不发起二维码请求', async () => {
    const h = harness(); await h.answer(h.waiting({ expiresAt: h.now / 1000 - 1 }));
    assertQRRemoved(h); assert.equal(h.nodes['mijia-qr'].srcWrites, 0);
    assert.equal(h.nodes['mijia-state'].textContent, '二维码已过期');
  });
  await test('取消绑定当前会话，先撤码并等待旧请求收尾，保留既有授权', async () => {
    const h = harness(); await h.answer(h.waiting({ hasCredentials: true }));
    assert.equal(h.nodes['mijia-retained'].hidden, false);
    const staleImage = h.nodes['mijia-qr'].onload;
    await h.advance(2000); h.nodes['mijia-cancel'].click();
    assertQRRemoved(h); assert.equal(h.requests.length, 2);
    assert.equal(h.requests[1].options.signal.aborted, true);
    h.requests[1].respond(h.waiting({ revision: 2 })); await h.flush();
    assert.equal(h.requests.length, 3); assert.match(h.requests[2].url, /\/cancel$/);
    assert.deepEqual(JSON.parse(h.requests[2].options.body), { sessionId: 'fixture-session' });
    staleImage(); assertQRRemoved(h);
    await h.answer(h.state('connected', { hasCredentials: true, checkedAt: h.now / 1000, message: '已取消，保留原有连接。' }));
    assert.equal(h.nodes['mijia-connect'].textContent, '重新连接');
    assert.equal(h.nodes['mijia-state'].textContent, '已连接'); assert.equal(h.maxLiveRequests, 1);
  });
  await test('二维码加载错误立即停止旧会话展示，迟到状态不复活', async () => {
    const h = harness(); await h.answer(h.waiting());
    await h.advance(2000); h.nodes['mijia-qr'].onerror(); assertQRRemoved(h);
    assert.match(h.nodes['mijia-message'].textContent, /二维码加载失败/);
    h.requests[1].respond(h.waiting()); await h.flush(); assertQRRemoved(h);
    assert.equal(h.nodes['mijia-state'].textContent, '连接未完成');
  });
  await test('HTTP 失败安全呈现文本并撤下旧码', async () => {
    const h = harness(); await h.answer(h.waiting()); await h.advance(2000);
    await h.answer({ error: '<img src=x onerror=alert(1)> 请重试' }, false);
    assertQRRemoved(h); assert.equal(h.nodes['mijia-message'].textContent, '<img src=x onerror=alert(1)> 请重试');
    assert.equal(h.nodes['mijia-connect'].disabled, false);
  });
  await test('隐藏页面暂停全部计时并撤码，返回仅查询状态', async () => {
    const h = harness(); await h.answer(h.waiting());
    const staleLoad = h.nodes['mijia-qr'].onload;
    await h.visibility(true); assertQRRemoved(h); assert.equal(h.timers.size, 0);
    staleLoad(); assertQRRemoved(h);
    await h.advance(150000); assert.equal(h.requests.length, 1);
    await h.visibility(false); assert.equal(h.requests.length, 2);
    assert.match(h.requests.at(-1).url, /\/status$/); assertQRRemoved(h);
    await h.answer(h.state('expired')); assertQRRemoved(h);
  });
  await test('快速切回页面时，旧请求完成后串行恢复查询', async () => {
    const h = harness();
    await h.visibility(true); await h.visibility(false);
    assert.equal(h.requests.length, 1); assert.equal(h.requests[0].options.signal.aborted, true);
    h.requests[0].respond(h.state('connected', { hasCredentials: true })); await h.flush();
    assert.equal(h.requests.length, 2); assert.match(h.requests[1].url, /\/status$/);
    await h.answer(h.state('unconfigured'));
    assert.equal(h.nodes['mijia-state'].textContent, '未连接'); assert.equal(h.maxLiveRequests, 1);
  });
  await test('页面卸载停止请求，往返缓存恢复不自动新建授权', async () => {
    const h = harness(); await h.answer(h.waiting());
    h.window.emit('pagehide'); assertQRRemoved(h); assert.equal(h.timers.size, 0);
    await h.advance(200000); assert.equal(h.requests.length, 1);
    h.window.emit('pageshow'); assert.equal(h.requests.length, 2);
    assert.match(h.requests[1].url, /\/status$/);
  });
  await test('组件准备与生成期间轮询，取消入口只绑定真实会话', async () => {
    const h = harness(); await h.answer(h.state('installing', { sessionId: 'install-session' }));
    assert.equal(h.nodes['mijia-cancel'].hidden, false); assertQRRemoved(h);
    await h.advance(2000); await h.answer(h.state('starting', { sessionId: 'install-session', revision: 2 }));
    await h.advance(2000); assert.equal(h.requests.length, 3);
  });
  await test('旧版本状态不覆盖新二维码，同一状态不重复下载', async () => {
    const h = harness(); await h.answer(h.waiting({ revision: 3 }));
    const source = h.nodes['mijia-qr'].src;
    await h.advance(2000); await h.answer(h.waiting({ revision: 2 }));
    assert.equal(h.nodes['mijia-qr'].src, source); assert.equal(h.nodes['mijia-qr'].srcWrites, 1);
    await h.advance(2000); await h.answer(h.waiting({ revision: 3 }));
    assert.equal(h.nodes['mijia-qr'].srcWrites, 1);
  });
  console.log(`console mijia: ${passed} 项隔离回归通过`);
})().catch(error => { console.error(error); process.exitCode = 1; });
