/**
 * [INPUT]: 依赖 app.js 的 DOM、鉴权与界面操作，使用浏览器 WebSocket/Pointer Events。
 * [OUTPUT]: 提供首页触控板激活/页面滚动隔离与全屏共享的有序控制通道、能力状态、空闲控制权恢复、心跳与取消。
 * [POS]: Web 控制输入边界；位移合并，离散事件先冲刷位移，断线不回放。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/* ---------- 触控板：WebSocket 通道 ---------- */

const WS_PORT = 46388;
let ws = null;
let wsReady = false;
let reconnectTimer = 0;

// WS 端口自动推导：默认 46388；经端口映射访问时（页面端口 ≠ 46387）
// 假设映射者把 WS 也做了 +1 端口平移（18087→18088），跟随页面主机与端口。
function wsEndpoint() {
  const isDefault = location.port === '' || location.port === '46387';
  const port = isDefault ? WS_PORT : Number(location.port) + 1;
  return `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.hostname}:${port}`;
}

function wsConnect() {
  if (ws && ws.readyState <= 1) return;
  try {
    ws = new WebSocket(wsEndpoint());
  } catch {
    scheduleReconnect();
    return;
  }
  const connection = ws;
  // 浏览器 WS 不能带自定义头，用首帧 auth 握手：服务端校验后才放开手势转发。
  ws.onopen = () => {
    if (ws !== connection) return;
    {
      ws.send(JSON.stringify({ t: 'auth', token: pairToken(), v: 1 }));
    }
    wsReady = true;
  };
  ws.onclose = () => { if (ws !== connection) return; wsReady = false; wsAuthorized = false; controlOwner = false; resetPadQueue(); cancelPadGesture(); notifyWS({ t: 'closed' }); window.pocketdeskMotionSuspend?.('disconnected'); scheduleReconnect(); };
  ws.onerror = () => { try { connection.close(); } catch { /* 已关闭 */ } };
  // 下行：服务端主动推的光标位置、错误与鉴权回执都从这里分发。
  // 触控板此前是纯上行通道，鼠标叠加层需要它变成双向的。
  ws.onmessage = event => {
    if (ws !== connection) return;
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    if (message?.t === 'auth_ok') {
      if (controlInfo.session !== message.session) controlSequence = 0;
      wsAuthorized = true; controlOwner = message.controller !== false; controlInfo = message;
      syncMotionWithControl();
    }
    if (message?.t === 'control') { controlOwner = message.controller; controlInfo.controller = controlOwner; if (!controlOwner) cancelPadGesture(); syncMotionWithControl(); }
    notifyWS(message);
  };
}

// 鉴权是否真的通过了。wsReady 只说明 socket 打开，不等于服务端认可——
// 订阅鼠标这类"要等服务端放行"的动作必须看这个，不能看 wsReady。
let wsAuthorized = false;
let controlOwner = false;
let controlInfo = {};

// 翻腕识别与操作通道同生共死：失去控制权就停识别，拿回来才让它重新验证有效数据。
// 直接原因不是省电——离开场景后的迟到候选不能发，恢复后也必须重新证明传感器还在出数。
function syncMotionWithControl() {
  if (controlOwner) window.pocketdeskMotionResume?.();
  else window.pocketdeskMotionSuspend?.('control-lost');
}
let controlSequence = 0;
const wsListeners = new Set();

function notifyWS(message) {
  for (const listener of wsListeners) {
    try { listener(message); } catch { /* 单个订阅者出错不影响别人 */ }
  }
}

/** 订阅下行消息；返回退订函数。screen.js 用它收光标位置。 */
function onWSMessage(listener) {
  wsListeners.add(listener);
  return () => wsListeners.delete(listener);
}

function scheduleReconnect() {
  clearTimeout(reconnectTimer);
  reconnectTimer = setTimeout(wsConnect, 2000);
}

wsConnect();

