/**
 * [INPUT]: 依赖 app.js 的 authHeaders、浏览器 dialog/fetch/Blob/history 与 index.html 的画面节点。
 * [OUTPUT]: 工具栏入口打开专注画面，自动刷新/暂停、原尺寸查看、多屏选择；返回保留草稿，隐藏取消请求并释放画面。
 * [POS]: Web 的独立查看层，复用配对身份；原生 dialog 隔离后台输入，浏览器返回仅关闭查看层。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(() => {
  const panel = document.querySelector('#screen-view');
  const open = document.querySelector('#screen-open');
  const close = document.querySelector('#screen-close');
  const displays = document.querySelector('#screen-display');
  const displayRow = document.querySelector('#screen-display-row');
  const refresh = document.querySelector('#screen-refresh');
  const auto = document.querySelector('#screen-auto');
  const zoom = document.querySelector('#screen-zoom');
  const status = document.querySelector('#screen-status');
  const empty = document.querySelector('#screen-empty');
  const emptyTitle = document.querySelector('#screen-empty-title');
  const emptyHelp = document.querySelector('#screen-empty-help');
  const permission = document.querySelector('#screen-permission');
  const image = document.querySelector('#screen-image');
  let timer;
  let controller;
  let imageURL;
  let generation = 0;
  let updating = true;
  let historyPending = false;
  let lastUpdate = '';
  const visible = () => panel.open && !document.hidden;
  const ownsHistory = () => history.state?.pocketdeskScreen === true;

  function stop() {
    generation += 1;
    clearTimeout(timer);
    controller?.abort();
    controller = null;
    refresh.disabled = false;
    refresh.textContent = '刷新';
  }

  function releaseImage() {
    image.hidden = true;
    image.removeAttribute('src');
    if (imageURL) URL.revokeObjectURL(imageURL);
    imageURL = null;
    zoom.disabled = true;
  }

  function updateControls() {
    auto.setAttribute('aria-pressed', String(updating));
    auto.textContent = updating ? '暂停更新' : '继续更新';
    if (lastUpdate) status.textContent = `${updating ? '自动更新' : '已暂停'} · 最近画面 ${lastUpdate}`;
  }

  async function request(path, signal, method = 'GET') {
    const response = await fetch(path, { headers: authHeaders(), cache: 'no-store', signal, method });
    if (!response.ok) {
      const result = await response.json();
      throw new Error(response.status === 401 ? '请到电脑端控制台重新扫码配对。' : result.error || '无法获取画面。');
    }
    return response;
  }

  async function capture() {
    if (!visible() || controller) return;
    clearTimeout(timer);
    const current = generation;
    const pending = new AbortController();
    controller = pending;
    refresh.disabled = true;
    refresh.textContent = '获取中…';
    if (!imageURL) {
      empty.hidden = false;
      emptyTitle.textContent = '正在获取画面…';
      emptyHelp.textContent = '稍等片刻，就能看到电脑当前屏幕。';
      permission.hidden = true;
    }
    const timeout = setTimeout(() => pending.abort(), 12000);
    try {
      if (!displays.options.length) {
        const response = await request('/api/screen/displays', pending.signal);
        const result = await response.json();
        if (current !== generation) return;
        displays.replaceChildren(...result.displays.map(display => new Option(display.name, display.id)));
        displayRow.hidden = displays.options.length < 2;
        if (!displays.options.length) throw new Error('未找到显示器。');
      }
      const response = await request(`/api/screen/frame?display=${encodeURIComponent(displays.value)}`, pending.signal);
      const blob = await response.blob();
      if (current !== generation || !visible()) return;
      const previous = imageURL;
      imageURL = URL.createObjectURL(blob);
      image.src = imageURL;
      image.hidden = false;
      empty.hidden = true;
      zoom.disabled = false;
      if (previous) URL.revokeObjectURL(previous);
      lastUpdate = new Date().toLocaleTimeString();
      updateControls();
    } catch (error) {
      if (current !== generation) return;
      updating = false;
      releaseImage();
      lastUpdate = '';
      updateControls();
      empty.hidden = false;
      const needsPermission = /系统设置.*录制/.test(error.message);
      emptyTitle.textContent = needsPermission ? '先允许查看电脑屏幕' : '暂时无法获取画面';
      emptyHelp.textContent = error.name === 'AbortError' ? '连接超时。请检查手机和电脑的网络，再点击刷新。' : error.message;
      permission.hidden = !needsPermission;
      status.textContent = '更新已暂停 · 处理后点击刷新';
      displays.replaceChildren();
      displayRow.hidden = true;
    } finally {
      clearTimeout(timeout);
      if (current === generation) {
        controller = null;
        refresh.disabled = false;
        refresh.textContent = '刷新';
        if (visible() && updating) timer = setTimeout(capture, 1000);
      }
    }
  }

  function closeViewer(fromHistory = false) {
    stop();
    releaseImage();
    panel.close();
    document.body.classList.remove('screen-viewing');
    open.focus({ preventScroll: true });
    if (!fromHistory && ownsHistory()) {
      historyPending = true;
      history.back();
    }
  }

  open.addEventListener('click', () => {
    if (panel.open || historyPending) return;
    // 独立查看层不改草稿、目标或触控板模式，仅收起软键盘。
    document.activeElement?.blur();
    updating = true;
    lastUpdate = '';
    updateControls();
    status.textContent = '正在连接电脑…';
    image.classList.remove('zoomed');
    zoom.setAttribute('aria-pressed', 'false');
    zoom.textContent = '放大画面';
    displays.replaceChildren();
    displayRow.hidden = true;
    history.pushState({ ...history.state, pocketdeskScreen: true }, '');
    document.body.classList.add('screen-viewing');
    panel.showModal();
    capture();
  });
  close.addEventListener('click', () => closeViewer());
  panel.addEventListener('cancel', event => { event.preventDefault(); closeViewer(); });
  window.addEventListener('popstate', () => {
    historyPending = false;
    if (panel.open) closeViewer(true);
    // 浏览器前进不恢复旧截图，也不保留一个无对应画面的历史标记。
    if (ownsHistory()) history.replaceState({ ...history.state, pocketdeskScreen: false }, '');
  });
  // 刷新页面时只显示主界面，清理上一页留下的查看标记。
  if (ownsHistory()) history.replaceState({ ...history.state, pocketdeskScreen: false }, '');
  document.addEventListener('visibilitychange', () => {
    stop();
    if (visible()) capture(); else releaseImage();
  });
  window.addEventListener('pagehide', () => { stop(); releaseImage(); });
  window.addEventListener('pageshow', () => { if (visible()) capture(); });
  refresh.addEventListener('click', capture);
  displays.addEventListener('change', () => { stop(); releaseImage(); capture(); });
  auto.addEventListener('click', () => {
    updating = !updating;
    if (!updating) stop();
    updateControls();
    if (updating) capture();
  });
  zoom.addEventListener('click', () => {
    const enlarged = image.classList.toggle('zoomed');
    zoom.setAttribute('aria-pressed', String(enlarged));
    zoom.textContent = enlarged ? '适应屏幕' : '放大画面';
  });
  permission.addEventListener('click', async () => {
    permission.disabled = true;
    try {
      await request('/api/screen/permission', undefined, 'POST');
      emptyHelp.textContent = '请在 Mac 的系统设置里允许 PocketDesk 录屏，然后点击刷新。系统如提示重启应用，请先重启。';
    } catch (error) { emptyHelp.textContent = error.message; }
    finally { permission.disabled = false; }
  });
})();
