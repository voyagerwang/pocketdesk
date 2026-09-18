/**
 * [INPUT]: 依赖 Node assert 与 motion-recognizer 纯函数，输入合成姿态时间序列。
 * [OUTPUT]: 验证限时前翻达幅度即触发，不依赖停稳或回弹，冷却回位后复用；覆盖多采样率噪声、漂移、快翻和异常数据拒绝。
 * [POS]: tests 的识别器回归，无浏览器和桌面发送副作用。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('assert');
const { makeRecognizer, DEFAULT_PARAMS, isUsableSample } = require('../Web/motion-recognizer.js');

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log('  ✓ ' + name); }
  catch (e) { console.error('  ✗ ' + name + '\n    ' + e.message); process.exitCode = 1; }
}

// 把一系列绝对样本喂给识别器，返回 { fired, events }
function run(samples, params) {
  const r = makeRecognizer(params);
  const out = { fired: 0, events: [] };
  // 先持稳手机，再开始本次动作。
  const first = samples[0];
  const prepared = ramp(first.t - 240, first.beta, first.t - 30, first.beta, 30, first);
  for (const s of [...prepared, ...samples]) {
    const res = r.push(s);
    if (res.fired) out.fired++;
    if (res.events.length) out.events.push(...res.events);
  }
  return out;
}

// 生成线性插值样本：从 (t0,beta0) 到 (t1,beta1)，每 step ms 一帧，其余维度恒定。
function ramp(t0, beta0, t1, beta1, step, extra = {}) {
  const out = [];
  for (let t = t0; t <= t1; t += step) {
    const k = (t - t0) / (t1 - t0 || 1);
    out.push({ t, beta: beta0 + (beta1 - beta0) * k, gamma: extra.gamma || 0, alpha: extra.alpha || 0, accel: extra.accel || 9.8 });
  }
  return out;
}

test('正常翻腕：前倾并保持 → 触发一次', () => {
  const samples = [
    ...ramp(0, 0, 300, 30, 30),        // 0→30° 前翻
    ...ramp(300, 30, 800, 30, 30),     // 保持 30°
    ...ramp(800, 30, 1000, 0, 30),     // 回位
  ];
  const { fired } = run(samples);
  assert.ok(fired >= 1, '应当至少触发一次，实际 ' + fired);
});

test('剧烈震动（加速度尖峰）→ 拒绝，不触发', () => {
  const samples = [];
  for (let t = 0; t <= 800; t += 30) {
    const beta = t < 300 ? (t / 300) * 30 : 30;
    const accel = (t % 90 === 0) ? 20 : 9.8; // 周期性猛抖
    samples.push({ t, beta, gamma: 0, alpha: 0, accel });
  }
  const { fired, events } = run(samples);
  assert.strictEqual(fired, 0, '震动场景不应触发');
  assert.ok(events.some(e => e.reason === 'accel'), '应记录 accel 拒绝');
});

test('左右扭转（gamma 过大）→ 拒绝，不触发', () => {
  const samples = [
    ...ramp(0, 0, 120, 12, 30),
    ...ramp(150, 15, 800, 30, 30, { gamma: 50 }), // 持续扭转
  ];
  const { fired, events } = run(samples);
  assert.strictEqual(fired, 0, '扭转场景不应触发');
  assert.ok(events.some(e => e.reason === 'gamma'), '应记录 gamma 拒绝');
});

test('屏幕旋转（alpha 剧变）→ 拒绝，不触发', () => {
  const samples = [
    ...ramp(0, 0, 120, 12, 30),
    ...ramp(150, 15, 800, 30, 30, { alpha: 300 }), // 每帧 +300° → 远超阈值
  ];
  const { fired } = run(samples);
  assert.strictEqual(fired, 0, '转屏场景不应触发');
});

test('快速前翻达标后立刻回位也应触发', () => {
  const samples = [
    ...ramp(0, 0, 200, 30, 30),   // 200ms 内抬起
    ...ramp(200, 30, 260, 0, 30), // 60ms 后放下，仍然是有效前翻
  ];
  const { fired } = run(samples);
  assert.strictEqual(fired, 1, '达标前翻不要求悬停');
});

test('静止无动作 → 不触发', () => {
  const samples = ramp(0, 0, 1000, 2, 30); // 几乎不动
  const { fired } = run(samples);
  assert.strictEqual(fired, 0, '静止不应触发');
});

test('默认角度有效且不再有停稳时间参数', () => {
  assert.ok(DEFAULT_PARAMS.liftDeg > 0);
  assert.equal(DEFAULT_PARAMS.holdMinMs, undefined);
  assert.ok(DEFAULT_PARAMS.accelMax > 9.8); // 必须高于重力，否则静止就拒
});

// 免证书方案的数据层门禁：能不能用翻腕，取决于"传感器真的在出数"，而不是"接口存在"。
test('有效样本：静止的合法零值必须算通过', () => {
  assert.strictEqual(isUsableSample({ beta: 0, gamma: 0, alpha: 0, accel: 9.8 }), true,
    '手机平放桌面时零值是正常读数，不能判成没数据');
  assert.strictEqual(isUsableSample({ beta: null, gamma: null, alpha: null, accel: 0 }), true,
    '只有加速度轴出数也应算有效');
});

test('无效样本：null / NaN / 空对象一律不算出数', () => {
  assert.strictEqual(isUsableSample({ beta: null, gamma: null, alpha: null, accel: null }), false,
    '全轴为 null 说明设备没给传感器数据');
  assert.strictEqual(isUsableSample({ beta: NaN, gamma: NaN, alpha: NaN, accel: NaN }), false,
    'NaN 不是有效读数，全轴为 NaN 应判无效');
  assert.strictEqual(isUsableSample({}), false, '空样本无效');
  assert.strictEqual(isUsableSample(null), false, 'null 样本无效');
});

test('灵敏度预设 high 比 low 更易触发（同一样本）', () => {
  const samples = [...ramp(0, 0, 300, 16, 30), ...ramp(300, 16, 800, 16, 30)];
  const low = run(samples, { liftDeg: 30 }).fired;
  const high = run(samples, { liftDeg: 15 }).fired;
  assert.ok(high >= 1 && low === 0, 'high 应触发而 low 不应（16° 低于 low 阈值）');
});

test('慢慢换握姿不累计成发送角度', () => {
  assert.equal(run(ramp(0, 0, 6000, 60, 20)).fired, 0);
});

test('快速翻腕后停稳仍触发一次', () => {
  assert.equal(run([...ramp(0, 0, 100, 30, 20), ...ramp(100, 30, 600, 30, 20)]).fired, 1);
});

test('前翻过程中达角度立即触发，不等待动作停止', () => {
  assert.equal(run(ramp(0, 0, 300, 30, 20)).fired, 1);
});

test('未达前翻幅度的小幅来回抖动不能发送', () => {
  const samples = ramp(0, 0, 100, 3, 20);
  for (let t = 120; t <= 1500; t += 20) samples.push({ t, beta: t % 40 ? 0 : 6, gamma: 0, alpha: 0, accel: 9.8 });
  assert.equal(run(samples).fired, 0);
});

test('冷却结束仍保持前倾、继续前倾均不重复发送', () => {
  assert.equal(run([
    ...ramp(0, 0, 300, 30, 20), ...ramp(300, 30, 1400, 30, 20),
    ...ramp(1400, 30, 1700, 60, 20), ...ramp(1700, 60, 2200, 60, 20),
  ]).fired, 1);
});

test('回位持稳后可以连续发第二次', () => {
  assert.equal(run([
    ...ramp(0, 0, 300, 30, 20), ...ramp(300, 30, 1200, 30, 20),
    ...ramp(1200, 30, 1400, 0, 20), ...ramp(1400, 0, 1700, 0, 20),
    ...ramp(1700, 0, 1900, 30, 20), ...ramp(1900, 30, 2500, 30, 20),
  ]).fired, 2);
});

test('启动期间的移动不会成为一次甩送', () => {
  const r = makeRecognizer();
  const samples = [...ramp(0, 0, 300, 30, 20), ...ramp(300, 30, 1000, 30, 20)];
  assert.equal(samples.filter(s => r.push(s).fired).length, 0);
});

test('朝向跨 359/0 度不误判为转屏', () => {
  const samples = [...ramp(0, 0, 300, 30, 20), ...ramp(300, 30, 1000, 30, 20)];
  samples.forEach(s => { s.alpha = s.t < 160 ? 359 : 0; });
  assert.equal(run(samples).fired, 1);
});

test('无效姿态、数据断流作废动作，恢复静止不补发', () => {
  for (const patch of [{ beta: null }, { beta: NaN }, { gamma: null }, { alpha: undefined }, { accel: NaN }, { t: 700 }]) {
    const samples = [...ramp(0, 0, 120, 12, 20), { t: 140, beta: 14, gamma: 0, alpha: 0, accel: 9.8, ...patch }, ...ramp(720, 30, 1500, 30, 20)];
    assert.equal(run(samples).fired, 0);
  }
});

test('前翻未达幅度即超时，之后停止不补发', () => {
  const samples = [...ramp(0, 0, 100, 10, 20), ...ramp(100, 10, 2100, 18, 20), ...ramp(2100, 18, 2800, 18, 20)];
  assert.equal(run(samples).fired, 0);
  assert.ok(run(samples).events.some(e => e.reason === 'lift-too-long'));
});

test('长时间监听不重复返回旧事件', () => {
  const r = makeRecognizer();
  assert.equal(r.push({ t: 0, beta: null }).events.length, 1);
  for (const s of ramp(20, 0, 2000, 0, 20)) assert.equal(r.push(s).events.length, 0);
});

test('30/60/100Hz 含细小读数抖动仍可武装并正常翻腕', () => {
  for (const step of [10, 1000 / 60, 1000 / 30]) {
    const r = makeRecognizer();
    let fired = 0;
    for (let i = 0; i * step < 1800; i++) {
      const t = i * step;
      const beta = t < 500 ? 0 : t < 700 ? (t - 500) * .15 : 30;
      if (r.push({ t, beta: beta + (i % 2 ? .3 : -.3), gamma: 0, alpha: 0, accel: 9.8 }).fired) fired++;
    }
    assert.equal(fired, 1, '采样间隔 ' + step);
  }
});

test('只有细小噪声而没有翻腕不会发送', () => {
  const r = makeRecognizer();
  for (let t = 0; t <= 6000; t += 10) {
    assert.equal(r.push({ t, beta: t % 20 ? .3 : -.3, gamma: 0, alpha: 0, accel: 9.8 }).fired, false);
  }
});

test('前翻达标后自然回弹到阈值以下仍发送一次', () => {
  for (const step of [10, 20, 30]) {
    for (const liftDeg of [15, 22, 30]) {
      const peak = liftDeg + 10, rest = liftDeg - 8;
      assert.equal(run([
        ...ramp(0, 0, 240, peak, step),
        ...ramp(240, peak, 420, rest, step),
        ...ramp(420, rest, 1200, rest, step),
      ], { liftDeg }).fired, 1);
    }
  }
});

test('完整前翻后回到原握姿可发送，不要求悬停在前倾角度', () => {
  assert.equal(run([
    ...ramp(0, 0, 240, 34, 20), ...ramp(240, 34, 440, 0, 20),
    ...ramp(440, 0, 1800, 0, 20),
  ]).fired, 1);
});

test('未达到幅度的前翻回弹不能发送', () => {
  assert.equal(run([
    ...ramp(0, 0, 240, 12, 20), ...ramp(240, 12, 440, 0, 20),
    ...ramp(440, 0, 1800, 0, 20),
  ]).fired, 0);
});

console.log('\n识别器测试通过 ' + passed + ' 项' + (process.exitCode ? '（有失败）' : ''));
