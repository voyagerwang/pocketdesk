/**
 * [INPUT]: 依赖 pocketdeskLockState 同步独立解锁表单； 依赖 ScreenFrames/Geometry/Gestures/Pip、共享控制通道与可见输入区。
 * [OUTPUT]: 编排浮窗和正立全屏、默认点击/滚动合一与长按放大瞄准、小窗屏幕直选与全屏显示器快捷轮换、可见键盘视口与首页隔离、画面新鲜度、锁屏/断屏恢复、控制权与光标呈现。
 * [POS]: Web 画面工作台入口；几何、网络与手势分别委托独立模块，退出统一释放资源。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(() => {
  const $ = id => document.getElementById(id);
  const panel = $('screen-view'), viewport = panel.querySelector('.screen-viewport');
  const image = $('screen-image'), cursor = $('screen-cursor'), menu = $('screen-menu');
  const geometry = new ScreenGeometry();
  let displays = [], display = 0, port = 0, imageURL, cursorSample, cursorAt = 0;
  let bakedCursor = true, watch = false, mode = 'touch', contextPoint;
  let openEpoch = 0, permissionTimer, requestedPermission = false, noticeTimer;
  let frameNote = '', transientNote = '', hadReady = false;
  let screenLocked = false, recoveryBusy = false, lastRecovery = 0;
  // 默认始终轻点点击、滑动滚动，指针模式仅在更多中按需启用。
  let aimPoint = null, homeScroll = 0;
  const fullscreen = () => panel.open && panel.classList.contains('fullscreen');
  const ready = () => fullscreen() && !document.hidden && !watch && !screenLocked && frames.fresh() && window.pocketdeskControlReady();
  const send = command => {
    if (!['up', 'scrollEnd', 'cancel', 'cursor-subscribe', 'take-control'].includes(command.t) && !ready()) return false;
    const sent = window.pocketdeskSend(command);
    if (!sent && !['up', 'scrollEnd', 'cancel'].includes(command.t)) feedback(inputBlockReason());
    else if (!['up', 'scrollEnd', 'cancel'].includes(command.t)) frames.interact();
    return sent;
  };
  function paintNotice() {
    const text = screenLocked ? '电脑已锁屏' : transientNote || frameNote || controlBlockReason();
    $('screen-notice').textContent = text; $('screen-notice').hidden = !text;
  }
  function controlBlockReason() {
    if (watch) return '仅观看 · 在更多中恢复控制';
    const state = window.pocketdeskControlState();
    if (state === 'permission') return '请在电脑上允许辅助功能';
    if (state === 'connecting') return '控制连接正在重连';
    if (state === 'viewer') return '另一页面正在控制 · 可在更多中接管';
    return '';
  }
  function inputBlockReason() {
    if (screenLocked) return '电脑已锁屏，请先解锁';
    return controlBlockReason() || (!frames.fresh() ? frameNote || '正在获取新画面，请稍候' : '');
  }
  function feedback(text) {
    clearTimeout(noticeTimer); transientNote = text; paintNotice();
    if (text) noticeTimer = setTimeout(() => { transientNote = ''; paintNotice(); }, 3500);
  }
  function cancel() {
    gestures.cancel(); send({ t: 'cancel' }); cursor.hidden = true;
    $('screen-context').hidden = true;
  }
  function paint() {
    const z = geometry.zoom;
    image.style.transform = `translate3d(${z.x}px,${z.y}px,0) scale(${z.scale})`;
    paintCursor();
  }
  function paintCursor() {
    const visible = fullscreen() && frames.fresh() && !bakedCursor && cursorSample?.displayId === display && geometry.base && performance.now() - cursorAt < 2000;
    cursor.hidden = !visible;
    if (!visible) return;
    const p = geometry.project(cursorSample.rx, cursorSample.ry);
    cursor.style.transform = `translate3d(${p.x}px,${p.y}px,0)`;
  }
  function paintAim() {
    const lens = $('screen-aim');
    lens.hidden = !aimPoint || !geometry.base || !frames.fresh();
    if (lens.hidden) return;
    const size = 120, magnification = 3, g = geometry, point = g.project(aimPoint.rx, aimPoint.ry);
    const width = g.base.width * g.zoom.scale * magnification;
    const height = g.base.height * g.zoom.scale * magnification;
    lens.style.backgroundImage = `url("${image.src}")`;
    lens.style.backgroundSize = `${width}px ${height}px`;
    lens.style.backgroundPosition = `${size/2 - aimPoint.rx * width}px ${size/2 - aimPoint.ry * height}px`;
    lens.style.left = `${Math.max(0, Math.min(g.view.width-size, point.x-size/2))}px`;
    lens.style.top = `${Math.max(0, Math.min(g.view.height-size, point.y > size+28 ? point.y-size-28 : point.y+28))}px`;
  }
  function measure() {
    if (!panel.open || image.hidden) return;
    const rect = viewport.getBoundingClientRect(), old = geometry.viewport;
    const rotated = fullscreen() && rect.height > rect.width;
    viewport.classList.toggle('rotated', rotated);
    viewport.style.setProperty('--surface-width', `${rect.height}px`);
    viewport.style.setProperty('--surface-height', `${rect.width}px`);
    if (!rect.width || !rect.height) return;
    if (old && geometry.base && geometry.rotated === rotated && old.left === rect.left && old.top === rect.top && old.width === rect.width && old.height === rect.height
      && geometry.imageWidth === image.naturalWidth && geometry.imageHeight === image.naturalHeight) return;
    gestures.cancel();
    geometry.measure(rect, image.naturalWidth, image.naturalHeight, displays.find(d => d.id === display), rotated);
    geometry.imageWidth = image.naturalWidth; geometry.imageHeight = image.naturalHeight; paint();
  }
  function layout() {
    if (fullscreen()) {
      const v = window.visualViewport;
      panel.classList.toggle('compact-height', (v?.height || innerHeight) < 360);
      for (const [key, value] of Object.entries({ left: v?.offsetLeft || 0, top: v?.offsetTop || 0, width: v?.width || innerWidth, height: v?.height || innerHeight })) {
        panel.style.setProperty(`--screen-${key}`, `${value}px`);
      }
    } else pip.paint();
    requestAnimationFrame(measure);
  }
  const pip = new ScreenPip(panel, measure);
  for (const edge of ['n', 'ne', 'e', 'se', 's', 'sw', 'w', 'nw']) {
    const handle = document.createElement('div'); handle.className = `screen-resize ${edge}`; handle.dataset.edge = edge; panel.appendChild(handle);
  }
  const gestures = new ScreenGestures(viewport, {
    active: () => fullscreen() && !image.hidden, ready, blockedReason: inputBlockReason, geometry, display: () => display, send,
    sensitivity: () => typeof sensitivity === 'number' ? sensitivity : 1,
    doubleClickMs: () => window.pocketdeskControlInfo().doubleClickMs || 350,
    feedback, paint, interact: () => frames.interact(),
    dismissKeyboard: () => {
      if (!window.pocketdeskKeyboardActive()) return false;
      window.pocketdeskHideKeyboard(); return true;
    },
    touch: (x, y) => {
      const dot = $('screen-touch'), p = geometry.local(x, y);
      dot.hidden = false; dot.style.left = `${p.x}px`; dot.style.top = `${p.y}px`;
      clearTimeout(dot.hideTimer); dot.hideTimer = setTimeout(() => { dot.hidden = true; }, 180);
    },
    aim: point => { aimPoint = point; paintAim(); },
    context: point => { contextPoint = point; $('screen-context').hidden = false; },
  });
  const frames = new ScreenFrames({
    async present(blob, meta, generation) {
      const url = URL.createObjectURL(blob), next = new Image(); next.src = url;
      try { await next.decode(); }
      catch (error) { URL.revokeObjectURL(url); throw error; }
      if (generation !== frames.epoch || !panel.open) { URL.revokeObjectURL(url); return; }
      const previous = imageURL; imageURL = url; image.src = url;
      bakedCursor = meta.cursorIncluded !== false;
      image.hidden = false; $('screen-empty').hidden = true; $('screen-permission').hidden = true;
      if (previous) URL.revokeObjectURL(previous);
      // decode 已完成；下一次布局读取使用新图片的固有尺寸。
      requestAnimationFrame(() => { measure(); paintAim(); });
    },
    state(text) { frameNote = text; paintNotice(); paintCursor(); },
  });
  function subscribeCursor() { window.pocketdeskSend({ t: 'cursor-subscribe', enabled: fullscreen() && !document.hidden }); }
  function startFrames() {
    if (display && panel.open && !document.hidden) frames.start(display, fullscreen(), port);
    subscribeCursor();
  }
  async function loadDisplays(epoch = openEpoch) {
    try {
      const r = await fetch('/api/screen/displays', { headers: authHeaders(), cache: 'no-store' });
      const data = await r.json();
      if (!panel.open || epoch !== openEpoch) return;
      if (!r.ok) {
        $('screen-empty-help').textContent = data.error || '暂时无法读取显示器';
        $('screen-permission').hidden = false;
        if (!requestedPermission && data.canRequest) requestPermission();
        throw new Error(data.error || '请在电脑上开启屏幕录制权限');
      }
      displays = data.displays || []; port = data.streamPort;
      if (!displays.length) throw new Error('未发现可用显示器');
      if (!displays.some(d => d.id === display)) display = displays[0].id;
      $('screen-display').replaceChildren(...displays.map(d => new Option(d.name, d.id)));
      paintDisplay(); startFrames();
      clearTimeout(permissionTimer);
    } catch (error) {
      if (!panel.open || epoch !== openEpoch) return;
      frameNote = error.message; paintNotice();
    }
  }
  async function requestPermission() {
    requestedPermission = true; const epoch = openEpoch;
    try { await fetch('/api/screen/permission', { method: 'POST', headers: authHeaders() }); } catch {}
    feedback('请在电脑上允许屏幕录制，允许后会自动连接');
    let attempts = 0;
    const poll = async () => {
      if (!panel.open || epoch !== openEpoch || ++attempts > 30) return;
      await loadDisplays(epoch);
      if (image.hidden) permissionTimer = setTimeout(poll, 3000);
    };
    permissionTimer = setTimeout(poll, 3000);
  }
  function open() {
    if (panel.open) return;
    ++openEpoch; screenLocked = false; lastRecovery = Date.now(); requestedPermission = false; panel.show(); panel.classList.add('pip');
    $('screen-empty').hidden = false; pip.paint();
    fetch('/api/screen/wake', { method: 'POST', headers: authHeaders() }).catch(() => {});
    history.pushState({ pocketdeskScreen: 'pip' }, ''); loadDisplays();
  }
  function isolateHome(value) {
    const root = document.documentElement;
    if (value === root.classList.contains('screen-fullscreen-open')) return;
    if (value) homeScroll = window.scrollY;
    root.classList.toggle('screen-fullscreen-open', value);
    document.body.classList.toggle('screen-fullscreen-open', value);
    document.querySelector('body > main').inert = value;
    if (!value) window.scrollTo(0, homeScroll);
  }
  function setFullscreen(value) {
    cancel(); pip.cancel(); window.pocketdeskHideKeyboard();
    panel.classList.toggle('fullscreen', value); panel.classList.toggle('pip', !value);
    panel.style.left = ''; panel.style.top = ''; panel.style.width = ''; panel.style.height = ''; panel.style.transform = '';
    isolateHome(value);
    menu.hidden = true; geometry.reset(); layout(); startFrames();
    if (!value) { try { screen.orientation?.unlock?.(); } catch {} viewport.classList.remove('rotated'); }
    if (!value && document.fullscreenElement === panel) document.exitFullscreen?.().catch(() => {});
  }
  function close() {
    if (!panel.open) return;
    window.pocketdeskClearUnlock?.();
    ++openEpoch; cancel(); frames.stop(); pip.cancel(); window.pocketdeskHideKeyboard();
    clearTimeout(permissionTimer); panel.close();
    isolateHome(false);
    panel.classList.remove('fullscreen'); panel.classList.add('pip');
    try { screen.orientation?.unlock?.(); } catch {}
    viewport.classList.remove('rotated');
    subscribeCursor(); image.hidden = true; geometry.base = null; geometry.view = null; geometry.viewport = null;
    if (imageURL) { image.removeAttribute('src'); URL.revokeObjectURL(imageURL); imageURL = null; }
    if (document.fullscreenElement === panel) document.exitFullscreen?.().catch(() => {});
  }
  function back() {
    if (!$('screen-context').hidden) { $('screen-context').hidden = true; gestures.cancel(); return; }
    if (!menu.hidden) { menu.hidden = true; return; }
    if (!$('screen-compose').hidden) { window.pocketdeskHideKeyboard(); return; }
    if (history.state?.pocketdeskScreen) history.back();
    else if (fullscreen()) setFullscreen(false); else close();
  }
  $('screen-open').addEventListener('click', open);
  $('screen-fullscreen').addEventListener('click', () => {
    setFullscreen(true); history.pushState({ pocketdeskScreen: 'full' }, '');
    // 页面全屏始终可用；原生全屏只是隐藏浏览器栏的增强能力。
    const lockLandscape = () => {
      if (!fullscreen()) return;
      try { screen.orientation?.lock?.('landscape').catch(() => {}); } catch {}
    };
    try {
      const request = panel.requestFullscreen?.();
      if (request) request.then(lockLandscape).catch(lockLandscape);
      else lockLandscape();
    } catch { lockLandscape(); }
  });
  $('screen-back').addEventListener('click', back);
  $('screen-pip-close').addEventListener('click', back);
  $('screen-close').addEventListener('click', () => {
    const steps = fullscreen() && history.state?.pocketdeskScreen === 'full' ? -2 : -1;
    close(); if (history.state?.pocketdeskScreen) history.go(steps);
  });
  window.addEventListener('popstate', event => {
    if (event.state?.pocketdeskScreen === 'pip' && panel.open) setFullscreen(false);
    else close();
  });
  panel.addEventListener('cancel', e => { e.preventDefault(); back(); });
  document.addEventListener('keydown', e => {
    if (e.key !== 'Escape' || !panel.open) return;
    e.preventDefault();
    if (!menu.hidden) menu.hidden = true;
    else if (window.pocketdeskKeyboardActive()) window.pocketdeskHideKeyboard();
    else back();
  });
  $('screen-more').onclick = () => {
    cancel(); menu.hidden = !menu.hidden;
    $('screen-more').setAttribute('aria-expanded', String(!menu.hidden));
    // 复用首页已配置快捷键及其执行回执，避免维护第二份配置。
    $('screen-shortcuts').replaceChildren(...Array.from(document.querySelectorAll('#shortcut-bar button'), source => {
      const button = document.createElement('button'); button.type = 'button'; button.textContent = source.textContent;
      button.onclick = () => { if (ready()) { source.click(); frames.interact(); } else feedback('请先接管控制'); };
      return button;
    }));
  };
  $('screen-menu-close').onclick = () => { menu.hidden = true; };
  $('screen-permission').onclick = requestPermission;
  $('screen-refresh').onclick = () => { cancel(); loadDisplays(); feedback('正在重新连接画面'); };
  function paintDisplay() {
    const index = displays.findIndex(d => d.id === display);
    $('screen-display').value = String(display);
    $('screen-pip-displays').replaceChildren(...displays.map((item, i) => {
      const button = document.createElement('button'); button.type = 'button';
      button.textContent = `屏幕 ${i + 1}`;
      button.setAttribute('aria-pressed', String(item.id === display));
      button.onclick = () => switchDisplay(item.id);
      return button;
    }));
    $('screen-switch').querySelector('span').textContent = `屏幕 ${index + 1}`;
    $('screen-switch').disabled = displays.length < 2;
    $('screen-switch').setAttribute('aria-label', `当前显示器 ${index + 1}，点击切换下一台`);
  }
  function switchDisplay(next) {
    if (next === display || !displays.some(d => d.id === next)) return;
    cancel(); window.pocketdeskHideKeyboard(); frames.stop(); display = next;
    image.hidden = true; $('screen-empty').hidden = false; cursorSample = null;
    geometry.reset(); geometry.base = null; geometry.view = null; geometry.viewport = null;
    menu.hidden = true; $('screen-more').setAttribute('aria-expanded', 'false'); paintDisplay(); startFrames();
  }
  $('screen-display').onchange = () => switchDisplay(Number($('screen-display').value));
  $('screen-switch').onclick = () => {
    if (displays.length > 1) switchDisplay(displays[(displays.findIndex(d => d.id === display) + 1) % displays.length].id);
  };
  function controlMode() { return watch ? 'view' : mode; }
  $('screen-quality').onchange = () => { frames.width = Number($('screen-quality').value); startFrames(); };
  function setMode(next) {
    mode = next; gestures.setMode(controlMode()); $('screen-mode').querySelector('span').textContent = mode === 'touch' ? '触屏' : '指针';
    $('screen-help').textContent = mode === 'touch' ? '轻点点击 · 滑动滚动 · 按住放大瞄准，松手点击 · 双指缩放/轻点更多' : '单指移动鼠标 · 轻点点击 · 双指滚动 · 长按拖动 · 双指轻点右键';
    $('screen-adjust').textContent = '调整视野';
    menu.hidden = true; $('screen-more').setAttribute('aria-expanded', 'false');
  }
  setMode(mode);
  $('screen-mode').onclick = () => setMode(mode === 'touch' ? 'pointer' : 'touch');
  $('screen-fit').onclick = () => { cancel(); geometry.reset(); paint(); menu.hidden = true; };
  $('screen-adjust').onclick = () => {
    const adjusting = gestures.mode !== 'view'; gestures.setMode(adjusting ? 'view' : mode);
    $('screen-adjust').textContent = adjusting ? '完成调整' : '调整视野'; menu.hidden = true;
    feedback(adjusting ? '调整视野：拖动或双指缩放；点模式按钮恢复控制' : '已恢复控制');
  };
  $('screen-rightclick').onclick = () => { send({ t: 'click', button: 'right' }); menu.hidden = true; };
  $('screen-context-right').onclick = () => { if (contextPoint) gestures.absolute('click', contextPoint, { button: 'right' }); $('screen-context').hidden = true; };
  $('screen-context-drag').onclick = () => { gestures.arm(contextPoint); $('screen-context').hidden = true; feedback('请再按住画面并移动，开始拖动'); };
  $('screen-context-cancel').onclick = () => { $('screen-context').hidden = true; gestures.cancel(); };
  $('screen-watch').onclick = () => {
    cancel(); window.pocketdeskHideKeyboard(); watch = !watch; gestures.setMode(controlMode());
    $('screen-watch').textContent = watch ? '恢复控制' : '仅观看'; $('screen-watch').setAttribute('aria-pressed', String(watch)); paintNotice();
  };
  $('screen-takeover').onclick = () => { window.pocketdeskSend({ t: 'take-control' }); watch = false; gestures.setMode(controlMode()); $('screen-watch').textContent = '仅观看'; menu.hidden = true; };
  window.pocketdeskOnWSMessage(data => {
    if (data.t === 'cursor') { cursorSample = data; cursorAt = performance.now(); paintCursor(); }
    else if (data.t === 'closed' || data.t === 'control') { cancel(); window.pocketdeskHideKeyboard(); paintNotice(); }
    else if (data.t === 'auth_ok') { subscribeCursor(); paintNotice(); }
    else if (data.t === 'error') feedback(data.error || data.message || '操作未完成');
  });
  window.pocketdeskScreenCanInput = ready;
  window.pocketdeskScreenInputReason = inputBlockReason;
  window.pocketdeskScreenMessage = text => { if (fullscreen()) feedback(text); };
  window.pocketdeskKeyboardClosed = layout;
  new ResizeObserver(measure).observe(viewport);
  window.addEventListener('resize', layout);
  window.visualViewport?.addEventListener('resize', layout);
  window.visualViewport?.addEventListener('scroll', layout);
  document.addEventListener('visibilitychange', () => {
    cancel(); window.pocketdeskHideKeyboard();
    if (document.hidden) frames.stop(); else if (panel.open) startFrames();
    subscribeCursor();
  });
  window.addEventListener('blur', () => { if (panel.open) { cancel(); pip.cancel(); } });
  window.addEventListener('pagehide', () => { cancel(); frames.stop(); });
  window.addEventListener('pageshow', () => { if (panel.open) startFrames(); });
  // 显示器睡眠/重连后会暂时消失；恢复时重新枚举，避免永远请求旧显示器。
  setInterval(async () => {
    if (!panel.open || document.hidden || recoveryBusy) return;
    recoveryBusy = true; const epoch = openEpoch;
    try {
      const response = await fetch('/api/screen/state', { headers: authHeaders(), cache: 'no-store', signal: AbortSignal.timeout(4000) });
      const state = await response.json();
      if (!panel.open || epoch !== openEpoch) return;
      const wasLocked = screenLocked; screenLocked = state.locked === true;
      window.pocketdeskLockState?.(state.state || (screenLocked ? 'locked' : 'unlocked'));
      if (screenLocked) { if (!wasLocked) { cancel(); window.pocketdeskHideKeyboard(); } }
      else if ((wasLocked || (!frames.fresh() && Date.now() - lastRecovery > 8000)) && !frames.abort) {
        lastRecovery = Date.now(); await loadDisplays(epoch);
      }
      paintNotice();
    } catch { /* 断网时由控制连接与原始取帧错误提示，不覆盖成未知错误。 */ }
    finally { recoveryBusy = false; }
  }, 3000);
  setInterval(() => {
    if (!panel.open) return;
    const canControl = ready();
    if (hadReady && !canControl) cancel(); hadReady = canControl;
    paintNotice();
    $('kb-toggle').disabled = !canControl; $('screen-send').disabled = !canControl || sendEl.disabled;
    paintCursor();
  }, 250);
})();
