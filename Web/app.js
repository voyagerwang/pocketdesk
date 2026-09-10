/**
 * [INPUT]: 消费首页 DOM、HTTP 配置/状态与逐图上传接口、浏览器文件读取/图片解码/Canvas 压缩和本地存储。
 * [OUTPUT]: 提供配对鉴权、目标选择（显式点击委托输入层开启隔离的新草稿轮次）、历史/快捷键，以及最多 8 张图片的原生多选追加、横向预览、逐张删除、批次幂等上传和处理完成门闩。
 * [POS]: Web 首页编排与共享状态；输入委托 compose.js，控制连接委托 pad.js，全屏委托 screen.js。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

const row = document.querySelector('#targets');
let textEl = document.querySelector('#text'); // IME 恢复时由 compose.js 替换并重新绑定
const sendEl = document.querySelector('#send');
const messageEl = document.querySelector('#message');
const connectionEl = document.querySelector('#connection');

// 全屏可见编辑框（index.html 的 #kb-proxy，在 #screen-view 内部，
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
  window.pocketdeskScreenMessage?.(text);
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
    return true;
  } catch (error) {
    message(error.message, true);
    return false;
  }
}

async function selectTarget(button) {
  const targetId = button.dataset.targetId;
  const rebuiltDraft = beginDraftForExplicitTarget(targetId);
  selected = targetId;
  markSelected();
  const activated = await activateTarget(selected);
  // 切换目标或失败后重选当前目标，代表用户要以此刻输入位置开始新一轮；已有正文
  // 立即触发新绑定，纯图片发送时绑定。健康状态重复点击不重建，避免把全文再次追加。
  if (activated && rebuiltDraft && textEl.value) scheduleLive();
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

/* ---------- 触控板卡片：轻点展开，滑动保留页面滚动，点输入框自动收起 ---------- */

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
let pendingImages = []; // { id, dataUrl, uploaded }
function newImageId() {
  const bytes = new Uint32Array(4); crypto.getRandomValues(bytes);
  return [...bytes].map(value => value.toString(16).padStart(8, '0')).join('');
}
let imageBatchId = newImageId();
let imageGeneration = 0;
let imagePreparation = Promise.resolve();
let imagePreparationError = null;

imageBtn.addEventListener('click', () => imageFile.click());
imageFile.addEventListener('change', () => {
  const generation = imageGeneration;
  const files = [...imageFile.files];
  imageFile.value = '';
  if (!files.length) return;
  if (files.some(file => !file.type.startsWith('image/'))) { message('所选文件中包含非图片。', true); return; }
  imagePreparationError = null;
  message('正在处理图片…');
  imagePreparation = imagePreparation.then(async () => {
    if (generation !== imageGeneration) return;
    if (pendingImages.length + files.length > 8) throw new Error('一次最多选择 8 张图片。');
    const additions = await Promise.all(files.map(async file => ({ id: newImageId(), dataUrl: await compressImage(file), uploaded: false })));
    if (additions.some(item => Math.ceil(item.dataUrl.split(',')[1].length * 3 / 4) > 8 * 1024 * 1024)) throw new Error('单张图片不能超过 8MB。');
    if (generation !== imageGeneration) return;
    if (pendingImages.length + additions.length > 8) throw new Error('一次最多选择 8 张图片。');
    pendingImages.push(...additions); renderPendingImages();
    try {
      await uploadPendingImages();
      if (generation === imageGeneration) message('图片已就绪，输入文字后一起发送。');
    } catch (error) {
      if (generation === imageGeneration) message(error.message || '图片上传失败，发送时会重试。', true);
    }
  }).catch(error => {
    if (generation === imageGeneration) {
      imagePreparationError = error;
      message(error.message || '图片处理失败。', true);
    }
  });
});

function renderPendingImages() {
  imagePreview.replaceChildren(...pendingImages.map(item => {
    const wrap = document.createElement('div'); wrap.className = 'image-preview-item';
    const img = document.createElement('img'); img.src = item.dataUrl; img.alt = '待发送图片';
    const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'image-remove'; remove.dataset.imageId = item.id; remove.setAttribute('aria-label', '移除图片'); remove.textContent = '×';
    remove.disabled = submittingDraft;
    remove.addEventListener('click', () => {
      if (submittingDraft) return;
      pendingImages = pendingImages.filter(entry => entry.id !== item.id).map(entry => ({ ...entry, uploaded: false }));
      imageBatchId = newImageId(); renderPendingImages();
    });
    wrap.append(img, remove); return wrap;
  }));
  imagePreview.hidden = pendingImages.length === 0;
}

async function uploadPendingImages() {
  const generation = imageGeneration, batchId = imageBatchId, items = [...pendingImages];
  for (const item of items) {
    const response = await fetch('/api/image', { method: 'POST', headers: authHeaders(), body: JSON.stringify({ batchId, imageId: item.id, data: item.dataUrl.split(',')[1] }) });
    if (!response.ok) { const result = await response.json().catch(() => ({})); throw new Error(result.error || '图片上传失败。'); }
    if (generation === imageGeneration && batchId === imageBatchId && pendingImages.includes(item)) item.uploaded = true;
  }
}

// 大图压到 2048px JPEG（质量 0.85）：聊天场景够清晰，base64 体可控制在数 MB 内。
function compressImage(file) { return new Promise((resolve, reject) => {
  const reader = new FileReader(); reader.onerror = () => reject(new Error('图片读取失败。'));
  reader.onload = () => {
    const image = new Image();
    image.onload = () => {
      const scale = Math.min(1, 2048 / Math.max(image.width, image.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.round(image.width * scale);
      canvas.height = Math.round(image.height * scale);
      canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
      resolve(canvas.toDataURL('image/jpeg', 0.85));
    };
    image.onerror = () => reject(new Error('所选图片已损坏。'));
    image.src = String(reader.result);
  };
  reader.readAsDataURL(file);
}); }

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
        // 有手机草稿时，普通回车属于本轮提交：先冲刷全文，确认后统一清空。
        // 空草稿及带修饰键的回车仍是普通桌面快捷键。
        if (!shortcut.action && /^(return|enter)$/i.test(shortcut.hotkey.trim())
            && (liveValue().trim() || pendingImages.length)) {
          await send();
          return;
        }
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
    window.pocketdeskAccessibility = current.accessibility;
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
    window.pocketdeskAccessibility = status.accessibility;
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
    // 浏览器恢复的正文可能早于目标就绪；就绪后补齐，不等下一次手敲。
    if (textEl.value) scheduleLive();
  } catch {
    connectionEl.textContent = '未连接';
    message('无法连接本机服务。确认手机与 Mac 在同一网络。', true);
  }
}

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



// 下行入口：screen.js 订阅服务端推送（光标位置 / 错误 / 鉴权回执）。
