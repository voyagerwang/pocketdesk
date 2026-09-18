/**
 * [INPUT]: compose 的草稿/提交票据、recipients 的显式选择，以及 pad 的真实控制连接身份。
 * [OUTPUT]: 提供桌面展示上报；150ms 节流实时草稿、失败提示、单请求在途、草稿合并、重连快照、心跳和绑定提交身份的回执。
 * [POS]: 手机展示旁路；不执行任务，不注入桌面。连接失效丢弃旧连接消息，任务仍由任务 API 查账。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  const state = { generation: 0, seq: 0, version: 0, timer: null,
    selected: false, lastText: null, session: '', queue: [], sending: false, dirty: false, warned: false };

  function warn(text) {
    if (!state.selected || state.warned) return;
    state.warned = true;
    if (typeof message === 'function') message(text, true);
  }

  function controller() {
    return window.pocketdeskControlState?.() === 'ready' ? window.pocketdeskControlInfo?.().session || '' : '';
  }

  function post(action, extra, session = controller()) {
    if (!session) { state.dirty = true; return; }
    const body = Object.assign({ action, session, generation: state.generation,
      seq: ++state.seq, version: state.version }, extra || {});
    // 在途消息不变；仅合并尚未发送的尾部草稿，不跨越提交或选择边界。
    const tail = state.queue[state.queue.length - 1];
    if (action === 'draft' && tail?.action === 'draft' && tail.session === session) state.queue.pop();
    state.queue.push(body);
    pump();
  }

  async function pump() {
    if (state.sending) return;
    state.sending = true;
    while (state.queue.length) {
      const body = state.queue.shift();
      if (body.session !== controller()) continue;
      const abort = new AbortController();
      const timeout = setTimeout(() => abort.abort(), 5000);
      try {
        const response = await fetch('/api/v1/sprite/session', {
          method: 'POST', headers: authHeaders(), body: JSON.stringify(body), signal: abort.signal
        });
        if (!response.ok) {
          state.dirty = true;
          warn(response.status === 409 ? '桌面反馈未连接，请先接管控制。' : '桌面反馈同步失败，正在重试。');
        } else { state.warned = false; }
      } catch (_) { state.dirty = true; warn('桌面反馈连接中断，正在重试。'); }
      finally { clearTimeout(timeout); }
    }
    state.sending = false;
  }

  function flushDraft(force = false) {
    if (!state.selected) return;
    const text = typeof liveValue === 'function' ? liveValue() : '';
    if (!force && text === state.lastText) return;
    state.lastText = text;
    state.version += 1;
    post('draft', { text });
  }

  function synchronize() {
    const session = controller();
    if (!session) return;
    if (session === state.session && !state.dirty) return;
    state.session = session;
    state.dirty = false;
    post(state.selected ? 'select' : 'deselect');
    flushDraft(true);
  }

  window.pocketdeskSpriteSelect = function () {
    state.generation += 1;
    state.selected = true;
    state.warned = false;
    state.session = controller();
    if (!state.session) warn(window.pocketdeskControlState?.() === 'viewer'
      ? '请先接管控制，才能在电脑显示小精灵。' : '正在连接电脑，连上后会显示小精灵。');
    post('select');
    flushDraft(true);
  };
  window.pocketdeskSpriteDeselect = function () {
    clearTimeout(state.timer); state.timer = null;
    state.generation += 1;
    state.selected = false;
    post('deselect');
  };
  window.pocketdeskSpriteDraft = function () {
    if (state.timer) return;
    state.timer = setTimeout(() => { state.timer = null; flushDraft(); }, 150);
  };
  window.pocketdeskSpriteSubmitting = function (text) {
    clearTimeout(state.timer); state.timer = null;
    const ticket = { version: ++state.version,
      requestId: `${Date.now()}-${Math.random().toString(36).slice(2)}`, session: controller() };
    state.lastText = text;
    post('submitting', { text, version: ticket.version, requestId: ticket.requestId }, ticket.session);
    return ticket;
  };
  window.pocketdeskSpriteSubmitted = function (taskId, ticket) {
    if (!ticket) return;
    post('submitted', { taskId: taskId || '', version: ticket.version, requestId: ticket.requestId }, ticket.session);
  };
  window.pocketdeskSpriteSubmitFailed = function (ticket) {
    if (!ticket) return;
    post('submit-failed', { version: ticket.version, requestId: ticket.requestId }, ticket.session);
  };

  // 手机刷新会建立新的控制连接；只恢复快照，不回放旧提交事件。
  if (typeof onWSMessage === 'function') onWSMessage(message => {
    if (message.t === 'auth_ok' || message.t === 'control') synchronize();
  });
  setInterval(() => {
    synchronize();
    if (state.selected && controller()) post('heartbeat');
  }, 5000);
})();
