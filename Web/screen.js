/**
 * [INPUT]: 依赖 app.js 的 authHeaders、浏览器 dialog/fetch/Blob/history 与 index.html 的画面节点。
 * [OUTPUT]: 工具栏入口打开专注画面，自动刷新/暂停、原尺寸查看、多屏选择；PiP 悬浮窗常驻、点画面移光标（悬浮窗内点击顺带单击）；
 *           返回保留草稿，隐藏取消请求并释放画面。
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

  // PiP 悬浮窗：与全屏查看器共用同一轮询循环与 Blob URL，操作不离开主界面。
  const pip = document.querySelector('#screen-pip');
  const pipImage = document.querySelector('#pip-image');
  const pipBadge = document.querySelector('#pip-open');   // 全屏查看器里的"悬浮"按钮
  const pipExpand = document.querySelector('#pip-expand'); // 悬浮窗上的"展开"回全屏
  const pipClose = document.querySelector('#pip-close');
  const pipToggle = document.querySelector('#screen-pip-toggle'); // 发送行上的小屏入口

  let timer;
  let controller;
  let imageURL;
  let generation = 0;
  let updating = true;
  let historyPending = false;
  let lastUpdate = '';
  // 悬浮窗模式：off = 未开启；on = 常驻缩略图（轮询持续）
  let pipMode = false;
  const visible = () => (panel.open || pipMode) && !document.hidden;
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
    pipImage.removeAttribute('src');
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
        displayRow.hidden = displays.options.length < 2 || pipMode;
        if (!displays.options.length) throw new Error('未找到显示器。');
      }
      const response = await request(`/api/screen/frame?display=${encodeURIComponent(displays.value)}`, pending.signal);
      const blob = await response.blob();
      if (current !== generation || !visible()) return;
      const previous = imageURL;
      imageURL = URL.createObjectURL(blob);
      // 全屏与悬浮窗共用同一帧：两个 <img> 引用同一 objectURL，零拷贝。
      image.src = imageURL;
      image.hidden = false;
      if (pipMode) pipImage.src = imageURL;
      empty.hidden = true;
      zoom.disabled = false;
      if (previous) URL.revokeObjectURL(previous);
      lastUpdate = new Date().toLocaleTimeString();
      updateControls();
    } catch (error) {
      if (current !== generation) return;
      // 瞬态错误（超时/5xx）保留最后一帧：悬浮窗置灰提示但不清屏，自动退避重试。
      updating = false;
      lastUpdate = '';
      updateControls();
      const transient = error.name === 'AbortError' || (error.message || '').includes('稍后重试');
      if (!imageURL || !transient) {
        releaseImage();
        empty.hidden = false;
        const needsPermission = /系统设置.*录制/.test(error.message);
        emptyTitle.textContent = needsPermission ? '先允许查看电脑屏幕' : '暂时无法获取画面';
        emptyHelp.textContent = error.name === 'AbortError' ? '连接超时。请检查手机和电脑的网络，再点击刷新。' : error.message;
        permission.hidden = !needsPermission;
        displays.replaceChildren();
        displayRow.hidden = true;
        status.textContent = '更新已暂停 · 处理后点击刷新';
      } else {
        status.textContent = '连接不稳，正在重试…';
        timer = setTimeout(capture, 2000);
      }
    } finally {
      clearTimeout(timeout);
      if (current === generation) {
        controller = null;
        refresh.disabled = false;
        refresh.textContent = '刷新';
        if (visible() && updating && !timer) timer = setTimeout(capture, 1000);
      }
    }
  }

  /* ---------- 点画面移光标 ---------- */

  // 点击 <img>：把像素坐标换算成显示器的比例坐标发给 Mac。
  // 全屏查看器里点 = 仅移动光标（下一步"返回操控"用触控板点击）；
  // 悬浮窗里点 = 移动 + 左键单击（所见即所得）。
  function sendTap(event, target) {
    const rect = target.getBoundingClientRect();
    const rx = (event.clientX - rect.left) / rect.width;
    const ry = (event.clientY - rect.top) / rect.height;
    if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return;
    if (!window.pocketdeskSend) { status.textContent = '触控板通道未连接，无法点画面移动光标。'; return; }
    window.pocketdeskSend({ t: 'tap', rx, ry, display: Number(displays.value), click: target === pipImage });
    status.textContent = `光标已移至画面位置${target === pipImage ? '（已单击）' : ''}`;
  }

  image.addEventListener('click', event => sendTap(event, image));
  pipImage.addEventListener('click', event => sendTap(event, pipImage));

  /* ---------- PiP 悬浮窗 ---------- */

  function showPip() {
    pipMode = true;
    pip.hidden = false;
    if (imageURL) pipImage.src = imageURL;
    document.body.classList.add('pip-on');
    pipToggle.setAttribute('aria-pressed', 'true');
    if (!panel.open) {
      updating = true;
      updateControls();
      status.textContent = '悬浮窗已开启';
      capture();
    }
  }

  function hidePip() {
    pipMode = false;
    pip.hidden = true;
    document.body.classList.remove('pip-on');
    pipToggle.setAttribute('aria-pressed', 'false');
    // 悬浮窗是唯一视图时，关闭它就停轮询。
    if (!panel.open) { stop(); releaseImage(); }
    if (panel.open) displayRow.hidden = displays.options.length < 2;
  }

  // 入口一：发送行上的小屏图标，直接悬浮。
  pipToggle.addEventListener('click', () => { pip.hidden ? showPip() : hidePip(); });
  // 入口二：全屏查看器里"悬浮"按钮，全屏转悬浮。
  pipBadge.addEventListener('click', () => {
    closeViewer();       // 关全屏（会退 history、还原焦点）
    showPip();
  });
  pipClose.addEventListener('click', hidePip);
  // 悬浮窗"展开"→关浮层、开全屏；全屏"悬浮"→关全屏、开浮层。
  pipExpand.addEventListener('click', () => { hidePip(); openViewer(); });

  /* ---------- 全屏查看器 ---------- */

  function openViewer() {
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
    displayRow.hidden = displays.options.length < 2 || pipMode;
    history.pushState({ ...history.state, pocketdeskScreen: true }, '');
    document.body.classList.add('screen-viewing');
    panel.showModal();
    capture();
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
    // 全屏关到悬浮窗模式：轮询继续。
    if (pipMode) { updating = true; updateControls(); capture(); }
  }

  open.addEventListener('click', openViewer);
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

  /* ---------- 悬浮窗拖动（Pointer Events，适配触屏） ---------- */

  (() => {
    let dragId = null;
    let startX = 0, startY = 0, originX = 0, originY = 0;
    pip.addEventListener('pointerdown', event => {
      if (event.target === pipImage) return;   // 图片区域留给"点画面移光标"
      dragId = event.pointerId;
      const rect = pip.getBoundingClientRect();
      startX = event.clientX; startY = event.clientY;
      originX = rect.left; originY = rect.top;
      pip.setPointerCapture(dragId);
    });
    pip.addEventListener('pointermove', event => {
      if (event.pointerId !== dragId) return;
      const nextX = Math.min(window.innerWidth - 60, Math.max(0, originX + event.clientX - startX));
      const nextY = Math.min(window.innerHeight - 60, Math.max(0, originY + event.clientY - startY));
      pip.style.left = `${nextX}px`;
      pip.style.top = `${nextY}px`;
      pip.style.right = 'auto';
      pip.style.bottom = 'auto';
    });
    const endDrag = event => { if (event.pointerId === dragId) dragId = null; };
    pip.addEventListener('pointerup', endDrag);
    pip.addEventListener('pointercancel', endDrag);
  })();
})();
