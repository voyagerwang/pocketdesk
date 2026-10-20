/**
 * [INPUT]: 消费 localStorage 的配对 token、/api/v1 的任务接口与事件流；
 *          依赖 app.js 的 message() 提示（缺失时降级为静默，不阻塞任务链路）。
 * [OUTPUT]: 提供 window.pocketdeskAgent——未完成任务默认续接、明确换件事及原任务重试；新建/补充/重试共用幂等票据和丢包查账，提供忙碌门禁、有界轮询与活动任务找回。
 * [POS]: Web 的小精灵任务客户端；只管与 Mac 的任务 API 对话，不碰输入区、不执行工具、不发桌面输入。
 *        轮询策略按方案 §9：2s 起、连续无事件按 1.5 倍退避至上限 10s；事件到来立即回到 2s。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';

  var TOKEN_KEY = 'voicedeck.pair-token';
  var POLL_START = 2000;
  var POLL_MAX = 10000;
  var POLL_FACTOR = 1.5;
  // 与 Sources/AgentModels.TaskStatus.isActive 保持同构。
  var ACTIVE = { accepted: 1, running: 1, needsInput: 1, verifying: 1 };

  var state = {
    task: null,          // 当前任务快照
    cursor: 0,           // 事件游标
    interval: POLL_START,
    timer: null,
    polling: false,
    listeners: [],
    pendingRequest: null,
    retrying: false,
    sending: false,
    inputIntent: null,   // 用户明确选择的输入归属，刷新同一任务不会覆盖
    seq: 0,
    page: null           // 当前网页绑定（用户可解绑）
  };

  function token() { try { return localStorage.getItem(TOKEN_KEY) || ''; } catch (e) { return ''; } }

  function headers() {
    var h = { 'Content-Type': 'application/json' };
    var t = token();
    if (t) h.Authorization = 'Bearer ' + t;
    return h;
  }

  function notify(reason) {
    for (var i = 0; i < state.listeners.length; i++) {
      try { state.listeners[i](state.task, reason); } catch (e) { /* 单个订阅者出错不影响其他 */ }
    }
  }

  // 统一请求。非 2xx 抛出带 message 的错误，让调用方直接把服务端人话显示出来。
  async function api(path, options) {
    var res = await fetch(path, Object.assign({ headers: headers(), cache: 'no-store' }, options || {}));
    var text = await res.text();
    var payload = null;
    try { payload = JSON.parse(text); } catch (e) { payload = null; }
    if (!res.ok) {
      var error = new Error((payload && payload.error) || ('请求失败（' + res.status + '）'));
      error.status = res.status;
      throw error;
    }
    return payload || {};
  }

  function isActive(task) { return Boolean(task && ACTIVE[task.status]); }
  function canRecover(task) {
    return Boolean(task && (['failed', 'needsInput', 'submitted'].includes(task.status)
      || (task.recovery && task.canFollowUp !== false && !isActive(task))));
  }

  function inputMode() {
    if (state.inputIntent && state.task && state.inputIntent.taskId === state.task.id) return state.inputIntent.mode;
    return canRecover(state.task) ? 'supplement' : 'new';
  }

  // 只选择下一段话的归属；保留旧任务与当前草稿，不执行任务、不清输入框。
  function chooseInput(mode) {
    if (mode !== 'supplement' && mode !== 'new') throw new Error('请选择补充解释或新任务。');
    if (state.retrying || state.sending) throw new Error('正在提交，请稍候。');
    if (mode === 'new' && state.pendingRequest?.retry) throw new Error('请先核对上次提交，输入的内容会保留。');
    if (isActive(state.task) && state.task.status !== 'needsInput') throw new Error('正在执行，请稍候。');
    if (mode === 'supplement' && !canRecover(state.task)) throw new Error('当前没有需要补充的任务。');
    state.inputIntent = { mode: mode, taskId: state.task && state.task.id };
    notify('input');
  }

  function restoreInput() {
    chooseInput('supplement');
    state.inputIntent = null;
    notify('input');
  }

  // MARK: 轮询

  function schedule(delay) {
    clearTimeout(state.timer);
    if (!isActive(state.task)) { state.polling = false; return; }
    state.polling = true;
    state.timer = setTimeout(tick, delay == null ? state.interval : delay);
  }

  async function tick() {
    if (!state.task) { state.polling = false; return; }
    var taskId = state.task.id;
    try {
      var res = await api('/api/v1/tasks/' + encodeURIComponent(taskId) + '/events?after=' + state.cursor);
      var events = res.events || [];
      if (res.needRefresh) {
        // 事件被截断：补取已经没有意义，直接拉快照重建。
        await refresh();
        state.interval = POLL_START;
      } else if (events.length) {
        state.cursor = events[events.length - 1].seq;
        await refresh();
        // 有进展就把节奏收回来，别让退避把"刚有结果"也拖到 10s 后才显示。
        state.interval = POLL_START;
      } else {
        state.interval = Math.min(Math.round(state.interval * POLL_FACTOR), POLL_MAX);
      }
    } catch (e) {
      // 单次轮询失败不宣布任务失败：断线恢复的重头戏就在下一次成功轮询上。
      state.interval = Math.min(Math.round(state.interval * POLL_FACTOR), POLL_MAX);
    }
    if (state.task && state.task.id === taskId) schedule();
  }

  async function refresh() {
    if (!state.task) return null;
    var taskId = state.task.id;
    var res = await api('/api/v1/tasks/' + encodeURIComponent(taskId));
    if (!state.task || state.task.id !== taskId) return state.task;
    if (isOlder(res.task)) return state.task;
    state.task = res.task || null;
    notify('refresh');
    if (!isActive(state.task)) state.interval = POLL_START;
    return state.task;
  }

  function startPolling() {
    state.interval = POLL_START;
    schedule(0);
  }

  function stopPolling() {
    clearTimeout(state.timer);
    state.timer = null;
    state.polling = false;
  }

  // MARK: 提交

  function newRequestId() {
    state.seq += 1;
    return 'r' + Date.now().toString(36) + '-' + state.seq;
  }

  /**
   * 提交新任务。网络失败会先按同一 requestId 查账再决定是否重试——
   * 请求可能已经落到 Mac 上了，盲发新 ID 会跑出第二个任务。
   */
  async function submit(text, context) {
    var body = { text: text, controlSession: window.pocketdeskControlInfo?.().session || '' };
    if (context) body.context = context;
    return postInput('/api/v1/tasks', 'new', body, null);
  }

  async function postInput(path, operation, body, taskId) {
    if (state.sending) throw new Error('正在提交，请稍候。');
    state.sending = true;
    notify('sending');
    try { return await performInput(path, operation, body, taskId); }
    finally { state.sending = false; notify('sending'); }
  }

  async function performInput(path, operation, body, taskId) {
    var fingerprint = JSON.stringify([operation, taskId, body.text, body.context || null]);
    if (state.pendingRequest && state.pendingRequest.fingerprint !== fingerprint)
      throw new Error('上一段内容是否收到还未核实，请先重试原内容；当前草稿已保留。');
    var request = state.pendingRequest || { id: newRequestId(), fingerprint: fingerprint, retry: state.retrying,
      taskId: taskId, path: path, body: Object.assign({}, body) };
    state.pendingRequest = request;
    body.requestId = request.id;
    var res;
    try {
      res = await api(path, { method: 'POST', body: JSON.stringify(body) });
    } catch (e) {
      // 明确拒绝没有接收这段正文，不能把冲突票据查出的其他任务当成本次成功。
      if (e.status >= 400 && e.status < 500 && e.status !== 408 && e.status !== 429) {
        state.pendingRequest = null;
        throw e;
      }
      var recovered = null;
      try { recovered = await recoverByRequest(request.id); } catch (_) { /* 保留票据，重试仍查同一次输入 */ }
      if (recovered) {
        var recoveredTask = recovered.task || recovered;
        if (taskId && recoveredTask.id !== taskId) throw new Error('补充回执与原任务不一致，请刷新后核对。');
        state.pendingRequest = null; state.inputIntent = null;
        adopt(recoveredTask); return state.task;
      }
      throw e;
    }
    state.pendingRequest = null;
    state.inputIntent = null;
    adopt(res.task);
    return state.task;
  }

  /// 提交回包丢失时的查账：同一个 requestId 在服务端只对应一个任务。
  async function recoverByRequest(requestId) {
    try {
      var res = await api('/api/v1/tasks/by-request/' + encodeURIComponent(requestId));
      return res.task ? res : null;
    } catch (e) {
      if (e.status === 404) return null;
      throw e;
    }
  }

  async function followUp(text) {
    if (!state.task) return submit(text, state.page);
    return postInput('/api/v1/tasks/' + encodeURIComponent(state.task.id) + '/actions', 'supplement', {
      action: 'supplement', text: text, expectedRevision: state.task.revision,
      controlSession: window.pocketdeskControlInfo?.().session || ''
    }, state.task.id);
  }

  // 未完成后下一句默认解释原任务；用户明确选择新任务时才解除输入归属。
  async function send(text) {
    if (state.retrying || state.sending) throw new Error('正在提交，请稍候。');
    if (isActive(state.task) && state.task.status !== 'needsInput') throw new Error('正在执行，请稍候。');
    if (inputMode() === 'supplement') return followUp(text);
    return submit(text, state.page);
  }

  // 仅接受服务端明确提供的重试动作；旧回执与未核实发送仍须用户补充，不猜测重试安全性。
  async function retry() {
    if (state.retrying || state.sending) throw new Error('正在提交，请稍候。');
    var pending = state.pendingRequest?.retry ? state.pendingRequest : null;
    if (!pending && (!canRecover(state.task) || state.task.status === 'submitted'
      || state.task.recovery?.kind === 'unconfirmed'
      || state.task.recovery?.primaryAction?.kind !== 'retry'))
      throw new Error('请先补充信息，再继续这件事。');
    state.retrying = true;
    notify('retry');
    try {
      // 上次提交是否收到仍不明确：先查同一票据；查账失败时保留票据，404才允许原票据恢复。
      if (pending) {
        var recovered = await recoverByRequest(pending.id);
        if (recovered) {
          var task = recovered.task || recovered;
          if (task.id !== pending.taskId) throw new Error('刚才的结果暂时无法核对，请稍后再试。');
          state.pendingRequest = null; state.inputIntent = null; adopt(task); return state.task;
        }
        return await postInput(pending.path, 'supplement', Object.assign({}, pending.body), pending.taskId);
      }
      return await followUp('继续处理刚才的请求');
    }
    finally { state.retrying = false; notify('retry'); }
  }

  async function abandon() {
    if (!state.task) return null;
    var res = await api('/api/v1/tasks/' + encodeURIComponent(state.task.id) + '/actions', {
      method: 'POST',
      body: JSON.stringify({ action: 'cancel', expectedRevision: state.task.revision })
    });
    adopt(res.task);
    stopPolling();
    return res;
  }

  function isOlder(task) {
    return task && state.task?.id === task.id && Number.isFinite(task.revision)
      && Number.isFinite(state.task.revision) && task.revision < state.task.revision;
  }

  function adopt(task) {
    if (!task) return;
    if (isOlder(task)) return;
    if (!state.task || state.task.id !== task.id) state.inputIntent = null;
    state.task = task;
    state.cursor = 0;
    notify('adopt');
    if (isActive(task)) startPolling(); else stopPolling();
  }

  /// 恢复：页面回到前台或重新连上时，按已保存的 taskId 补取，不重新派发。
  async function resume(taskId) {
    if (!taskId) return null;
    try {
      var res = await api('/api/v1/tasks/' + encodeURIComponent(taskId));
      if (res.task) { adopt(res.task); return state.task; }
    } catch (e) { /* 查不到就当作没有任务 */ }
    return null;
  }

  /// 页面刷新/重连后从服务端找回最新活动任务。任务事实源在 Mac，不把正文落进 localStorage。
  async function recoverActive() {
    try {
      var res = await api('/api/v1/tasks?cursor=0');
      var summaries = res.tasks || [];
      var active = summaries.find(function (task) { return isActive(task); });
      return active ? resume(active.id) : null;
    } catch (e) {
      return null;
    }
  }

  /// 「新任务」：只解除手机与旧任务的关联，不删除历史、不取消旧任务、不调用电脑清空接口（方案 §5）。
  function detach() {
    stopPolling();
    state.task = null;
    state.cursor = 0;
    state.pendingRequest = null;
    state.inputIntent = null;
    notify('detach');
  }

  // MARK: 能力与网页绑定

  async function executors() {
    var res = await api('/api/v1/executors');
    return res.executors || null;
  }

  /// 读取电脑当前网页绑定；读不到（前台不是浏览器、没授权）返回 null，由面板如实显示。
  async function fetchPage() {
    try {
      var res = await api('/api/v1/context/page');
      state.page = res.page || null;
      notify('page');
      return state.page;
    } catch (e) {
      state.page = null;
      notify('page');
      return null;
    }
  }

  function bindPage(page) { state.page = page; notify('page'); }
  function currentPage() { return state.page; }

  window.pocketdeskAgent = {
    submit: submit,
    send: send,
    retry: retry,
    isRetrying: function () { return state.retrying; },
    isSubmitting: function () { return state.sending; },
    hasPendingRetry: function () { return state.pendingRequest?.retry === true; },
    chooseInput: chooseInput,
    restoreInput: restoreInput,
    inputMode: inputMode,
    hasInputChoice: function () { return !!state.inputIntent && state.inputIntent.taskId === state.task?.id; },
    canRecover: function () { return canRecover(state.task); },
    followUp: followUp,
    abandon: abandon,
    resume: resume,
    recoverActive: recoverActive,
    detach: detach,
    refresh: refresh,
    executors: executors,
    fetchPage: fetchPage,
    bindPage: bindPage,
    currentPage: currentPage,
    current: function () { return state.task; },
    isActive: function () { return isActive(state.task); },
    onChange: function (callback) { state.listeners.push(callback); return function () { state.listeners = state.listeners.filter(function (fn) { return fn !== callback; }); }; },
    stopPolling: stopPolling,
    // 供测试：轮询节奏是纯逻辑，必须可断言，不能只靠 setTimeout 观察。
    _pollInterval: function () { return state.interval; },
    _resetPoll: function () { state.interval = POLL_START; },
    _constants: { POLL_START: POLL_START, POLL_MAX: POLL_MAX, POLL_FACTOR: POLL_FACTOR }
  };
})();
