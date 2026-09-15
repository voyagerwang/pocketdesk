/**
 * [INPUT]: 消费 agent-client.js 的任务快照与事件、index.html 的 #agent-* 容器。
 * [OUTPUT]: 提供 window.pocketdeskAgentPanel——渲染当前任务卡、结果/来源、当前网页绑定与可用动作。
 * [POS]: Web 的小精灵展示层：**只呈现，不执行工具、不发任何桌面输入**。
 *        所有文本一律 textContent 落地，模型或网页返回的 HTML/脚本不会被解析（方案 §9 安全呈现）。
 *        M1 的按钮是「放弃并保留草稿」而不是「停止」——runtime 不支持真中断，叫停止就是谎报（方案 §2）。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';

  var el = {};
  var lastRenderedStatus = null;

  function $(id) { return document.getElementById(id); }

  function init() {
    el.panel = $('agent-panel');
    el.status = $('agent-status');
    el.result = $('agent-result');
    el.sources = $('agent-sources');
    el.abandon = $('agent-abandon');
    el.newTask = $('agent-new');
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
    if (el.newTask) {
      el.newTask.addEventListener('click', function () {
        window.pocketdeskAgent.detach();
        render();
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
    label.textContent = task.statusText || task.status;
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
    var body = task.result || (task.status === 'failed' ? task.error : '') || '';
    if (!body) {
      // 阶段消息按实际事件产生，不用倒计时假装进度（方案 §7）。
      if (window.pocketdeskAgent.isActive()) {
        var hint = document.createElement('p');
        hint.className = 'agent-hint';
        hint.textContent = '小精灵正在处理，结果会直接出现在这里。';
        el.result.append(hint);
      }
      return;
    }
    var pre = document.createElement('div');
    pre.className = task.status === 'failed' ? 'agent-text is-error' : 'agent-text';
    // textContent 而非 innerHTML：回答里的标签一律当纯文本显示。
    pre.textContent = body;
    el.result.append(pre);
  }

  function renderSources(task) {
    el.sources.textContent = '';
    if (!task || !task.sources || !task.sources.length) return;
    var title = document.createElement('span');
    title.className = 'agent-sources-title';
    title.textContent = '来源：';
    el.sources.append(title);
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
      el.sources.append(link);
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
    renderStatus(task);
    renderResult(task);
    renderSources(task);
    renderPage();
    if (el.abandon) el.abandon.hidden = !window.pocketdeskAgent.isActive();
    if (el.newTask) el.newTask.hidden = !task;
    lastRenderedStatus = task ? task.status : null;
  }

  window.pocketdeskAgentPanel = {
    init: init,
    render: render,
    lastStatus: function () { return lastRenderedStatus; }
  };
})();
