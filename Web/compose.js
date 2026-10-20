/**
 * [INPUT]: 依赖app.js的目标、草稿、历史和多图门闩，ComposeQueue、原生IME与全屏输入区。
 * [OUTPUT]: 首页/全屏共享草稿ID、全文/选区同步与图文提交；显式切目标保留内容并隔离旧轮次。
 *           回车及IME换行动作统一提交，Shift+Enter换行，组合态只确认候选；失败保留正文、附件和原ID。
 *           clearDraft先核验电脑删除再清手机；恢复仅发只读probe，确认原绑定后按公共前缀补差量。
 *           小精灵独立任务提交、历史和草稿展示；回执绑定本次票据，在提交锁释放后呈现接续状态。
 * [POS]: Web输入编排层；每次提交等待自己的结果，输入同步不能代替提交成功。
 *        画面定位失焦与真正收键盘分流，长按不改焦点；安卓IME自愈由androidInputPatch限定。
 *        发送只注册pocketdeskComposeSend；pad.js拥有pocketdeskSend，画面指令不能进入草稿提交。
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
// 服务端给结构化状态，此层给人话；冻结恢复仅探测原绑定，不重放正文。
let liveState = 'active';
let liveProbing = false;
let recoveryTimer = null;
let recoveryAttempts = 0;
let recoveryListenersAttached = false;
// 在途探测登记待续期请求，收尾补排；直接return会让恢复链断在首轮。
let recoveryPending = false;
let recoveryPendingDelay = 0;
const RECOVERY_INTERVAL = 1500;
// 1.5秒探测最多20次，耗尽后等用户回前台或重新聚焦。
const RECOVERY_MAX_ATTEMPTS = 20;
// 最近一次用户输入时间：体感发送门禁用它判断“刚说完/还在输入”时不发。
let lastInputAt = Date.now();
function pocketdeskMarkInput() { lastInputAt = Date.now(); }
let liveTimer = null;
// 显式切换/失败重选以当前电脑位置开新轮，保留正文附件，隔离旧绑定与队列。
function beginDraftForExplicitTarget(targetId, force = false) {
  if (!force && (!targetId || (targetId === selected && !livePaused))) return false;
  clearTimeout(liveTimer);
  stopRecovery();
  liveQueue.clear('已切换目标，旧目标的未发送同步已取消');
  liveQueue = makeLiveQueue();
  liveDraftId = newDraftId();
  liveMode = null;
  liveTarget = null;
  livePaused = false;
  liveFailure = '';
  liveState = 'active';
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
    if (!response.ok) {
      // 服务端把人类文案与状态码分开回；这里把状态码一并带出去，供冻结/恢复决策使用。
      const error = new Error(result.error || '同步失败');
      if (result.state) error.state = result.state;
      throw error;
    }
    if (!['replace', 'selection', 'deferred'].includes(result.mode)) throw new Error('电脑端版本较旧，请先更新 PocketDesk');
    if (command.draftId === liveDraftId) { liveMode = result.mode; liveState = result.state || 'active'; }
    return result;
  });
}
let liveQueue = makeLiveQueue();
function pushLive(text, submit = false, withImage = false, retry = false, reconcileOnFailure = false) {
  if (selected === SPRITE_ID) return Promise.resolve(null); // AI 草稿绝不进入桌面输入队列
  liveTarget ??= selected || FRONTMOST_ID;
  const command = { draftId: liveDraftId, text, submit, retry, reconcileOnFailure, usePendingImage: withImage, imageBatchId: withImage && pendingImages.length ? imageBatchId : undefined, imageIds: withImage && pendingImages.length ? pendingImages.map(item => item.id) : undefined, targetId: liveTarget, contextPromise: fullComposeOpen() ? contextPromise : null };
  const task = liveQueue.push(command).then(result => {
    if (command.draftId !== liveDraftId) return result;
    if (!command.submit && typeof result.text === 'string' && result.text !== command.text &&
        liveValue().startsWith(command.text)) {
      const merged = result.text + liveValue().slice(command.text.length);
      textEl.value = merged;
      kbProxy.value = merged;
      imePrevLen.set(textEl, merged.length);
      imePrevLen.set(kbProxy, merged.length);
    }
    if (command.retry) {
      livePaused = false; liveFailure = '';
      // 核验删除期间用户可能又输入了字，恢复后补齐最新全文。
      if (!command.submit && liveValue() !== command.text) scheduleLive();
    }
    paintLive(liveMode === 'deferred' ? 'off' : 'on', submit ? '提交动作已发出' : (liveMode === 'selection' ? '实时输入已发出' : '已同步')); return result;
  }).catch(error => {
    if (command.draftId !== liveDraftId || error.name === 'ComposeCancelledError') throw error;
    livePaused = true;
    liveState = error.state || 'interrupted';
    liveFailure = error.message;
    clearTimeout(liveTimer);
    paintLive('error', error.message);
    startRecovery();
    throw error;
  });
  return task;
}

/* ---------- 跨弹窗安全恢复：只读探测，绝不重放正文 ---------- */
// 回前台、窗口/输入框聚焦和有界轮询均只读探测，确认原绑定后才补差量。
function liveStateNote(state, fallback) {
  if (state === 'interrupted') return '输入焦点被弹窗或其它窗口打断，已冻结；回到原输入框会自动继续。';
  if (state === 'needs-user-focus') return '请在电脑上点一下原输入框即可继续；手机文字已保留。';
  if (state === 'committed') return '本轮已提交，请开始新的草稿。';
  return fallback || '同步已暂停，草稿已保留。';
}

