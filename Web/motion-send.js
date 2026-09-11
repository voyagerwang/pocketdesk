/**
 * [INPUT]: 依赖 motion-recognizer.js（全局 MotionRecognizer：makeRecognizer / isUsableSample）
 *          与 compose.js/settings.js 暴露的 window.pocketdeskComposeSend / pocketdeskCanMotionSend /
 *          pocketdeskHasDraft / pocketdeskSettingsOpen / pocketdeskMotionEnabled。
 * [OUTPUT]: 注册 window.pocketdeskMotion（控制器）与 window.pocketdeskWristAvailable（能力门禁）。
 *           采集 DeviceMotion/Orientation 喂给识别器；触发候选时经门禁复用 pocketdeskComposeSend()。
 *           对外给出四级状态 status()：unsupported（环境）/ needs-permission（授权）/
 *           unverified（数据）/ running（运行），另加过渡态 verifying。
 *           另注册 pocketdeskMotionSuspend/Resume 供控制通道在断线与失去租约时停识别。
 * [POS]: 翻腕发送的传感器侧；默认不自动发送，必须用户开启、授权且真的收到有效数据。
 *        不提供任何证书向导：非安全上下文由设置面板整组隐藏，用户走发送按钮。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 *
 * 免证书降级（docs/wrist-send-no-certificate-plan.md 阶段 2）：
 * 手机不得为翻腕发送下载、安装或手动信任 CA。因此这里不再判断"如何引导用户装证书"，
 * 只判断"这台手机的这个浏览器现在能不能真的拿到运动数据"，并把结论按四级状态交出去。
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

  // 数据层探测窗口：开启后最多等这么久，等真实传感器出数。3 秒是方案给的初值，待双机实测校准。
  var PROBE_WINDOW_MS = 3000;
  // 需要两个有效样本：设备启动监听器时可能补发一帧旧数据，单帧不足以证明"在持续出数"。
  var PROBE_MIN_SAMPLES = 2;

  var params = Motion.DEFAULT_PARAMS;
  var authGranted = false;    // 授权层：用户同意过（或平台无需授权）。同意 ≠ 出数。
  var dataVerified = false;   // 数据层：本次订阅真的收到过有效样本。挂起后失效，恢复要重验。
  var verifying = false;      // 正在探测，供 UI 显示"正在确认"
  var active = false;         // 运行层：识别器在跑，可能产生候选
  var suspended = '';         // 挂起原因：hidden / offline / control-lost / disconnected 等
  var recognizer = null;
  var stopListening = null;
  var lastAccel = 9.8;

  function sensorSupported() {
    // 优先看标准构造器；部分 WebView 仅暴露 on* 事件属性，退一步兼容。
    var hasMotion = typeof window.DeviceMotionEvent !== 'undefined' || ('ondevicemotion' in window);
    var hasOrient = typeof window.DeviceOrientationEvent !== 'undefined' || ('ondeviceorientation' in window);
    return !!(hasMotion && hasOrient);
  }
  function needsPermission() {
    // iOS 13+ 需显式授权，且必须由用户点按触发；其余平台靠安全上下文即可。
    return sensorSupported() && typeof window.DeviceMotionEvent !== 'undefined'
      && typeof window.DeviceMotionEvent.requestPermission === 'function';
  }
  function secure() {
    return window.isSecureContext === true;
  }

  /* ---------- 第一层：环境 ---------- */

  // 环境不过关时设置面板整组隐藏（hidden: true）——不显示灰色开关、不出现证书下载，
  // 也不给"去系统设置里配置"的维修教程。翻腕是可选捷径，普通发送始终可达。
  function environment() {
    if (!secure()) return { ok: false, hidden: true, code: 'insecure-context' };
    if (!sensorSupported()) return { ok: false, hidden: true, code: 'no-sensor-api' };
    return { ok: true, code: 'ok' };
  }

  // 能力门禁：settings.js 的 wristAvailability() 直接委托它。
  // 顺序很关键：先判安全上下文。多数安卓浏览器其实支持传感器，只是必须 HTTPS；
  // 若先判传感器，会把"没开 HTTPS / 用了受限 WebView"误报成"设备不支持"，误导用户。
  function available() {
    var env = environment();
    if (!env.ok) return env;
    if (needsPermission() && !authGranted) return { ok: false, code: 'needs-permission' };
    if (!dataVerified) return { ok: false, code: 'unverified' };
    return { ok: true, code: 'ok' };
  }

  // 给 UI 的一句话状态。四种真实边界 + 一个过渡态，UI 只按这个字符串分支，不再自己猜。
  function status() {
    if (!environment().ok) return 'unsupported';
    if (active) return 'running';
    if (verifying) return 'verifying';
    if (needsPermission() && !authGranted) return 'needs-permission';
    if (!dataVerified) return 'unverified';
    return 'ready';
  }

  /* ---------- 统一的传感器订阅 ---------- */

  // 探测与识别共用同一条订阅路径：避免出现"探测能收到数、识别收不到"的两套代码分叉。
  // 回调的第二参数标明这一帧来自 deviceorientation（只有它带姿态角，识别器只吃这一种）。
  function listen(handleSample) {
    function onMotion(event) {
      var a = event.accelerationIncludingGravity || event.acceleration;
      var magnitude = null;
      if (a && a.x !== null && a.y !== null && a.z !== null) {
        var x = a.x || 0, y = a.y || 0, z = a.z || 0;
        magnitude = Math.sqrt(x * x + y * y + z * z);
      }
      if (magnitude !== null && isFinite(magnitude)) lastAccel = magnitude;
      handleSample({ t: event.timeStamp || Date.now(), accel: magnitude, beta: null, gamma: null, alpha: null }, false);
    }
    function onOrient(event) {
      handleSample({
        t: event.timeStamp || Date.now(),
        beta: event.beta, gamma: event.gamma, alpha: event.alpha, accel: lastAccel,
      }, true);
    }
    window.addEventListener('devicemotion', onMotion, { passive: true });
    window.addEventListener('deviceorientation', onOrient, { passive: true });
    return function stop() {
      window.removeEventListener('devicemotion', onMotion);
      window.removeEventListener('deviceorientation', onOrient);
    };
  }

  /* ---------- 第二层：授权 ---------- */

  function requestPermission() {
    if (!sensorSupported()) return Promise.resolve({ ok: false, code: 'no-sensor-api' });
    if (!needsPermission()) { authGranted = true; return Promise.resolve({ ok: true }); }
    // 必须在用户点按的同一个任务里调用：前面不能有 await，否则 iOS 判定丢失用户激活。
    return Promise.resolve()
      .then(function () { return window.DeviceMotionEvent.requestPermission(); })
      .then(function (motion) {
        if (motion !== 'granted') return { ok: false, code: 'permission-denied' };
        if (typeof window.DeviceOrientationEvent.requestPermission !== 'function') return { ok: true };
        return window.DeviceOrientationEvent.requestPermission().then(function (orient) {
          return orient === 'granted' ? { ok: true } : { ok: false, code: 'permission-denied' };
        });
      })
      .then(function (result) {
        if (result.ok) authGranted = true;
        return result;
      }, function () { return { ok: false, code: 'permission-denied' }; });
  }

  /* ---------- 第三层：数据 ---------- */

  // 真的接一段传感器事件，收到有限、非 null 的值才算"出数"。
  // 静止（全 0）是合法样本：手机平放桌面不能判成不支持，否则误杀一半正常场景。
  function probeData(timeoutMs) {
    var timeout = typeof timeoutMs === 'number' ? timeoutMs : PROBE_WINDOW_MS;
    if (!environment().ok) return Promise.resolve({ ok: false, code: environment().code, samples: 0, elapsedMs: 0 });
    if (stopListening) stopListening();
    verifying = true;
    var startedAt = Date.now();
    return new Promise(function (resolve) {
      var seen = 0;
      var settled = false;
      var timer = 0;
      function finish(ok, code) {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (stopListening) { stopListening(); stopListening = null; }
        verifying = false;
        if (ok) dataVerified = true;
        resolve({ ok: ok, code: code || '', samples: seen, elapsedMs: Date.now() - startedAt });
      }
      timer = setTimeout(function () { finish(false, 'no-sensor-data'); }, timeout);
      stopListening = listen(function (sample) {
        if (!Motion.isUsableSample(sample)) return;
        seen++;
        if (seen >= PROBE_MIN_SAMPLES) finish(true, 'ok');
      });
    });
  }

  /* ---------- 第四层：运行 ---------- */

  // 候选 → 发送：复用 compose.js 的 send()，并走统一门禁（不重复实现发送逻辑）。
  function candidateToSend() {
    if (!active) return;                                                       // 没在跑就不可能有候选
    if (window.pocketdeskSettingsOpen && window.pocketdeskSettingsOpen()) return;     // 设置期间不误发
    if (!window.pocketdeskHasDraft || !window.pocketdeskHasDraft()) return;           // 没内容不发
    if (!window.pocketdeskCanMotionSend || !window.pocketdeskCanMotionSend()) return; // 输入中/提交中/组合态不发
    if (window.pocketdeskComposeSend) window.pocketdeskComposeSend();
  }

  // 运行态一变就广播：设置面板据此回填开关，避免"偏好是开、实际没跑"或反过来的显示错位。
  function notify() {
    if (typeof window.CustomEvent !== 'function') return;
    window.dispatchEvent(new window.CustomEvent('pocketdesk-motion-status'));
  }

  function startActive() {
    if (active) return;
    if (stopListening) { stopListening(); stopListening = null; }
    recognizer = Motion.makeRecognizer(params);
    stopListening = listen(function (sample, isOrientation) {
      if (!recognizer || !isOrientation) return;
      var result = recognizer.push(sample);
      if (result.fired) candidateToSend();
    });
    active = true;
    notify();
  }

  function stopActive() {
    if (!active) return;
    active = false;
    if (stopListening) { stopListening(); stopListening = null; }
    recognizer = null;
    notify();
  }

  // 用户点开关的那一次交互里走完 授权 → 数据 → 运行。
  // 任何一步失败都返回失败码，由设置面板把开关拨回去并给同一句人话：
  // 不循环弹权限框、不要求系统配置、不提证书与端口。
  function enable() {
    var env = environment();
    if (!env.ok) return Promise.resolve({ ok: false, code: env.code });
    return requestPermission().then(function (permission) {
      if (!permission.ok) return permission;
      return probeData(PROBE_WINDOW_MS).then(function (data) {
        if (!data.ok) return data;
        suspended = '';
        startActive();
        return { ok: true, code: 'ok' };
      });
    });
  }

  function disable() {
    stopActive();
    suspended = '';
    dataVerified = false;   // 下次开启重新验证：偏好只代表意愿，不代表这次还能出数
  }

  /* ---------- 挂起与恢复 ---------- */

  // 切后台、断网、失去控制权都停识别。理由不是省电，而是"离开场景后的迟到候选不能发"。
  function suspend(reason) {
    if (!active && !verifying) { suspended = reason || 'suspended'; return; }
    stopActive();
    dataVerified = false;
    suspended = reason || 'suspended';
  }

  // 恢复后不自动请求权限（那需要用户点按），只重新验证有效数据；验证通过才起识别。
  // 已有开启偏好不能直接等同运行成功——这是"已有偏好安全停用"的落点。
  function resume() {
    if (!window.pocketdeskMotionEnabled || !window.pocketdeskMotionEnabled()) return Promise.resolve({ ok: false, code: 'disabled' });
    if (!environment().ok) return Promise.resolve({ ok: false, code: environment().code });
    if (needsPermission() && !authGranted) return Promise.resolve({ ok: false, code: 'needs-permission' });
    if (active || verifying) return Promise.resolve({ ok: active, code: active ? 'ok' : 'verifying' });
    return probeData(PROBE_WINDOW_MS).then(function (data) {
      if (!data.ok) return data;
      suspended = '';
      startActive();
      return { ok: true, code: 'ok' };
    });
  }

  document.addEventListener('visibilitychange', function () {
    if (document.hidden) suspend('hidden');
    else resume();
  });
  window.addEventListener('pagehide', function () { suspend('pagehide'); });
  window.addEventListener('offline', function () { suspend('offline'); });
  window.addEventListener('online', function () { resume(); });

  /* ---------- 诊断（方案阶段 1 的真机基线用） ---------- */

  // 只回报环境与一次探测的事实，不触发任何桌面发送；手机端不展示这些内容。
  function diagnose() {
    return {
      protocol: window.location.protocol,
      secureContext: secure(),
      userAgent: navigator.userAgent || '',
      hasDeviceMotion: typeof window.DeviceMotionEvent !== 'undefined',
      hasDeviceOrientation: typeof window.DeviceOrientationEvent !== 'undefined',
      hasRequestPermission: needsPermission(),
      environment: environment(),
      status: status(),
      authGranted: authGranted,
      dataVerified: dataVerified,
      active: active,
      suspended: suspended,
    };
  }

  function setParams(patch) { params = Object.assign({}, params, patch); if (recognizer) recognizer = Motion.makeRecognizer(params); }
  function setPreset(name) { if (PRESETS[name]) setParams(PRESETS[name]); }
  function getParams() { return Object.assign({}, params); }

  window.pocketdeskMotion = {
    environment: environment,
    available: available,
    status: status,
    enable: enable,
    disable: disable,
    suspend: suspend,
    resume: resume,
    probeData: probeData,
    diagnose: diagnose,
    setParams: setParams,
    setPreset: setPreset,
    getParams: getParams,
    isActive: function () { return active; },
    needsPermission: needsPermission,
    PRESETS: PRESETS,
  };
  window.pocketdeskWristAvailable = available;
  window.pocketdeskMotionSuspend = suspend;
  window.pocketdeskMotionResume = resume;

  // 启动即恢复：偏好开启且环境允许时静默重验一次数据；验证不过就本次停用，不打扰用户。
  function tryRestore() {
    if (!window.pocketdeskMotionEnabled || !window.pocketdeskMotionEnabled()) return;
    if (!environment().ok) return;
    resume();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', tryRestore);
  else tryRestore();
})();
