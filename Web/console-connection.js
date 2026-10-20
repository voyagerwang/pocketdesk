/**
 * [INPUT]: 消费 Server /api/status 的 workspaceURL、ipWorkspaceURL 与 phoneLastSeen；二维码请求复用 /api/qr 的 host/ip 两种入口。
 * [OUTPUT]: window.PocketDeskConsoleConnection.render(status) 与 unavailable()；投影当前 IP 主入口、需手机支持的可选电脑名称入口及在线事实，无地址或服务失败时撤下旧链接和二维码。
 * [POS]: 电脑控制台的连接展示边界；从 console.html 的状态轮询独立出来，使地址刷新先于接收者查询，不持久化授权、不主动跳转手机地址。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';

  const byId = id => document.getElementById(id);
  const primary = {
    image: byId('qr-ip'), link: byId('ipUrl'), message: byId('connect-message'), type: 'ip'
  };
  const named = {
    image: byId('qr-host'), link: byId('hostUrl'), message: byId('fallback-message'), type: 'host'
  };
  const namedSection = byId('connectionFallback');
  const label = byId('connectionLabel');
  const help = byId('connectionHelp');
  const phoneState = byId('phoneState');

  // 地址中的授权只交给链接与二维码；可见文本只展示 origin，避免凭据混入说明。
  function invitation(value) {
    if (typeof value !== 'string' || !value) return null;
    try {
      const url = new URL(value);
      if (url.protocol !== 'http:' || url.username || url.password || url.hash || url.pathname !== '/' ||
          url.searchParams.size !== 1 || !/^[A-Za-z0-9_-]{20,128}$/.test(url.searchParams.get('token') || '')) return null;
      return {
        url: url.href, address: url.origin + '/',
        named: url.hostname.endsWith('.local'), ipv4: /^\d{1,3}(?:\.\d{1,3}){3}$/.test(url.hostname)
      };
    } catch { return null; }
  }

  function clear(entry, message) {
    entry.image.hidden = true;
    entry.image.removeAttribute('src');
    delete entry.image.dataset.url;
    delete entry.image.dataset.error;
    entry.link.removeAttribute('href');
    entry.link.textContent = message;
    entry.link.classList.add('is-empty');
    entry.message.hidden = true;
    entry.message.textContent = '';
    entry.message.classList.remove('error');
  }

  function show(entry, target) {
    entry.link.textContent = target.address;
    entry.link.href = target.url;
    entry.link.classList.remove('is-empty');
    if (entry.image.dataset.url === target.url && !entry.image.dataset.error) return;
    // 先撤下旧图，避免地址已更新时仍能扫到上一次的二维码。
    entry.image.hidden = true;
    entry.image.removeAttribute('src');
    entry.image.dataset.url = target.url;
    delete entry.image.dataset.error;
    entry.message.textContent = '正在生成连接码…';
    entry.message.classList.remove('error');
    entry.message.hidden = false;
    entry.image.src = '/api/qr?type=' + entry.type + '&t=' + Date.now();
  }

  [primary, named].forEach(entry => {
    entry.image.onload = () => {
      if (!entry.image.dataset.url) return;
      entry.image.hidden = false;
      entry.message.hidden = true;
    };
    entry.image.onerror = () => {
      if (!entry.image.dataset.url) return;
      entry.image.hidden = true;
      entry.image.removeAttribute('src');
      entry.image.dataset.error = 'true';
      entry.message.textContent = '连接码生成失败，请稍候；也可打开上方网址。';
      entry.message.classList.add('error');
      entry.message.hidden = false;
    };
  });

  function render(status) {
    const workspaceURL = invitation(status && status.workspaceURL);
    const ipURL = invitation(status && status.ipWorkspaceURL);
    // 首次连接不依赖手机解析电脑名称；缺少 IP 时也不把 .local 默认为可用入口。
    const mainURL = ipURL && ipURL.ipv4 ? ipURL : workspaceURL && workspaceURL.ipv4 ? workspaceURL : null;
    const namedURL = workspaceURL && workspaceURL.named ? workspaceURL : null;
    label.textContent = '扫码连接手机 · App 和浏览器通用';
    help.textContent = '手机和电脑需连同一 Wi-Fi。当前 IP 可能随网络变化。';
    if (mainURL) show(primary, mainURL);
    else clear(primary, '暂无 IP 连接网址，请确认电脑已连接 Wi-Fi。');

    namedSection.hidden = !namedURL;
    if (namedURL) show(named, namedURL);
    else {
      namedSection.open = false;
      clear(named, '暂无电脑名称连接地址。');
    }

    const seen = Number(status && status.phoneLastSeen) * 1000;
    phoneState.className = 'pill';
    if (!Number.isFinite(seen) || seen <= 0) phoneState.textContent = '等待手机连接…';
    else if (Date.now() - seen < 15000) {
      phoneState.textContent = '手机已连接'; phoneState.classList.add('ready');
    } else phoneState.textContent = '手机最后连接于 ' + Math.round((Date.now() - seen) / 60000) + ' 分钟前';
  }

  function unavailable() {
    clear(primary, '服务未响应，请确认电脑上的 PocketDesk 正在运行。');
    clear(named, '电脑名称连接暂不可用。');
    namedSection.hidden = true;
    namedSection.open = false;
    phoneState.textContent = '手机状态暂不可用';
    phoneState.className = 'pill';
  }

  window.PocketDeskConsoleConnection = { render, unavailable };
})();
