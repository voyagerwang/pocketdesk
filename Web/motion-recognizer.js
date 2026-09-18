/**
 * [INPUT]: 纯函数识别器，不依赖任何浏览器 API；样本为 { t(ms), beta, gamma, alpha, accel(m/s²) }。
 * [OUTPUT]: makeRecognizer(params) 返回 { push(sample), reset(reason), state() }，push 返回 { fired, phase, events }；
 *           isUsableSample(sample) 判定传感器是否真的在出数（供免证书方案的“数据层”门禁使用）。
 * [POS]: 甩送手势识别核心；按横竖屏映射前翻轴，侧向限制相对握姿；支持姿态前翻或短促整体加速度脉冲。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 *
 * 手势定义（来自 WRIST_SEND_EXECUTION_PLAN）：手机上沿向远离自己的方向前翻，达到角度立即发送，不要求停稳或回弹。
 * 不自动提高灵敏度；阈值需真机标定，故全部可配。
 */
(function (global) {
  'use strict';

  // 默认阈值：保守、可经 setParams / 预设覆盖。单位：角度(°)、时间(ms)、加速度(m/s²)。
  var DEFAULT_PARAMS = {
    liftDeg: 22,        // 相对起点前倾超过此角度才算“抬起”
    liftRateMax: 720,   // °/s，拒绝姿态跳变，允许正常快速翻腕
    liftRateMin: 35,    // °/s，慢慢换握姿不启动动作
    liftMaxMs: 650,     // 起翻后必须在此窗口内达到角度
    armMs: 180,        // 新基线需连续稳定后才可识别
    filterMs: 40,      // 姿态低通时间常数，抑制采样噪声，不使用固定帧数
    settleDeg: 3,      // 起始握姿基线的噪声容差，不用于发送后的姿态判定
    returnDeg: 8,       // 回到起点附近，才能识别下一次动作
    gammaMaxDeg: 35,    // 相对握姿的侧向变化上限，不限制起始侧倾
    gammaRateMax: 110,  // °/s
    alphaRateMax: 220,  // °/s 屏幕旋转 → 拒绝
    accelMax: 17,       // m/s² 平动/震动 → 拒绝（重力约 9.8）
    gapMaxMs: 220,      // 数据缺口 → 复位
    cooldownMs: 600,    // 触发后冷却，避免持续倾斜重复发
    impulseMin: 2.8,    // 相对重力的短促加速度增量，支持手机整体向前甩
    impulsePeak: 4.2,   // 没有明显角度变化时需要更强的峰值，减少走路误触
    impulseMaxMs: 280,   // 甩送脉冲最长窗口
  };

  // 有效样本判定：motion-send 用它证明"传感器真的在出数"，而不是"接口存在"。
  // 三个要点，少一个就会把能用的手机判成不能用：
  //   1) null / undefined / NaN 是没数据（无陀螺仪的安卓 WebView 会全轴给 null）；
  //   2) 0 是**合法读数**——手机平放桌面时 rotationRate 与相对倾角就是 0，静止不能算失败；
  //   3) 只要求任一轴有效：设备可能只提供 devicemotion 或只提供 deviceorientation。
  function isUsableSample(sample) {
    if (!sample || typeof sample !== 'object') return false;
    var axes = ['beta', 'gamma', 'alpha', 'accel'];
    for (var i = 0; i < axes.length; i++) {
      var value = sample[axes[i]];
      if (typeof value === 'number' && isFinite(value)) return true;
    }
    return false;
  }

  function makeRecognizer(params) {
    var p = Object.assign({}, DEFAULT_PARAMS, params || {});
    var baseline = null;
    var prev = null;
    var phase = 'arming';
    var liftStart = 0, armStart = null, anchor = null;
    var cooldownUntil = 0;
    var events = [];
    var sideBaseline = null;
    var screenAngle = null;
    var accelBaseline = 9.8;
    var impulseStart = null;
    var impulsePeak = 0;

    function delta(a, b) { return ((a - b + 540) % 360) - 180; }
    function valid(s) {
      return s && ['t', 'beta', 'gamma', 'alpha', 'accel'].every(function (key) {
        return typeof s[key] === 'number' && isFinite(s[key]);
      });
    }
    function reset(reason) {
      if (reason) events.push({ t: prev ? prev.t : 0, type: 'reset', reason: reason });
      baseline = null; prev = null; anchor = null; armStart = null;
      sideBaseline = null; screenAngle = null; accelBaseline = 9.8;
      impulseStart = null; impulsePeak = 0;
      phase = 'arming'; liftStart = 0;
    }
    function result(fired) {
      var out = { fired: !!fired, phase: phase, events: events };
      events = []; // 每帧只返回新事件，长时间监听不会累积历史。
      return out;
    }
    function reject(reason, t) {
      events.push({ t: t, type: 'reject', reason: reason });
      reset();
      return result(false);
    }
    // 只在建立起始握姿时检查噪声窗口；前翻启动后不再检查停稳。
    function stable(s) {
      if (!anchor ||
          Math.abs(delta(s.beta, anchor.beta)) > p.settleDeg ||
          Math.abs(delta(s.gamma, anchor.gamma)) > p.settleDeg ||
          Math.abs(delta(s.alpha, anchor.alpha)) > p.settleDeg) {
        anchor = s; armStart = s.t;
        return false;
      }
      return true;
    }

    function push(s) {
      if (!valid(s)) return reject('invalid', s && s.t);
      // Landscape forward tilt lies on gamma; preserve the portrait beta direction.
      var angle = typeof s.screenAngle === 'number' ? s.screenAngle : 0;
      angle = ((angle % 360) + 360) % 360;
      if (screenAngle !== null && angle !== screenAngle) return reject('screen', s.t);
      screenAngle = angle;
      if (angle === 90 || angle === 270) {
        s = Object.assign({}, s, { beta: (angle === 90 ? -1 : 1) * s.gamma, gamma: s.beta });
      } else if (angle === 180) {
        s = Object.assign({}, s, { beta: -s.beta, gamma: -s.gamma });
      }
      var raw = s;
      var t = s.t;
      if (prev && t <= prev.t) return result(false); // 重复/乱序不回拨时钟。
      if (prev && t - prev.t > p.gapMaxMs) return reject('gap', t);
      if (s.accel > p.accelMax) return reject('accel', t);
      if (sideBaseline !== null && Math.abs(delta(s.gamma, sideBaseline)) > p.gammaMaxDeg) return reject('gamma', t);
      if (!prev) {
        prev = s; baseline = s.beta; sideBaseline = s.gamma; accelBaseline = s.accel; anchor = s; armStart = t;
        return result(false);
      }
      var dt = (t - prev.t) / 1000;
      // 差分会把细小传感器噪声放大成高速运动，先按真实采样间隔低通。
      var weight = 1 - Math.exp(-(t - prev.t) / p.filterMs);
      s = Object.assign({}, s, {
        beta: prev.beta + delta(s.beta, prev.beta) * weight,
        gamma: prev.gamma + delta(s.gamma, prev.gamma) * weight,
        alpha: prev.alpha + delta(s.alpha, prev.alpha) * weight,
      });
      var signedRate = delta(s.beta, prev.beta) / dt;
      var betaRate = Math.abs(signedRate);
      var gammaRate = Math.abs(delta(s.gamma, prev.gamma)) / dt;
      var alphaRate = Math.abs(delta(s.alpha, prev.alpha)) / dt;
      var previous = prev;
      prev = s;
      if (gammaRate > p.gammaRateMax) return reject('gamma', t);
      if (alphaRate > p.alphaRateMax) return reject('alpha', t);
      if (betaRate > p.liftRateMax) return reject('beta', t);

      if (phase === 'arming') {
        baseline = s.beta;
        sideBaseline = s.gamma;
        accelBaseline = accelBaseline * 0.9 + s.accel * 0.1;
        if (stable(raw) && t >= cooldownUntil && t - armStart >= p.armMs) {
          phase = 'idle'; anchor = null; armStart = null;
        }
        return result(false);
      }
      var dBeta = delta(s.beta, baseline);
      if (phase === 'release') {
        // 保留本次起点，持续倾斜/继续向前不能通过冷却后重复发送。
        if (t >= cooldownUntil && Math.abs(dBeta) <= p.returnDeg) reset('returned');
        return result(false);
      }
      if (phase === 'idle') {
        var impulse = s.accel - accelBaseline;
        if (impulse >= p.impulseMin) {
          if (impulseStart === null) { impulseStart = t; impulsePeak = impulse; }
          impulsePeak = Math.max(impulsePeak, impulse);
          if (t - impulseStart <= p.impulseMaxMs &&
              (dBeta >= p.liftDeg * 0.3 || impulsePeak >= p.impulsePeak)) {
            events.push({ t: t, type: 'fire', mode: 'impulse' });
            cooldownUntil = t + p.cooldownMs;
            phase = 'release';
            return result(true);
          }
          if (t - impulseStart > p.impulseMaxMs) { impulseStart = null; impulsePeak = 0; }
        } else if (impulseStart !== null) {
          impulseStart = null; impulsePeak = 0;
        }
        if (signedRate < p.liftRateMin) {
          baseline = s.beta; // 慢速换握姿随动，不积攒角度。
          sideBaseline = s.gamma;
          accelBaseline = accelBaseline * 0.9 + s.accel * 0.1;
          return result(false);
        }
        baseline = previous.beta;
        dBeta = delta(s.beta, baseline);
        liftStart = previous.t;
        phase = 'lift';
      }
      if (phase === 'lift') {
        if (t - liftStart > p.liftMaxMs) return reject('lift-too-long', t);
        if (dBeta < -p.settleDeg) return reject('reversed', t);
        // 前翻幅度是唯一动作完成条件，不等待悬停，也不检查后续回弹。
        if (dBeta >= p.liftDeg) {
          events.push({ t: t, type: 'fire' });
          cooldownUntil = t + p.cooldownMs;
          phase = 'release';
          return result(true);
        }
      }
      return result(false);
    }

    return {
      push: push,
      reset: reset,
      params: p,
      state: function () { return { phase: phase, baseline: baseline, cooldownUntil: cooldownUntil }; },
    };
  }

  var api = { makeRecognizer: makeRecognizer, DEFAULT_PARAMS: DEFAULT_PARAMS, isUsableSample: isUsableSample };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.MotionRecognizer = api;
})(typeof window !== 'undefined' ? window : (typeof globalThis !== 'undefined' ? globalThis : this));
