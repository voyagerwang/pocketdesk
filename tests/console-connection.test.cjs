/**
 * [INPUT]: 真实控制台连接脚本与页面结构，最小 DOM/时钟替身及固定主机名、变化 IP 的状态快照。
 * [OUTPUT]: 验证默认 IP 链接与主二维码及时更新，电脑名称仅为可选入口，凭据不展示，断线/空地址清除旧码且恢复可重试。
 * [POS]: tests 的控制台连接行为回归；只在 VM 内呈现状态，不连接服务、不读真实配对凭据、不执行桌面操作。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element {
  constructor() {
    this.attributes = {};
    this.dataset = {};
    this.events = {};
    this.classes = new Set();
    this.hidden = false;
    this.textContent = '';
    this.srcWrites = 0;
    this.classList = {
      add: name => this.classes.add(name),
      remove: name => this.classes.delete(name),
      contains: name => this.classes.has(name),
      toggle: (name, on) => on ? this.classes.add(name) : this.classes.delete(name)
    };
  }
  set src(value) { this.setAttribute('src', value); }
  get src() { return this.attributes.src || ''; }
  set href(value) { this.setAttribute('href', value); }
  get href() { return this.attributes.href || ''; }
  set innerHTML(_) { throw new Error('连接说明不得解析为 HTML'); }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name === 'src') this.srcWrites += 1;
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  removeAttribute(name) { delete this.attributes[name]; }
  addEventListener(name, handler) { (this.events[name] ||= []).push(handler); }
  emit(name) {
    const event = { target: this };
    this[`on${name}`]?.(event);
    for (const handler of this.events[name] || []) handler(event);
  }
}

const webRoot = path.join(__dirname, '..', 'Web');
const html = fs.readFileSync(path.join(webRoot, 'console.html'), 'utf8');
const source = fs.readFileSync(path.join(webRoot, 'console-connection.js'), 'utf8');
const ids = ['qr-host', 'hostUrl', 'connectionLabel', 'connectionHelp', 'connect-message',
  'connectionFallback', 'qr-ip', 'ipUrl', 'fallback-message', 'phoneState'];
for (const id of ids) {
  assert.equal((html.match(new RegExp(`id="${id}"`, 'g')) || []).length, 1,
    `连接脚本依赖的 #${id} 必须在真实控制台唯一存在`);
}
assert.match(html, /<script\s+src="\/console-connection\.js\?v=/,
  '控制台必须加载带版本号的连接脚本');

const nodes = Object.fromEntries(ids.map(id => [id, new Element()]));
let now = 0;
const context = vm.createContext({
  window: {}, URL, Date: { now: () => ++now },
  document: { getElementById: id => nodes[id] || null }
});
// 经典脚本共用全局词法作用域；已有控制台的 $/state 不能被新模块重复声明。
vm.runInContext('const $ = "existing-console-selector"; const state = {}; const setLink = "existing-console-helper";', context);
vm.runInContext(source, context, { filename: 'console-connection.js' });
const connection = context.window.PocketDeskConsoleConnection;
assert.equal(typeof connection?.render, 'function');
assert.equal(typeof connection?.unavailable, 'function');
assert.deepEqual(Object.keys(context.window), ['PocketDeskConsoleConnection'],
  '连接模块只公开自己的入口，不向页面散落全局变量');

const stableURL = 'http://pocketdesk-fixture.local:46387/?token=fixture-connection-token';
const ipA = 'http://192.168.0.20:46387/?token=fixture-connection-token';
const ipB = 'http://192.168.0.21:46387/?token=fixture-connection-token';
const stateFor = ipWorkspaceURL => ({ workspaceURL: stableURL, ipWorkspaceURL });
const qrType = id => new URL(nodes[id].src, 'http://127.0.0.1:46387').searchParams.get('type');
function assertCleared(entries = [['qr-ip', 'ipUrl'], ['qr-host', 'hostUrl']]) {
  for (const [id, linkId] of entries) {
    assert.equal(nodes[id].hidden, true, `${id} 不得留下可扫描的失效图像`);
    assert.equal(nodes[id].getAttribute('src'), null, `${id} 清除旧二维码请求地址`);
    assert.ok(!nodes[id].dataset.url, `${id} 清除旧连接快照`);
    assert.equal(nodes[linkId].getAttribute('href'), null, `${linkId} 不得继续打开旧地址`);
  }
}

connection.render(stateFor(ipA));
assert.equal(nodes.ipUrl.href, ipA, '默认连接直接使用已验证可达的当前 IP');
assert.match(nodes.connectionLabel.textContent, /扫码连接手机/);
assert.doesNotMatch(nodes.connectionLabel.textContent, /固定/);
assert.match(nodes.connectionHelp.textContent, /当前 IP 可能随网络变化/, '默认 IP 入口明确说明地址可能变化');
assert.equal(qrType('qr-ip'), 'ip', '默认二维码对应当前 IP');
assert.equal(nodes.hostUrl.href, stableURL, '名称入口保留为可选连接');
assert.equal(qrType('qr-host'), 'host');
for (const id of ['hostUrl', 'ipUrl'])
  assert.doesNotMatch(nodes[id].textContent, /fixture-connection-token|token=/, '可见链接文字不泄漏凭据');
assert.equal(nodes.connectionFallback.hidden, false);
nodes['qr-host'].emit('load');
nodes['qr-ip'].emit('load');
assert.equal(nodes['qr-ip'].hidden, false, '成功加载后才展示可扫描图像');
const firstHostQR = nodes['qr-host'].src;
const firstIPQR = nodes['qr-ip'].src;

connection.render(stateFor(ipB));
assert.equal(nodes.ipUrl.href, ipB, '路由器重新分配 IP 后，默认入口及时更新');
assert.notEqual(nodes['qr-ip'].src, firstIPQR, '默认二维码不能保留旧 IP');
assert.equal(nodes['qr-ip'].dataset.url, ipB);
assert.equal(nodes['qr-ip'].hidden, true, '新 IP 图片加载前撤下旧码');
assert.equal(nodes.hostUrl.href, stableURL);
assert.equal(nodes['qr-host'].src, firstHostQR, 'IP 变化不重载可选名称二维码');
nodes['qr-ip'].emit('load');
const unchangedIPQR = nodes['qr-ip'].src;
connection.render(stateFor(ipB));
assert.equal(nodes['qr-host'].src, firstHostQR);
assert.equal(nodes['qr-ip'].src, unchangedIPQR, '相同状态轮询不重载二维码');

nodes['qr-ip'].emit('error');
assert.equal(nodes['qr-ip'].hidden, true, '二维码加载失败隐藏破图');
assert.ok(nodes['connect-message'].textContent, '二维码失败给出可读反馈');
connection.render(stateFor(ipB));
assert.equal(nodes['qr-ip'].hidden, true, '重试成功前不显示旧码');
assert.notEqual(nodes['qr-ip'].src, unchangedIPQR, '失败后的恢复必须重新请求图片');
nodes['qr-ip'].emit('load');
assert.equal(nodes['qr-ip'].hidden, false, '同一地址的后续轮询能重试二维码');

connection.unavailable();
assertCleared();
assert.ok(nodes.ipUrl.textContent, '服务不可用时说明当前无法提供连接');
connection.render(stateFor(ipB));
assert.equal(nodes.ipUrl.href, ipB, '服务恢复后重新显示当前 IP 入口');
nodes['qr-host'].emit('load');
nodes['qr-ip'].emit('load');
assert.equal(nodes['qr-host'].hidden, false);
assert.equal(nodes['qr-ip'].hidden, false);

connection.render({});
assertCleared();
connection.render({ workspaceURL: ipB, ipWorkspaceURL: ipB });
assert.equal(nodes.ipUrl.href, ipB, '仅 IP 时保留默认入口');
assert.equal(nodes.connectionFallback.hidden, true, '无电脑名称时不显示重复二维码');
connection.render({ workspaceURL: ipA });
assert.equal(nodes.ipUrl.href, ipA, '旧服务只提供带授权的数字地址时仍可兼容');
connection.render({ workspaceURL: stableURL });
assertCleared([['qr-ip', 'ipUrl']]);
assert.match(nodes.connectionLabel.textContent, /扫码连接手机/, '缺 IP 时仍不把名称入口升为默认');
connection.render(stateFor(ipA));
assert.equal(nodes.ipUrl.href, ipA);
assert.equal(nodes.connectionFallback.hidden, false, '可选名称随状态恢复');

connection.render({ lanURL: stableURL, ipURL: ipA });
assertCleared();
console.log('console connection: 默认 IP 更新/名称可选/凭据隐藏/失效清理/错误恢复/全局隔离全部通过');
