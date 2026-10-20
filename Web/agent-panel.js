/**
 * [INPUT]: 消费 agent-client.js 的任务快照与事件、index.html 的 #agent-* 容器。
 * [OUTPUT]: 按恢复事实展示主动作；重试沿用原任务，补充/换件事保留草稿并同步首页与全屏输入归属。独占任务卡显隐，提供 window.pocketdeskAgentPanel 与结果/来源、成功派单接续。
 * [POS]: Web 的小精灵展示层：**只呈现，不执行工具、不发任何桌面输入**。
 *        所有文本一律 textContent 落地，模型或网页返回的 HTML/脚本不会被解析（方案 §9 安全呈现）。
 *        M1 的按钮是「放弃并保留草稿」而不是「停止」——runtime 不支持真中断，叫停止就是谎报（方案 §2）。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';

  var el = {};
  var lastRenderedStatus = null;
  var lastRenderedTaskId = null;
  var handedOff = new Set();

  function $(id) { return document.getElementById(id); }

  function init() {
    el.panel = $('agent-panel');
    el.status = $('agent-status');
    el.result = $('agent-result');
    el.sources = $('agent-sources');
    el.primary = $('agent-primary');
    el.actionError = $('agent-action-error');
    el.actions = $('agent-actions');
    el.supplement = $('agent-supplement');
    el.newTask = $('agent-new');
    [el.supplement, el.newTask].forEach(function (button) {
      if (button) button.addEventListener('click', function () {
        try {
          chooseInput(button === el.supplement ? 'supplement' : 'new');
        } catch (error) { window.pocketdeskMessage?.(error.message, true); }
      });
    });
    if (el.primary) el.primary.addEventListener('click', runPrimary);
    ['agent-compose-switch', 'agent-screen-switch'].forEach(function (id) {
      $(id)?.addEventListener('click', function () {
        if (submittingDraft || window.pocketdeskAgent.isSubmitting()) return;
        try {
          if (window.pocketdeskAgent.inputMode() === 'new') {
            window.pocketdeskAgent.restoreInput();
            window.pocketdeskFocusCompose?.();
          } else chooseInput('new');
        }
        catch (error) { showError(error); }
      });
    });
    ['agent-compose-recover', 'agent-screen-recover'].forEach(function (id) {
      $(id)?.addEventListener('click', async function () {
        if (window.pocketdeskAgent.isRetrying() || submittingDraft) return;
        try { await window.pocketdeskAgent.retry(); } catch (error) { showError(error); }
      });
    });
    el.abandon = $('agent-abandon');
    el.continue = $('agent-continue');
    if (el.continue) el.continue.addEventListener('click', function () {
      var task = window.pocketdeskAgent.current();
      if (task && task.handoffTargetId) window.pocketdeskContinueInApp?.(task.handoffTargetId);
    });
    el.page = $('agent-page');
    el.pageLabel = $('agent-page-label');
    el.pageClear = $('agent-page-clear');

    if (el.abandon) {
      el.abandon.addEventListener('click', function () {
        el.abandon.disabled = true;
        window.pocketdeskAgent.abandon().then(function (res) {
          if (res && res.note && typeof window.pocketdeskMessage === 'function') window.pocketdeskMessage(res.note);
        }).catch(function (error) {
          if (typeof window.pocketdeskMessage === 'function') window.pocketdeskMessage(error.message, true);
        }).then(function () {
          el.abandon.disabled = false;
        });
      });
    }
    if (el.pageClear) {
      el.pageClear.addEventListener('click', function () {
        window.pocketdeskAgent.bindPage(null);
        render();
      });
    }
    window.pocketdeskAgent.onChange(render);
    render();
  }

  function chooseInput(mode) {
    if (submittingDraft || window.pocketdeskAgent.isSubmitting()) return;
    window.pocketdeskAgent.chooseInput(mode);
    if (el.actionError) { el.actionError.textContent = ''; el.actionError.hidden = true; }
    window.pocketdeskFocusCompose?.();
  }

  function showError(error) {
    if (el.actionError) { el.actionError.textContent = error.message; el.actionError.hidden = false; }
    else window.pocketdeskMessage?.(error.message, true);
  }

  function hasDraft() { return typeof liveValue === 'function' && !!liveValue().trim(); }
  function primaryAction(task) {
    var action = task?.recovery?.primaryAction;
    if (action?.kind === 'retry' && task.status !== 'submitted' && task.recovery.kind !== 'unconfirmed')
      return { kind: 'retry', title: action.title || '再试一次' };
    return { kind: 'input', title: action?.title || task?.recovery?.inputLabel || '补充信息' };
  }

  async function runPrimary() {
    var agent = window.pocketdeskAgent;
    if (agent.isRetrying() || submittingDraft) return;
    if (primaryAction(agent.current()).kind !== 'retry' || hasDraft()) { chooseInput('supplement'); return; }
    if (el.actionError) { el.actionError.textContent = ''; el.actionError.hidden = true; }
    try { await agent.retry(); } catch (error) { showError(error); }
  }

  function originalText(task) {
    var original = task?.messages?.find(function (message) { return message.role === 'user'; });
    return ((original ? original.text : task?.text) || '').replace(/\s+/g, ' ').trim();
  }

  // 输入归属贴近两个实际编辑器；模式切换只改提示，不覆盖正文或重建输入法会话。
  function renderInputContext(task, recovery, busy) {
    var selected = window.pocketdeskIsSpriteSelected?.();
    var mode = window.pocketdeskAgent.inputMode();
    var original = originalText(task);
    var pending = window.pocketdeskAgent.hasPendingRetry();
    ['compose', 'screen'].forEach(function (surface) {
      var context = $('agent-' + surface + '-context');
      var label = $('agent-' + surface + '-label');
      var button = $('agent-' + surface + '-switch');
      var recover = $('agent-' + surface + '-recover');
      if (!context) return;
      context.hidden = !selected || (!recovery && !pending);
      if (label) {
        label.textContent = pending ? '上次提交待确认，输入内容会保留' : mode === 'new' ? '说件新事情'
          : '接着说 · ' + (original.length > 28 ? original.slice(0, 28) + '…' : original);
        label.title = mode === 'new' ? '下一句话会作为新的请求' : original;
      }
      if (button) { button.textContent = mode === 'new' ? '返回刚才' : '换件事'; button.disabled = busy || pending; button.hidden = pending; }
      if (recover) { recover.hidden = !pending; recover.disabled = busy; recover.textContent = busy ? '正在核对…' : '核对上次提交'; }
      var question = $('agent-' + surface + '-question');
      if (question) {
        question.hidden = !recovery || mode === 'new' || task?.recovery?.kind !== 'clarification';
        question.textContent = question.hidden ? '' : task.result || task.error || '';
      }
      var editor = $(surface === 'compose' ? 'text' : 'kb-proxy');
      if (editor) {
        if (!editor.dataset.agentPlaceholder) editor.dataset.agentPlaceholder = editor.getAttribute('placeholder') || '输入文字…';
        editor.setAttribute('placeholder', selected && recovery
          ? mode === 'new' ? '想让我帮你做什么？' : task?.recovery?.kind === 'unconfirmed' ? '补充线索，核对刚才的结果…' : '补充一点信息，接着处理…'
          : editor.dataset.agentPlaceholder);
      }
    });
  }

  // 只认 http/https：防止模型或页面塞进 javascript: 之类的链接。
  function safeURL(value) {
    try {
      var url = new URL(value, location.href);
      return (url.protocol === 'http:' || url.protocol === 'https:') ? url.href : null;
    } catch (e) {
      return null;
    }
  }

  function renderStatus(task) {
    el.status.textContent = '';
    if (!task) {
      el.status.className = 'agent-status';
      if (el.result) el.result.textContent = '';
      if (el.sources) el.sources.textContent = '';
      return;
    }
    el.status.className = 'agent-status is-' + task.status;
    var label = document.createElement('span');
    label.className = 'agent-status-label';
    label.textContent = task.recovery?.headline || (task.deliveryRecipient ? '已发送' : task.handoffTargetId && task.status === 'succeeded' ? '已交给 ' + task.handoffTargetName : (task.statusText || task.status));
    el.status.append(label);

    if (window.pocketdeskAgent.isActive() && task.status !== 'needsInput') {
      var dot = document.createElement('span');
      dot.className = 'agent-dot';
      dot.setAttribute('aria-hidden', 'true');
      el.status.append(dot);
      // 软超时只提示，不停止等待：硬超时由服务端决定（方案 §9）。
      if (task.softDeadline && Date.now() / 1000 > task.softDeadline) {
        var slow = document.createElement('span');
        slow.className = 'agent-slow';
        slow.textContent = '已超过 5 分钟，仍在等待…';
        el.status.append(slow);
      }
    }
  }

  function renderResult(task) {
    el.result.textContent = '';
    if (!task) return;
    var brief = document.createElement('div');
    brief.className = 'agent-brief';
    var recovery = window.pocketdeskAgent.canRecover();
    var text = (recovery ? originalText(task) : task.text || '').replace(/\s+/g, ' ').trim();
    brief.textContent = (recovery ? '刚才：' : '') + (text.length > 44 ? text.slice(0, 44) + '…' : text);
    el.result.append(brief);
    var body = task.result || task.error || '';
    if (recovery) {
      var question = document.createElement('div');
      question.className = 'agent-text agent-recovery-detail';
      question.textContent = body;
      el.result.append(question);
      var next = task.recovery?.nextStep;
      if (next && next !== body) {
        var step = document.createElement('p');
        step.className = 'agent-next-step';
        step.textContent = next;
        el.result.append(step);
      }
    } else if (body) {
      var details = document.createElement('details');
      var summary = document.createElement('summary');
      summary.textContent = task.status === 'failed' ? '查看原因' : '查看结果';
      var full = document.createElement('div');
      full.className = 'agent-text';
      full.textContent = body;
      details.append(summary, full);
      el.result.append(details);
    }
  }

  function renderSources(task) {
    el.sources.textContent = '';
    if (!task || !task.sources || !task.sources.length) return;
    var disclosure = document.createElement('details');
    el.sources.append(disclosure);
    var title = document.createElement('summary');
    title.className = 'agent-sources-title';
    title.textContent = '来源';
    disclosure.append(title);
    task.sources.forEach(function (source) {
      var href = safeURL(source.url);
      var link = document.createElement(href ? 'a' : 'span');
      if (href) {
        link.href = href;
        link.target = '_blank';
        link.rel = 'noopener noreferrer';
      }
      link.className = 'agent-source';
      link.textContent = source.domain || source.title || source.url;
      link.title = source.url;
      disclosure.append(link);
    });
  }

  function renderPage() {
    var page = window.pocketdeskAgent.currentPage();
    if (!page || !el.page) {
      if (el.page) el.page.hidden = true;
      return;
    }
    el.page.hidden = false;
    el.pageLabel.textContent = '';
    var name = document.createElement('strong');
    name.textContent = page.title || '未命名页面';
    el.pageLabel.append(name);
    if (page.domain) {
      var domain = document.createElement('span');
      domain.className = 'agent-page-domain';
      domain.textContent = ' · ' + page.domain;
      el.pageLabel.append(domain);
    }
  }

  function render() {
    if (!el.panel) return;
    var task = window.pocketdeskAgent.current();
    var recovery = window.pocketdeskAgent.canRecover();
    var draft = hasDraft();
    var busy = !!submittingDraft || window.pocketdeskAgent.isRetrying() || window.pocketdeskAgent.isSubmitting();
    var newRequest = recovery && window.pocketdeskAgent.inputMode() === 'new';
    var editing = recovery && !newRequest && (draft || window.pocketdeskAgent.hasInputChoice());
    if (typeof syncSpriteExpression === 'function') syncSpriteExpression(false);
    var orb = document.querySelector('.target-sprite');
    if (orb) orb.classList.toggle('is-working', !!task && ['accepted', 'running', 'verifying'].includes(task.status));
    // HTML 默认 hidden 避免启动闪烁；任务到达后必须在小精灵模式显式解除。
    // 父层 hidden 不解开会让整个任务卡（含放弃按钮）永久不可见。
    el.panel.hidden = !task || !(window.pocketdeskIsSpriteSelected && window.pocketdeskIsSpriteSelected())
      || newRequest || (!recovery && !window.pocketdeskAgent.isActive() && draft);
    el.panel.classList.toggle('is-editing', editing);
    el.panel.classList.toggle('is-question', task?.recovery?.kind === 'clarification');
    renderStatus(task);
    renderResult(task);
    renderSources(task);
    renderPage();
    renderInputContext(task, recovery, busy);
    if (el.actionError && (task?.id !== lastRenderedTaskId || !recovery)) {
      el.actionError.hidden = true; el.actionError.textContent = '';
    }
    if (el.abandon) el.abandon.hidden = recovery || !window.pocketdeskAgent.isActive();
    var action = primaryAction(task);
    if (el.primary) {
      el.primary.hidden = !recovery || editing;
      el.primary.disabled = busy || window.pocketdeskAgent.hasPendingRetry();
      el.primary.textContent = window.pocketdeskAgent.isRetrying() ? '正在继续…' : action.title;
    }
    if (el.supplement) {
      el.supplement.hidden = !recovery || editing || action.kind !== 'retry';
      el.supplement.disabled = busy;
      el.supplement.textContent = task?.recovery?.inputLabel || '补充说明';
    }
    if (el.newTask) {
      el.newTask.hidden = !recovery || editing;
      el.newTask.disabled = busy || window.pocketdeskAgent.hasPendingRetry();
    }
    if (el.continue) {
      el.continue.hidden = !task || !task.handoffTargetId;
      el.continue.textContent = task && task.handoffTargetName ? '继续聊 ' + task.handoffTargetName + ' →' : '';
    }
    if (el.actions) el.actions.hidden = ![el.primary, el.supplement, el.newTask, el.continue, el.abandon]
      .some(function (button) { return button && !button.hidden; });
    if (!submittingDraft && task && task.handoffTargetId && task.status === 'succeeded' && !handedOff.has(task.id)) {
      handedOff.add(task.id);
      var key = 'pd-handoff-' + task.id;
      var seen = false;
      try { seen = sessionStorage.getItem(key); sessionStorage.setItem(key, '1'); } catch (_) {}
      // 已切离小精灵或开始写下一条时，不让迟到回执抢走用户正在输入的目标。
      if (!seen && window.pocketdeskIsSpriteSelected?.() && !window.pocketdeskHasDraft?.())
        window.pocketdeskFollowHandoff?.(task.handoffTargetId);
    }
    lastRenderedStatus = task ? task.status : null;
    lastRenderedTaskId = task?.id || null;
  }

  window.pocketdeskAgentPanel = {
    init: init,
    render: render,
    lastStatus: function () { return lastRenderedStatus; }
  };
})();
