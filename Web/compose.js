/**
 * [INPUT]: 依赖 app.js 的草稿/目标/历史与多图处理门闩、ComposeQueue、原生 IME、全屏输入区。
 * [OUTPUT]: 提供可见输入栏、手机全文同步与图文提交；发送等待图片处理、补传完整批次并冻结附件编辑，失败保留草稿及附件；用户显式切换目标时保留内容并开启隔离的新草稿轮次。
 * [POS]: Web 输入编排层；每次提交等待自己的完成结果，不用同步成功代替提交成功。
 *        手机侧同时兜住安卓 Chrome 的两处“点输入框不弹键盘”：键盘被收起后残留焦点的
 *        再聚焦，以及点在内边距/空白处时的补聚焦；均只作用于粗指针设备。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/* ---------- 草稿快照：通用应用持续实时同步，特殊远控才暂存 ---------- */
const LIVE_DEBOUNCE = 90;
const liveFlagEl = document.querySelector('#live-flag');
let liveComposing = false;
// 选区可能是用户选中的正文，不能拿它猜输入法候选并从全文里剔除。
function liveValue() { return (fullComposeOpen() ? kbProxy : textEl).value; }
const newDraftId = () => Date.now().toString(36) + '-' + Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(36)).join('-');
let liveDraftId = newDraftId();
let liveMode = null;
let liveTarget = null;
let livePaused = false;
let liveFailure = '';
let submittingDraft = false;

// 最近一次用户输入时间：体感发送门禁用它判断“刚说完/还在输入”时不发。
let lastInputAt = Date.now();
function pocketdeskMarkInput() { lastInputAt = Date.now(); }

let liveTimer = null;

// 切换目标或失败后重选当前应用，都以电脑此刻的前台与输入位置开始新一轮；
// 正文与附件仍保留，旧失败/执行状态及队列不得穿越目标。
function beginDraftForExplicitTarget(targetId) {
  if (!targetId || (targetId === selected && !livePaused)) return false;
  clearTimeout(liveTimer);
  liveQueue.clear('已切换目标，旧目标的未发送同步已取消');
  liveQueue = makeLiveQueue();
  liveDraftId = newDraftId();
  liveMode = null;
  liveTarget = null;
  livePaused = false;
  liveFailure = '';
  inputContext = null;
  contextPromise = null;
  paintLive('off');
  return true;
}

function currentTargetName() {
  if (selected === FRONTMOST_ID) return frontmostLabel || '当前前台';
  return (targets.find(item => item.id === selected) || { name: selected }).name;
}

// state: off / on / error
function paintLive(state, note) {
  if (livePaused && liveFailure) { state = 'error'; note = liveFailure; }
  const noteEl = document.querySelector('#screen-input-status');
  if (noteEl) {
    noteEl.textContent = state === 'error' ? note || '' : '';
    noteEl.hidden = !noteEl.textContent;
  }
  syncKeyboardDraft();
  if (!liveFlagEl) return;
  if (state === 'off') { liveFlagEl.hidden = true; return; }
  liveFlagEl.hidden = false;
  liveFlagEl.dataset.state = state;
  liveFlagEl.textContent = note || '';
}