// 手势增量在 rAF 帧内合并成一条消息；down/up/click 立即发送。
let pendingMove = { x: 0, y: 0 };
let pendingScroll = { x: 0, y: 0 };
let pendingZoom = 0;
let flushQueued = false;

function resetPadQueue() {
  pendingMove = { x: 0, y: 0 }; pendingScroll = { x: 0, y: 0 }; pendingZoom = 0; flushQueued = false;
}
function sendPadNow(command) {
  const meta = ['cursor-subscribe', 'heartbeat', 'take-control'].includes(command.t);
  if (!wsReady || !wsAuthorized || (!meta && !controlOwner)) return false;
  if (ws.bufferedAmount > 65536) { ws.close(); resetPadQueue(); return false; }
  if (command.t === 'pointer' && !controlInfo.absolutePointerV1) {
    if (!['move', 'click'].includes(command.action)) return false;
    command = { ...command, t: 'tap', click: command.action === 'click' };
  }
  ws.send(JSON.stringify({ ...command, session: controlInfo.session, seq: ++controlSequence }));
  return true;
}
function flushPad() {
  flushQueued = false;
  if (!wsAuthorized || !controlOwner) { resetPadQueue(); return; }
  if (pendingMove.x || pendingMove.y) sendPadNow({ t: 'move', dx: pendingMove.x, dy: pendingMove.y });
  if (pendingScroll.x || pendingScroll.y) sendPadNow({ t: 'scroll', dx: pendingScroll.x, dy: pendingScroll.y });
  if (pendingZoom) sendPadNow({ t: 'zoom', delta: pendingZoom });
  resetPadQueue();
}
function queuePad(command) {
  if (!wsReady || !wsAuthorized) return false;
  if (['move', 'scroll', 'zoom'].includes(command.t)) {
    if (!controlOwner) return false;
    if (command.t === 'move') { pendingMove.x += command.dx; pendingMove.y += command.dy; }
    if (command.t === 'scroll') { pendingScroll.x += command.dx; pendingScroll.y += command.dy; }
    if (command.t === 'zoom') pendingZoom += command.delta;
    if (!flushQueued) { flushQueued = true; requestAnimationFrame(flushPad); }
    return true;
  }
  flushPad(); return sendPadNow(command);
}
let lastControlCheck = 0;
setInterval(() => {
  if (document.hidden) return;
  sendPadNow({ t: 'heartbeat' });
  // auth 只在服务端没有控制者时获权，不使用会抢占其他手机的 take-control。
  if (wsReady && wsAuthorized && !controlOwner && Date.now() - lastControlCheck > 3000) {
    lastControlCheck = Date.now();
    ws.send(JSON.stringify({ t: 'auth', token: pairToken(), v: 1 }));
  }
}, 500);
window.pocketdeskSend = queuePad;
window.pocketdeskOnWSMessage = onWSMessage;
window.pocketdeskControlReady = () => wsAuthorized && controlOwner && window.pocketdeskAccessibility !== false;
window.pocketdeskControlInfo = () => controlInfo;
window.pocketdeskControlState = () => !wsReady || !wsAuthorized ? 'connecting'
  : window.pocketdeskAccessibility === false ? 'permission' : !controlOwner ? 'viewer' : 'ready';

/* ---------- 触控板：手势状态机 ---------- */

const pointers = new Map();   // pointerId -> {x, y, ts}
let gesture = null;           // 'pending' | 'cursor' | 'two' | 'idle'；drag 由 dragArmed 表示
let holdTimer = 0;
let dragArmed = false;        // 长按已触发，左键在 Mac 上处于按下状态
let sawTwoFingers = false;
let pendingRightClick = false;
let lastTap = null;           // 双击检测：350ms 内同一附近的第二次点按
let twoInfo = null;           // 双指中点与间距
let twoVy = 0;                // 双指滚动的松手速度（px/ms）
let momentumRaf = 0;          // 惯性滚动动画帧
const SCROLL_ZONE_PX = 36;    // 触控板右缘单指滚动区宽度（与 ::after 视觉带宽同宽，视觉不撒谎）
let twoStartedAt = 0;
let twoMoved = 0;

