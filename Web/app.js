/**
 * [INPUT]: 依赖浏览器 fetch/WebSocket/Pointer Events 与 index.html 的 Dock、文本框、触控板节点。
 * [OUTPUT]: 提供配对 token 管理（URL ?token= → localStorage → 写请求 Authorization 头与 WS 首帧 auth）、
 *           本地状态加载、应用唤醒、send 命令提交、在线心跳（可见 5s、隐藏停轮）与前台应用跟随（选中态自动对齐 Mac 前台）；
 *           触控板卡片经 ws:46388 发送 move/click/down/up/scroll/zoom 手势命令（每帧合并一次，降低包率），支持指针手势与键盘方向键；
 *           同一条 ws 也收下行：auth_ok / cursor（Mac 光标位置）/ error（命令被拒原因）/ closed，经 window.pocketdeskOnWSMessage 分发；
 *           wsReady 只说明 socket 打开，**不等于鉴权通过**——要等服务端 auth_ok 才是 wsAuthorized（回环豁免也会回执）。
 *           快捷键按钮条：渲染 /api/status 下发的 shortcuts（语义串 hotkey），点击 POST /api/shortcut-trigger 注入组合键到 Mac 前台应用；
 *           Dock 选中项采用 roving tabindex，方向键在组内移动选中。
 * [POS]: Web 的交互适配层；与未来 WebSocket transport 共享 SendCommand JSON 形状。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

const row = document.querySelector('#targets');
const textEl = document.querySelector('#text');
const sendEl = document.querySelector('#send');
const messageEl = document.querySelector('#message');
const connectionEl = document.querySelector('#connection');

// 全屏原生键盘的隐形代理（index.html 的 #kb-proxy，在 #screen-view 内部，
// 这样进入原生全屏后它仍被渲染、还能拿到焦点；它没有任何可见形态）。
const screenViewEl = document.querySelector('#screen-view');
let kbProxy = document.querySelector('#kb-proxy');   // let：卡死时整个换元素（见 recreateKbProxy）

/* ---------- 配对 token：扫码 URL 携带，之后本地持久化 ---------- */

const PAIR_TOKEN_KEY = 'voicedeck.pair-token';

// 扫码进入：URL ?token= → localStorage，并从地址栏抹除，避免泄漏进分享/历史。
(function captureToken() {
  const token = new URLSearchParams(location.search).get('token');
  if (token && /^[A-Za-z0-9_-]+$/.test(token)) {
    localStorage.setItem(PAIR_TOKEN_KEY, token);
    history.replaceState(null, '', location.pathname);
  }
})();

function pairToken() { return localStorage.getItem(PAIR_TOKEN_KEY) || ''; }

function authHeaders() {
  const headers = { 'Content-Type': 'application/json' };
  if (pairToken()) headers.Authorization = `Bearer ${pairToken()}`;
  return headers;
}

const mainEl = document.querySelector('main');
const padCard = document.querySelector('#pad-card');
const pad = document.querySelector('#pad');
const padTarget = document.querySelector('#pad-target');
const sensEl = document.querySelector('#sens');
const scrollSpeedEl = document.querySelector('#scroll-speed');
const rulerEl = document.querySelector('#ruler-mode');
const padSettings = document.querySelector('#pad-settings');

let targets = [];
let selected = null;        // null = 尚未选择；boot 后由心跳对齐到 Mac 当前真实前台
const FRONTMOST_ID = '__frontmost__';   // 伪目标：前台是非 Dock 应用时，发送直接注入当前前台
let lastActivateAt = 0;     // 刚在手机上激活过应用时，短暂抑制前台跟随，避免竞态回跳
let lastSeenFront = null;   // 边沿触发：只在电脑前台应用发生变化时跟随一次
let frontmostLabel = null;  // 伪目标态的前台应用名：识别到什么，"发送到 X"就写什么
let manualUntil = 0;        // 手动滑动 Dock 期间暂停跟随，避免抢用户的操作

/* ---------- 通用 ---------- */

// tone: true/'error'=失败；'warn'=发出去了但未能确认生效；其余=正常。
// 中间态必须有自己的长相——"不确定"和"成功"共用一张脸，就是"点了没反应还以为是自己错觉"的来源。
function message(text, error = false) {
  messageEl.textContent = text;
  messageEl.className = error === 'warn' ? 'warn' : (error ? 'error' : '');
}

// 触感反馈：成功轻点一下，不确定稍重，失败双震。手机常常不在视线里，震动是唯一不看屏也能分辨的通道。
function haptic(pattern) {
  if (navigator.vibrate) { try { navigator.vibrate(pattern); } catch (error) { /* 不支持震动则忽略 */ } }
}

/* ---------- 渲染 ---------- */

function renderTargets() {
  row.innerHTML = '';
  targets.forEach(target => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `target${target.id === selected ? ' selected' : ''}`;
    button.dataset.targetId = target.id;
    button.setAttribute('role', 'radio');
    button.setAttribute('aria-checked', String(target.id === selected));
    // roving tabindex：整组只留一个 Tab 停靠点，就是当前选中项。
    button.tabIndex = target.id === selected ? 0 : -1;
    // 应用图标由服务端从系统取；img 加载失败才露出首字兜底（首字只给眼睛看，读屏念下方名称）。
    button.innerHTML = `<span class="target-icon"><img src="/api/icon?id=${encodeURIComponent(target.id)}" alt="" draggable="false"><span class="target-initial" aria-hidden="true"></span></span><small></small>`;
    const image = button.querySelector('img');
    // 首字默认隐藏：加载中不闪文字，确认拿不到图标时才由 CSS 放出来。
    const initial = button.querySelector('.target-initial');
    initial.textContent = target.name.slice(0, 1).toUpperCase();
    image.addEventListener('error', () => {
      image.classList.add('missing');
      initial.classList.add('visible');
    });
    button.querySelector('small').textContent = target.name;
    row.append(button);
  });
}

function markSelected() {
  row.querySelectorAll('.target').forEach(element => {
    const isSelected = element.dataset.targetId === selected;
    element.classList.toggle('selected', isSelected);
    element.setAttribute('aria-checked', String(isSelected));
    element.tabIndex = isSelected ? 0 : -1;   // Tab 下次进来落在选中项上
  });
  // 快捷键组随选中态切换：选中目标有专属组就只显示那组，否则回退全局组。
  syncShortcutsForSelected();
  const front = targets.find(item => item.id === selected);
  // 没有目标时按钮置灰并明说：点了也不会有去向。
  const hasTarget = Boolean(front) || selected === FRONTMOST_ID;
  sendEl.disabled = !hasTarget;
  sendEl.classList.toggle('no-target', !hasTarget);
  // 识别到什么就写什么：Dock 目标用配置名；伪目标用心跳识别出的前台应用名（frontmostLabel）。
  const label = front ? front.name : (selected === FRONTMOST_ID ? (frontmostLabel || '当前前台') : null);
  padTarget.textContent = label || '未选择';
  sendEl.textContent = label ? `发送到 ${label}` : '请先选择应用';
}