const fullComposeOpen = () => !document.querySelector('#screen-compose').hidden;
let inputContext = null;
let contextPromise = null;
function makeLiveQueue() {
  return new ComposeQueue(async command => {
    if (command.contextPromise) {
      const binding = await command.contextPromise;
      command = { ...command, context: binding.context, session: binding.session };
    }
    if (window.pocketdeskScreenCanInput && command.contextPromise && !window.pocketdeskScreenCanInput()) throw new Error('画面或控制尚未就绪，草稿已保留');
    const response = await fetch('/api/live-input', {
      method: 'POST', headers: authHeaders(),
      body: JSON.stringify({ draftId: command.draftId, expectedMode: liveMode, text: command.text, submit: command.submit, retry: command.retry, usePendingImage: command.usePendingImage, imageBatchId: command.imageBatchId, imageIds: command.imageIds, targetId: command.targetId, context: command.context, session: command.session }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || '同步失败');
    if (!['replace', 'selection', 'deferred'].includes(result.mode)) throw new Error('电脑端版本较旧，请先更新 PocketDesk');
    if (command.draftId === liveDraftId) liveMode = result.mode;
    return result;
  });
}
let liveQueue = makeLiveQueue();
function pushLive(text, submit = false, withImage = false, retry = false, reconcileOnFailure = false) {
  liveTarget ??= selected || FRONTMOST_ID;
  const command = { draftId: liveDraftId, text, submit, retry, reconcileOnFailure, usePendingImage: withImage, imageBatchId: withImage && pendingImages.length ? imageBatchId : undefined, imageIds: withImage && pendingImages.length ? pendingImages.map(item => item.id) : undefined, targetId: liveTarget, contextPromise: fullComposeOpen() ? contextPromise : null };
  const task = liveQueue.push(command).then(result => {
    if (command.draftId !== liveDraftId) return result;
    if (command.retry) {
      livePaused = false; liveFailure = '';
      // 核验删除期间用户可能又输入了字，恢复后补齐最新全文。
      if (!command.submit && liveValue() !== command.text) scheduleLive();
    }
    paintLive(liveMode === 'deferred' ? 'off' : 'on', submit ? '提交动作已发出' : (liveMode === 'selection' ? '实时输入已发出' : '已同步')); return result;
  }).catch(error => {
    if (command.draftId !== liveDraftId) throw error;
    livePaused = true;
    liveFailure ||= error.message;
    clearTimeout(liveTimer);
    paintLive('error', error.message); throw error;
  });
  return task;
}

function scheduleLive(reconcileOnFailure = false) {
  if (!selected || livePaused || liveMode === 'deferred' || sendEl.disabled || submittingDraft) return;
  clearTimeout(liveTimer);
  liveTimer = setTimeout(() => {
    if (!livePaused && liveMode !== 'deferred' && !submittingDraft) pushLive(liveValue(), false, false, false, reconcileOnFailure).catch(() => {});
  }, LIVE_DEBOUNCE);
}

// 发送前立刻把最新全文推过去：不等 debounce，否则最后一个字可能还没同步就按了回车。
function flushLive(text, submit = false, withImage = false, retry = false, reconcileOnFailure = false) {
  clearTimeout(liveTimer);
  return pushLive(text, submit, withImage, retry, reconcileOnFailure);
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
  if (el !== textEl || !el.isConnected || el.readOnly) return;
  const focused = document.activeElement === el;
  const replacement = el.cloneNode(false);
  replacement.value = el.value;
  const start = el.selectionStart, end = el.selectionEnd;
  liveComposing = false;
  el.blur();
  el.replaceWith(replacement);
  textEl = replacement;
  wireHomeCompose(textEl);
  textEl.setSelectionRange(start, end);
  // 同步聚焦保留本次用户手势；不在下一帧抢回用户已切走的焦点。
  if (focused) textEl.focus({ preventScroll: true });
}

function wireHomeCompose(el) {
  wireComposeIME(el, false);
  // 退出触控板模式只在 focus 上做：原先在 pointerdown 里同步摘掉 pad-mode，会让输入框
  // 在这一次点按**还没结束时就**从 52px 撑回 140px；安卓会因此把这一下判成无效点按，
  // 焦点拿不到、键盘也不弹。焦点到手后再变布局就与手势无关了。
  el.addEventListener('pointerdown', releaseStaleFocus);
  el.addEventListener('focus', exitPadMode);
  el.addEventListener('keydown', handleHomeComposeKeydown);
}

// 上一次 input 之后的长度：用来认"一次清空"这个指纹。
const imePrevLen = new WeakMap();

// 任一输入框（主页 textarea 或全屏键盘代理）都接同一套卡死防御；
// 全屏代理的改动要镜像回主页 textarea，因为直播同步的"真值"始终读 textEl。
// 首页与全屏都替换故障元素；镜像在事件触发时读取当前 textEl，避免引用已移除的首页框。
function wireComposeIME(el, mirrorTo, recover = recoverIME) {
  const current = () => el.isConnected && el === (mirrorTo ? kbProxy : textEl);
  imePrevLen.set(el, el.value.length);
  el.addEventListener('compositionstart', () => { if (current()) liveComposing = true; });
  el.addEventListener('compositionend', () => {
    if (!current()) return;
    liveComposing = false;
    pocketdeskMarkInput();
    if (mirrorTo) textEl.value = el.value;
    scheduleLive();
  });
  el.addEventListener('input', event => {
    if (!current()) return;
    pocketdeskMarkInput();
    const was = imePrevLen.get(el) ?? 0;
    imePrevLen.set(el, el.value.length);
    // 没走 compositionend 就直接 input（Gboard 清空常见）→ 组合态其实已结束，强制清掉卡死标记。
    if (!event.isComposing && liveComposing) liveComposing = false;
    // 全屏代理敲的字要同步回主页 textarea，直播同频才认得到。
    if (mirrorTo) textEl.value = el.value;
    // 删除仍属于本轮草稿。空串立即排队；暂停时先核验原文，
    // 不丢弃草稿 ID，否则电脑残文会变成下一轮无法管理的“原文”。
    if (selected && !sendEl.disabled && el.value.length < was && (livePaused || el.value === '') && !submittingDraft) {
      flushLive(el.value, false, false, livePaused, true).catch(() => {});
    } else scheduleLive(el.value.length < was);
    // 「上滑清空」指纹：一次 input 就从非空一步归零（退格是一格一格删，不会一步清空）。
    // 命中即重建——**不论是否处于组合态**，这正是以前漏掉 Gboard 的原因。
    if (was > 0 && el.value === '') {
      recover(el);
    }
  });
  // 兜底：会话死透时连 input 都不派发（渲染进程与 IME 失联，敲字完全没反应）。
  // beforeinput 到了却迟迟不见 input = 这次编辑没被吃进去，同样重建会话。
  // 代价极小的误伤：在空框上按退格本来也不出 input，会白重建一次会话（无感）。
  let editProbe = 0;
  el.addEventListener('beforeinput', () => {
    if (!current()) return;
    imePrevLen.set(el, el.value.length);
    clearTimeout(editProbe);
    editProbe = setTimeout(() => {
      if (el.isConnected && document.activeElement === el && !el.readOnly) recover(el);
    }, 700);
  });
  el.addEventListener('input', () => clearTimeout(editProbe));
  // 失焦/聚焦都是全新编辑会话，不该带着上一次的卡死态。
  el.addEventListener('blur', () => { clearTimeout(editProbe); endCompositionState(); });
  el.addEventListener('focus', () => {
    endCompositionState();
    // 回到已有草稿时即同步全文，不要求用户额外输入一个字来触发。
    if (el.value) scheduleLive();
  });

}
wireHomeCompose(textEl);

/* ---------- 主页输入框：安卓 Chrome 的“点了不弹键盘” ---------- */

// 键盘被系统返回键/返回手势收走后，textarea 往往**仍然是 activeElement**；焦点没有变化，
// Chrome 就不会再弹一次键盘——这时再点多少下都没反应。在 pointerdown 阶段先交还焦点
// （不动内容与光标），随后这一次原生点按就是真正的焦点变化，键盘随之回来。
// 键盘正开着时绝不动焦点：用户点正文是去挪光标的。
// 键盘弹起时 Chrome 只收“视觉视口”，window.innerHeight 不变；落差 >120px 即视为键盘已展开。
const coarsePointer = window.matchMedia?.('(pointer: coarse)').matches === true;

function keyboardExpanded() {
  const vv = window.visualViewport;
  return Boolean(vv) && vv.height < window.innerHeight - 120;
}

function releaseStaleFocus() {
  if (!coarsePointer || submittingDraft) return;
  if (document.activeElement === textEl && !keyboardExpanded()) textEl.blur();
}

// 手指落在卡片内边距/空白处时原生不聚焦，这里补一次；点按钮、滑杆不抢焦点。
document.querySelector('.compose')?.addEventListener('click', event => {
  if (submittingDraft) return;
  if (document.activeElement === textEl) return;
  if (event.target.closest('button, select, a, label, input')) return;
  textEl.focus({ preventScroll: true });
});
// 浏览器在返回页面时可能恢复已有正文而不派发 input；首次目标未就绪由 boot 补齐。
window.addEventListener('pageshow', () => { if (liveValue()) scheduleLive(); });

/* ---------- 全屏可见编辑区：与首页共用草稿与提交队列 ---------- */
// IME 异常时重建 textarea，保留草稿与所在面板，不改变电脑输入目标。
wireComposeIME(kbProxy, true, recreateKbProxy);
wireKbProxyExtras(kbProxy);   // 初始代理也要接 blur/focus/keydown（recreate 出来的同样接这一份）

// 这一轮会话里代理有没有真的吃到过字 / 是否怀疑会话已死 / 是否正在重建中。
let kbGotInput = false;
let kbSuspect = false;     // 上滑清空或 beforeinput 超时没回 input → 代理可能已死
let kbRecreating = false; // 重建期间抑制 blur 误触发 pocketdeskKeyboardClosed（避免重建瞬间画面闪一下重排）

// 键盘图标高亮态：键盘抬起=高亮，收起=灭。
function syncKbToggle() {
  const el = document.getElementById('kb-toggle');
  if (el) { el.classList.toggle('kb-active', kbActive); el.setAttribute('aria-pressed', String(kbActive)); }
  if (screenViewEl) screenViewEl.classList.toggle('keyboard-open', kbActive);
}

// 草稿编辑框的"会话外"监听：失焦复位、聚焦更新视口。初始与 recreate 出来的都接这一份。
function wireKbProxyExtras(p) {
  p.addEventListener('input', () => { kbGotInput = true; syncKeyboardDraft(); });
  // 用户收起原生键盘（返回键 / 键盘收起键）：失焦即复位，并交还布局权。
  p.addEventListener('blur', () => {
    if (kbRecreating) return;            // 重建时旧元素被移除会触发 blur，那是假失焦，跳过
    kbActive = false;
    window.pocketdeskKeyboardClosed?.(); // 让画面按真实视口重新铺一次
    syncKbToggle();
  });
  // 重建会话是 blur→focus 两步，focus 回来要把键盘态补上（blur 那边刚把它清掉）。
  p.addEventListener('focus', () => { kbActive = true; refreshKeyboardViewport(); syncKbToggle(); });
  // 原生回车交给输入法插入换行；提交使用底栏发送，不抢候选确认键。

}

// 造一个全新的可见编辑框：自带干净的原生编辑会话。每次需要都现造，旧的整个丢弃。
function buildKbProxy() {
  const p = document.createElement('textarea');
  p.id = 'kb-proxy';
  p.className = 'kb-proxy';
  p.rows = 1;
  p.placeholder = '输入文字…';
  p.setAttribute('enterkeyhint', 'enter');
  p.setAttribute('autocomplete', 'off');
  p.setAttribute('autocapitalize', 'sentences');
  p.setAttribute('spellcheck', 'false');
  p.setAttribute('aria-label', '当前输入草稿');
  // 放进 #screen-view 内部：进原生全屏（requestFullscreen）后整份文档只剩 panel，
  // 代理若挂在外面会随文档一起不渲染、键盘弹不出来。
  document.querySelector('#screen-compose-editor').appendChild(p);
  wireComposeIME(p, true, recreateKbProxy);
  wireKbProxyExtras(p);
  return p;
}

// 卡死自愈的终极手段：整个换掉代理元素。被 wireComposeIME 在检测到「上滑清空指纹」
// （一次 input 从非空一步归零）或「beforeinput 后迟迟没 input」时调用；
// 也被 showKeyboard 在「代理仍聚焦却一个字都没收到」这种明显死透的情况下调用。
// 全新元素 = 全新原生编辑会话，这是唯一能甩掉 Gboard 污点、不必刷新整页的办法。
function recreateKbProxy(el = kbProxy, { focus = true, feedback = true } = {}) {
  if (el !== kbProxy || !el.isConnected || el.readOnly) return;
  liveComposing = false;
  kbRecreating = true;
  if (kbProxy && kbProxy.isConnected) kbProxy.remove();
  kbProxy = buildKbProxy();
  kbProxy.value = textEl.value;
  syncKeyboardDraft();
  imePrevLen.set(kbProxy, kbProxy.value.length);   // 重新播种，别把旧长度当"一次清空"的指纹
  kbActive = focus;
  kbGotInput = false;
  kbSuspect = false;
  if (focus) kbProxy.focus({ preventScroll: true });
  // 键盘动画结束后补测视口，兼容延迟更新可见区域的浏览器。
  [0, 60, 150, 300].forEach(delay => setTimeout(refreshKeyboardViewport, delay));
  kbRecreating = false;
  syncKbToggle();
  if (feedback) haptic(8);
}

// 原生键盘动画可能分多次更新可见视口；让工作台跟随布局，不与 Safari 的焦点滚动反复争抢。
let kbActive = false;

function refreshKeyboardViewport() {
  if (!kbActive) return;
  window.pocketdeskKeyboardClosed?.();
}
window.addEventListener('scroll', refreshKeyboardViewport, { passive: true });

// 唤起原生键盘：把主页草稿带过来，聚焦即弹键盘。
// 关键点：Gboard「上滑清空」会让代理**仍聚焦却已死透**（敲字不出 input）。这种情况
// blur→focus 同元素在部分 Android WebView 上对 Gboard 无效，必须整个换元素。
// 所以只要「仍聚焦且本轮没收到过字」或已打上 kbSuspect 标记，就直接 recreateKbProxy()
// 换新元素——这是唯一能甩掉污点、不必刷新整页的办法。
function refreshInputContext() {
  const session = window.pocketdeskControlInfo().session;
  contextPromise = fetch('/api/input-context', { headers: { ...authHeaders(), 'X-PocketDesk-Session': session }, cache: 'no-store' }).then(async response => {
    const context = await response.json();
    if (!response.ok || !context.context) throw new Error(context.error || '无法确定输入位置');
    context.session = session;
    inputContext = context;
    kbProxy.setAttribute('aria-label', '输入到：' + context.name);
    if (context.scope === 'application') paintLive('error', '请先确认电脑上的输入框');
    return context;
  });
  contextPromise.catch(error => paintLive('error', error.message));
  return contextPromise;
}

function showKeyboard() {
  if (window.pocketdeskScreenCanInput && !window.pocketdeskScreenCanInput()) { message(window.pocketdeskScreenInputReason?.() || '正在连接电脑，请稍候', true); return; }
  document.querySelector('#screen-compose').hidden = false;
  kbProxy.value = textEl.value;
  syncKeyboardDraft(); window.pocketdeskKeyboardClosed?.();
  const shouldSyncExistingDraft = Boolean(textEl.value);
  paintLive('off');
  if (!kbActive) liveQueue.clear();
  refreshInputContext();

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
  [0, 60, 150, 300].forEach(delay => setTimeout(refreshKeyboardViewport, delay));
  if (shouldSyncExistingDraft && kbProxy.value) scheduleLive();
  haptic(8);
}

// 收起：只需交出焦点，键盘自己会落下。
// 刻意**不清 value**——代理只是草稿的暂存副本，下次唤起一律用 textEl 重新播种；
// 清了反而可能在 IME 自愈（recreate）后把真值覆盖成空。
function hideKeyboard() {
  clearTimeout(liveTimer); liveQueue.clear('键盘已收起，未发送的草稿已保留');
  kbActive = false;
  document.querySelector('#screen-compose').hidden = true;
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
// 关闭 / 退出全屏 → hideKeyboard；视口变化由工作台重新布局。
  const kbToggle = document.getElementById('kb-toggle');
  if (kbToggle) {
    // 关键：在 pointerdown 时就快照 kbActive，再决定 click 时开还是关。
    // 否则点按钮会让 #kb-proxy 失焦 → blur 先把 kbActive 翻成 false，
    // 随后 click 里读到 false 反而去 showKeyboard() —— 表现成"再点一下收不起、高亮消不掉"。
    let kbToggleWasActive = false;
    kbToggle.addEventListener('pointerdown', () => { kbToggleWasActive = fullComposeOpen(); });
    kbToggle.addEventListener('click', event => {
      event.stopPropagation();   // 防穿透；closest('button') 已让 panel 拖动跳过它
      if (kbToggleWasActive) hideKeyboard(); else showKeyboard();
      kbToggleWasActive = false;
    });
  }
window.pocketdeskShowKeyboard = showKeyboard;
window.pocketdeskHideKeyboard = hideKeyboard;
window.pocketdeskKeyboardActive = () => fullComposeOpen();

// 体感发送门禁与触发入口（motion-send.js 委托至此，不重复实现发送逻辑）。
window.pocketdeskSend = send;
window.pocketdeskInputSettled = (ms = 700) => Date.now() - lastInputAt >= ms;
window.pocketdeskHasDraft = () => Boolean(textEl.value || pendingImages.length);
window.pocketdeskCanMotionSend = () => {
  if (!selected || sendEl.disabled || submittingDraft || liveComposing) return false;
  if (!(window.pocketdeskInputSettled && window.pocketdeskInputSettled(700))) return false; // 仍在输入/听写中
  return true;
};

function clearCompose() {
  const keyboardFocused = document.activeElement === kbProxy;
  liveDraftId = newDraftId(); liveMode = null; liveTarget = null; livePaused = false;
  liveFailure = '';
  textEl.value = '';
  kbProxy.value = '';
  // 提交封闭本轮原生编辑会话，旧输入法迟到的候选/input 不能把已发送文字填回来。
  textEl.readOnly = false; kbProxy.readOnly = false;
  recoverIME(textEl);
  recreateKbProxy(kbProxy, { focus: keyboardFocused, feedback: false });
  clearTimeout(liveTimer);
  liveQueue.clear('本次输入已结束');
  paintLive('off');
  imageGeneration += 1; pendingImages = []; imageBatchId = newImageId(); imagePreparationError = null;
  renderPendingImages();
}

async function send() {
  if (sendEl.disabled || submittingDraft) return;
  if (!selected) {
    message('请先在上方 Dock 选择一个目标应用。', true);
    return;
  }
  if (liveComposing) { message('请先结束听写或确认输入法候选，再发送。', true); return; }
  submittingDraft = true;
  sendEl.disabled = true;
  textEl.readOnly = true; kbProxy.readOnly = true;
  document.querySelector('#screen-send').disabled = true;
  imageBtn.disabled = true; imageFile.disabled = true;
  imagePreview.querySelectorAll('button').forEach(button => { button.disabled = true; });
  clearTimeout(liveTimer);
  try {
    message('正在处理待发送内容…');
    await imagePreparation;
    if (imagePreparationError) throw imagePreparationError;
    // 等附件稳定后读取完整草稿，避免纯图片仍在压缩时被误判为空。
    const raw = liveValue();
    textEl.value = raw;
    const text = raw.trim();
    if (!text && !pendingImages.length) throw new Error('先输入一点内容或选择一张图片。');
    exitPadMode();
    const retry = livePaused;
    if (retry && fullComposeOpen()) refreshInputContext();
    message(retry ? '正在核对原输入框并重试…' : liveMode === 'replace' || liveMode === 'selection' ? '正在提交…' : '正在输入最终文本…');
    if (pendingImages.length) await uploadPendingImages();
    const result = await flushLive(raw, true, pendingImages.length > 0, retry);
    if (result.committed === true || result.outcome !== 'sent') clearCompose();
    // 提交收尾不能被历史存储配额/隐私模式阻断，更不能因此提示用户重新发送。
    let historyNote = '';
    try { pushHistory(text || '[图片]', currentTargetName()); }
    catch { historyNote = '（本机历史未能保存）'; }
    // committed 只确认本轮动作执行过；sent 仍不声称第三方消息已送达。
    if (result.outcome === 'sent') {
      message((result.detail || '已发送，未能确认是否生效。') + historyNote, 'warn');
      haptic([22]);
    } else {
      message((result.detail || '已发送。') + historyNote);
      haptic([12]);
    }
  } catch (error) {
    // 同频失败时不回退到整段粘贴：内容可能已经打进去一半，再粘一遍就成了重复。
    // 输入框原样保留，用户看清原因后可以自己重试。
    message(error.message, true);
    haptic([28, 50, 28]);
  } finally {
    submittingDraft = false;
    sendEl.disabled = false;
    textEl.readOnly = false; kbProxy.readOnly = false;
    document.querySelector('#screen-send').disabled = false;
    imageBtn.disabled = false; imageFile.disabled = false;
    imagePreview.querySelectorAll('button').forEach(button => { button.disabled = false; });
  }
}

sendEl.addEventListener('click', send);
function handleHomeComposeKeydown(event) {
  // 中文/日文输入法在选词、候选期间按回车是给 IME 用的，不能当成“发送”。
  if (event.isComposing || event.keyCode === 229) return;
  if (event.key === 'Enter' && !event.shiftKey) {
    event.preventDefault();
    send();
  }
}


document.querySelector('#screen-compose').addEventListener('pointerdown', event => {
  if (event.target.closest('button')) event.preventDefault();
});
document.querySelector('#screen-send').addEventListener('click', sendFromKeyboard);
document.querySelector('#screen-keyboard-close').addEventListener('click', hideKeyboard);
/* ---------- 原生输入法：编辑框始终可见，发送按需出现 ---------- */
function syncKeyboardDraft() {
  const hasDraft = Boolean(textEl.value || pendingImages.length);
  document.querySelector('#screen-send').hidden = !hasDraft;
  document.querySelector('#screen-send').setAttribute('aria-label', livePaused ? '核对原输入框并重试' : '发送文字');
  // 保留原生选区与内部滚动；短句一行，长文最多三行，避免挤掉电脑画面。
  if (fullComposeOpen()) {
    kbProxy.style.height = '44px';
    kbProxy.style.height = `${Math.min(88, Math.max(44, kbProxy.scrollHeight + 2))}px`;
  }
}
