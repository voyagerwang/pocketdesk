/**
 * [INPUT]: app.js 的 authHeaders 配对请求头、phone-files 收件 API 与首页容器。
 * [OUTPUT]: 独立收件列表；每项只保留“下载”和“移除/拒绝”，点击下载时换取短票据并直接交给浏览器，
 *           ZIP 一次下载，失败原地重试；列表轮询代际挡住迟到响应复活已拒绝项。
 * [POS]: 不依赖当前小精灵任务或接收者；隐藏页停止轮询，刷新找回未过期收件，不声称浏览器已保存文件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';
  const base = '/api/v1/phone-files';
  const panel = document.getElementById('phone-files');
  const list = document.getElementById('phone-files-list');
  const notice = document.getElementById('phone-files-notice');
  let timer, loading = false, revision = '', failures = 0, listEpoch = 0;
  const busy = new Set();
  const errors = new Map();
  let files = [];

  // 列表轮询与逐项操作分离保护：capture 只由 poll 使用，捕获发起时的 listEpoch；
  // 任何一次确认/拒绝成功都会推进 listEpoch，让仍在途的旧列表响应整体作废，
  // 不复活已删除项。逐项操作（accept/dismiss）不共用这个序号——不同文件并行接收
  // 的成功响应互不丢弃，同一文件由 busy 集合串行化。
  async function request(path, method = 'GET', capture) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    const captured = capture ? listEpoch : null;
    try {
      const response = await fetch(base + path, { method, headers: authHeaders(), signal: controller.signal, cache: 'no-store' });
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || '收件失败，请稍后重试。');
      if (capture && captured !== listEpoch) return null;
      return result;
    } finally { clearTimeout(timeout); }
  }
  function size(value) {
    return value < 1024 ? value + ' B' : value < 1024 * 1024 ? (value / 1024).toFixed(1) + ' KB' : (value / 1024 / 1024).toFixed(1) + ' MB';
  }
  function button(text, action, id) {
    const node = document.createElement('button');
    node.type = 'button';
    node.textContent = text;
    node.disabled = busy.has(id);
    node.addEventListener('click', action);
    return node;
  }
  function render() {
    panel.hidden = files.length === 0;
    list.replaceChildren();
    files.forEach(file => {
      const row = document.createElement('article');
      row.className = 'phone-file';
      const name = document.createElement('strong');
      name.textContent = file.name;
      const info = document.createElement('p');
      const count = file.fileNames?.length || 1;
      info.textContent = size(file.size) + (count > 1 ? ' · ' + count + ' 个文件 · ZIP' : '') + ' · 保留至 ' + new Date(file.expiresAt * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      row.append(name, info);
      if (count > 1) {
        const details = document.createElement('details');
        const title = document.createElement('summary');
        title.textContent = '查看文件清单';
        const names = document.createElement('ul');
        file.fileNames.forEach(value => { const item = document.createElement('li'); item.textContent = value; names.append(item); });
        details.append(title, names);
        row.append(details);
      }
      const actions = document.createElement('div');
      actions.className = 'phone-file-actions';
      actions.append(button(busy.has(file.id) ? '请稍候…' : '下载', () => download(file), file.id),
        button(file.accepted ? '移除' : '拒绝', () => dismiss(file), file.id));
      const status = document.createElement('p');
      status.setAttribute('role', 'status');
      status.className = errors.has(file.id) ? 'phone-file-error' : '';
      status.textContent = errors.get(file.id) || '点击下载后保存到手机。';
      row.append(actions, status);
      list.append(row);
    });
  }
  async function dismiss(file) {
    if (busy.has(file.id)) return;
    busy.add(file.id); errors.delete(file.id); render();
    try {
      await request('/' + encodeURIComponent(file.id) + '/dismiss', 'POST');
      files = files.filter(value => value.id !== file.id);
      listEpoch += 1;
      revision = '';
    } catch (error) {
      errors.set(file.id, error.name === 'AbortError' ? '请求超时，请重试。' : error.message);
    } finally { busy.delete(file.id); render(); }
  }
  async function download(file) {
    if (busy.has(file.id)) return;
    busy.add(file.id); errors.delete(file.id); render();
    try {
      const result = await request('/' + encodeURIComponent(file.id) + '/accept', 'POST');
      const url = new URL(result.url, location.origin);
      if (url.origin !== location.origin || !url.pathname.startsWith(base + '/download/')) throw new Error('下载地址无效，请重试。');
      file.accepted = true; listEpoch += 1; revision = '';
      location.assign(url.href);
    } catch (error) { errors.set(file.id, error.name === 'AbortError' ? '请求超时，请重试。' : error.message); }
    finally { busy.delete(file.id); render(); }
  }
  async function poll() {
    clearTimeout(timer);
    if (document.hidden || loading) return;
    loading = true;
    try {
      if (!pairToken()) return;
      const result = await request('', 'GET', true);
      if (!result) return;
      failures = 0; notice.textContent = '';
      const next = JSON.stringify(result.files);
      if (next !== revision && busy.size === 0) { files = result.files; revision = next; render(); }
    } catch (_) {
      failures++;
      if (files.length) notice.textContent = '收件列表暂时无法更新，正在重连…';
    } finally {
      loading = false;
      if (!document.hidden) timer = setTimeout(poll, Math.min(15000, 3000 * (failures + 1)));
    }
  }
  document.addEventListener('visibilitychange', () => { clearTimeout(timer); if (!document.hidden) poll(); });
  window.addEventListener('online', poll);
  poll();
})();
