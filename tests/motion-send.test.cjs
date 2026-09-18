/**
 * [INPUT]: Node vm 与真实 motion-recognizer/motion-send，通过浏览器事件替身注入姿态。
 * [OUTPUT]: 验证输入静默只限制最终提交；开关、设置、组合输入、空草稿、提交和挂起中断不补发。
 * [POS]: tests 的体感到提交入口集成回归，不连接网络、不发桌面按键。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function surface() {
  const listeners = new Map();
  return {
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(fn);
    },
    removeEventListener(type, fn) { listeners.get(type)?.delete(fn); },
    dispatchEvent(event) { [...(listeners.get(event.type) || [])].forEach(fn => fn(event)); }
  };
}

async function fixture() {
  let sends = 0, t = 100;
  const state = { settings: false, draft: true, allowed: true, settled: true };
  const window = Object.assign(surface(), {
    isSecureContext: true, DeviceMotionEvent: function () {}, DeviceOrientationEvent: function () {},
    location: { protocol: 'https:' },
    pocketdeskMotionEnabled: () => true,
    pocketdeskSettingsOpen: () => state.settings,
    pocketdeskHasDraft: () => state.draft,
    pocketdeskCanMotionSend: ({ requireSettled = true } = {}) => state.allowed && (!requireSettled || state.settled),
    pocketdeskComposeSend: () => { sends++; }
  });
  const document = Object.assign(surface(), { readyState: 'loading', hidden: false });
  const context = vm.createContext({ window, document, console, setTimeout, clearTimeout, Date });
  for (const name of ['motion-recognizer.js', 'motion-send.js']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '../Web', name), 'utf8'), context);
  }
  function sample(beta) {
    t += 20;
    window.dispatchEvent({ type: 'devicemotion', timeStamp: t, accelerationIncludingGravity: { x: 0, y: 0, z: 9.8 } });
    window.dispatchEvent({ type: 'deviceorientation', timeStamp: t, beta, gamma: 0, alpha: 0 });
  }
  function hold(beta, ms = 500) { for (let i = 0; i < ms / 20; i++) sample(beta); }
  function tilt(from = 0, to = 30) { for (let i = 1; i <= 10; i++) sample(from + (to - from) * i / 10); }
  const enabled = window.pocketdeskMotion.enable();
  await Promise.resolve();
  sample(0); sample(0);
  assert.equal((await enabled).ok, true);
  return { window, document, state, sample, hold, tilt, sends: () => sends };
}

// 直接执行生产 compose 的门禁，避免替身把接口接错也测成通过。
const composeSource = fs.readFileSync(path.join(__dirname, '../Web/compose.js'), 'utf8');
const gateSource = composeSource.slice(composeSource.indexOf('window.pocketdeskCanMotionSend ='), composeSource.indexOf('\nfunction clearCompose'));
const gateWindow = { pocketdeskInputSettled: () => false };
const gateContext = vm.createContext({ window: gateWindow, selected: 'app', SPRITE_ID: 'sprite',
  sendEl: { disabled: false }, submittingDraft: false, liveComposing: false, livePaused: false, liveProbing: false });
vm.runInContext(gateSource, gateContext);
assert.equal(gateWindow.pocketdeskCanMotionSend(), false);
assert.equal(gateWindow.pocketdeskCanMotionSend({ requireSettled: false }), true);
gateContext.liveComposing = true;
assert.equal(gateWindow.pocketdeskCanMotionSend({ requireSettled: false }), false);
gateContext.liveComposing = false; gateContext.livePaused = true;
assert.equal(gateWindow.pocketdeskCanMotionSend({ requireSettled: false }), false);

(async () => {
  const normal = await fixture();
  normal.hold(0); normal.tilt();
  assert.equal(normal.sends(), 1, '前翻过程中就经过统一发送入口，不等待停稳');
  normal.hold(30, 1200); normal.tilt(30, 60); normal.hold(60);
  assert.equal(normal.sends(), 1, '保持倾斜不能再提交');

  for (const key of ['settings', 'draft', 'allowed']) {
    const f = await fixture();
    f.hold(0); f.tilt(0, 12);
    f.state[key] = key === 'settings';
    f.hold(30, 100);
    f.state[key] = key !== 'settings';
    f.hold(30, 1500);
    assert.equal(f.sends(), 0, key + ' 打断的候选不随门禁恢复补发');
    f.tilt(30, 0); f.hold(0); f.tilt(0, 12); f.hold(30);
    assert.equal(f.sends(), 1, key + ' 恢复后新动作仍可发送');
  }

  const immediate = await fixture();
  immediate.state.settled = false;
  immediate.hold(0); immediate.tilt(0, 12);
  assert.equal(immediate.sends(), 0, '300ms 静默前不提交');
  immediate.state.settled = true;
  immediate.tilt(12, 40);
  assert.equal(immediate.sends(), 1, '起翻不等待输入静默，达标时已静默即提交');

  const late = await fixture();
  late.state.settled = false;
  late.hold(0); late.tilt(); late.hold(30);
  assert.equal(late.sends(), 0, '动作完成时输入仍未稳定，不提交');
  late.state.settled = true; late.hold(30, 1500);
  assert.equal(late.sends(), 0, '被丢弃候选不能随输入静默补发');

  for (const action of ['disable', 'suspend']) {
    const f = await fixture();
    f.hold(0); f.tilt(0, 12);
    f.window.pocketdeskMotion[action]();
    f.hold(30, 1000);
    assert.equal(f.sends(), 0, action + ' 后不能发旧候选');
  }
  console.log('motion send: 完整动作 / 不重复 / 设置与输入门禁 / 恢复新动作 / 关闭挂起通过');
})().catch(error => { console.error(error); process.exitCode = 1; });
