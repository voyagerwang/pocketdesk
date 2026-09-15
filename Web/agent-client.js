/**
 * [INPUT]: 消费 localStorage 的配对 token、/api/v1 的任务接口与事件流；
 *          依赖 app.js 的 message() 提示（缺失时降级为静默，不阻塞任务链路）。
 * [OUTPUT]: 提供 window.pocketdeskAgent——小精灵任务的提交、追问、放弃、有界轮询与状态订阅。
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
  var ACTIVE = { accepted: 1, running: 1, needsInput: 1, verifying: 1 };

  var state = {
    task: null,          // 当前任务快照
    cursor: 0,           // 事件游标
    interval: POLL_START,
    timer: null,
    polling: false,
    listeners: [],
    pendingRequestId: null,
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
    var res = await api('/api/v1/tasks/' + encodeURIComponent(state.task.id));
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
    var requestId = state.pendingRequestId || newRequestId();
    state.pendingRequestId = requestId;
    var body = { requestId: requestId, text: text };
    if (context) body.context = context;
    var res;
    try {
      res = await api('/api/v1/tasks', { method: 'POST', body: JSON.stringify(body) });
    } catch (e) {
      var recovered = await recoverByRequest(requestId);
      if (recovered) { state.pendingRequestId = null; adopt(recovered.task || recovered); return state.task; }
      throw e;
    }
    state.pendingRequestId = null;
    adopt(res.task);
    return state.task;
  }

  /// 提交回包丢失时的查账：同一个 requestId 在服务端只对应一个任务。
  async function recoverByRequest(requestId) {
    try {
      var res = await api('/api/v1/tasks/by-request/' + encodeURIComponent(requestId));
      return res.task ? res : null;
    } catch (e) {
      return null;
    }
  }

  async function followUp(text) {
    if (!state.task) return submit(text, state.page);
    var res = await api('/api/v1/tasks/' + encodeURIComponent(state.task.id) + '/actions', {
      method: 'POST',
      body: JSON.stringify({ action: 'supplement', text: text, expectedRevision: state.task.revision })
    });
    adopt(res.task);
    return state.task;
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

  function adopt(task) {
    if (!task) return;
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

  /// 「新任务」：只解除手机与旧任务的关联，不删除历史、不取消旧任务、不调用电脑清空接口（方案 §5）。
  function detach() {
    stopPolling();
    state.task = null;
    state.cursor = 0;
    state.pendingRequestId = null;
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
    followUp: followUp,
    abandon: abandon,
    resume: resume,
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