/* ---------- 选中与唤醒 ---------- */

async function activateTarget(targetId) {
  lastActivateAt = Date.now();
  const target = targets.find(item => item.id === targetId);
  message(`正在唤醒 ${target ? target.name : targetId}…`);
  try {
    const response = await fetch('/api/activate', {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({ targetId }),
    });
    const result = await response.json();
    if (response.status === 401) throw new Error('未配对：请在电脑端控制台重新扫码。');
    if (!response.ok) throw new Error(result.error || '无法唤醒应用。');
    message(`${target ? target.name : targetId} 已置于电脑前台，可开始输入。`);
    // 按应用偏好切面板：触控板型应用直接展开触控板（收起键盘），输入型保持输入区。
    // 只在手动激活时切——前台自动跟随不切，避免被动抢走用户正打字的键盘。
    if (target?.openPanel === 'pad') enterPadMode(); else exitPadMode();
  } catch (error) {
    message(error.message, true);
  }
}

async function selectTarget(button) {
  selected = button.dataset.targetId;
  markSelected();
  await activateTarget(selected);
}

row.addEventListener('click', event => {
  const button = event.target.closest('.target');
  if (!button || button.parentElement !== row) return;
  selectTarget(button);
});

row.addEventListener('contextmenu', event => {
  if (event.target.closest('.target')) event.preventDefault();
});

// 键盘：方向键 / Home / End 移动选中与焦点（只改选中，不顺手唤醒应用）；回车或空格激活。
row.addEventListener('keydown', event => {
  const button = event.target.closest('.target');
  if (!button) return;
  const buttons = [...row.querySelectorAll('.target')];
  const at = buttons.indexOf(button);
  let to = -1;
  if (event.key === 'ArrowRight') to = Math.min(buttons.length - 1, at + 1);
  else if (event.key === 'ArrowLeft') to = Math.max(0, at - 1);
  else if (event.key === 'Home') to = 0;
  else if (event.key === 'End') to = buttons.length - 1;
  else return;
  event.preventDefault();
  const next = buttons[to];
  if (!next) return;
  if (next !== button) {
    selected = next.dataset.targetId;
    markSelected();
  }
  next.focus();
  next.scrollIntoView({ block: 'nearest', inline: 'nearest' });
});

/* ---------- 触控板卡片：触碰自动展开，点输入框自动收起 ---------- */

function enterPadMode() {
  mainEl.classList.add('pad-mode');
  textEl.blur(); // 收起手机键盘，把屏幕让给触控板
}

function exitPadMode() {
  mainEl.classList.remove('pad-mode');
  // 收起设置面板：滑杆只在触控板展开时有意义，切回输入不残留。
  padCard.classList.remove('show-tuning');
  padSettings.setAttribute('aria-expanded', 'false');
}

pad.addEventListener('pointerdown', enterPadMode);
textEl.addEventListener('pointerdown', exitPadMode);
textEl.addEventListener('focus', exitPadMode);

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
  return `ws://${location.hostname}:${port}`;
}

function wsConnect() {
  try {
    ws = new WebSocket(wsEndpoint());
  } catch {
    scheduleReconnect();
    return;
  }
  // 浏览器 WS 不能带自定义头，用首帧 auth 握手：服务端校验后才放开手势转发。
  ws.onopen = () => {
    if (pairToken()) {
      ws.send(JSON.stringify({ t: 'auth', token: pairToken() }));
    }
    wsReady = true;
  };
  ws.onclose = () => { wsReady = false; wsAuthorized = false; notifyWS({ t: 'closed' }); scheduleReconnect(); };
  ws.onerror = () => { try { ws.close(); } catch { /* 已关闭 */ } };
  // 下行：服务端主动推的光标位置、错误与鉴权回执都从这里分发。
  // 触控板此前是纯上行通道，鼠标叠加层需要它变成双向的。
  ws.onmessage = event => {
    let message;
    try { message = JSON.parse(event.data); } catch { return; }
    if (message?.t === 'auth_ok') wsAuthorized = true;
    notifyWS(message);
  };
}

// 鉴权是否真的通过了。wsReady 只说明 socket 打开，不等于服务端认可——
// 订阅鼠标这类"要等服务端放行"的动作必须看这个，不能看 wsReady。
let wsAuthorized = false;
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

function flushPad() {
  flushQueued = false;
  if (!wsReady) return;
  if (Math.abs(pendingMove.x) > 0.001 || Math.abs(pendingMove.y) > 0.001) {
    ws.send(JSON.stringify({ t: 'move', dx: pendingMove.x, dy: pendingMove.y }));
    pendingMove = { x: 0, y: 0 };
  }
  if (Math.abs(pendingScroll.x) > 0.001 || Math.abs(pendingScroll.y) > 0.001) {
    ws.send(JSON.stringify({ t: 'scroll', dx: pendingScroll.x, dy: pendingScroll.y }));
    pendingScroll = { x: 0, y: 0 };
  }
  if (Math.abs(pendingZoom) > 0.002) {
    ws.send(JSON.stringify({ t: 'zoom', delta: pendingZoom }));
    pendingZoom = 0;
  }
}

function queuePad(message) {
  if (!wsReady) return;
  if (message.t === 'move') {
    pendingMove.x += message.dx; pendingMove.y += message.dy;
  } else if (message.t === 'scroll') {
    pendingScroll.x += message.dx; pendingScroll.y += message.dy;
  } else if (message.t === 'zoom') {
    pendingZoom += message.delta;
  } else {
    ws.send(JSON.stringify(message));
    return;
  }
  if (!flushQueued) {
    flushQueued = true;
    requestAnimationFrame(flushPad);
  }
}

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

/* ---------- 设置齿轮：默认收起，点开才显示滑杆 ---------- */

padSettings.addEventListener('pointerdown', event => event.stopPropagation()); // 不触发触控板手势与 Mac 点击
padSettings.addEventListener('click', event => {
  event.stopPropagation();
  const open = padCard.classList.toggle('show-tuning');
  padSettings.setAttribute('aria-expanded', String(open));
});