function attachRecoveryListeners() {
  if (recoveryListenersAttached) return;
  recoveryListenersAttached = true;
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) return;
    recoveryAttempts = 0; scheduleProbe(120);
  });
  window.addEventListener('focus', () => { recoveryAttempts = 0; scheduleProbe(120); });
  // focusin 冒泡：首页框与全屏代理都覆盖，且代理被重建（recreateKbProxy）后依然有效。
  document.addEventListener('focusin', event => {
    const target = event.target;
    if (target === textEl || (target && target.id === 'kb-proxy')) { recoveryAttempts = 0; scheduleProbe(120); }
  }, true);
}

function startRecovery() {
  attachRecoveryListeners();
  recoveryAttempts = 0;
  scheduleProbe(RECOVERY_INTERVAL);
}

function stopRecovery() {
  clearTimeout(recoveryTimer);
  recoveryTimer = null;
  recoveryAttempts = 0;
  liveProbing = false;
  recoveryPending = false;
  recoveryPendingDelay = 0;
}

function scheduleProbe(delay) {
  if (!livePaused) return;
  if (recoveryAttempts >= RECOVERY_MAX_ATTEMPTS) return;
  // 在途只登记续期，由finally补排；避免并发探测，也不丢下一轮。
  if (liveProbing) { recoveryPending = true; recoveryPendingDelay = delay; return; }
  clearTimeout(recoveryTimer);
  recoveryTimer = setTimeout(() => { probeLive(); }, delay);
}

async function probeLive() {
  if (!livePaused || liveProbing || submittingDraft || !selected) return;
  liveProbing = true;
  recoveryAttempts += 1;
  try {
    const session = window.pocketdeskControlInfo?.().session || '';
    const response = await fetch('/api/live-input', {
      method: 'POST', headers: authHeaders(),
      body: JSON.stringify({
        draftId: liveDraftId, text: liveValue(), targetId: liveTarget ?? selected,
        probe: true, context: inputContext?.context, session,
      }),
    });
    const result = await response.json();
    if (!response.ok) { scheduleProbe(RECOVERY_INTERVAL); return; }
    if (result.state === 'recoverable') {
      livePaused = false; liveFailure = ''; liveState = 'active';
      stopRecovery();
      paintLive('on', '已恢复同步');
      // 恢复后不重放正文：照常走 scheduleLive，服务端按公共前缀只写差量。
      if (liveValue() !== '') scheduleLive();
    } else {
      liveState = result.state || 'interrupted';
      liveFailure = result.note || liveStateNote(liveState, liveFailure);
      paintLive('error', liveFailure);
      scheduleProbe(RECOVERY_INTERVAL);
    }
  } catch {
    scheduleProbe(RECOVERY_INTERVAL);
  } finally {
    liveProbing = false;
    // 收尾后补排：恢复成功时 stopRecovery 已经把 pending 清空，这里不会误续期。
    if (recoveryPending) {
      recoveryPending = false;
      const delay = recoveryPendingDelay || RECOVERY_INTERVAL;
      recoveryPendingDelay = 0;
      scheduleProbe(delay);
    }
  }
}