const sens = () => parseFloat(sensEl.value);
const scrollFactor = () => parseFloat(scrollSpeedEl.value);

sensEl.value = localStorage.getItem('pd-sens') || sensEl.value;
scrollSpeedEl.value = localStorage.getItem('pd-scroll') || scrollSpeedEl.value;
sensEl.addEventListener('input', () => localStorage.setItem('pd-sens', sensEl.value));
scrollSpeedEl.addEventListener('input', () => localStorage.setItem('pd-scroll', scrollSpeedEl.value));

// 刻度尺排数：写进 #pad 的 data-ruler，CSS 据此隐去内列（单排锚点回退方案）。
rulerEl.value = localStorage.getItem('pd-ruler') || rulerEl.value;
pad.dataset.ruler = rulerEl.value;
rulerEl.addEventListener('change', () => {
  pad.dataset.ruler = rulerEl.value;
  localStorage.setItem('pd-ruler', rulerEl.value);
});

/* 设置入口不在触控板里了：全局唯一入口在 header，由 settings.js 负责。
   触控板只保留手势本身，不再兼管面板显隐，避免"删了 DOM 还留着监听"。 */

let padActivationStart = null;
pad.addEventListener('click', event => {
  if (mainEl.classList.contains('pad-mode') || !padActivationStart) return;
  if (Math.hypot(event.clientX - padActivationStart.x, event.clientY - padActivationStart.y) < 8) enterPadMode();
  padActivationStart = null;
});
pad.addEventListener('pointerdown', event => {
  if (!mainEl.classList.contains('pad-mode')) {
    padActivationStart = { x: event.clientX, y: event.clientY }; return;
  }
  if (event.button > 0) return;
  event.preventDefault();
  if (momentumRaf) { cancelAnimationFrame(momentumRaf); momentumRaf = 0; } // 新手势接管，停掉惯性
  try { pad.setPointerCapture(event.pointerId); } catch { /* 指针已失效时忽略，不影响手势 */ }
  const rect = pad.getBoundingClientRect();
  const zone = pointers.size === 0 && event.clientX > rect.right - SCROLL_ZONE_PX ? 'scroll' : 'cursor';
  pointers.set(event.pointerId, { x: event.clientX, y: event.clientY, sx: event.clientX, sy: event.clientY, ts: performance.now(), zone, vy: 0, lastT: 0 });
  pad.classList.add('pad-active');
  if (pointers.size === 1) {
    gesture = 'pending';
    dragArmed = false;
    sawTwoFingers = false;
    pendingRightClick = false;
    clearTimeout(holdTimer);
    holdTimer = setTimeout(() => {
      if (pointers.size === 1 && gesture === 'pending' && zone !== 'scroll') {
        dragArmed = true;
        pad.classList.add('pad-drag');
        queuePad({ t: 'down' });
      }
    }, 500);
  } else if (pointers.size === 2) {
    if (dragArmed) { queuePad({ t: 'up' }); dragArmed = false; }
    // 第二根手指落下：取消长按与单击判定，进入滚动/捏合。
    clearTimeout(holdTimer);
    sawTwoFingers = true;
    gesture = 'two';
    twoVy = 0;
    const [a, b] = [...pointers.values()];
    twoInfo = { mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2, dist: Math.hypot(a.x - b.x, a.y - b.y), t: performance.now() };
    twoStartedAt = twoInfo.t;
    twoMoved = 0;
  }
});

// 松手后的惯性滚动：速度按帧衰减，衰减完发送 scrollEnd 让 Mac 停稳。
function startMomentum(v) {
  if (momentumRaf) cancelAnimationFrame(momentumRaf);
  let last = performance.now();
  const step = now => {
    const dt = Math.min(48, now - last);
    last = now;
    if (!wsReady || Math.abs(v) < 0.06) {
      queuePad({ t: 'scrollEnd' });
      momentumRaf = 0;
      return;
    }
    queuePad({ t: 'scroll', dx: 0, dy: v * dt * scrollFactor() });
    v *= Math.pow(0.94, dt / 16);
    momentumRaf = requestAnimationFrame(step);
  };
  momentumRaf = requestAnimationFrame(step);
}

