/**
 * [INPUT]: 消费首页 DOM、HTTP 配置/状态与逐图上传接口、浏览器文件读取/图片解码和本地存储；合规 JPEG 保留原始字节，其他图片经 Canvas 转换。
 * [OUTPUT]: 提供原始完整球球图标、接收者常驻标识与服务端回执驱动的应用接续入口； 应用/小精灵共享当前正文，切换仅重建目标绑定并失效旧选择回执；提供配对鉴权、目标选择（显式点击委托输入层开启隔离的新草稿轮次）、小精灵活动任务启动找回、历史/快捷键，以及最多 8 张图片的原生多选追加、横向预览、逐张删除、批次幂等上传和处理完成门闩。
 *           快捷键按钮条对 action 为 draft.clear 的项走本地分支：调 window.pocketdeskClearDraft()，不投递按键；
 *           该全局缺失时如实报错，不做静默 no-op。唤醒回执按服务端聚焦核验结论分级提示
 *           （clickedInput/inputFocused：已点进输入框 / 请点一下输入框 / 未能确认聚焦），不再一律说"可开始输入"。
 *           心跳失败按原因分流（配对失效 / 手机离线 / 电脑端 HTTP 异常 / 页面脚本出错 / 真断链）：
 *           先琥珀色示警并 1.2 秒补拍，连续不通≥15 秒才升红并给出该原因的下一步，恢复时报出中断时长。
 * [POS]: Web 首页编排与共享状态；输入委托 compose.js，控制连接委托 pad.js，全屏委托 screen.js。
 * [PROTOCOL]: boot() 对齐前台目标后主动 activateTarget 一次，使手机“默认选中”与实际桌面绑定就绪对齐（与手动点目标等价，不移动鼠标、不重置草稿）；变更时更新此头部，然后检查 CLAUDE.md
 */

const row = document.querySelector('#targets');
let textEl = document.querySelector('#text'); // IME 恢复时由 compose.js 替换并重新绑定
const sendEl = document.querySelector('#send');
const messageEl = document.querySelector('#message');
const connectionEl = document.querySelector('#connection');

// 徽标语义：能连上 + 电脑端辅助功能已授权 + 本机持有控制租约，三者皆备才「已就绪」。
// 前两项走 HTTP /api/status，第三项走 WS 控制通道（pad.js 暴露的 pocketdeskControlState）。
// 三者任一不满足就如实降级，不再挂假「已就绪」（对照 app.js 心跳注释同一条原则）。
let lastAccessibility = true;   // 最近一次 /api/status 的 accessibility，心跳/boot 写入
let httpDown = false;           // HTTP 连续失败（未连接），优先于一切状态

function refreshConnectionBadge() {
  if (httpDown) {
    connectionEl.textContent = '未连接';
    connectionEl.classList.remove('ready', 'warn');
    return;
  }
  // 控制态由 WS 通道实时维护：viewer = 控制权已旁落，需先接管。
  const ctrl = typeof window.pocketdeskControlState === 'function' ? window.pocketdeskControlState() : 'ready';
  if (lastAccessibility === false) {
    connectionEl.textContent = '需授权';
    connectionEl.classList.remove('ready', 'warn');
    return;
  }
  if (ctrl === 'viewer') {
    connectionEl.textContent = '需接管';
    connectionEl.classList.remove('ready');
    connectionEl.classList.add('warn');
    return;
  }
  // 挂上"多久前联系上过"：已经连上但数据在变旧时，这个数字是唯一能看出来的线索。
  const age = lastContactAt ? Date.now() - lastContactAt : 0;
  connectionEl.textContent = age >= 10000 ? `已就绪 · ${humanGap(age)}前` : '已就绪';
  connectionEl.classList.add('ready');
  connectionEl.classList.remove('warn');
}

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
const pad = document.querySelector('#pad');
// 三个触控板参数的真身已迁进 #phone-settings 面板，ID 未变，这里照旧取到同一批元素；
// 值的读写与持久化仍在 pad.js，面板只负责把它们放到该在的位置。
const sensEl = document.querySelector('#sens');
const scrollSpeedEl = document.querySelector('#scroll-speed');
const rulerEl = document.querySelector('#ruler-mode');