/* ---------- 历史发送 ---------- */

const histBtn = document.querySelector('#history-btn');
const historyPanel = document.querySelector('#history-panel');
const historyList = document.querySelector('#history-list');
const historyClear = document.querySelector('#history-clear');
const HIST_KEY = 'pd-history';

histBtn.addEventListener('click', () => {
  const open = historyPanel.hidden;
  historyPanel.hidden = !open;
  // aria-pressed 同时驱动按钮高亮态，面板开闭有明确的按钮反馈。
  histBtn.setAttribute('aria-pressed', String(open));
  disarmClear();
  if (open) renderHistory();
});

// 清空二次确认：第一下点变"确认清空？"，再点才真清；3.5 秒不动作自动还原。
let clearArmTimer = 0;

function disarmClear() {
  clearTimeout(clearArmTimer);
  historyClear.textContent = '清空';
  historyClear.classList.remove('armed');
}

historyClear.addEventListener('click', () => {
  if (!historyClear.classList.contains('armed')) {
    historyClear.classList.add('armed');
    historyClear.textContent = '确认清空？';
    clearArmTimer = setTimeout(disarmClear, 3500);
    return;
  }
  disarmClear();
  localStorage.removeItem(HIST_KEY);
  renderHistory();
});

// 收起按钮：面板头部右侧，与时钟按钮同效（收起 + 取消高亮）。
document.querySelector('#history-collapse').addEventListener('click', () => {
  historyPanel.hidden = true;
  histBtn.setAttribute('aria-pressed', 'false');
  disarmClear();
});

