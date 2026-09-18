/**
 * [INPUT]: 消费 agent-client.js 的任务快照与事件、index.html 的 #agent-* 容器。
 * [OUTPUT]: 提供 window.pocketdeskAgentPanel——任务优先的球球表情刷新、状态、简短任务说明与成功接续入口，完整结果按需展开，渲染当前任务卡、结果/来源、当前网页绑定与可用动作。
 * [POS]: Web 的小精灵展示层：**只呈现，不执行工具、不发任何桌面输入**。
 *        所有文本一律 textContent 落地，模型或网页返回的 HTML/脚本不会被解析（方案 §9 安全呈现）。
 *        M1 的按钮是「放弃并保留草稿」而不是「停止」——runtime 不支持真中断，叫停止就是谎报（方案 §2）。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';

  var el = {};
  var lastRenderedStatus = null;
  var handedOff = new Set();

  function $(id) { return document.getElementById(id); }

  function init() {
    el.panel = $('agent-panel');
    el.status = $('agent-status');
    el.result = $('agent-result');
    el.sources = $('agent-sources');
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
    label.textContent = task.deliveryRecipient ? '已发送' : task.handoffTargetId && task.status === 'succeeded' ? '已交给 ' + task.handoffTargetName : (task.statusText || task.status);
    el.status.append(label);

    if (window.pocketdeskAgent.isActive()) {
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
    var text = (task.text || '').replace(/\s+/g, ' ').trim();
    brief.textContent = text.length > 44 ? text.slice(0, 44) + '…' : text;
    el.result.append(brief);
    var body = task.result || task.error || '';
    if (task.status === 'needsInput') {
      var question = document.createElement('div');
      question.textContent = body;
      el.result.append(question);
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
    if (typeof syncSpriteExpression === 'function') syncSpriteExpression();
    var orb = document.querySelector('.target-sprite');
    if (orb) orb.classList.toggle('is-working', !!task && ['accepted', 'running', 'verifying'].includes(task.status));
    // HTML 默认 hidden 避免启动闪烁；任务到达后必须在小精灵模式显式解除。
    // 父层 hidden 不解开会让整个任务卡（含放弃按钮）永久不可见。
    el.panel.hidden = !task || !(window.pocketdeskIsSpriteSelected && window.pocketdeskIsSpriteSelected())
      || (!window.pocketdeskAgent.isActive() && typeof liveValue === 'function' && !!liveValue());
    renderStatus(task);
    renderResult(task);
    renderSources(task);
    renderPage();
    if (el.abandon) el.abandon.hidden = !window.pocketdeskAgent.isActive();
    if (el.continue) {
      el.continue.hidden = !task || !task.handoffTargetId;
      el.continue.textContent = task && task.handoffTargetName ? '继续聊 ' + task.handoffTargetName + ' →' : '';
    }
    if (task && task.handoffTargetId && task.handoffRequested && task.status === 'succeeded' && !handedOff.has(task.id)) {
      handedOff.add(task.id);
      var key = 'pd-handoff-' + task.id;
      var seen = false;
      try { seen = sessionStorage.getItem(key); sessionStorage.setItem(key, '1'); } catch (_) {}
      // 已切离小精灵或开始写下一条时，不让迟到回执抢走用户正在输入的目标。
      if (!seen && window.pocketdeskIsSpriteSelected?.() && !window.pocketdeskHasDraft?.())
        window.pocketdeskContinueInApp?.(task.handoffTargetId);
    }
    lastRenderedStatus = task ? task.status : null;
  }

  window.pocketdeskAgentPanel = {
    init: init,
    render: render,
    lastStatus: function () { return lastRenderedStatus; }
  };
})();