let targets = [];
let selected = null;        // null = 尚未选择；boot 后由心跳对齐到 Mac 当前真实前台
const FRONTMOST_ID = '__frontmost__';   // 伪目标：前台是非 Dock 应用时，发送直接注入当前前台
let lastActivateAt = 0;     // 刚在手机上激活过应用时，短暂抑制前台跟随，避免竞态回跳
let lastSeenFront = null;   // 边沿触发：只在电脑前台应用发生变化时跟随一次
let frontmostLabel = null;  // 伪目标态的前台应用名：识别到什么，"发送到 X"就写什么
let manualUntil = 0;        // 手动滑动 Dock 期间暂停跟随，避免抢用户的操作
const SPRITE_ID = '__sprite__';   // 内置接收者：小精灵不是应用，绝不走 activate / AX 输入绑定
let recipientOrder = [];    // 服务端保存的接收者顺序；首次迁移把小精灵放在首位

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

/* ---------- 触控板卡片：轻点展开，滑动保留页面滚动，点输入框自动收起 ---------- */

function enterPadMode() {
  mainEl.classList.add('pad-mode');
  textEl.blur(); // 收起手机键盘，把屏幕让给触控板
}

// 设置已迁到 header 的独立面板，退出触控板不再顺手关它：
// 面板是模态的，开着的时候触控板本来就收不到点击，这里再关一次只会制造两处状态。
function exitPadMode() {
  mainEl.classList.remove('pad-mode');
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

// 合规 JPEG 直接保留：避免手机 Canvas 重绘黑图，也不压窄长截图文字。
// 其他格式或超限 JPEG 仍压到最长边 2048px（质量 0.85）。
function compressImage(file) { return new Promise((resolve, reject) => {
  const reader = new FileReader(); reader.onerror = () => reject(new Error('图片读取失败。'));
  reader.onload = () => {
    const image = new Image();
    image.onload = () => {
      // 小于 8MiB 的 JPEG 保留原图，避免手机 Canvas 重绘黑图和长图文字缩损。
      if (file.type === 'image/jpeg' && file.size < 8 * 1024 * 1024) {
        resolve(String(reader.result));
        return;
      }
      try {
        const scale = Math.min(1, 2048 / Math.max(image.width, image.height));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(image.width * scale));
        canvas.height = Math.max(1, Math.round(image.height * scale));
        const context = canvas.getContext('2d');
        if (!context) throw new Error('图片处理失败，请重新选择。');
        context.fillStyle = '#fff';
        context.fillRect(0, 0, canvas.width, canvas.height);
        context.drawImage(image, 0, 0, canvas.width, canvas.height);
        const result = canvas.toDataURL('image/jpeg', 0.85);
        if (!result.startsWith('data:image/jpeg;base64,')) throw new Error('图片处理失败，请重新选择。');
        resolve(result);
      } catch (error) { reject(error); }
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
        // 「清空会话」是本地动作：清手机草稿 + 请求电脑清空，不投递任何按键。
        // 服务端把它的 delivery 标成 deviceLocal，误发到 shortcut-trigger 会被明确拒绝。
        if (shortcut.action === 'draft.clear') {
          // 本地动作缺失只可能是页面装了半截（compose.js 未加载）。静默 no-op 会被当成
          // "点了没反应"，所以这里如实报错；执行结果由 clearDraft 自己提示（含文档类豁免）。
          if (typeof window.pocketdeskClearDraft !== 'function') {
            message('手机页面未加载完整，请刷新后重试。', true);
            haptic([28, 50, 28]);
            return;
          }
          await window.pocketdeskClearDraft();
          return;
        }
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

const HEARTBEAT_MS = 5000;         // 正常节拍
const HEARTBEAT_RETRY_MS = 1200;   // 失败后的补拍节拍：恢复要快，不让用户空等一个 5 秒周期
let heartbeat = 0;
let heartbeatFailures = 0;  // 连续失败计数：≥2 判定断连，成功即清零
let heartbeatRetry = 0;     // 失败后的补拍定时器（同时最多一个，不叠加）
let lastContactAt = 0;      // 最近一次心跳成功的本地时刻：算中断时长，徽标显示"多久前"

// 网络层的失败必须和页面自身的脚本错误分开。两者都会落进同一个 catch，
// 但只有前者是"连接"问题；不分开的话，页面里任何一个 TypeError 都会被说成
// "与电脑断开"，把人引到查 Wi-Fi 的方向上去。
function taggedFetch(input, init) {
  return fetch(input, init).catch(error => {
    const wrapped = new Error((error && error.message) || '网络错误');
    wrapped.isNetwork = true;
    throw wrapped;
  });
}

function httpStatusError(status) {
  const error = new Error(`HTTP ${status}`);
  error.httpStatus = status;
  return error;
}

// 中断时长的人话写法：3 秒 / 1 分 12 秒 / 4 分钟。
function humanGap(ms) {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds} 秒`;
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return rest ? `${minutes} 分 ${rest} 秒` : `${minutes} 分钟`;
}

// 把失败翻译成用户能照着做的下一步。四种原因长得一模一样，解法却完全不同：
// 配对失效要重新扫码 / 手机没网要回同一 Wi-Fi / 电脑端 HTTP 卡住只需等 /
// 页面脚本出错要下拉刷新。一律说成"已断开"，等于把三件事都说成了一件。
function heartbeatAdvice(error) {
  if (error && error.httpStatus === 401) return '配对已失效：请重新扫码连接';
  if (error && error.httpStatus) {
    return `手机连得上电脑，是电脑端服务返回异常（HTTP ${error.httpStatus}）`;
  }
  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    return '手机当前没有网络：请连回与电脑同一个 Wi-Fi';
  }
  if (error && !error.isNetwork) {
    return `页面内部出错（${error.name}: ${error.message}）：这不是网络问题，下拉刷新即可`;
  }
  // 心跳打不通但控制通道还活着 = 网络没断，是电脑端 HTTP 这一路卡住了。
  const control = typeof window.pocketdeskControlState === 'function' ? window.pocketdeskControlState() : 'connecting';
  if (control !== 'connecting') return '电脑端响应超时（控制通道仍在）';
  return '手机可能不在同一 Wi-Fi，或电脑端已退出';
}

function scheduleHeartbeatRetry() {
  if (heartbeatRetry) return;
  heartbeatRetry = setTimeout(() => { heartbeatRetry = 0; heartbeatTick(); }, HEARTBEAT_RETRY_MS);
}

function cancelHeartbeatRetry() {
  if (!heartbeatRetry) return;
  clearTimeout(heartbeatRetry);
  heartbeatRetry = 0;
}

// 心跳 + 前台跟随（边沿触发）：前台命中 Dock 目标时选中态跟过去一次；
// 前台是非目标应用（如 Finder）则进入伪目标态，发送直接注入当前前台。
// 手动滑动 Dock、刚手动激活的短时间内不跟随，之后可自由手动切换。
async function heartbeatTick() {
  try {
    const paired = await taggedFetch('/api/pair', { method: 'POST', keepalive: true,
            headers: { ...authHeaders(), 'Content-Type': 'application/json' },
            body: JSON.stringify(window.pocketdeskDevice?.() || { userAgent: navigator.userAgent || '' }) });
    if (!paired.ok) throw httpStatusError(paired.status);
    const current = await taggedFetch('/api/status').then(response => response.json());
    window.pocketdeskAccessibility = current.accessibility;
    // 连接恢复：无论此前断过几次，先把顶部状态拉回真实值；中断了多久一并说清，
    // 否则用户会觉得"刚才其实没断、是页面在瞎报"。
    if (heartbeatFailures > 0) {
      const gap = lastContactAt ? Date.now() - lastContactAt : 0;
      heartbeatFailures = 0;
      cancelHeartbeatRetry();
      message(gap >= 10000 ? `已重新连接到电脑（中断 ${humanGap(gap)}）。` : '已重新连接到电脑。');
    }
    lastContactAt = Date.now();
    httpDown = false;
    lastAccessibility = current.accessibility;
    refreshConnectionBadge();
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
    // 安全连接地址随之刷新，供设置面板在开启甩送时升级到 HTTPS 触发证书信任。
    window.pocketdeskSecureURL = current.secureURL || '';
    followFrontmost(current);

  } catch (error) {
    // 连续两拍失败才改口，避免单次抖动误报；顶部状态立即反映真实值，不挂假"已就绪"。
    // 分级：刚失败按琥珀色示警（"在重试"），持续不通超过 15 秒才升红并带上具体原因——
    // 一次 Wi-Fi 唤醒抖动不该吓人，但一直不通必须说清是哪一种不通。
    heartbeatFailures++;
    const gap = lastContactAt ? Date.now() - lastContactAt : 0;
    if (heartbeatFailures >= 2) {
      httpDown = true;
      connectionEl.textContent = '未连接';
      connectionEl.classList.remove('ready', 'warn');
      const hard = gap >= 15000;
      const advice = heartbeatAdvice(error);
      message(hard ? `${advice}。已中断 ${humanGap(gap)}，轻点此处立即重试` : `${advice}，正在自动重试…`,
              hard ? true : 'warn');
    }
    scheduleHeartbeatRetry();
  }
}

function startHeartbeat(interval = HEARTBEAT_MS) {
  clearInterval(heartbeat);
  heartbeat = setInterval(heartbeatTick, interval);
}

function stopHeartbeat() {
  clearInterval(heartbeat);
  heartbeat = 0;
  cancelHeartbeatRetry();
}

// 系统层的网络事件是最准的一手信号，但只用它"提前补拍"，不跳过分级判定：
// Android 在 Wi-Fi 唤醒/切换的瞬间会先报一两秒假离线，若拿它直接甩红色报错，
// 就是从"漏报"换成了"误报"。断网原因由心跳分类器（navigator.onLine）如实说清。
for (const event of ['online', 'offline']) {
  window.addEventListener(event, () => {
    cancelHeartbeatRetry();
    heartbeatTick();
  });
}

// 断连提示本身可点：等自动重试有时要好几秒，用户想立刻恢复的那股心气应该被接住。
messageEl.addEventListener('click', () => {
  if (!httpDown && heartbeatFailures === 0) return;
  cancelHeartbeatRetry();
  heartbeatTick();
});

// 浏览器进后台不完全停摆：UU 远程分屏等场景里页面仍"可见但无焦点"，
// 完全停轮询会导致 Mac 前台切换不再同步到手机。后台降频到 15s，回前台立即补拍。
const BACKGROUND_HEARTBEAT_MS = 15000;

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    // 后台没人看屏幕，补拍没有意义：留着只会白耗电，也容易在唤醒瞬间堆积。
    cancelHeartbeatRetry();
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
    // 接收者顺序由控制台保存；读失败时退回「小精灵在前 + 应用原顺序」，不阻塞启动。
    try {
      const recipients = await fetch('/api/recipients', { headers: authHeaders() }).then(response => response.json());
      recipientOrder = Array.isArray(recipients.order) ? recipients.order : [];
    } catch { recipientOrder = []; }
    syncShortcuts(status.shortcuts || []);
    renderTargets();
    applyTheme(status.theme);
    httpDown = false;
    lastContactAt = Date.now();
    lastAccessibility = status.accessibility;
    refreshConnectionBadge();
    if (!status.accessibility) message('请先在电脑端控制台完成授权，页面仍可输入。', true);
    // 启动默认跟随真实前台；只确定接收者，不激活或移动电脑上的焦点。
    applyFrontmost(status);
    startHeartbeat();
    // 控制租约走 WS 通道：服务端易主时下行 control/auth_ok，此时立即刷新徽标，
    // 不要等到下一拍（≤5s）HTTP 心跳才发现「已就绪」是假的。
    if (typeof window.pocketdeskOnWSMessage === 'function') {
      window.pocketdeskOnWSMessage(message => {
        if (message && (message.t === 'control' || message.t === 'auth_ok')) refreshConnectionBadge();
      });
    }
    // 浏览器恢复的正文可能早于目标就绪；就绪后补齐，不等下一次手敲。
    // 小精灵正文只在手机上，发送前不进 /api/live-input（方案 §5），所以这里不能同步。
    if (textEl.value && selected !== SPRITE_ID) scheduleLive();
    // 小精灵面板：任务卡与当前网页绑定都由它自己渲染，失败不影响主流程。
    try {
      window.pocketdeskAgentPanel?.init();
      await window.pocketdeskAgent?.recoverActive();
      window.pocketdeskAgent?.fetchPage();
    } catch { /* 面板缺失只影响小精灵，不拖垮首页 */ }
    // 安全连接地址（含正确主机，无 token）：供设置面板在开启甩送时升级到 HTTPS 触发证书信任。
    window.pocketdeskSecureURL = status.secureURL || '';
    // 若刚才是从 HTTP 升级到安全连接过来的，恢复升级前留在输入框的正文。
    const preSecureDraft = localStorage.getItem('pd-draft-pre-secure');
    if (preSecureDraft) {
      try {
        localStorage.removeItem('pd-draft-pre-secure');
        if (textEl) { textEl.value = preSecureDraft; scheduleLive(); }
      } catch { /* 存储异常忽略 */ }
    }
  } catch {
    httpDown = true;
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



// 提示出口：小精灵的任务卡与客户端共用它，避免各脚本自己造一套 toast。
// 它们对缺失做了降级（静默），但这个全局本身不该缺席——所以在这里显式导出。
window.pocketdeskMessage = message;

// 下行入口：screen.js 订阅服务端推送（光标位置 / 错误 / 鉴权回执）。