function loadHistory() {
  try {
    const parsed = JSON.parse(localStorage.getItem(HIST_KEY) || '[]');
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function pushHistory(text, targetName) {
  const items = loadHistory();
  // 相同内容去重：只保留最新一条，不重复占位（时间与目标随之刷新）。
  const deduped = items.filter(item => item.text !== text);
  deduped.unshift({ text, target: targetName, ts: Date.now() });
  localStorage.setItem(HIST_KEY, JSON.stringify(deduped.slice(0, 20)));
}

function renderHistory() {
  const items = loadHistory();
  historyList.innerHTML = '';
  if (!items.length) {
    const empty = document.createElement('div');
    empty.className = 'hist-item empty';
    empty.textContent = '还没有发送记录';
    historyList.append(empty);
    return;
  }
  items.forEach(item => {
    const div = document.createElement('div');
    div.className = 'hist-item';
    const textDiv = document.createElement('div');
    textDiv.className = 'hist-text';
    textDiv.textContent = item.text;
    const meta = document.createElement('small');
    const time = new Date(item.ts);
    meta.textContent = `${item.target || ''} · ${String(time.getHours()).padStart(2, '0')}:${String(time.getMinutes()).padStart(2, '0')}`;
    div.append(textDiv, meta);
    div.addEventListener('click', () => {
      textEl.value = item.text;
      historyPanel.hidden = true;
      histBtn.setAttribute('aria-pressed', 'false');
      disarmClear();
      textEl.focus();
      // 程序赋值不会触发 input 事件，故需手动触发同频：否则电脑输入框要等你下次手敲/删除才同步。
      scheduleLive();
    });
    historyList.append(div);
  });
}

/* ---------- 图片发送：选图 → 预览 → 与文字一起发送（经 Mac 剪贴板粘贴） ---------- */

const imageBtn = document.querySelector('#image-btn');
const imageFile = document.querySelector('#image-file');
const imagePreview = document.querySelector('#image-preview');
const imageThumb = document.querySelector('#image-thumb');
const imageRemove = document.querySelector('#image-remove');
let pendingImage = null; // { dataUrl, base64 }

imageBtn.addEventListener('click', () => imageFile.click());
imageFile.addEventListener('change', () => {
  const file = imageFile.files[0];
  imageFile.value = '';
  if (!file) return;
  if (!file.type.startsWith('image/')) { message('只能选择图片。', true); return; }
  compressImage(file, dataUrl => {
    pendingImage = { dataUrl };
    imageThumb.src = dataUrl;
    imagePreview.hidden = false;
    // 选图即预上传：发送时只带标记，请求体保持轻量，粘贴也更早就绪。
    message('图片上传中…');
    fetch('/api/image', {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify({ data: dataUrl.split(',')[1] }),
    }).then(async response => {
      if (!response.ok) {
        const result = await response.json().catch(() => ({}));
        throw new Error(result.error || '图片上传失败。');
      }
      if (pendingImage) message('图片已就绪，输入文字后一起发送。');
    }).catch(error => {
      pendingImage = null;
      imageThumb.src = '';
      imagePreview.hidden = true;
      message(error.message, true);
    });
  });
});

imageRemove.addEventListener('click', () => {
  pendingImage = null;
  imageThumb.src = '';
  imagePreview.hidden = true;
});

// 大图压到 2048px JPEG（质量 0.85）：聊天场景够清晰，base64 体可控制在数 MB 内。
function compressImage(file, done) {
  const reader = new FileReader();
  reader.onload = () => {
    const image = new Image();
    image.onload = () => {
      const scale = Math.min(1, 2048 / Math.max(image.width, image.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(image.width * scale);
      canvas.height = Math.round(image.height * scale);
      canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
      done(canvas.toDataURL('image/jpeg', 0.85));
    };
    image.src = String(reader.result);
  };
  reader.readAsDataURL(file);
}

/* ---------- 快捷键按钮条：渲染电脑端自定义的快捷键，点击注入组合键到 Mac 前台 ---------- */

const shortcutBar = document.querySelector('#shortcut-bar');
let shortcuts = [];
let customShortcuts = []; // 过滤默认示例（undo/copy/paste），手机上只展示用户自己录的

// 语义串展示：最后一个 token 是主键，其余是修饰键符号。
// enter/backspace/esc 等别名归一到同一符号，与控制台 hotkeyDisplay 的归一表保持一致。
function hotkeyLabel(hotkey) {
  const named = { up: '↑', down: '↓', left: '←', right: '→', return: '⏎', enter: '⏎',
    delete: '⌫', backspace: '⌫', escape: 'esc', space: '空格', tab: '⇥' };
  const mods = { cmd: '⌘', shift: '⇧', opt: '⌥', ctrl: '⌃' };
  const parts = (hotkey || '').split('+').map(part => part.trim());
  return parts.map((part, index) => {
    const token = part.toLowerCase();
    return index < parts.length - 1 ? (mods[token] || part) : (named[token] || part.toUpperCase());
  }).join('');
}

// 按钮文案：键位符号 + 名称；名称与键位展示重复时只显示一个（如 label=↑、hotkey=Up 都显示 ↑），
// 与控制台 renderShortcuts 的去重规则一致。
function shortcutLabel(shortcut) {
  const display = hotkeyLabel(shortcut.hotkey);
  return shortcut.label === display ? display : `${display} ${shortcut.label}`.trim();
}

function renderShortcuts() {
  shortcutBar.innerHTML = '';
  shortcutBar.hidden = !customShortcuts.length;
  customShortcuts.forEach(shortcut => {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'shortcut-key';
    button.textContent = shortcutLabel(shortcut);
    button.addEventListener('click', async () => {
      button.disabled = true;
      try {
        const response = await fetch('/api/shortcut-trigger', {
          method: 'POST',
          headers: authHeaders(),
          // action 一并上报：服务端按 id 回查配置，查不到时用上报内容兜底（旧列表/重启后场景）。
          body: JSON.stringify({ id: shortcut.id, label: shortcut.label, hotkey: shortcut.hotkey, action: shortcut.action || null }),
        });
        const result = await response.json().catch(() => ({}));
        if (!response.ok) {
          // blocked/failed：前置条件不满足或执行出错，明确失败，不要含糊。
          message(result.error || '快捷键触发失败。', true);
          haptic([28, 50, 28]);
          return;
        }
        if (result.outcome === 'sent') {
          // 发出去了但服务端没观察到任何状态变化：说清楚"不确定"，别假装成功。
          message(result.detail || '已发送，未能确认是否生效。', 'warn');
          haptic([22]);
        } else {
          message(result.detail || '已完成。');
          haptic([12]);
        }
      } catch {
        message('无法连接本机服务。', true);
        haptic([28, 50, 28]);
      } finally {
        button.disabled = false;
      }
    });
    shortcutBar.append(button);
  });
}

// 服务端下发的全局组原样保存；展示组按选中态重算（专属组优先）。
let globalShortcuts = [];

function syncShortcuts(list) {
  globalShortcuts = list || [];
  syncShortcutsForSelected();
}

// 快捷键按钮条当前该显示哪组：
// 有专属组 → 前排专属 + 后排全局（showGlobal 为 false 时只显专属）；
// 无专属组 → 全局组。全局组过滤默认示例（undo/copy/paste），无自定义项时整条隐藏。
function syncShortcutsForSelected() {
  const target = targets.find(item => item.id === selected);
  const scoped = Array.isArray(target?.shortcuts) ? target.shortcuts : [];
  const showGlobal = target?.showGlobal !== false;
  const list = scoped.length
    ? (showGlobal ? [...scoped, ...globalShortcuts] : scoped)
    : globalShortcuts;
  shortcuts = list;
  const isDefault = s => ['undo', 'copy', 'paste'].includes(s.id) && s.label === { undo: '撤销', copy: '复制', paste: '粘贴' }[s.id];
  const hasCustom = list.some(s => !isDefault(s));
  customShortcuts = hasCustom ? list.filter(s => !isDefault(s)) : [];
  renderShortcuts();
}

// 手动滑动 Dock 时暂停前台跟随，不抢用户的切换操作。
row.addEventListener('scroll', () => { manualUntil = Date.now() + 4000; }, { passive: true });

/* ---------- 横向滚动墨线指示：右侧还有内容时亮起，滚到底淡出 ---------- */

// Dock 与快捷键条共用：内容不溢出时不显示，溢出时跟随滚动位置翻转。
// 返回 update 供内容异步填充后手动触发（图标 img 加载会改变 scrollWidth）。
function trackScrollCue(element) {
  const update = () => {
    const remaining = element.scrollWidth - element.scrollLeft - element.clientWidth;
    element.dataset.more = remaining > 24 ? 'true' : 'false';
  };
  element.addEventListener('scroll', update, { passive: true });
  window.addEventListener('resize', update);
  // 布局与图片加载都晚于脚本：双 rAF 后首拍，再挂图片加载触发。
  requestAnimationFrame(() => requestAnimationFrame(update));
  element.addEventListener('load', update, true); // capture：img 的 load 不冒泡
  return update;
}

trackScrollCue(row);
trackScrollCue(document.querySelector('#shortcut-bar'));

pad.addEventListener('pointerdown', event => {
  enterPadMode();
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
      if (pointers.size === 1 && gesture === 'pending') {
        dragArmed = true;
        pad.classList.add('pad-drag');
        queuePad({ t: 'down' });
      }
    }, 500);
  } else if (pointers.size === 2) {
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
    } else if (gesture === 'pending' && performance.now() - lift.ts < 300) {
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
pad.addEventListener('pointercancel', padLift);

// 键盘驱动触控板：方向键移光标、回车/空格单击、Esc 退出。走现成的 queuePad 封装，不动 ws 协议。
const PAD_KEY_STEP = 14;

pad.addEventListener('keydown', event => {
  const dir = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[event.key];
  if (dir) {
    event.preventDefault();
    queuePad({ t: 'move', dx: dir[0] * PAD_KEY_STEP * sens(), dy: dir[1] * PAD_KEY_STEP * sens() });
    return;
  }
  if (event.key === 'Enter' || event.key === ' ') {
    event.preventDefault();
    queuePad({ t: 'click', button: 'left', count: 1 });
    return;
  }
  if (event.key === 'Escape') {
    exitPadMode();
    pad.blur();
  }
});

pad.addEventListener('focus', enterPadMode);

/* ---------- 连接与发送 ---------- */

const HEARTBEAT_MS = 5000;
let heartbeat = 0;
let heartbeatFailures = 0;  // 连续失败计数：≥2 判定断连，成功即清零

// 心跳 + 前台跟随（边沿触发）：前台命中 Dock 目标时选中态跟过去一次；
// 前台是非目标应用（如 Finder）则进入伪目标态，发送直接注入当前前台。
// 手动滑动 Dock、刚手动激活的短时间内不跟随，之后可自由手动切换。
async function heartbeatTick() {
  try {
    fetch('/api/pair', { method: 'POST', keepalive: true });
    const current = await fetch('/api/status').then(response => response.json());
    // 连接恢复：无论此前断过几次，先把顶部状态拉回真实值。
    if (heartbeatFailures > 0) {
      heartbeatFailures = 0;
      message('已重新连接到电脑。');
    }
    connectionEl.textContent = current.accessibility ? '已就绪' : '需授权';
    connectionEl.classList.toggle('ready', current.accessibility);
    // 目标列表跟随服务端：控制台改了 openPanel/showGlobal/专属快捷键时，手机下一拍同步。
    if (JSON.stringify(current.targets || []) !== JSON.stringify(targets)) {
      targets = current.targets || [];
      renderTargets();
      syncShortcutsForSelected();
    }
    // 快捷键列表跟随服务端：控制台改完配置，手机 5 秒内自动刷新按钮。
    if (JSON.stringify(current.shortcuts || []) !== JSON.stringify(globalShortcuts)) {
      syncShortcuts(current.shortcuts || []);
    }
    // 主题跟随服务端：电脑端切换后，手机下一拍（≤5s）自动换肤。
    applyTheme(current.theme);
    const frontId = current.frontmostId;      // 命中 Dock 目标时的 id，否则 null
    const frontName = current.frontmostName;  // 前台应用名（始终有值）
    const key = frontId ?? frontName ?? null;
    if (!key) return;
    // 抑制期内不消费也不记录：lastSeenFront 保持原值，抑制结束后下一拍仍会应用这次切换。
    if (Date.now() <= manualUntil || Date.now() - lastActivateAt < 2500) return;
    // 边沿触发：只在电脑前台应用发生变化时跟随一次。
    if (key === lastSeenFront) return;
    lastSeenFront = key;
    if (frontId && targets.some(item => item.id === frontId)) {
      selected = frontId;
      frontmostLabel = null;   // Dock 目标态：名字由 markSelected 从 targets 取
      markSelected();   // 统一出口：图标选中态与"发送到 X"文案同步更新
      const name = (targets.find(item => item.id === frontId) || { name: frontId }).name;
      message(`${name} 已在电脑前台，可直接输入。`);
    } else if (frontName) {
      selected = FRONTMOST_ID;
      frontmostLabel = frontName;   // 识别到什么就叫什么：按钮直接显示该应用名
      markSelected();
      message(`已切到 ${frontName}（未添加），发送将直接输入到它。`);
    }
  } catch {
    // 连续两拍失败才判定断连，避免单次网络抖动误报；顶部状态立即改口，不再挂假"已就绪"。
    heartbeatFailures++;
    if (heartbeatFailures >= 2) {
      connectionEl.textContent = '未连接';
      connectionEl.classList.remove('ready');
      message('与电脑的连接已断开：请确认同一 Wi-Fi，或重新扫码。', true);
    }
  }
}

function startHeartbeat(interval = HEARTBEAT_MS) {
  clearInterval(heartbeat);
  heartbeat = setInterval(heartbeatTick, interval);
}

function stopHeartbeat() {
  clearInterval(heartbeat);
  heartbeat = 0;
}

// 浏览器进后台不完全停摆：UU 远程分屏等场景里页面仍"可见但无焦点"，
// 完全停轮询会导致 Mac 前台切换不再同步到手机。后台降频到 15s，回前台立即补拍。
const BACKGROUND_HEARTBEAT_MS = 15000;

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    startHeartbeat(BACKGROUND_HEARTBEAT_MS);
    return;
  }
  heartbeatTick();
  startHeartbeat();
});

async function boot() {
  try {
    const status = await fetch('/api/status').then(response => response.json());
    targets = status.targets;
    syncShortcuts(status.shortcuts || []);
    renderTargets();
    applyTheme(status.theme);
    connectionEl.textContent = status.accessibility ? '已就绪' : '需授权';
    connectionEl.classList.toggle('ready', status.accessibility);
    if (!status.accessibility) message('请先在电脑端控制台完成授权，页面仍可输入。', true);
    // 刷新后立即对齐一次选中态：Mac 前台命中 Dock 目标就选它，否则进入伪目标并记住前台名，
    // 保证底部"发送到 X"与 Dock 高亮始终反映真实状态，而不是上次会话的残留默认值。
    const frontId = status.frontmostId;
    if (frontId && targets.some(item => item.id === frontId)) {
      selected = frontId;
      lastSeenFront = frontId;
      frontmostLabel = null;
    } else if (status.frontmostName) {
      selected = FRONTMOST_ID;
      lastSeenFront = status.frontmostName;
      frontmostLabel = status.frontmostName;
    }
    markSelected();
    startHeartbeat();
  } catch {
    connectionEl.textContent = '未连接';
    message('无法连接本机服务。确认手机与 Mac 在同一网络。', true);
  }
}

/* ---------- 实时同频：手机输入框 ↔ 电脑输入框 ---------- */
// 每次 input 把 textarea 的**全文**发给服务端，由服务端求差（保留公共前缀 → 退掉旧尾巴 → 补上新尾巴）。
// 传全文而不是"刚敲了哪个键"：全文是幂等的，丢一包、乱一次序，下一次同步自然补齐。
// 关键修复：曾经在输入法组合态（compositionstart→compositionend）期间直接跳过同步，导致"手机有字、电脑要松手才出字"。
// 现在组合态也照常同步，只是尽量只发"已提交"部分（见 liveValue），既实时又把拼音倒进电脑的概率降到最低。
const LIVE_DEBOUNCE = 90;          // 合并连打，别每个键一次往返
const LIVE_COOLDOWN = 3000;        // 同步失败后歇一会儿，别拿同一条报错刷屏

const liveFlagEl = document.querySelector('#live-flag');
let liveComposing = false;   // 输入法组合态标记：仅用于决定取"全文"还是"已提交前缀"，不再据此跳过同步

// 取"当前应同步到电脑"的文本。
// 曾经的做法：组合态直接不派同步 → 要等"松手/停顿"才下发，体验就是手机有字、电脑没字。
// 现在实时下发，但尽量只发"已提交"部分：
//   - 非组合态：全文即已提交，直接发。
//   - 组合态且能区分已提交/未提交（桌面端：未提交文本落在 selectionStart..selectionEnd）：剔除未提交部分，避免把拼音倒进电脑。
//   - 组合态且 caret 折叠（移动端常见，iOS 打字期间 composition 一直不结束）：无法可靠剥离拼音，发全文以保证实时；
//       中文会短暂露出拼音，提交后由服务端差值算法自动纠正为汉字。
function liveValue() {
  const el = textEl;
  if (!el.isComposing && !liveComposing) return el.value;
  const s = el.selectionStart, e = el.selectionEnd;
  if (typeof s === 'number' && typeof e === 'number' && e > s) {
    return el.value.slice(0, s) + el.value.slice(e);
  }
  return el.value;
}
let liveTimer = null;
let liveInFlight = null;     // 在途请求的 Promise
let liveQueued = null;       // 在途期间的最新文本：中间态无意义，只留最后一次
let liveSynced = false;      // 电脑端输入框是否已被本轮同频接管（决定发送走回车还是整段粘贴）
let liveBlockedUntil = 0;    // 冷却截止时刻

function currentTargetName() {
  if (selected === FRONTMOST_ID) return frontmostLabel || '当前前台';
  return (targets.find(item => item.id === selected) || { name: selected }).name;
}

// state: off / on / error
function paintLive(state, note) {
  if (!liveFlagEl) return;
  if (state === 'off') { liveFlagEl.hidden = true; return; }
  liveFlagEl.hidden = false;
  liveFlagEl.dataset.state = state;
  liveFlagEl.textContent = note || '';
}

function pushLive(text, submit = false) {
  // 严格串行：同时只让一个请求在途。后来者覆盖前一个排队项，于是服务端看到的永远是最新全文，
  // 即便响应乱序回来也不会把旧文本写回去。
  if (liveInFlight) {
    liveQueued = { text, submit };
    return liveInFlight;
  }
  const task = (async () => {
    try {
      const response = await fetch('/api/live-input', {
        method: 'POST',
        headers: authHeaders(),
        body: JSON.stringify({ text, targetId: selected || FRONTMOST_ID, submit: submit || undefined }),
      });
      const result = await response.json();
      if (response.status === 401) throw new Error('未配对：请在电脑端控制台重新扫码。');
      if (!response.ok) throw new Error(result.error || '同步失败。');
      liveSynced = !submit;   // 提交后电脑端输入框被清空，同频关系随之结束
      liveBlockedUntil = 0;
      paintLive('on', `已同频到${currentTargetName()}`);
      return result;
    } catch (error) {
      // 冷却期内不再重试：一次失败往往是一串失败（应用切不过去、没授权），刷屏只会盖掉真正的原因。
      liveBlockedUntil = Date.now() + LIVE_COOLDOWN;
      paintLive('error', '未同频：点发送将整段粘贴');
      throw error;
    } finally {
      liveInFlight = null;
      if (liveQueued) {
        const next = liveQueued;
        liveQueued = null;
        pushLive(next.text, next.submit).catch(() => {});
      }
    }
  })();
  liveInFlight = task;
  return task;
}

function scheduleLive() {
  if (Date.now() < liveBlockedUntil) return;
  clearTimeout(liveTimer);
  liveTimer = setTimeout(() => { pushLive(liveValue()).catch(() => {}); }, LIVE_DEBOUNCE);
}

// 发送前立刻把最新全文推过去：不等 debounce，否则最后一个字可能还没同步就按了回车。
function flushLive(text, submit = false) {
  clearTimeout(liveTimer);
  return pushLive(text, submit);
}

// 输入法卡死防御（修 Gboard 等第三方键盘“上滑清空”后输入框点不进、只能刷新页面）：
// 该手势是一次超大的 deleteSurroundingText，Android WebView 的编辑会话常被它搞死——
// 之后敲字不出 input、点也点不进输入框，只剩刷新整页一条路。
// 判据不看组合态（liveComposing）：Gboard 常在**没开组合态**时直接发这次大删除，
// 只看组合态就等于把最常见的那条路漏掉了。
function endCompositionState() {
  liveComposing = false;
}

function recoverIME(el) {
  // 卡死时 blur 再 focus，Android WebView 会重建编辑会话——比刷新整页轻得多。
  // rAF 包一层确保 blur 先生效，不跟浏览器默认的点按聚焦打架。
  liveComposing = false;
  el.blur();
  requestAnimationFrame(() => el.focus({ preventScroll: true }));
}

// 上一次 input 之后的长度：用来认"一次清空"这个指纹。
const imePrevLen = new WeakMap();

// 任一输入框（主页 textarea 或全屏键盘代理）都接同一套卡死防御；
// 全屏代理的改动要镜像回主页 textarea，因为直播同步的"真值"始终读 textEl。
// recover：会话卡死时怎么重建。主页框用 recoverIME（blur→focus 同元素）；
// 全屏代理传 recreateKbProxy——Gboard「上滑清空」在某些 Android WebView 上对同元素
// blur→focus 免疫，必须整个换掉元素（新元素带全新原生编辑会话）才救得回来。
function wireComposeIME(el, mirrorTo, recover = recoverIME) {
  el.addEventListener('compositionstart', () => { liveComposing = true; });
  el.addEventListener('compositionend', () => { liveComposing = false; scheduleLive(); });
  el.addEventListener('input', event => {
    const was = imePrevLen.get(el) ?? 0;
    imePrevLen.set(el, el.value.length);
    // 没走 compositionend 就直接 input（Gboard 清空常见）→ 组合态其实已结束，强制清掉卡死标记。
    if (!event.isComposing && liveComposing) liveComposing = false;
    // 全屏代理敲的字要同步回主页 textarea，直播同频才认得到。
    if (mirrorTo && mirrorTo !== el) mirrorTo.value = el.value;
    scheduleLive();
    // 「上滑清空」指纹：一次 input 就从非空一步归零（退格是一格一格删，不会一步清空）。
    // 命中即重建——**不论是否处于组合态**，这正是以前漏掉 Gboard 的原因。
    if (was > 0 && el.value === '') recover();
  });
  // 兜底：会话死透时连 input 都不派发（渲染进程与 IME 失联，敲字完全没反应）。
  // beforeinput 到了却迟迟不见 input = 这次编辑没被吃进去，同样重建会话。
  // 代价极小的误伤：在空框上按退格本来也不出 input，会白重建一次会话（无感）。
  let editProbe = 0;
  el.addEventListener('beforeinput', () => {
    clearTimeout(editProbe);
    editProbe = setTimeout(() => recover(), 700);
  });
  el.addEventListener('input', () => clearTimeout(editProbe));
  // 失焦/聚焦都是全新编辑会话，不该带着上一次的卡死态。
  el.addEventListener('blur', endCompositionState);
  el.addEventListener('focus', endCompositionState);
  // 兜底：点输入框时若组合态仍卡死，重建 IME 会话，解决“点不进、软键盘不弹”。
  el.addEventListener('pointerdown', () => { if (liveComposing) recover(); });
}
wireComposeIME(textEl, null);

/* ---------- 全屏原生键盘（参考 UU 远程：点画面输入框，直接把手机键盘浮起来）----------
   这里**没有任何可见面板，也没有发送按钮**：#kb-proxy 只是个 1px 的隐形输入框，
   职责是拿到焦点（浏览器只对可聚焦元素弹键盘）、接住 IME 输入。
   不造可见面板是因为竖屏全屏整层转了 90°，HUD 的最小化/刷新/关闭落在手机右侧，
   贴底面板必然压住它们；不造发送按钮是因为原生键盘右下角本来就有"发送"（enterkeyhint=send）。
   敲的字经 wireComposeIME 镜像回 textEl，再走直播同频实时打进 Mac 当前聚焦的输入框——
   全屏时手机看到的就是电脑画面，文字出现在"该出现的地方"，这里不必再抄一遍。

   Gboard「上滑清空」会把当前元素的原生 IME 会话彻底搞死（之后敲字不出 input、
   点也点不进、只剩刷新整页）。唯一可靠的解法是丢掉这个被污染的元素、换一个全新的
   textarea——新元素带全新的原生编辑会话，绝不继承旧污点。所以代理一律用
   buildKbProxy() 现造现用，卡死就 recreateKbProxy() 整个换掉。 */
wireComposeIME(kbProxy, textEl, recreateKbProxy);
wireKbProxyExtras(kbProxy);   // 初始代理也要接 blur/focus/keydown（recreate 出来的同样接这一份）

// 这一轮会话里代理有没有真的吃到过字 / 是否怀疑会话已死 / 是否正在重建中。
let kbGotInput = false;
let kbSuspect = false;     // 上滑清空或 beforeinput 超时没回 input → 代理可能已死
let kbRecreating = false; // 重建期间抑制 blur 误触发 pocketdeskKeyboardClosed（避免重建瞬间画面闪一下重排）

// 键盘图标高亮态：键盘抬起=高亮，收起=灭。
function syncKbToggle() {
  const el = document.getElementById('kb-toggle');
  if (el) el.classList.toggle('kb-active', kbActive);
}

// 隐形代理的"会话外"监听：失焦复位、聚焦摁滚动、回车发送。初始与 recreate 出来的都接这一份。
function wireKbProxyExtras(p) {
  p.addEventListener('input', () => { kbGotInput = true; });
  // 用户收起原生键盘（返回键 / 键盘收起键）：失焦即复位，并交还布局权。
  p.addEventListener('blur', () => {
    if (kbRecreating) return;            // 重建时旧元素被移除会触发 blur，那是假失焦，跳过
    kbActive = false;
    window.pocketdeskKeyboardClosed?.(); // 让画面按真实视口重新铺一次
    syncKbToggle();
  });
  // 重建会话是 blur→focus 两步，focus 回来要把键盘态补上（blur 那边刚把它清掉）。
  p.addEventListener('focus', () => { kbActive = true; pinScroll(); syncKbToggle(); });
  // 原生键盘右下角的"发送"键（enterkeyhint=send）按下来就是一个 Enter。
  p.addEventListener('keydown', event => {
    if (event.isComposing || event.keyCode === 229) return;   // 输入法选词期间的回车归 IME
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      sendFromKeyboard();
    }
  });
}

