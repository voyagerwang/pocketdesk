/**
 * [INPUT]: 依赖 motion-recognizer.js（全局 MotionRecognizer）与 compose.js/settings.js 暴露的
 *           window.pocketdeskSend / pocketdeskCanMotionSend / pocketdeskHasDraft /
 *           pocketdeskSettingsOpen / pocketdeskMotionEnabled。
 * [OUTPUT]: 注册 window.pocketdeskMotion（控制器）与 window.pocketdeskWristAvailable（能力门禁）。
 *           采集 DeviceMotion/Orientation，喂给识别器；触发候选时经门禁复用 send() 发送。
 * [POS]: 翻腕发送的传感器侧；默认不自动发送，必须用户在设置中开启且已授权。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';
  var Motion = window.MotionRecognizer;
  if (!Motion) { console.error('[motion-send] MotionRecognizer 未加载'); return; }

  // 灵敏度预设：只调两个最影响手感的量，其余保持默认。低=需明显前倾，高=轻动作即可。
  var PRESETS = {
    low: { liftDeg: 30, holdMinMs: 320 },
    medium: { liftDeg: 22, holdMinMs: 240 },
    high: { liftDeg: 15, holdMinMs: 160 },
  };

  var params = Motion.DEFAULT_PARAMS;
  var granted = false;
  var active = false;
  var recognizer = null;
  var lastAccel = 9.8;
  var onCandidate = null;
  var motionHandler = null, orientHandler = null;

  function sensorSupported() {
    // 优先看标准构造器；部分 WebView 仅暴露 on* 事件属性，退一步兼容。
    var hasMotion = typeof window.DeviceMotionEvent !== 'undefined' || ('ondevicemotion' in window);
    var hasOrient = typeof window.DeviceOrientationEvent !== 'undefined' || ('ondeviceorientation' in window);
    return !!(hasMotion && hasOrient);
  }
  function needsPermission() {
    // iOS 13+ 需显式授权；其余平台靠安全上下文即可。
    return sensorSupported() && typeof DeviceMotionEvent.requestPermission === 'function';
  }
  function secure() {
    return typeof window.isSecureContext !== 'undefined' ? window.isSecureContext : true;
  }

  // 能力门禁：settings.js 的 wristAvailability() 直接委托它。
  // 顺序很关键：先判安全上下文。多数安卓浏览器其实支持传感器，只是必须 HTTPS；
  // 若先判传感器，会把“没开 HTTPS / 用了受限 WebView”误报成“设备不支持”，误导用户。
  function available() {
    if (!secure()) {
      var host = window.location.hostname || '<电脑局域网IP>';
      return { ok: false, reason: '需通过 HTTPS 打开本页：运动传感器要求安全上下文。请在手机浏览器访问 https://' + host + ':46487 （不是 :46387 的 HTTP 地址），并信任证书。' };
    }
    if (!sensorSupported()) {
      return { ok: false, reason: '当前浏览器未提供运动传感器（DeviceMotion / DeviceOrientation）。请用手机自带 Chrome 打开上面的 HTTPS 地址，勿用扫码预览/系统内置的受限浏览器。' };
    }
    if (needsPermission() && !granted) return { ok: false, needsPermission: true, reason: '请先点击“授权运动传感器”' };
    if (!needsPermission() && !granted) granted = true; // 安卓等无需显式授权，安全上下文即视为已授权
    return { ok: granted, reason: granted ? '' : '尚未授权运动传感器' };
  }

  async function requestPermission() {
    if (!sensorSupported()) return { ok: false, reason: '本设备不支持运动传感器' };
    if (needsPermission()) {
      try {
        var m = await DeviceMotionEvent.requestPermission();
        var o = (typeof DeviceOrientationEvent.requestPermission === 'function') ? await DeviceOrientationEvent.requestPermission() : 'granted';
        if (m !== 'granted' || o !== 'granted') return { ok: false, reason: '传感器权限被拒绝，请在系统设置中允许运动与方向访问' };
      } catch (e) { return { ok: false, reason: '授权失败：' + (e && e.message || e) }; }
    }
    granted = true;
    return { ok: true };
  }

  function attach() {
    if (motionHandler) return;
    motionHandler = function (e) {
      var a = e.accelerationIncludingGravity || e.acceleration;
      if (a) {
        var x = a.x || 0, y = a.y || 0, z = a.z || 0;
        lastAccel = Math.sqrt(x * x + y * y + z * z) || 9.8;
      }
    };
    orientHandler = function (e) {
      if (!recognizer) return;
      var sample = { t: e.timeStamp || Date.now(), beta: e.beta || 0, gamma: e.gamma || 0, alpha: e.alpha || 0, accel: lastAccel };
      var res = recognizer.push(sample);
      if (res.fired && onCandidate) onCandidate();
    };
    window.addEventListener('devicemotion', motionHandler, { passive: true });
    window.addEventListener('deviceorientation', orientHandler, { passive: true });
  }
  function detach() {
    if (!motionHandler) return;
    window.removeEventListener('devicemotion', motionHandler);
    window.removeEventListener('deviceorientation', orientHandler);
    motionHandler = null; orientHandler = null;
  }

  // 候选 → 发送：复用 compose.js 的 send()，并走统一门禁（不重复实现发送逻辑）。
  function candidateToSend() {
    if (!window.pocketdeskMotionEnabled || !window.pocketdeskMotionEnabled()) return;
    if (window.pocketdeskSettingsOpen && window.pocketdeskSettingsOpen()) return;     // 设置期间不误发
    if (!window.pocketdeskHasDraft || !window.pocketdeskHasDraft()) return;           // 没内容不发
    if (!window.pocketdeskCanMotionSend || !window.pocketdeskCanMotionSend()) return; // 输入中/提交中/组合态不发
    if (window.pocketdeskComposeSend) window.pocketdeskComposeSend();
  }

  function startActive(cb) {
    onCandidate = cb || candidateToSend;
    recognizer = Motion.makeRecognizer(params);
    attach();
    active = true;
  }
  function stopActive() {
    active = false; onCandidate = null;
    detach(); recognizer = null;
  }
  function setParams(patch) { params = Object.assign({}, params, patch); if (recognizer) recognizer = Motion.makeRecognizer(params); }
  function setPreset(name) { if (PRESETS[name]) setParams(PRESETS[name]); }
  function getParams() { return Object.assign({}, params); }

  window.pocketdeskMotion = {
    available: available,
    requestPermission: requestPermission,
    startActive: startActive,
    stopActive: stopActive,
    setParams: setParams,
    setPreset: setPreset,
    getParams: getParams,
    isActive: function () { return active; },
    needsPermission: needsPermission,
    PRESETS: PRESETS,
  };
  window.pocketdeskWristAvailable = available;

  // 启动即恢复：若之前已开启且当前可用，直接进入活动监听（不自动发，等手势）。
  function maybeResume() {
    if (window.pocketdeskMotionEnabled && window.pocketdeskMotionEnabled() && available().ok) {
      startActive();
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', maybeResume);
  else maybeResume();
})();