function scheduleLive(reconcileOnFailure = false) {
  syncSpriteExpression();
  if (!selected || selected === SPRITE_ID || livePaused || liveMode === 'deferred' || sendEl.disabled || submittingDraft) return;
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
// 安卓编辑会话自愈独立门禁；iOS重建焦点会导致听写重复落字。
const androidInputPatch = /Android/i.test(navigator.userAgent);
// 安卓会话卡死时重建编辑元素，保留正文/选区并重新接事件。
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
  // 焦点到手才退出触控板；pointerdown改布局会让安卓拒绝这次点按。
  let tapStart = null;
  el.addEventListener('pointerdown', event => {
    if (!androidInputPatch || event.pointerType === 'mouse') return;
    tapStart = { at: performance.now(), x: event.clientX, y: event.clientY, pointerId: event.pointerId };
  });
  el.addEventListener('pointerup', event => {
    if (!tapStart || tapStart.pointerId !== event.pointerId) return;
    const tap = tapStart;
    tapStart = null;
    // 长按属于浏览器原生选区/粘贴手势，期间绝不能 blur 或重建编辑元素。
    if (performance.now() - tap.at >= 350 || Math.hypot(event.clientX - tap.x, event.clientY - tap.y) > 8) return;
    releaseStaleFocus();
    if (document.activeElement !== el) el.focus({ preventScroll: true });
  });
  el.addEventListener('pointercancel', () => { tapStart = null; });
  el.addEventListener('focus', exitPadMode);
}
// 上一次 input 之后的长度：用来认"一次清空"这个指纹。
const imePrevLen = new WeakMap();
const composeReturnState = new WeakMap();
// 两个编辑框共用IME防御；全屏镜像读取当前首页框，隔离已移除元素。
function wireComposeIME(el, mirrorTo, recover = recoverIME) {
  const current = () => el.isConnected && el === (mirrorTo ? kbProxy : textEl);
  el.addEventListener('keydown', event => { if (current()) handleComposeSubmitKeydown(event); });
  el.addEventListener('keyup', () => { if (current()) composeReturn(el).keepLineBreak = false; });
  imePrevLen.set(el, el.value.length);
  el.addEventListener('compositionstart', () => { if (current()) liveComposing = true; });
  el.addEventListener('compositionend', () => {
    if (!current()) return;
    liveComposing = false;
    composeReturn(el).compositionReturn = false;
    pocketdeskMarkInput();
    if (mirrorTo) textEl.value = el.value;
    scheduleLive();
    // 小精灵草稿上报：听写结束后同步最新整稿（与 input 事件共用同一节流）。
    if (selected === SPRITE_ID) window.pocketdeskSpriteDraft?.();
  });
  el.addEventListener('input', event => {
    if (!current()) return;
    pocketdeskMarkInput();
    const was = imePrevLen.get(el) ?? 0;
    imePrevLen.set(el, el.value.length);
    // 没走 compositionend 就直接 input（Gboard 清空常见）→ 组合态其实已结束，强制清掉卡死标记。
    const wasComposing = liveComposing;
    if (!event.isComposing && liveComposing) liveComposing = false;
    const submitted = handleComposeSubmitInput(event, wasComposing);
    imePrevLen.set(el, el.value.length);
    // 全屏代理敲的字要同步回主页 textarea，直播同频才认得到。
    if (mirrorTo) textEl.value = el.value;
    syncSpriteExpression();
    // 小精灵草稿上报（150ms 节流 latest-only）：只做展示旁路，不影响直播同步与发送事务。
    if (selected === SPRITE_ID) window.pocketdeskSpriteDraft?.();
    if (submitted) { syncKeyboardDraft(); return; }
    // 删除沿用本轮草稿ID；空串立即排队，暂停时先核验原文。
    if (selected && !sendEl.disabled && el.value.length < was && (livePaused || el.value === '') && !submittingDraft) {
      flushLive(el.value, false, false, livePaused, true).catch(() => {});
    } else scheduleLive(el.value.length < was);
    // 安卓一次非空归零重建会话；iOS同样的操作不重建，避免听写重复。
    if (androidInputPatch && was > 0 && el.value === '') {
      recover(el);
    }
  });
  // beforeinput后700ms无input才探测会话卡死；显式提交不参加该探针。
  let editProbe = 0;
  el.addEventListener('beforeinput', event => {
    if (!current()) return;
    // 显式提交会取消换行，故意不产生 input，不能交给700ms卡死探针。
    if (handleComposeSubmitBeforeInput(event)) { clearTimeout(editProbe); return; }
    imePrevLen.set(el, el.value.length);
    clearTimeout(editProbe);
    editProbe = setTimeout(() => {
      // iOS可能延迟落字，重建焦点会让听写重复，因此不探测。
      if (androidInputPatch && el.isConnected && document.activeElement === el && !el.readOnly) recover(el);
    }, 700);
  });
  el.addEventListener('input', () => clearTimeout(editProbe));
  // 失焦/聚焦都是全新编辑会话，不该带着上一次的卡死态。
  el.addEventListener('blur', () => { clearTimeout(editProbe); composeReturnState.delete(el); endCompositionState(); });
  el.addEventListener('focus', () => {
    endCompositionState();
    // 回到已有草稿时即同步全文，不要求用户额外输入一个字来触发。
    if (el.value) scheduleLive();
  });

}
wireHomeCompose(textEl);