// 造一个全新的隐形代理：自带干净的原生编辑会话。每次需要都现造，旧的整个丢弃。
function buildKbProxy() {
  const p = document.createElement('textarea');
  p.id = 'kb-proxy';
  p.className = 'kb-proxy';
  p.rows = 1;
  p.setAttribute('enterkeyhint', 'send');
  p.setAttribute('autocomplete', 'off');
  p.setAttribute('autocapitalize', 'sentences');
  p.setAttribute('spellcheck', 'false');
  p.setAttribute('aria-label', '唤起键盘');
  // 放进 #screen-view 内部：进原生全屏（requestFullscreen）后整份文档只剩 panel，
  // 代理若挂在外面会随文档一起不渲染、键盘弹不出来。
  (screenViewEl || document.body).appendChild(p);
  wireComposeIME(p, textEl, recreateKbProxy);
  wireKbProxyExtras(p);
  return p;
}

// 卡死自愈的终极手段：整个换掉代理元素。被 wireComposeIME 在检测到「上滑清空指纹」
// （一次 input 从非空一步归零）或「beforeinput 后迟迟没 input」时调用；
// 也被 showKeyboard 在「代理仍聚焦却一个字都没收到」这种明显死透的情况下调用。
// 全新元素 = 全新原生编辑会话，这是唯一能甩掉 Gboard 污点、不必刷新整页的办法。
function recreateKbProxy() {
  kbRecreating = true;
  if (kbProxy && kbProxy.isConnected) kbProxy.remove();
  kbProxy = buildKbProxy();
  kbProxy.value = textEl.value;
  imePrevLen.set(kbProxy, kbProxy.value.length);   // 重新播种，别把旧长度当"一次清空"的指纹
  kbActive = true;
  kbGotInput = false;
  kbSuspect = false;
  kbProxy.focus({ preventScroll: true });
  // 键盘升起有动画，头几帧浏览器还会再滚一次，多点几下才摁得住。
  [0, 60, 150, 300].forEach(delay => setTimeout(pinScroll, delay));
  kbRecreating = false;
  syncKbToggle();
  haptic(8);
}

