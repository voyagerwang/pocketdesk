/**
 * 翻腕识别器纯函数测试：用合成传感器样本验证“正常翻腕触发、异常一律拒绝”。
 * 运行：node tests/motion-recognizer.test.cjs
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
  for (const s of samples) {
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
    ...ramp(0, 0, 300, 30, 30),        // 0→30° 抬起（速率 100°/s < 130）
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
    ...ramp(0, 0, 300, 30, 30),
    ...ramp(300, 30, 800, 30, 30, { gamma: 50 }), // 持续扭转
  ];
  const { fired, events } = run(samples);
  assert.strictEqual(fired, 0, '扭转场景不应触发');
  assert.ok(events.some(e => e.reason === 'gamma'), '应记录 gamma 拒绝');
});

test('屏幕旋转（alpha 剧变）→ 拒绝，不触发', () => {
  const samples = [
    ...ramp(0, 0, 300, 30, 30),
    ...ramp(300, 30, 800, 30, 30, { alpha: 300 }), // 每帧 +300° → 远超阈值
  ];
  const { fired } = run(samples);
  assert.strictEqual(fired, 0, '转屏场景不应触发');
});

test('短触（抬起后很快放下）→ 不触发', () => {
  const samples = [
    ...ramp(0, 0, 200, 30, 30),   // 200ms 内抬起
    ...ramp(200, 30, 260, 0, 30), // 60ms 后放下，未达 holdMin
  ];
  const { fired } = run(samples);
  assert.strictEqual(fired, 0, '短触不应触发');
});

test('静止无动作 → 不触发', () => {
  const samples = ramp(0, 0, 1000, 2, 30); // 几乎不动
  const { fired } = run(samples);
  assert.strictEqual(fired, 0, '静止不应触发');
});

test('默认参数合理（liftDeg>0, holdMinMs>0）', () => {
  assert.ok(DEFAULT_PARAMS.liftDeg > 0);
  assert.ok(DEFAULT_PARAMS.holdMinMs > 0);
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
  const low = run(samples, { liftDeg: 30, holdMinMs: 320 }).fired;
  const high = run(samples, { liftDeg: 15, holdMinMs: 160 }).fired;
  assert.ok(high >= 1 && low === 0, 'high 应触发而 low 不应（16° 低于 low 阈值）');
});

console.log('\n识别器测试通过 ' + passed + ' 项' + (process.exitCode ? '（有失败）' : ''));
