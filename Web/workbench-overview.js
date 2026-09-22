/**
 * [INPUT]: 已配对主体、既有接收者状态与 Workbench 的 G2 固定只读接口。
 * [OUTPUT]: 显式展开/刷新任务、当前轮成果、机主记忆和独立执行规则；不执行或修改任务。
 * [POS]: 手机只读投影，无本地持久副本；后台、切走、换配对与失败均清理私密展示。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';
  const panel = document.getElementById('workbench-overview');
  if (!panel) return;
  const status = document.getElementById('workbench-overview-status');
  const list = document.getElementById('workbench-overview-list');
  const result = document.getElementById('workbench-overview-result');
  const more = document.getElementById('workbench-overview-more');
  const tabs = [...panel.querySelectorAll('[data-workbench-view]')];
  let owner = '', generation = 0, controller = null, busy = false, mode = 'tasks', nextCursor = null;
  const token = () => { try { return pairToken(); } catch { return ''; } };
  const node = (tag, text, className) => {
    const element = document.createElement(tag);
    if (text !== undefined) element.textContent = text;
    if (className) element.className = className;
    return element;
  };
  const date = value => Number.isNaN(Date.parse(value)) ? '时间未提供' : new Date(value).toLocaleString();
  function clear() { list.replaceChildren(); result.replaceChildren(); nextCursor = null; more.hidden = true; }
  function controls() {
    panel.setAttribute('aria-busy', String(busy));
    panel.querySelectorAll('button').forEach(button => { button.disabled = busy; });
    tabs.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.workbenchView === mode)));
  }
  function invalidate(message) {
    generation++; controller?.abort(); controller = null; busy = false; owner = ''; clear();
    status.textContent = message; controls();
  }
  function render() {
    panel.hidden = !window.pocketdeskIsSpriteSelected?.();
    if (panel.hidden || document.hidden) {
      invalidate('仅在查看时从工作台读取，展开后点刷新。'); panel.open = false;
    } else if (owner && owner !== token()) {
      invalidate('配对已变化，旧内容已清除；请重新刷新。');
    }
  }
  function validate(value, projection) {
    if (value?.protocolVersion !== 1 || value.authority !== 'workbench' || value.scopeRef !== 'workbench:owner'
      || value.projection !== projection || !Number.isFinite(Date.parse(value.generatedAt))) throw new Error('工作台回包不匹配，请刷新核对。');
    return value;
  }
  async function load(path, projection, draw, artifactOnly = false) {
    render();
    if (panel.hidden || document.hidden || !panel.open) return;
    if (busy) return;
    const auth = token();
    if (!auth) { invalidate('需要重新配对才能查看工作台。'); return; }
    if (artifactOnly) result.replaceChildren(); else clear();
    owner = auth; busy = true; controls(); status.textContent = '正在读取工作台…';
    const run = ++generation, abort = new AbortController(); controller = abort;
    const timer = setTimeout(() => abort.abort(), 15000);
    try {
      const response = await fetch('/api/v1/workbench/views/' + path, {
        method: 'GET', headers: authHeaders(), cache: 'no-store', redirect: 'error', signal: abort.signal
      });
      const value = await response.json();
      if (run !== generation || auth !== token()) return;
      if (!response.ok) throw new Error(response.status === 403
        ? '尚未获得机主只读授权，请在工作台电脑端配置后刷新。'
        : response.status === 401 ? '配对已失效，请重新配对。'
          : response.status === 404 ? '当前轮次暂无可核验成果，请刷新任务后再查看。'
            : response.status === 503 ? '工作台连接尚未启用，请在电脑端完成接入后刷新。'
              : '工作台暂时无法读取，请稍后刷新。');
      draw(validate(value, projection));
      status.textContent = '读取于 ' + date(value.generatedAt) + ' · 非实时，请按需刷新';
    } catch (error) {
      if (run !== generation || auth !== token()) return;
      clear();
      status.textContent = error.name === 'AbortError' || error instanceof TypeError
        ? '连接中断或超时，旧内容已清除；请刷新重试。'
        : error.message;
    } finally {
      clearTimeout(timer);
      if (run === generation) {
        busy = false; controller = null;
        if (auth !== token()) invalidate('配对已变化，旧内容已清除；请重新刷新。');
        controls();
      }
    }
  }
  function showTasks(value) {
    if (!Array.isArray(value.tasks) || value.tasks.length > 20
      || !(value.nextCursor === null || Number.isSafeInteger(value.nextCursor) && value.nextCursor > 0)) throw new Error('任务回包不合法，请刷新。');
    if (!value.tasks.length) list.append(node('p', '暂无工作台来源任务。'));
    value.tasks.forEach(task => {
      if (!/^(?:WB-)?\d{8}-\d+$/.test(task.id) || !Number.isSafeInteger(task.attempt) || task.attempt < 1) throw new Error('任务归属信息不完整，请刷新。');
      const item = node('article', undefined, 'workbench-overview-item');
      item.append(node('h3', task.objective), node('p', task.statusLabel + (task.statusDetail ? ' · ' + task.statusDetail : '')));
      item.append(node('small', `${task.id} · 第 ${task.attempt} 轮 · ${task.executor || '未指定执行者'}${task.projectName ? ' · ' + task.projectName : ''}`));
      item.append(node('small', '更新于 ' + date(task.updatedAt)));
      const view = node('button', '查看本轮成果'); view.type = 'button';
      view.addEventListener('click', () => load('task-result/' + task.id, 'task_result', artifact => {
        if (artifact.taskId !== task.id || artifact.attempt !== task.attempt || typeof artifact.content !== 'string') throw new Error('任务轮次已变化，请刷新任务后再查看。');
        result.append(node('h3', task.id + ' · 第 ' + artifact.attempt + ' 轮成果'));
        result.append(node('p', artifact.reviewed ? '工作台记录：已完成验收。' : '工作台记录：成果尚未验收。'));
        if (artifact.truncated) result.append(node('p', '正文较长，仅展示前 100,000 字符；完整内容请在工作台查看。'));
        result.append(node('pre', artifact.content, 'workbench-overview-content'));
        result.focus();
      }, true));
      item.append(view); list.append(item);
    });
    nextCursor = value.nextCursor; more.hidden = nextCursor === null;
  }
  function showMemories(value) {
    if (!Array.isArray(value.entries) || value.entries.length > 200) throw new Error('记忆回包不合法，请刷新。');
    const rule = value.executionPreference;
    list.append(node('h3', '执行规则（独立于普通记忆）'));
    list.append(node('p', rule ? `${rule.executor} · ${rule.requestedModel || '未固定模型'} · ${rule.requestedCostPolicy === 'free_only' ? '仅限免费' : '未设费用限制'}` : '未设置长期执行规则。'));
    if (rule) list.append(node('small', '更新于 ' + date(rule.updatedAt)));
    if (value.instructions) { list.append(node('h3', '已保存的整体偏好'), node('pre', value.instructions, 'workbench-overview-content')); }
    list.append(node('h3', '显式记忆'));
    if (!value.entries.length) list.append(node('p', '暂无工作台身份的显式记忆。'));
    const kinds = { preference: '偏好', fact: '事实', skill_preference: '技能偏好', task_preference: '任务偏好' };
    const sources = { manual: '手动', command: '明确指令', conversation: '会话确认' };
    value.entries.forEach(entry => {
      const item = node('article', undefined, 'workbench-overview-item');
      item.append(node('p', entry.content), node('small', `${entry.status === 'disabled' ? '已停用' : '启用中'} · ${kinds[entry.kind] || entry.kind} · 来源：${sources[entry.source] || entry.source} · ${date(entry.updatedAt)}`));
      list.append(item);
    });
    if (value.hasMore) list.append(node('p', '仅显示最近 200 条，完整记忆请在工作台查看。'));
  }
  const refresh = () => load(mode, mode === 'tasks' ? 'task_page' : 'memory_page', mode === 'tasks' ? showTasks : showMemories);
  tabs.forEach(button => button.addEventListener('click', () => { mode = button.dataset.workbenchView; refresh(); }));
  document.getElementById('workbench-overview-refresh').addEventListener('click', refresh);
  more.addEventListener('click', () => { if (nextCursor !== null) load('tasks/' + nextCursor, 'task_page', showTasks); });
  panel.addEventListener('toggle', () => {
    if (!panel.open) invalidate('已收起，私密内容已清除。');
    else if (!owner) refresh();
  });
  window.addEventListener('storage', render);
  window.addEventListener('focus', render);
  window.addEventListener('pagehide', () => invalidate('页面已离开，请重新刷新。'));
  window.addEventListener('offline', () => invalidate('手机已离线，旧内容已清除；恢复连接后请刷新。'));
  document.addEventListener('visibilitychange', render);
  // 同页重新配对不会产生 storage 事件；只核对身份，不轮询业务或模型。
  setInterval(() => { if (owner && owner !== token()) render(); }, 1000);
  window.pocketdeskWorkbenchOverview = { render };
  render(); controls();
})();