// 键盘弹起时浏览器会自作主张滚一下页面（把焦点元素顶进可视区）——对全屏看画面来说，
// 那就是"整页被顶上去"：画面挪位，HUD 还可能被顶出屏幕。代理钉在左上角已经避开了
// 大部分自动滚动，这里再兜一层：键盘使用期间任何滚动都被摁回 0，画面纹丝不动。
// 只在代理真的持有焦点时才管，别去干扰主页的正常滚动。
let kbActive = false;

function pinScroll() {
  if (!kbActive) return;
  if (window.scrollY) window.scrollTo(0, 0);
  if (document.scrollingElement?.scrollTop) document.scrollingElement.scrollTop = 0;
}
if (window.visualViewport) {
  window.visualViewport.addEventListener('resize', pinScroll);
  window.visualViewport.addEventListener('scroll', pinScroll);
}
window.addEventListener('scroll', pinScroll, { passive: true });

// 唤起原生键盘：把主页草稿带过来，聚焦即弹键盘。
// 关键点：Gboard「上滑清空」会让代理**仍聚焦却已死透**（敲字不出 input）。这种情况
// blur→focus 同元素在部分 Android WebView 上对 Gboard 无效，必须整个换元素。
// 所以只要「仍聚焦且本轮没收到过字」或已打上 kbSuspect 标记，就直接 recreateKbProxy()
// 换新元素——这是唯一能甩掉污点、不必刷新整页的办法。
function showKeyboard() {
  if (kbSuspect || (document.activeElement === kbProxy && !kbGotInput)) {
    recreateKbProxy();
    return;
  }
  // 普通唤起 / 已在聚焦（移动光标）：不重建，避免键盘闪一下。
  kbProxy.value = textEl.value;
  imePrevLen.set(kbProxy, kbProxy.value.length);
  kbActive = true;
  kbGotInput = false;
  kbProxy.focus({ preventScroll: true });
  [0, 60, 150, 300].forEach(delay => setTimeout(pinScroll, delay));
  haptic(8);
}

