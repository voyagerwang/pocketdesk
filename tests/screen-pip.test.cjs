/**
 * [INPUT]: 依赖 Node vm/断言与真实 ScreenPip，注入指针事件、视口、面板和存储替身。
 * [OUTPUT]: 验证小窗双指缩放与中点锚定、尺寸夹取、额外触点隔离、松指/取消收尾，以及单指拖动、边柄缩放和持久化兼容。
 * [POS]: tests 的小窗触控行为回归；不访问真实网络、浏览器或电脑输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../Web/screen-pip.js'), 'utf8');

function setup({ width = 1000, height = 800, saved } = {}) {
  const values = new Map(saved === undefined ? [] : [['voicedeck.pip', JSON.stringify(saved)]]);
  const timers = new Map(); let timerID = 0, changes = 0;
  class Element {
    constructor(tag = 'div', classes = [], parent = null) {
      this.tagName = tag.toUpperCase(); this.parentElement = parent;
      this.nodeType = 1; this.dataset = {}; this.events = new Map(); this.style = {};
      this.classes = new Set(classes);
      this.classList = { contains: name => this.classes.has(name), add: name => this.classes.add(name), remove: name => this.classes.delete(name) };
    }
    addEventListener(type, fn) { if (!this.events.has(type)) this.events.set(type, []); this.events.get(type).push(fn); }
    emit(type, event) { for (const fn of this.events.get(type) || []) fn(event); }
    closest(selector) {
      for (const item of selector.split(',').map(item => item.trim())) {
        if (item.startsWith('.') ? this.classes.has(item.slice(1)) : item.toUpperCase() === this.tagName) return this;
      }
      return this.parentElement?.closest(selector) || null;
    }
    contains(target) { return target === this || (target.parentElement ? this.contains(target.parentElement) : false); }
    setPointerCapture(id) { this.captures ||= new Set(); this.captures.add(id); }
    releasePointerCapture(id) { this.captures?.delete(id); }
    hasPointerCapture(id) { return this.captures?.has(id) || false; }
    getBoundingClientRect() {
      const left = parseFloat(this.style.left) || 0, top = parseFloat(this.style.top) || 0;
      const width = parseFloat(this.style.width) || 0, height = parseFloat(this.style.height) || 0;
      return { left, top, x: left, y: top, width, height, right: left + width, bottom: top + height };
    }
  }
  const panel = new Element('dialog', ['pip']); panel.open = true;
  const surface = new Element('img', [], panel), window = new Element();
  const localStorage = { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) };
  const context = vm.createContext({ Element, window, localStorage, innerWidth: width, innerHeight: height,
    setTimeout: fn => { timers.set(++timerID, fn); return timerID; }, clearTimeout: id => timers.delete(id) });
  vm.runInContext(source, context);
  const pip = new context.ScreenPip(panel, () => changes++);
  pip.box = { x: 300, y: 220, w: 240, h: 135 }; pip.paint();
  function event(id, x, y, { target = surface, pointerType = 'touch', button = 0 } = {}) {
    return { pointerId: id, clientX: x, clientY: y, target, pointerType, button, cancelable: true,
      preventDefault() { this.defaultPrevented = true; }, stopPropagation() {} };
  }
  return { pip, panel, surface, window, context, values, changes: () => changes,
    snapshot: () => JSON.parse(JSON.stringify(pip.box)),
    down: (id, x, y, options) => panel.emit('pointerdown', event(id, x, y, options)),
    move: (id, x, y, options) => window.emit('pointermove', event(id, x, y, options)),
    up: (id, x, y, options) => window.emit('pointerup', event(id, x, y, options)),
    handle(edge) { const handle = new Element('div', ['screen-resize', edge], panel); handle.dataset.edge = edge; return handle; },
    button: () => new Element('button', [], panel), icon: parent => new Element('path', [], parent),
    flush() { const callbacks = [...timers.values()]; timers.clear(); callbacks.forEach(fn => fn()); } };
}

const near = (actual, expected, message) => assert.ok(Math.abs(actual - expected) < 1e-7, `${message}: ${actual} != ${expected}`);
const sameBox = (actual, expected, message) => { for (const key of ['x', 'y', 'w', 'h']) near(actual[key], expected[key], `${message} ${key}`); };
function beginPinch(h) { h.down(1, 360, 287.5); h.down(2, 480, 287.5); }
function expand(h) { beginPinch(h); h.move(1, 300, 287.5); h.move(2, 540, 287.5); }
let count = 0;
function check(name, run) { run(); count++; console.log(`ok ${count} - ${name}`); }

check('双指张开放大小窗，保持16:9和画面中点', () => {
  const h = setup(); expand(h);
  sameBox(h.pip.box, { x: 180, y: 152.5, w: 480, h: 270 }, '双指放大');
  near(parseFloat(h.panel.style.width), 480, '画面样式跟随放大');
});

check('双指合拢缩小，并跟随双指中点移动', () => {
  const h = setup(); expand(h); h.up(1, 300, 287.5); h.up(2, 540, 287.5); h.flush();
  h.down(3, 300, 287.5); h.down(4, 540, 287.5);
  h.move(3, 380, 297.5); h.move(4, 500, 297.5);
  sameBox(h.pip.box, { x: 320, y: 230, w: 240, h: 135 }, '双指缩小平移');
});

check('双指缩放保持非中心触点对应的画面位置', () => {
  const h = setup(); h.down(1, 320, 240); h.down(2, 380, 240);
  h.move(1, 290, 240); h.move(2, 410, 240);
  near(h.pip.box.w, 480, '非中心放大');
  near((350 - h.pip.box.x) / h.pip.box.w, 50 / 240, '横向触点锚定');
  near((240 - h.pip.box.y) / h.pip.box.h, 20 / 135, '纵向触点锚定');
});

check('缩到最小宽160，再放大仍可继续操作', () => {
  const h = setup(); beginPinch(h); h.move(1, 415, 287.5); h.move(2, 425, 287.5);
  near(h.pip.box.w, 160, '最小宽'); near(h.pip.box.h, 90, '最小高');
  h.up(1, 415, 287.5); h.up(2, 425, 287.5); h.flush();
  h.down(3, 390, 287.5); h.down(4, 450, 287.5); h.move(3, 360, 287.5); h.move(4, 480, 287.5);
  near(h.pip.box.w, 320, '最小尺寸可重新放大');
});

check('放大受手机视口约束且小窗仍在屏幕内', () => {
  const h = setup({ width: 390, height: 844 });
  h.pip.box = { x: 30, y: 100, w: 240, h: 135 }; h.pip.paint();
  h.down(1, 100, 160); h.down(2, 200, 160); h.move(1, -400, 160); h.move(2, 700, 160);
  near(h.pip.box.w, 374, '横向最大宽'); near(h.pip.box.h, 374 * 9 / 16, '等比高');
  assert.ok(h.pip.box.x >= 8 && h.pip.box.x + h.pip.box.w <= 382);
  assert.ok(h.pip.box.y >= 8 && h.pip.box.y + h.pip.box.h <= 836);
  const short = setup({ width: 1000, height: 200 });
  short.pip.box = { x: 30, y: 30, w: 200, h: 112.5 }; short.pip.paint();
  short.down(1, 100, 90); short.down(2, 200, 90); short.move(1, -400, 90); short.move(2, 700, 90);
  near(short.pip.box.h, 184, '纵向视口限制');
});

check('第三指不改变正在进行的双指手势', () => {
  const h = setup(); beginPinch(h); const before = h.snapshot();
  h.down(3, 700, 500); h.move(3, 900, 700); h.up(3, 900, 700);
  sameBox(h.pip.box, before, '第三指忽略');
  h.move(1, 300, 287.5); h.move(2, 540, 287.5); near(h.pip.box.w, 480, '双指继续放大');
});

check('松开一指没有位置跳变，剩余一指不意外缩放', () => {
  const h = setup(); expand(h); const before = h.snapshot();
  h.up(2, 540, 287.5); sameBox(h.pip.box, before, '松指');
  h.move(1, 300, 287.5); sameBox(h.pip.box, before, '剩余指原位');
  h.move(1, 320, 297.5); near(h.pip.box.w, before.w, '剩余指不缩放');
  h.up(1, 320, 297.5);
  assert.ok(Math.abs(h.pip.box.x - before.x) <= 20 + 1e-7, '不能套用缩放前单指坐标跳动');
  assert.ok(Math.abs(h.pip.box.y - before.y) <= 10 + 1e-7, '不能套用缩放前单指纵坐标跳动');
});

check('已单指拖动的小窗由第二指接管，保留眼前位置', () => {
  const h = setup(); h.down(1, 360, 287.5); h.move(1, 380, 302.5);
  h.down(2, 500, 302.5);
  sameBox(h.pip.box, { x: 320, y: 235, w: 240, h: 135 }, '第二指接管已有平移');
  assert.equal(h.panel.style.transform, '', '接管后只保留一份平移，不能叠加旧transform');
  h.move(1, 320, 302.5); h.move(2, 560, 302.5);
  sameBox(h.pip.box, { x: 200, y: 167.5, w: 480, h: 270 }, '接管后从当前位置放大');
});

check('松一指后重新加入第二指，从当前触点和当前小窗续接', () => {
  const h = setup(); expand(h); h.up(2, 540, 287.5);
  h.move(1, 340, 287.5); const before = h.snapshot();
  h.down(3, 460, 287.5); sameBox(h.pip.box, before, '重新加指不跳变');
  h.move(1, 310, 287.5); h.move(3, 490, 287.5);
  near(h.pip.box.w, before.w * 1.5, '续接按新的触点距离缩放');
  near((400 - h.pip.box.x) / h.pip.box.w, (400 - before.x) / before.w, '续接锚定当前中点');
});

check('松手的最后坐标参与单指、边柄和双指的最终几何', () => {
  const drag = setup(); drag.down(1, 360, 287.5); drag.move(1, 380, 302.5); drag.up(1, 390, 307.5);
  sameBox(drag.pip.box, { x: 330, y: 240, w: 240, h: 135 }, '单指松手最终位置');
  const resize = setup(), edge = { target: resize.handle('e') };
  resize.down(1, 540, 280, edge); resize.move(1, 560, 280, edge); resize.up(1, 580, 280, edge);
  near(resize.pip.box.w, 280, '边柄松手最终宽');
  const pinch = setup(); beginPinch(pinch); pinch.move(1, 300, 287.5); pinch.move(2, 540, 287.5);
  pinch.up(2, 570, 287.5);
  sameBox(pinch.pip.box, { x: 165, y: 135.625, w: 540, h: 303.75 }, '双指松手最终距离');
});

check('取消后迟到的移动和松指不再改变小窗', () => {
  const h = setup(); expand(h); h.window.emit('pointercancel', { pointerId: 2 }); const before = h.snapshot();
  h.move(1, 50, 100); h.move(2, 800, 700); h.up(1, 50, 100); h.up(2, 800, 700);
  sameBox(h.pip.box, before, '取消隔离'); h.flush();
  h.down(3, 400, 250); h.move(3, 420, 265); h.up(3, 420, 265);
  near(h.pip.box.x, before.x + 20, '取消后新手势仍可拖动');
});

check('按钮及其内部图标不启动拖动或双指手势', () => {
  for (const inside of [false, true]) {
    const h = setup(), button = h.button(), target = inside ? h.icon(button) : button;
    const before = h.snapshot();
    h.down(1, 360, 287.5, { target }); h.down(2, 480, 287.5, { target });
    h.move(1, 300, 287.5); h.move(2, 540, 287.5); h.up(1, 300, 287.5); h.up(2, 540, 287.5);
    sameBox(h.pip.box, before, '按钮不抢手势');
  }
});

check('鼠标单指拖动保持原行为，右键不拖动', () => {
  const h = setup(), options = { pointerType: 'mouse' };
  h.down(1, 360, 287.5, options); h.move(1, 380, 302.5, options); h.up(1, 380, 302.5, options);
  sameBox(h.pip.box, { x: 320, y: 235, w: 240, h: 135 }, '鼠标拖动'); h.flush();
  h.down(2, 360, 287.5, { pointerType: 'mouse', button: 2 }); h.move(2, 500, 400, options); h.up(2, 500, 400, options);
  sameBox(h.pip.box, { x: 320, y: 235, w: 240, h: 135 }, '右键忽略');
});

check('单指边柄保持等比缩放及固定对边', () => {
  for (const edge of ['e', 'w', 'n', 's', 'se', 'nw']) {
    const h = setup(), options = { target: h.handle(edge) }, before = h.snapshot();
    h.down(1, 400, 280, options); h.move(1, 424, 298, options); h.up(1, 424, 298, options);
    near(h.pip.box.h, h.pip.box.w * 9 / 16, `${edge} 等比`);
    assert.notEqual(h.pip.box.w, before.w, `${edge} 仍可缩放`);
    if (edge.includes('w')) near(h.pip.box.x + h.pip.box.w, before.x + before.w, `${edge} 右边固定`);
    else near(h.pip.box.x, before.x, `${edge} 左边固定`);
    if (edge.includes('n')) near(h.pip.box.y + h.pip.box.h, before.y + before.h, `${edge} 下边固定`);
    else near(h.pip.box.y, before.y, `${edge} 上边固定`);
  }
});

check('双指结束保存最终几何，新实例恢复同一小窗', () => {
  const h = setup(); expand(h); h.up(1, 300, 287.5); h.up(2, 540, 287.5);
  const saved = JSON.parse(h.values.get('voicedeck.pip'));
  sameBox(saved, h.pip.box, '保存最终小窗'); assert.ok(h.changes() > 0, '结束通知画面重新测量');
  const restored = setup({ saved });
  const panel = restored.panel;
  const pip = new restored.context.ScreenPip(panel, () => {}); pip.paint();
  sameBox(pip.box, saved, '重载恢复');
});

console.log(`screen-pip: ${count} behavior regressions passed`);
