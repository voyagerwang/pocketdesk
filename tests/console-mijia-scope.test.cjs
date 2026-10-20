/**
 * [INPUT]: 真实家庭范围脚本、控制台表单、最小 DOM、可取消 HTTP 与 50 秒时钟替身。
 * [OUTPUT]: 验证首次不自动授权、家庭显式保存与失败保留、草稿/账号隔离、同名纯文本和后台/超时恢复。
 * [POS]: 米家家庭范围前端回归；所有清单与回执合成，不读取实际账号、配置或设备。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'Web/console.html'), 'utf8');
const source = fs.readFileSync(path.join(root, 'Web/console-mijia-scope.js'), 'utf8');
const ids = ['mijia-scope', 'mijia-scope-current', 'mijia-scope-form', 'mijia-home', 'mijia-home-save', 'mijia-home-refresh', 'mijia-scope-message'];
for (const id of ids) assert.equal((html.match(new RegExp(`id="${id}"`, 'g')) || []).length, 1);
assert.ok(html.indexOf('/console-mijia-scope.js?v=') < html.indexOf('/console-mijia.js?v='));
assert.match(html, /仅开放所选家庭中已支持的灯和开关/);
assert.match(html, /摄像头、门锁、音箱、场景和其他未适配设备暂不接入/);
assert.match(html, /小米登录凭证仍是账号级授权/);
assert.doesNotMatch(html, /控制设备或执行手动场景/);
class Events {
  constructor() { this.events = {}; }
  addEventListener(type, callback) { (this.events[type] ||= []).push(callback); }
  emit(type) { for (const callback of this.events[type] || []) callback({ target: this, preventDefault() {} }); }
}
class Element extends Events {
  constructor() {
    super(); this.attributes = {}; this.children = []; this.value = ''; this.textContent = ''; this.disabled = false;
    this.classes = new Set(); this.classList = { toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name) };
  }
  set innerHTML(_) { throw new Error('家庭信息不得解释为 HTML'); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  replaceChildren(...children) { this.children = [...children]; }
  append(child) { this.children.push(child); }
  click() { if (!this.disabled) this.onclick?.(); }
}
function harness() {
  const nodes = Object.fromEntries(ids.map(id => [id, new Element()]));
  const document = new Events(); document.hidden = false;
  document.getElementById = id => nodes[id]; document.createElement = () => new Element();
  const window = new Events(), requests = [], timers = new Map(); let now = 0, timerId = 0, live = 0, maxLive = 0;
  function fetch(url, options) {
    live += 1; maxLive = Math.max(live, maxLive);
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    requests.push({ url, options, settled: false,
      respond(result, ok = true) { assert.equal(this.settled, false); this.settled = true; live -= 1; resolve({ ok, json: async () => result }); },
      reject(issue = new Error('网络中断')) { assert.equal(this.settled, false); this.settled = true; live -= 1; reject(issue); },
      abort() { const issue = new Error('aborted'); issue.name = 'AbortError'; this.reject(issue); }
    });
    return promise;
  }
  const context = vm.createContext({ document, window, fetch, AbortController,
    setTimeout: (callback, delay) => { const id = ++timerId; timers.set(id, { at: now + delay, callback }); return id; },
    clearTimeout: id => timers.delete(id) });
  vm.runInContext('const $ = "existing"; const data = {}; const connected = false;', context);
  vm.runInContext(source, context, { filename: 'console-mijia-scope.js' });
  async function flush() { for (let n = 0; n < 8; n++) await Promise.resolve(); }
  async function answer(result, ok = true) { const pending = requests.find(item => !item.settled); assert.ok(pending); pending.respond(result, ok); await flush(); }
  async function advance(ms) {
    now += ms;
    for (const [id, timer] of Array.from(timers)) if (timer.at <= now) { timers.delete(id); timer.callback(); }
    await flush();
  }
  function connection(state = 'connected', extra = {}) { window.PocketDeskMijiaScope.connectionChanged({ state, hasCredentials: true, checkedAt: 100, revision: 1, ...extra }); }
  function choose(id) { nodes['mijia-home'].value = id; nodes['mijia-home'].emit('change'); }
  function submit() { nodes['mijia-scope-form'].emit('submit'); }
  function refresh() { nodes['mijia-home-refresh'].click(); }
  async function visibility(hidden) { document.hidden = hidden; document.emit('visibilitychange'); await flush(); }
  return { nodes, requests, timers, window, document, flush, answer, advance, connection, choose, submit, refresh, visibility, get maxLive() { return maxLive; } };
}
const homes = [{ id: 'home-a', name: '上海的家' }, { id: 'home-b', name: '杭州的家' }];
const list = (selectedHomeId = null, entries = homes) => ({ homes: entries, selectedHomeId,
  selectedHomeName: entries.find(home => home.id === selectedHomeId)?.name || null, selectionRequired: !selectedHomeId });
let passed = 0;
async function test(name, run) { await run(); passed += 1; console.log(`✓ ${name}`); }
(async () => {
  await test('未连接不请求家庭，连接后只读列表且双家庭不默认选第一个', async () => {
    const h = harness(); assert.equal(h.requests.length, 0); assert.equal(h.nodes['mijia-home'].disabled, true);
    h.connection(); assert.match(h.requests[0].url, /\/homes$/);
    assert.equal(h.requests[0].options.headers['X-PocketDesk-Console'], '1');
    await h.answer(list());
    assert.equal(h.nodes['mijia-home'].value, '');
    assert.equal(h.nodes['mijia-home-save'].disabled, true);
    assert.match(h.nodes['mijia-scope-current'].textContent, /还需选择/);
    assert.equal(h.nodes['mijia-home'].children.length, 3);
    assert.ok(!h.nodes['mijia-home'].children.some(option => option.textContent === '所有家庭'));
    h.connection(); assert.equal(h.requests.length, 1, '相同连接状态不重复读取慢接口');
  });
  await test('仅一个家庭也必须由用户显式选择并保存', async () => {
    const h = harness(); h.connection(); await h.answer(list(null, [homes[0]]));
    assert.equal(h.nodes['mijia-home'].value, '');
    h.choose('home-a'); assert.equal(h.nodes['mijia-home-save'].disabled, false);
    assert.match(h.nodes['mijia-scope-message'].textContent, /尚未保存/);
    assert.doesNotMatch(h.nodes['mijia-scope-current'].textContent, /当前生效/);
    assert.equal(h.requests.length, 1);
  });
  await test('成功保存精准 homeId，确认回执后才改变生效范围，重复提交被阻止', async () => {
    const h = harness(); h.connection(); await h.answer(list('home-a'));
    h.choose('home-b'); assert.match(h.nodes['mijia-scope-current'].textContent, /上海的家/);
    h.submit(); h.submit(); assert.equal(h.requests.length, 2);
    assert.match(h.requests[1].url, /\/home$/);
    assert.equal(h.requests[1].options.method, 'POST');
    assert.equal(h.requests[1].options.headers['Content-Type'], 'application/json');
    assert.deepEqual(JSON.parse(h.requests[1].options.body), { homeId: 'home-b' });
    assert.equal(h.nodes['mijia-home'].disabled, true);
    assert.match(h.nodes['mijia-scope-current'].textContent, /上海的家/);
    await h.answer(list('home-b'));
    assert.equal(h.nodes['mijia-scope-current'].textContent, '当前生效：杭州的家');
    assert.equal(h.nodes['mijia-home-save'].disabled, true);
    assert.equal(h.nodes['mijia-scope-message'].textContent, '控制范围已保存。');
  });
  await test('保存明确失败保留旧确认范围和新草稿，允许用户重试', async () => {
    const h = harness(); h.connection(); await h.answer(list('home-a'));
    h.choose('home-b'); h.submit(); await h.answer({ error: '家庭访问已取消' }, false);
    assert.equal(h.nodes['mijia-scope-current'].textContent, '当前生效：上海的家');
    assert.equal(h.nodes['mijia-home'].value, 'home-b');
    assert.match(h.nodes['mijia-scope-message'].textContent, /保存失败.*家庭访问已取消/);
    assert.equal(h.nodes['mijia-home-save'].disabled, false);
  });
  await test('刷新家庭列表不偷偷保存或覆盖仍有效的未保存草稿', async () => {
    const h = harness(); h.connection(); await h.answer(list('home-a')); h.choose('home-b'); h.refresh();
    assert.equal(h.nodes['mijia-home-save'].disabled, true);
    await h.answer(list('home-a'));
    assert.equal(h.nodes['mijia-home'].value, 'home-b');
    assert.match(h.nodes['mijia-scope-message'].textContent, /尚未保存/);
    assert.match(h.nodes['mijia-scope-current'].textContent, /上海的家/);
    assert.ok(h.requests.every(request => request.options.method !== 'POST'));
  });
  await test('草稿指向已移除家庭时刷新撤下草稿，旧授权失效时不复用旧家庭', async () => {
    const h = harness(); h.connection(); await h.answer(list('home-a')); h.choose('home-b'); h.refresh();
    await h.answer(list(null, [{ id: 'home-c', name: '新家庭' }]));
    assert.equal(h.nodes['mijia-home'].value, '');
    assert.equal(h.nodes['mijia-home-save'].disabled, true);
    assert.match(h.nodes['mijia-scope-current'].textContent, /还需选择/);
  });
  await test('重新授权隔离旧账号在途家庭响应，新账号从未选开始', async () => {
    const h = harness(); h.connection();
    h.connection('waiting', { sessionId: 'fresh-login' });
    assert.equal(h.requests[0].options.signal.aborted, true);
    h.connection('connected', { checkedAt: 200, revision: 2 });
    assert.equal(h.requests.length, 1);
    h.requests[0].respond(list('home-a')); await h.flush();
    assert.equal(h.requests.length, 2);
    await h.answer(list(null, [{ id: 'home-c', name: '另一个账号的家' }]));
    assert.equal(h.nodes['mijia-home'].value, '');
    assert.doesNotMatch(h.nodes['mijia-scope-current'].textContent, /上海/);
    assert.equal(h.nodes['mijia-home'].children[1].textContent, '另一个账号的家');
    assert.equal(h.maxLive, 1);
  });
  await test('同名家庭附 ID 区分，名称和错误作为文本呈现', async () => {
    const h = harness(); h.connection();
    await h.answer(list(null, [{ id: 'one', name: '<img onerror=alert(1)>' }, { id: 'two', name: '<img onerror=alert(1)>' }]));
    assert.equal(h.nodes['mijia-home'].children[1].textContent, '<img onerror=alert(1)>（one）');
    assert.equal(h.nodes['mijia-home'].children[2].textContent, '<img onerror=alert(1)>（two）');
  });
  await test('家庭读取可等待超过扫码期限，50秒才超时，超时后可刷新', async () => {
    const h = harness(); h.connection(); await h.advance(40000);
    assert.equal(h.requests[0].options.signal.aborted, false);
    await h.advance(10000); assert.equal(h.requests[0].options.signal.aborted, true);
    h.requests[0].abort(); await h.flush();
    assert.match(h.nodes['mijia-scope-message'].textContent, /超时/);
    assert.equal(h.nodes['mijia-home-refresh'].disabled, false);
    assert.equal(h.timers.size, 0);
    h.refresh(); await h.answer(list()); assert.equal(h.nodes['mijia-home'].disabled, false);
  });
  await test('保存网络结果未知保留上次确认范围，先刷新核对，不自动重发', async () => {
    const h = harness(); h.connection(); await h.answer(list('home-a'));
    h.choose('home-b'); h.submit(); h.requests[1].reject(); await h.flush();
    assert.equal(h.nodes['mijia-scope-current'].textContent, '上次确认范围：上海的家');
    assert.match(h.nodes['mijia-scope-message'].textContent, /保存结果尚未确认/);
    assert.equal(h.nodes['mijia-home-save'].disabled, true);
    h.refresh(); await h.answer(list('home-b'));
    assert.equal(h.nodes['mijia-scope-current'].textContent, '当前生效：杭州的家');
    assert.equal(h.requests.filter(request => request.options.method === 'POST').length, 1);
  });
  await test('后台终止慢请求并清理时钟，前台串行查账，旧结果不回填', async () => {
    const h = harness(); h.connection(); await h.visibility(true);
    assert.equal(h.requests[0].options.signal.aborted, true); assert.equal(h.timers.size, 0);
    await h.advance(60000); assert.equal(h.requests.length, 1);
    await h.visibility(false); assert.equal(h.requests.length, 1);
    h.requests[0].respond(list('home-a')); await h.flush();
    assert.equal(h.requests.length, 2); await h.answer(list());
    assert.equal(h.nodes['mijia-home'].value, ''); assert.equal(h.maxLive, 1);
  });
  await test('空家庭与无效家庭清单不产生默认授权', async () => {
    const h = harness(); h.connection(); await h.answer(list(null, []));
    assert.match(h.nodes['mijia-scope-message'].textContent, /还没有可选择的家庭/);
    assert.equal(h.nodes['mijia-home-save'].disabled, true);
    h.refresh(); await h.answer({ homes: [{ id: 'duplicate', name: '甲' }, { id: 'duplicate', name: '乙' }] });
    assert.match(h.nodes['mijia-scope-message'].textContent, /重复标识/);
    assert.equal(h.nodes['mijia-home-save'].disabled, true);
  });
  console.log(`console mijia scope: ${passed} 项隔离回归通过`);
})().catch(issue => { console.error(issue); process.exitCode = 1; });