// 收起：只需交出焦点，键盘自己会落下。
// 刻意**不清 value**——代理只是草稿的暂存副本，下次唤起一律用 textEl 重新播种；
// 清了反而可能在 IME 自愈（recreate）后把真值覆盖成空。
function hideKeyboard() {
  kbActive = false;
  syncKbToggle();
  if (document.activeElement === kbProxy) kbProxy.blur();
  window.pocketdeskKeyboardClosed?.();   // 交还布局权，让画面按真实视口重新铺一次
}

// 发完就收：草稿空了说明已提交，键盘让位给画面。
async function sendFromKeyboard() {
  await send();
  if (!textEl.value) hideKeyboard();
}

// 全屏键盘图标（#kb-toggle）：唯一的“点此才弹键盘”入口。
// 点画面不再自动弹（避免切换窗口时点一下就蹦键盘）—— 见 screen.js 的 sendTap。
// 关闭 / 退出全屏 → hideKeyboard；键盘抬起期间 → 画面尺寸冻结（不跟着键盘引起的视口变化重排）。
  const kbToggle = document.getElementById('kb-toggle');
  if (kbToggle) {
    // 关键：在 pointerdown 时就快照 kbActive，再决定 click 时开还是关。
    // 否则点按钮会让 #kb-proxy 失焦 → blur 先把 kbActive 翻成 false，
    // 随后 click 里读到 false 反而去 showKeyboard() —— 表现成"再点一下收不起、高亮消不掉"。
    let kbToggleWasActive = false;
    kbToggle.addEventListener('pointerdown', () => { kbToggleWasActive = kbActive; });
    kbToggle.addEventListener('click', event => {
      event.stopPropagation();   // 防穿透；closest('button') 已让 panel 拖动跳过它
      if (kbToggleWasActive) hideKeyboard(); else showKeyboard();
      kbToggleWasActive = false;
    });
  }