pad.addEventListener('pointermove', event => {
  const point = pointers.get(event.pointerId);
  if (!point) return;
  const samples = event.getCoalescedEvents ? event.getCoalescedEvents() : [];
  const moves = samples.length ? samples : [event];

  // 右缘滚动区：单指上下滑直接滚动，并记录松手速度用于惯性。
  if (pointers.size === 1 && point.zone === 'scroll') {
    if (gesture === 'pending' && Math.abs(event.clientY - point.sy) <= 8) return;
    const nowT = performance.now();
    const dt = point.lastT ? nowT - point.lastT : 0;
    let dy = 0;
    for (const sample of moves) {
      dy += sample.clientY - point.y;
      point.y = sample.clientY;
    }
    if (dt > 0) point.vy = point.vy * 0.65 + (dy / dt) * 0.35;
    point.lastT = nowT;
    if (gesture === 'pending') { gesture = 'scroll'; clearTimeout(holdTimer); }
    if (gesture === 'scroll') {
      pad.classList.add('pad-scrolling'); // 右缘刻度墨点点亮
      queuePad({ t: 'scroll', dx: 0, dy: dy * scrollFactor() });
    }
    return;
  }

  if (pointers.size === 1) {
    let dx = 0;
    let dy = 0;
    for (const sample of moves) {
      dx += sample.clientX - point.x;
      dy += sample.clientY - point.y;
      point.x = sample.clientX;
      point.y = sample.clientY;
    }
    if (gesture === 'pending' && Math.hypot(point.x - point.sx, point.y - point.sy) > 8) {
      // 累计位移超过 8px 才算移动光标；手指静置抖动仍保持点按判定。
      gesture = 'cursor';
    }
    if (gesture === 'cursor') {
      // 长按拿起后服务端处于 dragging 状态，move 即拖动；否则移动光标。
      queuePad({ t: 'move', dx: dx * sens(), dy: dy * sens() });
    }
  } else if (pointers.size >= 2 && gesture === 'two') {
    const last = moves[moves.length - 1];
    point.x = last.clientX;
    point.y = last.clientY;
    const [a, b] = [...pointers.values()];
    const mx = (a.x + b.x) / 2;
    const my = (a.y + b.y) / 2;
    const dist = Math.hypot(a.x - b.x, a.y - b.y);
    const tx = mx - twoInfo.mx;
    const ty = my - twoInfo.my;
    const scale = dist / (twoInfo.dist || 1) - 1;
    twoMoved += Math.hypot(tx, ty);
    const dt = performance.now() - (twoInfo.t || performance.now());
    if (dt > 0) twoVy = twoVy * 0.65 + (ty / dt) * 0.35;
    if (Math.abs(scale) > 0.02) {
      // 指间距变化为主：捏合缩放（Cmd+滚轮）。
      queuePad({ t: 'zoom', delta: scale * 2 });
    } else {
      pad.classList.add('pad-scrolling'); // 双指滚动同样点亮刻度墨点
      queuePad({ t: 'scroll', dx: tx * scrollFactor(), dy: ty * scrollFactor() });
    }
    twoInfo = { mx, my, dist, t: performance.now() };
  }
});

