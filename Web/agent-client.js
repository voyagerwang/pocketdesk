/**
 * [INPUT]: localStorage 的配对 token/分主体请求日志、已鉴权 identity 与任务接口/事件流；
 *          依赖 app.js 的 message() 提示（缺失时降级为静默，不阻塞任务链路）。
 * [OUTPUT]: pocketdeskAgent——先落原快照再提交、按原编号只读恢复、主体/请求核验、并发锁与按权威修订补读的有界轮询。
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
    pendingRequestId: null,
    pendingRequestBody: null,
    submission: null,
    owner: null,
    journalScope: null,
    selection: 0,       // 选定任务代际；迟到恢复不能覆盖新提交或用户解绑
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
    var identity = token();
    if (state.owner !== null && state.owner !== identity) {
      stopPolling(); state.task = null; state.pendingRequestId = null; state.pendingRequestBody = null;
      state.journalScope = null;
      state.selection++;
      notify('identity');
    }
    state.owner = identity;
    var controller = new AbortController();
    var timeout = setTimeout(function () { controller.abort(); }, 20000);
    var res, text;
    try {
      res = await fetch(path, Object.assign({ headers: headers(), cache: 'no-store', signal: controller.signal }, options || {}));
      text = await res.text();
      if (identity !== token()) throw new Error('配对已变化，旧任务回执未应用。请重新连接。');
    } finally { clearTimeout(timeout); }
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

  // MARK: 请求先于副作用持久化；记录不保存配对凭据，确认后只留编号。
  async function journalScope() {
    var identity = token();
    if (!identity) throw new Error('请先配对，再提交任务。');
    if (state.owner === identity && state.journalScope) return state.journalScope;
    var value = await api('/api/v1/tasks/identity');
    if (value.protocolVersion !== 1 || !/^pocketdesk:[a-f0-9]{64}$/.test(value.journalScope || ''))
      throw new Error('电脑端尚不支持可靠请求恢复，请更新 PocketDesk 后重试；本次未发送。');
    if (identity !== token()) throw new Error('配对已变化，请重新连接。');
    state.journalScope = value.journalScope;
    return state.journalScope;
  }
  function journalPrefix() { return 'pocketdesk.agent-request.v1:' + state.journalScope + ':'; }
  function journals() {
    var entries = [], prefix = journalPrefix();
    try {
      for (var n = 0; n < localStorage.length; n++) {
        var key = localStorage.key(n);
        if (!key || !key.startsWith(prefix)) continue;
        var raw = localStorage.getItem(key);
        if (raw === null) continue;
        var entry = JSON.parse(raw);
        if (!entry || !/^r-[A-Za-z0-9-]+$/.test(entry.requestId) || key !== prefix + entry.requestId
          || !Number.isFinite(entry.createdAt) || !['pending', 'confirmed'].includes(entry.state)
          || entry.state === 'pending' && (!entry.body || entry.body.requestId !== entry.requestId || typeof entry.body.text !== 'string')
          || entry.state === 'confirmed' && typeof entry.taskId !== 'string') throw new Error('invalid journal');
        entries.push(entry);
      }
    } catch (e) { throw new Error('本机任务恢复记录无法读取，请先在电脑端核对；未开始新任务。'); }
    return entries.sort(function (a, b) { return a.createdAt - b.createdAt; });
  }
  function restorePending() {
    var pending = journals().find(function (entry) { return entry.state === 'pending'; });
    if (pending) { state.pendingRequestId = pending.requestId; state.pendingRequestBody = pending.body; }
    return pending;
  }
  function reserveRequest(body) {
    var key = journalPrefix() + body.requestId;
    try {
      var old = localStorage.getItem(key);
      if (old !== null) {
        var entry = JSON.parse(old);
        if (entry.state !== 'pending' || JSON.stringify(entry.body) !== JSON.stringify(body)) throw new Error('conflict');
        return;
      }
      localStorage.setItem(key, JSON.stringify({ requestId: body.requestId, state: 'pending', createdAt: Date.now(), body: body }));
    } catch (e) { throw new Error('无法保存原请求恢复记录，本次未发送；请检查手机存储后再试。'); }
  }
  function confirmRequest(requestId, task) {
    var key = journalPrefix() + requestId;
    // 已接收的任务不能因本地清理失败变成未接收；残留原记录下次仍只查同一编号。
    try {
      var previous = JSON.parse(localStorage.getItem(key) || 'null');
      localStorage.setItem(key, JSON.stringify({ requestId: requestId, taskId: task.id, state: 'confirmed', createdAt: previous?.createdAt || Date.now() }));
    } catch (e) {
      try { localStorage.removeItem(key); } catch (ignored) {
        if (typeof window.pocketdeskMessage === 'function')
          window.pocketdeskMessage('任务已接收，但本机原文副本暂未清除；请检查手机存储。刷新仍只查账，不会重发。', true);
      }
    }
    state.pendingRequestId = null; state.pendingRequestBody = null;
  }
  function receiptMatches(res, requestId) {
    return res && res.task && typeof res.task.id === 'string' && res.task.requestId === requestId;
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
      if (!state.task || state.task.id !== taskId) return;
      var events = res.events || [];
      if (res.needRefresh || res.taskRevision !== state.task.revision) {
        // 快照是权威：事件写失败/截断也能按修订恢复；旧服务缺修订时只读补取。
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
    return 'r-' + Array.from(crypto.getRandomValues(new Uint32Array(4)), function (n) { return n.toString(36); }).join('-');
  }

  /**
   * 提交新任务。网络失败会先按同一 requestId 查账再决定是否重试——
   * 请求可能已经落到 Mac 上了，盲发新 ID 会跑出第二个任务。
   */
  async function submit(text, context) {
    var identity = token();
    var signature = JSON.stringify([identity, text, context || null]);
    if (state.submission) {
      if (state.submission.signature === signature) return state.submission.promise;
      throw new Error('前一条提交尚未确认，本次正文未发送。');
    }
    // submit 的锁独立于输入界面：其它调用方不能并发创建两个任务或复用编号改正文。
    var promise = submitOnce(text, context, identity);
    state.submission = { signature: signature, promise: promise };
    try { return await promise; } finally { state.submission = null; }
  }

  async function submitOnce(text, context, identity) {
    var selection = ++state.selection;
    if (state.owner !== null && state.owner !== identity) {
      stopPolling(); state.task = null; state.pendingRequestId = null; state.pendingRequestBody = null;
      state.journalScope = null;
    }
    state.owner = identity;
    await journalScope();
    restorePending();
    if (state.pendingRequestBody) {
      var previous = state.pendingRequestBody;
      if (previous.text !== text || JSON.stringify(previous.context || null) !== JSON.stringify(context || null)) {
        var old = await recoverByRequest(previous.requestId);
        if (old && identity === token()) {
          confirmRequest(previous.requestId, old.task);
          if (selection === state.selection) adopt(old.task);
          throw new Error('前一任务已接收，本次修改后的正文未发送。草稿已保留，请确认原任务后再发。');
        }
        throw new Error('前一条提交结果仍未知，本次修改后的正文未发送。请先查明原任务，不要换正文重试。');
      }
    }
    var body = state.pendingRequestBody || { requestId: newRequestId(), text: text,
      controlSession: window.pocketdeskControlInfo?.().session || "" };
    if (!state.pendingRequestBody && context) body.context = JSON.parse(JSON.stringify(context));
    reserveRequest(body);
    state.pendingRequestId = body.requestId;
    state.pendingRequestBody = body;
    var requestId = body.requestId;
    var res;
    try {
      res = await api('/api/v1/tasks', { method: 'POST', body: JSON.stringify(body) });
      if (!receiptMatches(res, requestId)) throw new Error('任务回执编号不匹配，未确认接收，请查询原请求。');
    } catch (e) {
      var recovered = await recoverByRequest(requestId);
      if (identity !== token()) throw e;
      if (recovered) {
        confirmRequest(requestId, recovered.task);
        if (selection === state.selection) adopt(recovered.task);
        return recovered.task;
      }
      throw e;
    }
    confirmRequest(requestId, res.task);
    if (selection === state.selection) adopt(res.task);
    return res.task;
  }

  /// 提交回包丢失时的查账：同一个 requestId 在服务端只对应一个任务。
  async function recoverByRequest(requestId) {
    try {
      var res = await api('/api/v1/tasks/by-request/' + encodeURIComponent(requestId));
      return receiptMatches(res, requestId) ? res : null;
    } catch (e) {
      return null;
    }
  }

  async function followUp(text) {
    if (!state.task) return submit(text, state.page);
    var selection = state.selection;
    var res = await api('/api/v1/tasks/' + encodeURIComponent(state.task.id) + '/actions', {
      method: 'POST',
      body: JSON.stringify({ action: 'supplement', text: text, expectedRevision: state.task.revision })
    });
    if (selection === state.selection) adopt(res.task);
    return res.task;
  }

  // 完成后下一句话就是新任务；只有明确待补充时沿用旧任务。
  async function send(text) {
    await journalScope(); restorePending();
    // 未确认提交优先查原快照，不能把另一活动任务的 needsInput 当成它的续问。
    if (state.pendingRequestBody) return submit(text, state.pendingRequestBody.context || null);
    if (state.task && state.task.status === 'needsInput') return followUp(text);
    if (isActive(state.task)) throw new Error('正在执行，请稍候。');
    return submit(text, state.page);
  }

  async function abandon() {
    if (!state.task) return null;
    var selection = state.selection;
    var res = await api('/api/v1/tasks/' + encodeURIComponent(state.task.id) + '/actions', {
      method: 'POST',
      body: JSON.stringify({ action: 'cancel', expectedRevision: state.task.revision })
    });
    if (selection === state.selection) { adopt(res.task); stopPolling(); }
    return res;
  }

  function adopt(task) {
    if (!task) return;
    state.selection++;
    state.task = task;
    state.cursor = 0;
    notify('adopt');
    if (isActive(task)) startPolling(); else stopPolling();
  }

  /// 恢复：页面回到前台或重新连上时，按已保存的 taskId 补取，不重新派发。
  async function resume(taskId) {
    if (!taskId) return null;
    var selection = ++state.selection;
    try {
      var res = await api('/api/v1/tasks/' + encodeURIComponent(taskId));
      if (selection !== state.selection || state.submission) return null;
      if (res.task && res.task.id === taskId) { adopt(res.task); return state.task; }
    } catch (e) { /* 查不到就当作没有任务 */ }
    return null;
  }

  /// 刷新只查原编号；已确认日志只存编号，未确认原快照临时留手机，不自动 POST。
  async function recoverActive() {
    if (state.submission) return null;
    var selection = state.selection;
    try {
      var identity = token();
      await journalScope();
      if (selection !== state.selection || state.submission) return null;
      var pending = restorePending();
      if (pending) {
        var recovered = await recoverByRequest(pending.requestId);
        if (identity !== token() || selection !== state.selection || state.submission) return null;
        if (recovered) { confirmRequest(pending.requestId, recovered.task); adopt(recovered.task); return state.task; }
        if (typeof window.pocketdeskMessage === 'function') window.pocketdeskMessage('原任务接收结果仍待核对；未重发。原正文暂存在本机，请按原内容重试或在电脑端核对。', true);
        return null;
      }
      var confirmed = journals().filter(function (entry) { return entry.state === 'confirmed'; }).at(-1);
      if (confirmed) return resume(confirmed.taskId);
      // 兼容没有日志的旧页面，仅接纳唯一活动任务；不按“最近”猜测。
      var res = await api('/api/v1/tasks?cursor=0');
      if (selection !== state.selection || state.submission) return null;
      var summaries = res.tasks || [];
      var active = summaries.filter(function (task) { return isActive(task); });
      return active.length === 1 ? resume(active[0].id) : null;
    } catch (e) {
      return null;
    }
  }

  /// 「新任务」：只解除手机与旧任务的关联，不删除历史、不取消旧任务、不调用电脑清空接口（方案 §5）。
  function detach() {
    state.selection++;
    stopPolling();
    state.task = null;
    state.cursor = 0;
    // 未确认请求不能因为收起旧任务卡就遗忘，否则下一次点击会重新派一份。
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
