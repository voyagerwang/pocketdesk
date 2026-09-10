/**
 * [INPUT]: 纯函数识别器，不依赖任何浏览器 API；样本为 { t(ms), beta, gamma, alpha, accel(m/s²) }。
 * [OUTPUT]: makeRecognizer(params) 返回 { push(sample), reset(reason), state() }，push 返回 { fired, phase, events }。
 * [POS]: 翻腕手势识别核心；仅对“前倾并停住片刻”发出候选，对震动/扭转/转屏/数据缺口一律拒绝。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 *
 * 手势定义（来自 WRIST_SEND_EXECUTION_PLAN）：手机上沿向远离自己的方向轻翻一下，停住片刻后发送。
 * 不自动提高灵敏度；阈值需真机标定，故全部可配。
 */
(function (global) {
  'use strict';

  // 默认阈值：保守、可经 setParams / 预设覆盖。单位：角度(°)、时间(ms)、加速度(m/s²)。
  var DEFAULT_PARAMS = {
    liftDeg: 22,        // 相对起点前倾超过此角度才算“抬起”
    liftRateMax: 130,   // °/s，超过视为猛甩 → 拒绝
    holdMinMs: 220,     // 抬起后保持的最短时间（达到即触发）
    holdMaxMs: 1600,    // 持续倾斜超过此值视为手持姿势而非动作 → 拒绝
    returnDeg: 16,      // 回到此范围内视为一次动作完成（仅用于复位参考，不强制才发）
    gammaMaxDeg: 35,    // 左右扭转上限，超过 → 拒绝
    gammaRateMax: 110,  // °/s
    alphaRateMax: 220,  // °/s 屏幕旋转 → 拒绝
    accelMax: 17,       // m/s² 平动/震动 → 拒绝（重力约 9.8）
    gapMaxMs: 220,      // 数据缺口 → 复位
    cooldownMs: 600,    // 触发后冷却，避免持续倾斜重复发
  };

  function makeRecognizer(params) {
    var p = Object.assign({}, DEFAULT_PARAMS, params || {});
    var baseline = null;     // 初始 beta
    var prevBeta = null, prevGamma = null, prevAlpha = null, prevT = null;
    var phase = 'idle';
    var liftStart = 0;
    var cooldownUntil = 0;
    var events = [];

    function reset(reason) {
      if (reason) events.push({ t: prevT || 0, type: 'reset', reason: reason });
      baseline = null; prevBeta = null; prevGamma = null; prevAlpha = null; prevT = null;
      phase = 'idle'; liftStart = 0;
    }

    function push(s) {
      var t = s.t;
      var out = { fired: false, phase: phase, events: [] };
      if (baseline === null) {
        baseline = s.beta; prevBeta = s.beta; prevGamma = s.gamma; prevAlpha = s.alpha; prevT = t;
        out.events = events.slice();
        return out;
      }
      var dt = t - prevT;
      if (dt <= 0) { prevT = t; out.events = events.slice(); return out; }
      if (dt > p.gapMaxMs) { reset('gap'); out.events = events.slice(); return out; }

      var dBeta = s.beta - baseline;
      var prevDBeta = prevBeta - baseline;
      var betaRate = Math.abs(dBeta - prevDBeta) / (dt / 1000);
      var gammaRate = Math.abs(s.gamma - prevGamma) / (dt / 1000);
      var alphaRate = Math.abs(s.alpha - prevAlpha) / (dt / 1000);

      // 拒绝：震动 / 平动
      if (s.accel > p.accelMax) { events.push({ t: t, type: 'reject', reason: 'accel' }); reset('accel'); out.events = events.slice(); return out; }
      // 拒绝：左右扭转
      if (Math.abs(s.gamma) > p.gammaMaxDeg || gammaRate > p.gammaRateMax) { events.push({ t: t, type: 'reject', reason: 'gamma' }); reset('gamma'); out.events = events.slice(); return out; }
      // 拒绝：屏幕旋转
      if (alphaRate > p.alphaRateMax) { events.push({ t: t, type: 'reject', reason: 'alpha' }); reset('alpha'); out.events = events.slice(); return out; }

      if (t < cooldownUntil) {
        prevBeta = s.beta; prevGamma = s.gamma; prevAlpha = s.alpha; prevT = t;
        out.events = events.slice();
        return out;
      }

      if (phase === 'idle') {
        if (dBeta > p.liftDeg && betaRate <= p.liftRateMax) {
          phase = 'lift'; liftStart = t;
        }
      } else if (phase === 'lift') {
        if (dBeta < p.liftDeg) {
          reset('short');                       // 抬一下又很快放下，不算动作
        } else if (t - liftStart >= p.holdMinMs) {
          out.fired = true;
          events.push({ t: t, type: 'fire' });
          cooldownUntil = t + p.cooldownMs;
          reset();                             // 复位等待下一次（自然回位后进入新基线）
          out.events = events.slice();
          out.phase = 'idle';
          return out;
        } else if (t - liftStart > p.holdMaxMs) {
          events.push({ t: t, type: 'reject', reason: 'hold-too-long' });
          reset('hold-too-long'); out.events = events.slice(); return out;
        }
      }

      prevBeta = s.beta; prevGamma = s.gamma; prevAlpha = s.alpha; prevT = t;
      out.phase = phase; out.events = events.slice();
      return out;
    }

    return {
      push: push,
      reset: reset,
      params: p,
      state: function () { return { phase: phase, baseline: baseline, cooldownUntil: cooldownUntil }; },
    };
  }

  var api = { makeRecognizer: makeRecognizer, DEFAULT_PARAMS: DEFAULT_PARAMS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.MotionRecognizer = api;
})(typeof window !== 'undefined' ? window : (typeof globalThis !== 'undefined' ? globalThis : this));