/* ---------- 主页输入框：安卓 Chrome 的“点了不弹键盘” ---------- */
// 安卓系统收键盘可能遗留activeElement；仅短按且视口未缩小时重新聚焦。
function keyboardExpanded() {
  const vv = window.visualViewport;
  return Boolean(vv) && vv.height < window.innerHeight - 120;
}

function releaseStaleFocus() {
  if (!androidInputPatch || submittingDraft || liveComposing) return;
  if (document.activeElement === textEl && !keyboardExpanded()) textEl.blur();
}
// 手指落在卡片内边距/空白处时原生不聚焦，这里补一次；点按钮、滑杆不抢焦点。
document.querySelector('.compose')?.addEventListener('click', event => {
  if (!androidInputPatch || submittingDraft || liveComposing) return;
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
  let touchStartedAt = 0;
  let touchReleaseTimer = 0;
  p.addEventListener('input', () => { kbGotInput = true; syncKeyboardDraft(); });
  p.addEventListener('pointerdown', event => {
    if (event.pointerType !== 'mouse') {
      clearTimeout(touchReleaseTimer);
      touchStartedAt = performance.now();
    }
  });
  p.addEventListener('pointerup', () => {
    // 某些浏览器在 pointerup 之后才交给系统显示选区菜单，短暂保留长按证据。
    touchReleaseTimer = setTimeout(() => { touchStartedAt = 0; }, 700);
  });
  p.addEventListener('pointercancel', () => { touchStartedAt = 0; clearTimeout(touchReleaseTimer); });
  // 用户收起原生键盘（返回键 / 键盘收起键）：失焦即复位，并交还布局权。
  p.addEventListener('blur', () => {
    if (kbRecreating) return;            // 重建时旧元素被移除会触发 blur，那是假失焦，跳过
    // 点屏定位的短暂blur按时间戳重聚焦；真正关闭仍交还布局。
    if ((window.pocketdeskScreenTapPending || 0) && performance.now() - window.pocketdeskScreenTapPending < 400) {
      window.pocketdeskScreenTapPending = 0;
      setTimeout(() => { if (document.activeElement !== p) p.focus({ preventScroll: true }); }, 0);
      return;
    }
    // 长按/选区的临时blur不改布局、不抢焦点，避免打断系统菜单。
    if (p.selectionStart !== p.selectionEnd || (touchStartedAt && performance.now() - touchStartedAt >= 350)) return;
    kbActive = false;
    window.pocketdeskKeyboardClosed?.(); // 让画面按真实视口重新铺一次
    syncKbToggle();
  });
  // 重建会话是 blur→focus 两步，focus 回来要把键盘态补上（blur 那边刚把它清掉）。
  p.addEventListener('focus', () => { kbActive = true; refreshKeyboardViewport(); syncKbToggle(); });
  // 回车提交由 wireComposeIME 统一处理；组合态仍交给输入法确认候选。

}
// 造一个全新的可见编辑框：自带干净的原生编辑会话。每次需要都现造，旧的整个丢弃。
function buildKbProxy() {
  const p = document.createElement('textarea');
  p.id = 'kb-proxy';
  p.className = 'kb-proxy';
  p.rows = 1;
  p.placeholder = '输入文字…';
  p.setAttribute('enterkeyhint', 'send');
  p.setAttribute('autocomplete', 'off');
  p.setAttribute('autocapitalize', 'sentences');
  p.setAttribute('spellcheck', 'false');
  p.setAttribute('aria-label', '当前输入草稿');
  // 代理须在panel内部，否则原生全屏不渲染它，也无法弹键盘。
  document.querySelector('#screen-compose-editor').appendChild(p);
  wireComposeIME(p, true, recreateKbProxy);
  wireKbProxyExtras(p);
  return p;
}
// 原生编辑会话卡死时替换代理，保持草稿、选区和所在面板。
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
// 唤起带入首页草稿；疑似死会话才重建，正常聚焦不闪动键盘。
const CONTEXT_RETRY_LIMIT = 3;
const CONTEXT_RETRY_DELAY = 250;
// 提交后Electron重建编辑器时有界等待AX输入位置；耗尽后要求人工确认。
function refreshInputContext() {
  const session = window.pocketdeskControlInfo().session;
  const attempt = remaining => fetch('/api/input-context', {
    headers: { ...authHeaders(), 'X-PocketDesk-Session': session }, cache: 'no-store',
  }).then(async response => {
    const context = await response.json();
    if (!response.ok || !context.context) throw new Error(context.error || '无法确定输入位置');
    if (context.scope === 'application' && remaining > 0) {
      await new Promise(resolve => setTimeout(resolve, CONTEXT_RETRY_DELAY));
      return attempt(remaining - 1);
    }
    context.session = session;
    inputContext = context;
    kbProxy.setAttribute('aria-label', '输入到：' + context.name);
    if (context.scope === 'application') paintLive('error', '请先确认电脑上的输入框');
    return context;
  });
  contextPromise = attempt(CONTEXT_RETRY_LIMIT);
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
// 收键盘只交出焦点、不清正文；下一次唤起从首页草稿恢复。
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
// 全屏键盘图标是显式唤起入口；点画面不弹键盘，退出统一收起。
  const kbToggle = document.getElementById('kb-toggle');
  if (kbToggle) {
    // pointerdown快照开关意图，避免按钮引发blur后把关闭误判为打开。
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
// 草稿提交与pad.js的画面指令使用独立全局入口，共用各自的业务锁。
// 小精灵只聚焦草稿，不取桌面上下文、不触发live-input。
window.pocketdeskFocusCompose = () => {
  const el = fullComposeOpen() ? kbProxy : textEl;
  el.readOnly = false;
  el.focus({ preventScroll: true });
};
// 小精灵正文只交任务API；按钮和甩送复用同一提交锁。
async function sendToSprite() {
  if (submittingDraft) return;
  if (liveComposing) { message('请先结束听写或确认输入法候选，再发送。', true); return; }
  const submittedDraftId = liveDraftId;
  let spriteSubmission;
  submittingDraft = true;
  sendEl.disabled = true;
  textEl.readOnly = true; kbProxy.readOnly = true;
  clearTimeout(liveTimer);   // 这一轮不属于电脑输入框，不得触发任何同步
  try {
    const raw = liveValue();
    textEl.value = raw;
    const text = raw.trim();
    if (!text) throw new Error('先输入一点想让小精灵做的事。');
    const agent = window.pocketdeskAgent;
    if (!agent) throw new Error('小精灵组件还没加载好，请刷新页面重试。');
    // 提交在途即上报：Mac 面板显示「正在提交」，草稿保留；不提前写已接收。
    spriteSubmission = window.pocketdeskSpriteSubmitting?.(text);
    // 终态不依赖“新任务”按钮；待补充才继续旧任务。
    const task = await agent.send(text);
    // 服务端已持久接收：回执给 Mac 投影任务事实；版本匹配的清空只清本轮正文。
    window.pocketdeskSpriteSubmitted?.(task?.task?.id || task?.id, spriteSubmission);
    // 历史表示小精灵已接收，不等待下游任务完成；接收者固定，避免迟到回执记到切换后的应用。
    let historyNote = '';
    try { pushHistory(text, '小精灵'); }
    catch { historyNote = '已交给小精灵，但本机历史未能保存。'; }
    // 服务端确认持久接收后才清草稿；失败时正文保留，让人看清原因再决定（方案 §5）。
    if (selected === SPRITE_ID && liveDraftId === submittedDraftId) {
      clearCompose({ preserveImages: true });
    }
    if (historyNote) message(historyNote, 'warn');
    haptic([12]);
  } catch (error) {
    // 提交失败：Mac 面板结束「正在提交」，草稿继续保留展示。
    window.pocketdeskSpriteSubmitFailed?.(spriteSubmission);
    message(error.message, true);
    haptic([28, 50, 28]);
  } finally {
    submittingDraft = false;
    sendEl.disabled = false;
    textEl.readOnly = false; kbProxy.readOnly = false;
    window.pocketdeskAgentPanel?.render();
  }
}

window.pocketdeskComposeSend = send;
window.pocketdeskInputSettled = (ms = 300) => Date.now() - lastInputAt >= ms;
window.pocketdeskHasDraft = () => Boolean(textEl.value || pendingImages.length);
window.pocketdeskCanMotionSend = ({ requireSettled = true } = {}) => {
  if (!selected || sendEl.disabled || submittingDraft || liveComposing) return false;
  // 中断冻结中、恢复探测进行中、上一轮提交收尾中，一律不发：迟到候选不得提交新一轮草稿。
  if (selected === SPRITE_ID) {
    const task = window.pocketdeskAgent?.current();
    if (!liveValue().trim() || (window.pocketdeskAgent?.isActive() && task?.status !== 'needsInput')) return false;
  } else if (livePaused || liveProbing) return false;
  // 300ms稳定门禁覆盖说完即翻腕；动作采集可提前，实际提交仍须稳定。
  if (requireSettled && !(window.pocketdeskInputSettled && window.pocketdeskInputSettled(300))) return false; // 仍在输入/听写中
  return true;
};

function clearCompose({ preserveImages = false } = {}) {
  const keyboardFocused = document.activeElement === kbProxy;
  stopRecovery();
  liveDraftId = newDraftId(); liveMode = null; liveTarget = null; livePaused = false;
  liveFailure = '';
  liveState = 'active';
  textEl.value = '';
  kbProxy.value = '';
  syncSpriteExpression();
  // 提交封闭本轮原生编辑会话，旧输入法迟到的候选/input 不能把已发送文字填回来。
  textEl.readOnly = false; kbProxy.readOnly = false;
  recoverIME(textEl);
  recreateKbProxy(kbProxy, { focus: keyboardFocused, feedback: false });
  clearTimeout(liveTimer);
  liveQueue.clear('本次输入已结束');
  paintLive('off');
  if (!preserveImages) {
    imageGeneration += 1; pendingImages = []; imageBatchId = newImageId(); imagePreparationError = null;
  }
  renderPendingImages();
}

async function send() {
  if (sendEl.disabled || submittingDraft) return;
  if (!selected) {
    message('请先在上方 Dock 选择一个目标应用。', true);
    return;
  }
  // 内置接收者不进电脑输入链路：小精灵有自己完全独立的一条路径。
  if (selected === SPRITE_ID) return sendToSprite();
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
    // 同频失败保留原稿供核对，不回退整段粘贴，避免重复半段正文。
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
// 清空先由电脑确认删除，再清手机；文档类豁免由服务端回执说明。
async function clearDraft() {
  if (submittingDraft) { message('正在提交，请稍后再清空。', true); return false; }
  if (!selected || sendEl.disabled) { message('请先在上方 Dock 选择一个目标应用。', true); return false; }
  clearTimeout(liveTimer);
  try {
    const session = window.pocketdeskControlInfo?.().session || '';
    const response = await fetch('/api/live-input', {
      method: 'POST', headers: authHeaders(),
      // clear 是显式意图，不能靠"text 恰好为空"表达：空串只是结果，清空是一次幂等写入。
      body: JSON.stringify({ draftId: liveDraftId, text: '', clear: true, targetId: liveTarget ?? selected,
                             context: inputContext?.context, session }),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      message(result.error || '未能确认电脑已清空；手机草稿已保留。', true);
      haptic([28, 50, 28]);
      return false;
    }
    // 电脑侧有了结论才动手机：换新草稿身份、清附件与输入框，冻结态一并解除。
    clearCompose();
    message(result.note || '已清空。');
    haptic([12]);
    return true;
  } catch {
    message('无法连接本机服务；手机草稿已保留。', true);
    haptic([28, 50, 28]);
    return false;
  }
}
window.pocketdeskClearDraft = clearDraft;

sendEl.addEventListener('click', send);
/* ---------- 显式回车：桌面键盘与只派发输入事件的手机IME共用提交锁 ---------- */
function composeReturn(el) {
  if (!composeReturnState.has(el)) composeReturnState.set(el, {});
  return composeReturnState.get(el);
}
function submitComposeReturn() { return fullComposeOpen() ? sendFromKeyboard() : send(); }
function handleComposeSubmitKeydown(event) {
  const state = composeReturn(event.currentTarget);
  state.keepLineBreak = event.key === 'Enter' && event.shiftKey;
  state.compositionReturn = event.key === 'Enter' && (event.isComposing || liveComposing);
  if (event.key !== 'Enter' || state.keepLineBreak || state.compositionReturn || event.keyCode === 229) return;
  event.preventDefault();
  if (!event.repeat) submitComposeReturn();
}
function handleComposeSubmitBeforeInput(event) {
  const el = event.currentTarget, state = composeReturn(el);
  state.beforeLineBreak = null; state.compositionLineBreak = false;
  if (!['insertLineBreak', 'insertParagraph'].includes(event.inputType)) return false;
  if (event.isComposing || liveComposing) { state.compositionLineBreak = true; return false; }
  if (state.keepLineBreak || state.compositionReturn) return false;
  if (!event.cancelable) {
    state.beforeLineBreak = { value: el.value, start: el.selectionStart, end: el.selectionEnd };
    return false;
  }
  event.preventDefault(); submitComposeReturn(); return true;
}
function handleComposeSubmitInput(event, wasComposing = false) {
  const el = event.currentTarget, state = composeReturn(el), before = state.beforeLineBreak;
  const keepLineBreak = state.keepLineBreak || state.compositionReturn || state.compositionLineBreak;
  state.beforeLineBreak = null; state.keepLineBreak = false; state.compositionReturn = false; state.compositionLineBreak = false;
  if (!['insertLineBreak', 'insertParagraph'].includes(event.inputType) || event.isComposing || wasComposing || keepLineBreak) return false;
  // 不可取消或缺失beforeinput时，只撤回本次动作插入的换行，保留已有多行正文。
  if (before && el.value === before.value.slice(0, before.start) + '\n' + before.value.slice(before.end)) {
    el.value = before.value; el.setSelectionRange(before.start, before.end);
  } else {
    const at = el.selectionStart;
    if (el.selectionEnd !== at || el.value[at - 1] !== '\n') return false;
    el.value = el.value.slice(0, at - 1) + el.value.slice(at); el.setSelectionRange(at - 1, at - 1);
  }
  submitComposeReturn(); return true;
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