window.pocketdeskShowKeyboard = showKeyboard;
window.pocketdeskHideKeyboard = hideKeyboard;
window.pocketdeskKeyboardActive = () => kbActive;

async function postSend(text, withImage) {
  const response = await fetch('/api/send', {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({ targetId: selected, text, usePendingImage: withImage, image: null }),
  });
  const result = await response.json();
  if (response.status === 401) throw new Error('未配对：请在电脑端控制台重新扫码。');
  if (!response.ok) throw new Error(result.error || '发送失败。');
  return result;
}

function clearCompose() {
  textEl.value = '';
  liveSynced = false;
  liveQueued = null;
  paintLive('off');
  pendingImage = null;
  imageThumb.src = '';
  imagePreview.hidden = true;
}

async function send() {
  if (sendEl.disabled) return; // 发送进行中或未选目标（回车快捷键路径）
  if (!selected) {
    message('请先在上方 Dock 选择一个目标应用。', true);
    return;
  }
  // 同频链路要逐字符对齐，故用原文：trim 会吃掉首尾空格与换行，电脑端就对不上了。
  const raw = textEl.value;
  const text = raw.trim();
  if (!text && !pendingImage) {
    message('先输入一点内容或选择一张图片。', true);
    textEl.focus();
    return;
  }
  exitPadMode();
  sendEl.disabled = true;
  // 已同频 → 内容早就在电脑端输入框里了，发送只是补一次回车。
  const viaLive = liveSynced && !pendingImage;
  message(viaLive ? '正在回车提交…'
    : (selected === FRONTMOST_ID ? `直接输入到 ${frontmostLabel || '当前前台应用'}…` : '正在打开应用并输入…'));
  try {
    let result;
    if (pendingImage) {
      // 图片仍走粘贴通道：先把文字同频过去，再单独发图（text 留空，否则整段文字会被重复粘贴一遍）。
      if (raw && !liveSynced) await flushLive(raw).catch(() => {});
      result = await postSend('', true);
    } else if (viaLive) {
      result = await flushLive(raw, true);
    } else {
      result = await postSend(text, false);
    }
    // 发送成功就进历史：即使注入效果不符预期，内容也不会丢，可从历史一键回填重发。
    pushHistory(text || '[图片]', currentTargetName());
    clearCompose();
    // outcome=sent 表示目标没能在前台，内容可能没落到它的输入框：这是"发了却说没收到"的主因，必须说出来。
    if (result.outcome === 'sent') {
      message(result.detail || '已发送，未能确认是否生效。', 'warn');
      haptic([22]);
    } else {
      message(result.detail || '已发送。');
      haptic([12]);
    }
  } catch (error) {
    // 同频失败时不回退到整段粘贴：内容可能已经打进去一半，再粘一遍就成了重复。
    // 输入框原样保留，用户看清原因后可以自己重试。
    message(error.message, true);
    haptic([28, 50, 28]);
  } finally {
    sendEl.disabled = false;
  }
}

sendEl.addEventListener('click', send);
textEl.addEventListener('keydown', event => {
  // 中文/日文输入法在选词、候选期间按回车是给 IME 用的，不能当成“发送”。
  if (event.isComposing || event.keyCode === 229) return;
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    send();
  }
});

/* ---------- 主题跟随：唯一控制点在电脑端控制台，手机页经 /api/status 只读跟随 ---------- */

function applyTheme(name) {
  // 约定与控制台一致：data-theme="muji" = 米白克制风；无属性 = 经典蓝（服务端默认）。
  if (name === 'muji') {
    document.documentElement.setAttribute('data-theme', 'muji');
  } else {
    document.documentElement.removeAttribute('data-theme');
  }
  // 记住最近一次已知主题：下次刷新时 head 内联脚本先应用，避免闪回默认。
  try { localStorage.setItem('voicedeck.last-theme', name === 'muji' ? 'muji' : 'classic'); } catch (e) { /* 无痕模式 */ }
}

// 画面层（screen.js）与触控板通道的桥：tap 等即时消息经此直发（queuePad 对非合并消息不缓冲）。
window.pocketdeskSend = queuePad;
// 下行入口：screen.js 订阅服务端推送（光标位置 / 错误 / 鉴权回执）。
window.pocketdeskOnWSMessage = onWSMessage;

boot();
