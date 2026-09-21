/**
 * [INPUT]: app.js 的 authHeaders 配对请求头、phone-files 收件 API 与首页容器。
 * [OUTPUT]: 独立收件列表；手机明确接收后给一次点击的下载链接（不依赖程序化 click 的用户手势），
 *           ZIP 一次下载，拒绝/移除与失败原地重试；列表轮询代际挡住迟到响应复活已拒绝项，
 *           逐项操作互不共用代际；私网HTTPS将明确标注未加密的局域网下载前置，仍须用户点击，不自动降级。
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
  const started = new Set();
  const errors = new Map();
  const tickets = new Map();
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
  // 真实 <a> 下载链接：确认接口是异步 POST，用户手势在安卓浏览器里可能已过期，
  // 所以接收后给一次明确点击的链接，而不是程序化 click（会被当成非手势下载拦截）。
  function downloadLink(file) {
    const ticket = tickets.get(file.id);
    if (!ticket) return null;
    const link = document.createElement('a');
    link.href = ticket;
    link.setAttribute('download', file.name);
    link.rel = 'noreferrer noopener';
    link.target = '_blank';
    link.textContent = file.accepted ? '点击下载' : '接收';
    link.className = 'phone-file-download';
    link.addEventListener('click', () => {
      started.add(file.id);
      // 保留被点击的链接节点，避免WebView交给系统下载器之前重绘移除它。
      const status = link.closest('article')?.querySelector('[role="status"]');
      if (status) status.textContent = '已发起下载，请在浏览器下载列表查看；未完成可再点一次下载。';
    });
    return link;
  }
  // HTTPS 页面证书的临时放行未必被系统下载器继承；只提供用户主动选择的局域网兼容入口。
  // 不自动降级，不携带长期配对 token，不为公网或自定义端口猜测 HTTP 地址。
  function compatibilityLink(file) {
    const host = location.hostname;
    const local = /^192\.168\.\d+\.\d+$/.test(host) || /^10\.\d+\.\d+\.\d+$/.test(host) || /^172\.(1[6-9]|2\d|3[01])\.\d+\.\d+$/.test(host);
    if (!local || location.protocol !== 'https:' || location.port !== '46487') return null;
    const link = downloadLink(file);
    if (!link) return null;
    const url = new URL(link.href);
    url.protocol = 'http:'; url.port = '46387';
    link.href = url.href;
    link.removeAttribute('download');
    link.textContent = '局域网兼容下载（未加密）';
    link.className = 'phone-file-download';
    return link;
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
      if (file.accepted) {
        const link = downloadLink(file);
        const fallback = compatibilityLink(file);
        if (fallback) {
          actions.append(fallback);
          if (link) { link.textContent = 'HTTPS 下载'; link.classList.add('phone-file-secondary'); }
        }
        if (link) actions.append(link);
        actions.append(button('换新下载链接', () => act(file, 'accept'), file.id),
          button('移除', () => act(file, 'dismiss'), file.id));
      } else {
        actions.append(button(busy.has(file.id) ? '请稍候…' : count > 1 ? '接收全部' : '接收', () => act(file, 'accept'), file.id),
          button('拒绝', () => act(file, 'dismiss'), file.id));
      }
      const status = document.createElement('p');
      status.setAttribute('role', 'status');
      status.className = errors.has(file.id) ? 'phone-file-error' : '';
      status.textContent = errors.get(file.id) || (started.has(file.id) ? '已发起下载，请在浏览器下载列表查看；未完成可再点一次下载。' : file.accepted ? (tickets.has(file.id) ? '已确认接收，请点击上方下载按钮。' : '请先点击“换新下载链接”，再下载。') : '等待你确认接收');
      row.append(actions, status);
      if (file.accepted) {
        const fallback = compatibilityLink(file);
        if (fallback) {
          const explanation = document.createElement('p');
          explanation.textContent = '同一可信 Wi-Fi 下可直接选局域网下载（未加密）。HTTPS 下载取决于系统下载器是否信任电脑证书。';
          row.append(explanation);
        }
      }
      list.append(row);
    });
  }
  async function act(file, action) {
    if (busy.has(file.id)) return;
    busy.add(file.id); errors.delete(file.id); render();
    try {
      const result = await request('/' + encodeURIComponent(file.id) + '/' + action, 'POST');
      if (!result) return;
      if (action === 'accept') {
        const url = new URL(result.url, location.origin);
        if (url.origin !== location.origin || !url.pathname.startsWith(base + '/download/')) {
          throw new Error('下载地址无效，请重新接收。');
        }
        tickets.set(file.id, url.href);
        file.accepted = true;
      } else {
        files = files.filter(value => value.id !== file.id);
        started.delete(file.id);
        tickets.delete(file.id);
      }
      listEpoch += 1;
      revision = '';
    } catch (error) {
      errors.set(file.id, error.name === 'AbortError' ? '请求超时，请重试。' : error.message);
    } finally { busy.delete(file.id); render(); }
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
