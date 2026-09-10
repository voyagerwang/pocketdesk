/**
 * [INPUT]: 依赖 Node 内建断言与 Web 的纯几何、手势、输入队列模块。
 * [OUTPUT]: 验证坐标往返、手势取消与失控、帧率无关惯性、提交隔离；前次失败回执晚到仍保留同草稿删除，跨草稿不恢复。
 * [POS]: tests 的无桌面副作用回归入口；不发送网络请求或系统事件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
require('../Web/screen-geometry.js');
require('../Web/screen-gestures.js');
require('../Web/compose-queue.js');
const g = new ScreenGeometry();
g.measure({ left: 20, top: 50, width: 390, height: 700 }, 1920, 1080, { width: 1920, height: 1080 });
assert.equal(g.ratio(30, 55), null);
for (const scale of [1, 2, 4, 6]) {
  g.zoom = { scale, x: -135, y: -210 }; g.clamp();
  for (const rx of [0, .123, .5, .99, 1]) for (const ry of [0, .2, .8, 1]) {
    const p = g.project(rx, ry), result = g.ratio(p.x + g.view.left, p.y + g.view.top, true);
    assert.ok(Math.abs(result.rx - rx) < 1e-9 && Math.abs(result.ry - ry) < 1e-9);
  }
}
// 自动横屏：旋转后的正反坐标与指针增量仍一致。
g.measure({ left: 20, top: 50, width: 390, height: 700 }, 1920, 1080, {}, true);
for (const scale of [1, 3, 6]) {
  g.zoom = { scale, x: -100, y: -80 }; g.clamp();
  for (const rx of [0, .25, .9, 1]) for (const ry of [0, .3, 1]) {
    const p = g.project(rx, ry), client = g.client(p.x, p.y);
    const result = g.ratio(client.x, client.y, true);
    assert.ok(Math.abs(result.rx-rx)<1e-9 && Math.abs(result.ry-ry)<1e-9);
  }
}
assert.deepEqual(g.vector(10, 20), { x: 20, y: -10 });
g.measure({ left: 20, top: 50, width: 390, height: 700 }, 1920, 1080);
g.reset();
const commands = [];
const element = { addEventListener() {}, setPointerCapture() {}, releasePointerCapture() {} };
const gestures = new ScreenGestures(element, { active: () => true, ready: () => true, geometry: g,
  display: () => 1, send: m => commands.push(m), feedback() {}, interact() {}, sensitivity: () => 1, paint() {}, context() {} });
const event = (id, x=215, y=400) => ({ pointerId: id, clientX: x, clientY: y, button: 0, preventDefault() {} });
gestures.down(event(1)); gestures.cancel(); gestures.up(event(1));
assert.equal(commands.length, 0, '取消轻点不能产生点击');
gestures.arm({ rx: .5, ry: .5 }); gestures.down(event(1)); gestures.move(event(1, 230, 410)); gestures.cancel();
assert.deepEqual(commands.map(m => m.action || m.t), ['down', 'drag', 'up']);
commands.length = 0;
gestures.arm({ rx: .5, ry: .5 }); gestures.down(event(1)); gestures.down(event(2, 250, 430)); gestures.up(event(2)); gestures.up(event(1));
assert.equal(commands.filter(m => m.t === 'up').length, 1, '第二指加入必须松开拖动');
assert.ok(!commands.some(m => m.action === 'click'), '双指结束不能补单击');
gestures.cancel();
// 独立滚动：手机竖向手势始终滚动远端纵向，不因画面旋转变成横向滚动。
for (const rotated of [false, true]) {
  g.measure({ left: 0, top: 0, width: 390, height: 700 }, 1920, 1080, {}, rotated);
  g.reset(); gestures.setMode('scroll'); commands.length = 0;
  gestures.down(event(1, 195, 350)); gestures.move(event(1, 195, 310)); gestures.up(event(1, 195, 310));
  assert.equal(commands[0].action, 'move');
  assert.equal(commands[0].display, 1);
  assert.deepEqual(commands.find(m => m.t === 'scroll'), { t: 'scroll', dx: 0, dy: -40 });
  assert.equal(commands.at(-1).t, 'scrollEnd');
  assert.ok(!commands.some(m => m.action === 'click'));
}
commands.length = 0;
gestures.wheel({clientX:195,clientY:350,deltaX:0,deltaY:80,deltaMode:0,preventDefault(){}});
gestures.cancel();
assert.deepEqual(commands.map(m => m.action || m.t), ['move', 'scroll', 'scrollEnd']);
assert.equal(commands[1].dy, -80);
// 惯性按时间积分，60/120Hz 的距离一致；按下、取消和失控必须停止。
let nextFrame = 0; const animationFrames = new Map();
globalThis.requestAnimationFrame = callback => { animationFrames.set(++nextFrame, callback); return nextFrame; };
globalThis.cancelAnimationFrame = id => animationFrames.delete(id);
function fling(stepMs) {
  gestures.cancel(); commands.length = 0;
  gestures.flingAllowed = true; gestures.scrollAt = 1000; gestures.scrollVelocity = { x: 0, y: -1 };
  gestures.finishScroll(1000);
  for (let t = 1000 + stepMs; animationFrames.size; t += stepMs) {
    const callbacks = [...animationFrames.values()]; animationFrames.clear(); callbacks.forEach(fn => fn(t));
  }
  assert.equal(commands.at(-1).t, 'scrollEnd');
  return commands.filter(m => m.t === 'scroll').reduce((sum,m) => sum + m.dy, 0);
}
const distance60 = fling(1000/60), distance120 = fling(1000/120);
assert.ok(Math.abs(distance60-distance120) < 1, '惯性不能随屏幕刷新率变快或变慢');
assert.ok(distance60 < -200 && distance60 > -230);
gestures.scrollAt = 1000; gestures.scrollVelocity = {x:0,y:-1}; gestures.finishScroll(1000);
gestures.cancel(); assert.equal(animationFrames.size, 0); assert.equal(commands.at(-1).t, 'scrollEnd');
commands.length = 0;
gestures.scrollAt = 1000; gestures.scrollVelocity = {x:0,y:-1}; gestures.finishScroll(1150);
assert.equal(animationFrames.size,0, '停住手指再松开不应甩动');
assert.equal(commands.at(-1).t,'scrollEnd');
(async () => {
  // 放大瞄准只在松手且仍可控制时点击；取消和第二指接管均不得补单击。
  gestures.setMode('touch');
  let aim = null, ready = true;
  gestures.o.aim = point => { aim = point; };
  gestures.o.ready = () => ready;
  for (const ending of ['release', 'cancel', 'lost-control', 'second-finger']) {
    commands.length = 0; ready = true;
    gestures.down(event(1, 195, 350));
    await new Promise(resolve => setTimeout(resolve, 470));
    assert.ok(aim, '按住应显示瞄准镜');
    assert.equal(commands.length, 0, '瞄准中不能提前落键');
    if (ending === 'cancel') gestures.cancel();
    if (ending === 'lost-control') ready = false;
    if (ending === 'second-finger') {
      gestures.down(event(2, 215, 360)); gestures.up(event(2, 215, 360));
    }
    gestures.up(event(1, 195, 350));
    assert.equal(commands.filter(m => m.action === 'click').length, ending === 'release' ? 1 : 0);
    assert.equal(aim, null);
    gestures.cancel();
  }
  let release; const calls = [];
  const queue = new ComposeQueue(async v => { calls.push(v); return new Promise(resolve => { release = resolve; }); });
  const draft = queue.push({text:'a',targetId:'one'});
  const skipped = queue.push({text:'ab',targetId:'one'});
  const newest = queue.push({text:'abc',targetId:'one'});
  let submitted = false;
  const submit = queue.push({text:'abc',targetId:'one',submit:true}).then(() => { submitted = true; });
  release('draft'); await draft; await Promise.resolve();
  assert.equal(calls[1].text, 'abc'); assert.equal(submitted, false);
  release('latest'); await newest; await skipped; await Promise.resolve();
  assert.equal(calls[2].submit, true); assert.equal(submitted, false);
  release('submitted'); await submit; assert.equal(submitted, true);
  const failure = new ComposeQueue(async () => { throw new Error('disconnected'); });
  const results = await Promise.allSettled([failure.push({text:'x'}),failure.push({text:'x',submit:true})]);
  assert.ok(results.every(r => r.status === 'rejected'));
  const separated = [], context = Promise.resolve({context:'other'});
  let unblock;
  const isolated = new ComposeQueue(async v => {
    separated.push(v.text);
    if (v.text === 'in-flight') await new Promise(resolve => { unblock = resolve; });
  });
  const pending = [
    isolated.push({text:'in-flight', draftId:'one', targetId:'same'}),
    isolated.push({text:'old draft', draftId:'one', targetId:'same'}),
    isolated.push({text:'new draft', draftId:'two', targetId:'same'}),
    isolated.push({text:'new context', draftId:'two', targetId:'same', contextPromise:context}),
  ];
  unblock(); await Promise.all(pending);
  assert.deepEqual(separated, ['in-flight', 'old draft', 'new draft', 'new context']);
  // 删除先排队、失败回执后到：不能把用户的删除一起丢掉，也不能跨草稿核验。
  for (const sameDraft of [true, false]) {
    let failWrite; const sent = [];
    const deleting = new ComposeQueue(async value => {
      sent.push({...value});
      if (sent.length === 1) await new Promise((_, reject) => { failWrite = reject; });
    });
    const firstWrite = deleting.push({text:'已落入但读回超时',draftId:'a',targetId:'one'});
    const clearWrite = deleting.push({text:'',draftId:sameDraft?'a':'b',targetId:'one',reconcileOnFailure:true});
    const settled = Promise.allSettled([firstWrite, clearWrite]);
    failWrite(new Error('readback delayed'));
    const results = await settled;
    assert.equal(results[0].status, 'rejected');
    assert.equal(results[1].status, sameDraft ? 'fulfilled' : 'rejected');
    assert.equal(sent.length, sameDraft ? 2 : 1);
    if (sameDraft) assert.equal(sent[1].retry, true);
  }
  console.log('screen core: geometry, cancellation, two-finger takeover, queue completion passed');
})();