function padLift(event) {
  if (!pointers.has(event.pointerId)) return;
  const lift = pointers.get(event.pointerId);
  pointers.delete(event.pointerId);

  if (pointers.size === 0) {
    clearTimeout(holdTimer);
    pad.classList.remove('pad-active', 'pad-drag', 'pad-scrolling'); // 墨点随松手熄灭
    if (dragArmed) {
      queuePad({ t: 'up' });
      dragArmed = false;
    } else if (sawTwoFingers) {
      if (pendingRightClick && performance.now() - twoStartedAt < 300) {
        queuePad({ t: 'click', button: 'right' });
      }
    } else if (gesture === 'pending' && lift.zone !== 'scroll' && performance.now() - lift.ts < 300) {
      const now = performance.now();
      // 双击语义：第一下 clickState=1，第二下 clickState=2，**各自只有一组 down/up**。
      // 以前发的是 count（= 完整点击次数）：先 count=1 再 count=2，服务端按次数循环执行
      // 就成了 1+2 = 3 次点击。改用显式 clickState，一次轻点就是一次点击。
      const isDouble = !!lastTap && now - lastTap.ts < 350
        && Math.hypot(lift.x - lastTap.x, lift.y - lastTap.y) < 28;
      lastTap = isDouble ? null : { ts: now, x: lift.x, y: lift.y };
      queuePad({ t: 'click', button: 'left', clickState: isDouble ? 2 : 1 });
    } else if (lift.zone === 'scroll') {
      // 滚动区松手：有速度带惯性滑行，否则立即停稳。
      if (Math.abs(lift.vy) > 0.15) startMomentum(lift.vy);
      else queuePad({ t: 'scrollEnd' });
    }
    gesture = null;
    sawTwoFingers = false;
    pendingRightClick = false;
  } else if (pointers.size === 1) {
    // 双指抬起一指：够快且几乎没动才保留右键判定；剩余手指不再触发任何手势。
    pendingRightClick = gesture === 'two' && twoMoved < 12;
    if (!pendingRightClick) {
      if (Math.abs(twoVy) > 0.15) startMomentum(twoVy);
      else queuePad({ t: 'scrollEnd' });
    }
    gesture = 'idle';
  }
}

pad.addEventListener('pointerup', padLift);
function cancelPadGesture() {
  clearTimeout(holdTimer); cancelAnimationFrame(momentumRaf); momentumRaf = 0;
  if (dragArmed) queuePad({ t: 'up' });
  queuePad({ t: 'scrollEnd' });
  dragArmed = false; pointers.clear(); gesture = null; lastTap = null; resetPadQueue();
  pad.classList.remove('pad-drag', 'pad-active', 'pad-scrolling');
  padActivationStart = null;
}
pad.addEventListener('pointercancel', cancelPadGesture);
pad.addEventListener('lostpointercapture', event => { if (pointers.has(event.pointerId)) cancelPadGesture(); });
// iOS 手势只在触控板内开始时阻止浏览器滚动，不锁整页。
pad.addEventListener('touchmove', event => {
  if (pointers.size && event.cancelable) event.preventDefault();
}, { passive: false });
document.addEventListener('pointerdown', event => {
  if (!pad.contains(event.target) && (momentumRaf || pointers.size)) cancelPadGesture();
}, true);
window.addEventListener('pagehide', cancelPadGesture);
document.addEventListener('visibilitychange', () => { if (document.hidden) { cancelPadGesture(); queuePad({ t: 'cancel' }); } else if (!wsReady) wsConnect(); });

// 键盘驱动触控板：方向键移光标、回车/空格单击、Esc 退出。走现成的 queuePad 封装，不动 ws 协议。
const PAD_KEY_STEP = 14;

pad.addEventListener('keydown', event => {
  if (!mainEl.classList.contains('pad-mode')) {
    if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); enterPadMode(); }
    return;
  }
  const dir = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
  if (dir) {
    event.preventDefault();
    queuePad({ t: 'move', dx: dir[0] * PAD_KEY_STEP * sens(), dy: dir[1] * PAD_KEY_STEP * sens() });
    return;
  }
  if (event.key === 'Enter' || event.key === ' ') {
    event.preventDefault();
    queuePad({ t: 'click', button: 'left', clickState: 1 });
    return;
  }
  if (event.key === 'Escape') {
    exitPadMode();
    pad.blur();
  }
});



