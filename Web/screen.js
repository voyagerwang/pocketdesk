/**
 * [INPUT]: 依赖 app.js 的 authHeaders 与 window.pocketdeskSend / window.pocketdeskOnWSMessage（下行订阅）、浏览器 dialog/fetch/Blob/history 与 index.html 的画面节点（#screen-view 整块可拖、.screen-resize[*] 缩放、.screen-hud-* 浮层控件、#screen-image / #screen-cursor / #screen-display）。
 * [OUTPUT]: 电脑画面查看层，两种形态：可拖可缩的 PiP 浮窗（默认）与整层全屏（点全屏按钮进入，几何交 paintPanel 处理）；非模态 dialog——开着浮窗时主页触控板仍可操作，不独占手势。
 *           可拖可缩：position/size 落 localStorage（STORAGE_KEY='voicedeck.pip'），位置尺寸 clamp 到视口内、宽高比保持 16:9；
 *           整块浮窗任意位置（按钮与 8 个缩放 handle 除外）都能拖，8 个 .screen-resize handle 改尺寸（Pointer Events 统一手势）。
 *           panel.open 是唯一真值源，不另设状态机跟它对齐；resize 时重 clamp 一次防飘出屏幕。
 *           浮层只留两样：多显示器时的切屏键（左）、刷新与关闭两个圆形图标按钮（右）。
 *           **触屏没有 hover**，所以 HUD 靠 revealHud() 点一下浮窗加 .hud-visible 显形、2.6s 后自淡出。
 *           没有状态条：取帧失败只停表 + 在画面区给一句话，不把逐帧状态挂到 UI 上刷。
 *           撞到录屏权限墙时自动喊电脑端弹窗并轮询等结果，授权生效即自动接上画面。
 *           鼠标叠加层：画面是 1fps 的 JPEG、光标是 30Hz 的坐标，两条通路各走各的；
 *           与点击映射共用 contentRect() 一份几何（各算一遍迟早算出两个点）；
 *           暂停 / 光标不在当前屏 / 链路断 三种情况一律不画 —— 画了就是假实时；
 *           链路活着才请求 cursor=0 让画面不再烘焙鼠标，断了自动退回含鼠标截图（宁可旧，不能没有）。
 *           自动更新只有 scheduleNext() 一个调度入口，回调里必须把 timer 置空；
 *           取帧彻底失败（首帧没拿到 / 非瞬态错误）才 updating=false 停表，等人点刷新——刷新即恢复自动。
 * [POS]: Web 的独立查看层；浏览器返回与 Esc 都整层关闭回页面。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(() => {
  const panel = document.querySelector('#screen-view');
  const open = document.querySelector('#screen-open');
  const close = document.querySelector('#screen-close');
  const fullscreenBtn = document.querySelector('#screen-fullscreen');
  const resizers = panel.querySelectorAll('.screen-resize');
  const displays = document.querySelector('#screen-display'); // 列表数据源，不直接展示
  const displaySwitch = document.querySelector('#screen-display-switch');
  const refresh = document.querySelector('#screen-refresh');
  const empty = document.querySelector('#screen-empty');
  const emptyTitle = document.querySelector('#screen-empty-title');
  const emptyHelp = document.querySelector('#screen-empty-help');
  const permission = document.querySelector('#screen-permission');
  const image = document.querySelector('#screen-image');
  const cursorDot = document.querySelector('#screen-cursor');

  const DRAG_THRESHOLD = 8;      // 位移超过这么多像素才算"在拖"——否则就是点，留给画面上的点击
  const DRAG_CLICK_GUARD = 400;  // 拖完这次之后多久内不把 click 当作点画面（ms）

  const STORAGE_KEY = 'voicedeck.pip';
  const PIP_RATIO = 16 / 9;
  const PIP_MIN = 180;            // 浮窗最短边下限，再小看不清字
  const PIP_MAX_RATIO = 0.92;     // 单边不超过视口的 92%

  let timer;
  let permissionTimer;      // 等待电脑端授权期间的轮询
  let autoRequested = false; // 本次会话是否已替用户喊过一次
  let pipBox = null;         // {x, y, w, h}：localStorage 持久化
  let controller;
  let imageURL;
  let generation = 0;
  let updating = true;       // 自动更新是否在跑；取帧彻底失败时停表，等人点刷新
  let historyPending = false;
  let dragState = null;      // 整块拖动：{kind, startX, startY, originX, originY, originW, originH, edge}
  let lastDragEndAt = 0;     // 上次拖动结束的时刻：用来吃掉拖动尾巴上那次 click
  // panel.open 是唯一真值源：dialog 开着就是开着，不另立一个 viewState 去跟它对齐。
  const visible = () => panel.open && !document.hidden;
  const ownsHistory = () => history.state?.pocketdeskScreen === true;

  function loadPipBox() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return null;
      const box = JSON.parse(raw);
      if (!box || typeof box.x !== 'number' || typeof box.y !== 'number' || typeof box.w !== 'number' || typeof box.h !== 'number') return null;
      return box;
    } catch { return null; }
  }

  function savePipBox(box) {
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(box)); } catch { /* 隐私模式 / quota 满：无伤大雅 */ }
  }

  // 把浮窗放到默认位置（首次打开 / localStorage 失效时）：
  // 优先贴右下角（让开连接胶囊与输入区），取视口宽高的 70% 与 16:9，再 clamp 到屏幕内。
  function defaultPipBox() {
    const w = Math.min(window.innerWidth * 0.7, 420);
    const h = Math.round(w / PIP_RATIO);
    const margin = 16;
    const x = Math.max(margin, window.innerWidth - w - margin);
    const y = Math.max(margin, window.innerHeight - h - margin - 16);   // -16 让出 home indicator
    return { x, y, w, h };
  }

  // 写完位置/尺寸后做一次 clamp：不能飘出屏幕外（横竖屏切换尤其要防）
  function clampPipBox(box) {
    const margin = 8;
    const minSide = PIP_MIN;
    const maxW = Math.round(window.innerWidth * PIP_MAX_RATIO);
    const maxH = Math.round(window.innerHeight * PIP_MAX_RATIO);
    let w = Math.max(minSide, Math.min(maxW, box.w || minSide));
    let h = Math.max(minSide, Math.min(maxH, box.h || minSide));
    // 强制 16:9，宽是主轴
    if (Math.abs(w / h - PIP_RATIO) > 0.05) h = Math.round(w / PIP_RATIO);
    let x = Math.min(Math.max(margin, box.x ?? 0), window.innerWidth - w - margin);
    let y = Math.min(Math.max(margin, box.y ?? 0), window.innerHeight - h - margin);
    return { x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(h) };
  }

  // 全屏与否只认 class，不另立变量跟 DOM 对齐——那才是漂移的开始。
  const isFullscreen = () => panel.classList.contains('fullscreen');

  // 把浮窗盒写到 panel 的 inline style 上；全屏态则把这些痕迹全部清掉，
  // 交还给 CSS 基类的 inset:0 铺满。dialog 关着时同样收干净。
  function paintPanel() {
    if (!panel.open) {
      panel.classList.remove('pip', 'fullscreen');
      hideHud();
      panel.hidden = true;
      return;
    }
    panel.hidden = false;
    if (isFullscreen()) {
      panel.classList.remove('pip');
      panel.style.left = '';
      panel.style.top = '';
      panel.style.right = '';
      panel.style.bottom = '';
      panel.style.margin = '';
      panel.style.width = '';
      panel.style.height = '';
      revealHud(0);        // 整屏都有地方放控件，不用再淡出
      paintCursor();
      return;
    }
    panel.classList.add('pip');
    const box = clampPipBox(pipBox);
    pipBox = box;
    // 关键是清掉 inset:0 带来的 right/bottom 与 margin:auto：
    // 否则 fixed 定位下 left/right/width 同时非 auto，实际宽度会被 right 约束、位置会被 margin 平分。
    panel.style.left = `${box.x}px`;
    panel.style.top = `${box.y}px`;
    panel.style.right = 'auto';
    panel.style.bottom = 'auto';
    panel.style.margin = '0';
    panel.style.width = `${box.w}px`;
    panel.style.height = `${box.h}px`;
    // 刚打开/刚拖动时把控件亮一下：否则 280px 的小窗看着就是一块纯画面。
    revealHud();
    paintCursor();
  }

  // 触屏没有 hover：pip 态的 HUD 若只靠 :hover 淡入，手机上永远是隐形的，
  // "刷新/关闭"根本点不到。所以点一下浮窗就显形，隔一会儿自己淡出。
  let hudTimer;
  function revealHud(holdMs = 2600) {
    panel.classList.add('hud-visible');
    clearTimeout(hudTimer);
    if (holdMs > 0) hudTimer = setTimeout(() => panel.classList.remove('hud-visible'), holdMs);
  }
  function hideHud() {
    clearTimeout(hudTimer);
    panel.classList.remove('hud-visible');
  }
  panel.addEventListener('pointerdown', () => { if (panel.open) revealHud(); });

  // 自动更新的唯一调度入口。句柄必须在回调里置空：
  // 否则 clearTimeout 之后 timer 仍是旧 id，下一轮的 `!timer` 恒为假，
  // 自动更新跑完第二帧就悄悄停住——画面看起来是"卡住了"，没有任何报错，极难自查。
  function scheduleNext(ms) {
    clearTimeout(timer);
    timer = null;
    if (!visible() || !updating) return;
    timer = setTimeout(() => { timer = null; capture(); }, ms);
  }

  function stop() {
    generation += 1;
    clearTimeout(timer);
    timer = null;
    clearTimeout(permissionTimer);
    controller?.abort();
    controller = null;
    // 刷新按钮不设 disabled、不改文字：它只有一枚图标，
    // 以前写成 textContent='获取中…' 会直接把 SVG 图标换成文字（且关一次就换不回来）。
  }

  function releaseImage() {
    image.hidden = true;
    image.removeAttribute('src');
    if (imageURL) URL.revokeObjectURL(imageURL);
    imageURL = null;
  }

  // 显示器列表只此一份，两个入口（浮层切换键、右侧滑动手势）都从这里读名字、都走同一条 change 流程。
  function syncDisplays() {
    const many = displays.options.length > 1;
    displaySwitch.hidden = !many;
    if (!many) return;
    const name = displays.options[displays.selectedIndex]?.text ?? '';
    displaySwitch.textContent = name.split('·')[0].trim() || name;
    displaySwitch.title = `切换显示器（当前：${name}）`;
  }

  function switchDisplay(step) {
    if (displays.options.length < 2) return;
    const total = displays.options.length;
    displays.selectedIndex = (displays.selectedIndex + step + total) % total;
    displays.dispatchEvent(new Event('change'));
  }

  async function request(path, signal, method = 'GET') {
    const response = await fetch(path, { headers: authHeaders(), cache: 'no-store', signal, method });
    if (!response.ok) {
      const result = await response.json().catch(() => ({}));
      const failure = new Error(response.status === 401 ? '请到电脑端控制台重新扫码配对。' : result.error || '无法获取画面。');
      failure.payload = result;   // 带上 canRequest 等状态，交给调用方判断下一步
      throw failure;
    }
    return response;
  }

  async function capture() {
    if (!visible() || controller) return;
    clearTimeout(timer);
    timer = null;
    const current = generation;
    const pending = new AbortController();
    controller = pending;
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
        syncDisplays();
        if (!displays.options.length) throw new Error('未找到显示器。');
      }
      // 叠加层工作时让画面别再烘焙鼠标，否则屏幕上会出现两个指针；
      // 链路一断就自动退回含鼠标的截图，宁可旧一点也不能一个都没有。
      const response = await request(
        `/api/screen/frame?display=${encodeURIComponent(displays.value)}&cursor=${cursorLinkLive() ? 0 : 1}`,
        pending.signal);
      const blob = await response.blob();
      if (current !== generation || !visible()) return;
      const previous = imageURL;
      imageURL = URL.createObjectURL(blob);
      image.src = imageURL;
      image.hidden = false;
      empty.hidden = true;
      if (previous) URL.revokeObjectURL(previous);
    } catch (error) {
      if (current !== generation) return;
      const transient = error.name === 'AbortError' || (error.message || '').includes('稍后重试');
      // 画面已经在手上、只是这一帧没取到：什么都不做，finally 照常排下一轮。
      // 反过来——首帧都没拿到，或压根不是瞬态（没授权 / 没显示器），必须停表等人点刷新：
      // 以前这里写着"正在重试"却因为 updating 已被置 false 而根本没排下一轮，是句空话。
      if (!imageURL || !transient) {
        updating = false;
        syncCursorSubscription();   // 画面停了，30Hz 采样一起停，别在后台空转
        releaseImage();
        empty.hidden = false;
        const needsPermission = /系统设置.*录制/.test(error.message);
        emptyTitle.textContent = needsPermission ? '先允许查看电脑屏幕' : '暂时无法获取画面';
        emptyHelp.textContent = error.name === 'AbortError' ? '连接超时。请检查手机和电脑的网络，再点右上角刷新。' : error.message;
        permission.hidden = !needsPermission;
        displays.replaceChildren();
        syncDisplays();
        // 手机一点就替用户喊一声：让电脑把系统授权窗弹出来，然后自己等结果。
        if (needsPermission) askPermission(error.payload?.canRequest !== false, error.message);
      }
    } finally {
      clearTimeout(timeout);
      if (current === generation) {
        controller = null;
        scheduleNext(1000);
      }
    }
  }

  /* ---------- 电脑端授权联动 ---------- */

  // 手机上点开查看，就在电脑上把系统授权窗喊出来，再轮询等用户点「允许」，
  // 授权一生效就自动接上画面，全程不用回到电脑前操作、也不用手动刷新。
  // canRequest=false 表示本机已经弹过窗（系统对每个安装只弹一次），再喊也没反应，
  // 这时不空等，直接把人引到系统设置。
  function askPermission(canRequest = true, force = false) {
    if (!canRequest) {
      emptyTitle.textContent = '需要手动允许一次';
      emptyHelp.textContent = '请到电脑端「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」打开 PocketDesk；系统若提示重启应用，重启后点刷新。';
      permission.textContent = '已请求过，重新请求';
      return;
    }
    if (autoRequested && !force) return;
    autoRequested = true;
    permission.disabled = true;
    permission.textContent = '正在请求…';
    request('/api/screen/permission', undefined, 'POST')
      .then(() => {
        emptyTitle.textContent = '请在电脑上允许查看屏幕';
        emptyHelp.textContent = '已在电脑上弹出授权窗口。在电脑上点「允许」，这里会自动出现画面，不用刷新。';
        waitForPermission();
      })
      .catch(error => {
        autoRequested = false;
        emptyHelp.textContent = error.message || '请求失败，请点下方按钮重试。';
      })
      .finally(() => {
        permission.disabled = false;
        permission.textContent = '重新请求授权';
      });
  }

  // 授权动作发生在电脑上，手机只能靠轮询感知；每次 3 秒，最多等 90 秒。
  function waitForPermission(attempt = 0) {
    clearTimeout(permissionTimer);
    if (attempt >= 30) {
      emptyTitle.textContent = '还没等到授权';
      emptyHelp.textContent = '没检测到电脑上的授权变化。请确认已在电脑端点「允许」；若系统要求重启应用，重启后点刷新。';
      return;
    }
    permissionTimer = setTimeout(async () => {
      if (!visible()) return;
      try {
        await request('/api/screen/displays', undefined);
        clearTimeout(permissionTimer);
        emptyTitle.textContent = '已授权，正在获取画面…';
        emptyHelp.textContent = '稍等片刻。';
        updating = true;
        capture();
      } catch (error) {
        waitForPermission(attempt + 1);
      }
    }, 3000);
  }

  /* ---------- 点画面移光标 ---------- */

  // 点击 <img>：把像素坐标换算成显示器的比例坐标发给 Mac。单击不做进这里：误触代价太高，点击交给触控板。
  // 两处容易算错的地方：
  // 1) 用 offset 而非 client 坐标 —— 元素局部坐标系不受 CSS transform 影响，整层转 90° 时换算依然正确。
  // 2) object-fit: contain 会在元素框里留黑边，先剔除黑边，否则缩放后的画面定位是偏的。
  // 画面内容矩形：object-fit: contain 会在元素框内留黑边，真正的画面只占中间一块。
  // 点击映射与光标叠加必须共用这一份几何——各算一遍迟早算出两个不同的点。
  function contentRect() {
    if (!image.naturalWidth || !image.naturalHeight || image.hidden) return null;
    let width = image.offsetWidth;
    let height = image.offsetHeight;
    let offsetX = 0;
    let offsetY = 0;
    if (width / height > image.naturalWidth / image.naturalHeight) {
      width = height * (image.naturalWidth / image.naturalHeight);
      offsetX = (image.offsetWidth - width) / 2;
    } else {
      height = width * (image.naturalHeight / image.naturalWidth);
      offsetY = (image.offsetHeight - height) / 2;
    }
    return { x: offsetX, y: offsetY, width, height };
  }

  // 点画面 = 光标移过去 + 左键单击：tap 命令自带 click 参数，一条消息原子执行，
  // 不用"先 move 再 click"两条消息去赌顺序。
  // 以前刻意只移不点（怕误触），但全屏时整块画面就是给人点的，不点等于这屏白给。
  function sendTap(event) {
    // 刚拖完窗口的那一下 click 是拖动的尾巴，不是"点画面"。
    if (Date.now() - lastDragEndAt < DRAG_CLICK_GUARD) return;
    const rect = contentRect();
    if (!rect) return;
    const rx = (event.offsetX - rect.x) / rect.width;
    const ry = (event.offsetY - rect.y) / rect.height;
    if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return;
    // 通道没连上时静默放过：状态条已经去掉了，不为一条提示再把 toast 加回来。
    // 画面上点不动本身就是反馈——真要看原因，控制台里有一条 warn。
    if (!window.pocketdeskSend) { console.warn('[screen] 触控板通道未连接，点画面移动光标未发送'); return; }
    window.pocketdeskSend({ t: 'tap', rx, ry, display: Number(displays.value), click: true });
  }

  image.addEventListener('click', sendTap);

  /* ---------- 鼠标叠加层 ----------
     画面是 1fps 的 JPEG，光标是 30Hz 的坐标，两条通路各走各的（见 CLAUDE.md）。
     叠加层只画位置，不假装复刻系统光标形状；它也不是点击目标（pointer-events: none）。

     三条不画的红线，画了就是"假实时"：
       1) 暂停更新 —— 活鼠标叠在旧画面上，看着实时其实是错觉；
       2) 光标不在当前这块屏 —— 坐标属于别的显示器，画上去就是错的；
       3) 链路断了 —— 冻结在最后一个位置继续冒充实时，比不画更糟。 */
  let cursorState = null;
  let lastCursorAt = 0;
  let cursorFrame = 0;

  // 链路是否活着：3 秒内有新帧才算。截图要不要烘焙鼠标全看它——
  // 叠加层不在工作时绝不能关掉烘焙，否则会一个鼠标都看不见。
  const cursorLinkLive = () => Date.now() - lastCursorAt < 3000;

  function paintCursor() {
    cursorFrame = 0;
    const rect = contentRect();
    const watching = Number(displays.value);
    const drawable = rect && cursorState && updating && !image.hidden
      && cursorState.displayId === watching && !isFullscreen();
    if (!drawable) { cursorDot.hidden = true; return; }
    cursorDot.hidden = false;
    cursorDot.style.transform =
      `translate(${rect.x + cursorState.rx * rect.width}px, ${rect.y + cursorState.ry * rect.height}px)`;
  }

  // 订阅条件 = 查看器开着 + 自动更新开着 + 页面在前台。
  // 任一条不满足就退订：服务端没有订阅者时会停表，不在后台空转耗电。
  let cursorSubscribed = false;
  function syncCursorSubscription() {
    const wanted = panel.open && updating && !document.hidden && !isFullscreen();
    if (wanted === cursorSubscribed) return;
    cursorSubscribed = wanted;
    window.pocketdeskSend?.({ t: 'cursor-subscribe', enabled: wanted });
    if (!wanted) { cursorState = null; lastCursorAt = 0; paintCursor(); }
  }

  // WS 重连后服务端的订阅随旧连接丢失，auth_ok 时按当前意愿补发一次。
  function resendCursorSubscription() {
    cursorSubscribed = false;
    syncCursorSubscription();
  }

  window.pocketdeskOnWSMessage?.(message => {
    if (message?.t === 'cursor') {
      cursorState = { displayId: message.displayId, rx: message.rx, ry: message.ry };
      lastCursorAt = Date.now();
      // 每帧只画最新状态：中间帧没有意义，叠着画只是浪费电量。
      if (!cursorFrame) cursorFrame = requestAnimationFrame(paintCursor);
      return;
    }
    if (message?.t === 'auth_ok') { resendCursorSubscription(); return; }
    if (message?.t === 'closed') {
      cursorSubscribed = false;
      cursorState = null;
      lastCursorAt = 0;
      paintCursor();
      return;
    }
    // 服务端拒绝执行的命令（如显示器已拔掉）：没有状态条可写，只落控制台。
    // 不假装成功——但也不为一个低频异常把整块 UI 加回来。
    if (message?.t === 'error' && message.message) console.warn('[screen]', message.message);
  });


  /* ---------- 拖动 + 缩放（仅 pip 模式） ----------
     整块浮窗都能拖，不再有专门的把手元素：把手被 18px 的 resize 带和 20px 的 HUD
     内边距挤成 10px 一条缝，手机上根本捞不到——"拖动又坏了"就是这么来的。
     代价是"拖"和"点画面"抢同一根手指，用阈值分开：位移过 8px 才算拖，
     没过就是点，照常走 sendTap；拖完 400ms 内的那次 click 一律当作拖动的尾巴丢掉。

     三件刻意不在 pointerdown 上做的事（都会把点击弄坏）：
       1) 不 preventDefault —— 取消 pointerdown 会连带取消 mousedown/click 兼容事件；
       2) 不 setPointerCapture —— 捕获会把 click 也重定向到捕获元素，图片就收不到了；
       3) 所以 move/up 挂在 window 上，靠 pointerId 认人，不靠捕获。

     关键不变量：浮窗始终保持 16:9（resize 改完宽就把高同步过来），位置 clamp 在视口内。 */

  function startDrag(event, edge = null) {
    if (!panel.open || isFullscreen()) return;   // 全屏没有"拖/缩"这回事
    if (event.button) return;                    // 只认主键
    dragState = {
      pointerId: event.pointerId,
      edge,                                    // null = 拖整块；'nw' | 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w'
      startX: event.clientX,
      startY: event.clientY,
      originX: pipBox.x,
      originY: pipBox.y,
      originW: pipBox.w,
      originH: pipBox.h,
      moved: false,
    };
    // 整块拖动时给个 grabbing 光标反馈；缩放 handle 有自家 cursor，不加这个类。
    if (!edge) panel.classList.add('dragging');
  }

  function moveDrag(event) {
    if (!dragState || dragState.pointerId !== event.pointerId) return;
    event.preventDefault();
    const dx = event.clientX - dragState.startX;
    const dy = event.clientY - dragState.startY;
    // 过阈值才算"真拖动"：否则 0 位移的纯点按会被误记成 moved，吃掉随后的 click（点画面移光标）。
    if (Math.hypot(dx, dy) > DRAG_THRESHOLD) dragState.moved = true;
    const edge = dragState.edge;
    let { originX, originY, originW, originH } = dragState;
    let x = originX, y = originY, w = originW, h = originH;

    if (!edge) {
      // 拖整块：直接位移
      x = originX + dx;
      y = originY + dy;
    } else {
      // 8 个方向：以宽为主轴，高跟随保持 16:9（dx 决定 w 的变化量，dy 仅辅助）
      let delta = 0;
      if (edge.includes('e')) delta = dx;
      else if (edge.includes('w')) delta = -dx;
      else if (edge.includes('s')) delta = dy;
      else if (edge.includes('n')) delta = -dy;
      w = originW + delta;
      h = Math.round(w / PIP_RATIO);
      // 角点 handle：根据方向调整 (x, y) 让对边锚定不动
      if (edge === 'nw') { x = originX + (originW - w); y = originY + (originH - h); }
      else if (edge === 'ne') { y = originY + (originH - h); }
      else if (edge === 'sw') { x = originX + (originW - w); }
      // 'n' / 's' / 'e' / 'w'：单边，只改高/宽，不动 (x, y)
    }
    pipBox = clampPipBox({ x, y, w, h });
    paintPanel();
  }

  function endDrag(event) {
    if (!dragState || dragState.pointerId !== event.pointerId) return;
    const moved = dragState.moved;
    dragState = null;
    panel.classList.remove('dragging');
    try { event.currentTarget.releasePointerCapture(event.pointerId); } catch { /* 上面已说明 */ }
    // 只有真拖动了才吃掉随后的 click：纯点按（0 位移）不该被当成拖动尾巴，
    // 否则点画面移光标的 tap 会被 DRAG_CLICK_GUARD 误杀。
    if (moved) lastDragEndAt = Date.now();
    savePipBox(pipBox);
  }

  // 整块浮窗都能拖：在 panel 上接 pointerdown，但按钮与缩放 handle 不触发，
  // 把那次指针交给各自的点击 / 缩放逻辑（命中判定用 closest 排除）。
  panel.addEventListener('pointerdown', event => {
    if (event.target.closest('button, .screen-resize')) return;
    startDrag(event, null);
  });
  resizers.forEach(node => {
    const edge = Array.from(node.classList).find(cls => cls !== 'screen-resize');
    node.addEventListener('pointerdown', event => startDrag(event, edge));
  });
  // move/up 挂在 window 上、靠 pointerId 认人：指针一旦移出起点元素仍要收得到 move，
  // 否则整块拖动"拖不动"。不 setPointerCapture：捕获会把 click 重定向到捕获元素，图片收不到点。
  window.addEventListener('pointermove', moveDrag);
  window.addEventListener('pointerup', endDrag);
  window.addEventListener('pointercancel', endDrag);

  /* ---------- 查看器开关 ----------
     两种形态：可拖可缩的 PiP 浮窗 + 整层全屏（点全屏按钮切换）。开 = show()（非模态），
     所以浮窗开着时主页触控板仍能操作，不抢手势。panel.open 是唯一真值，
     不另设一个状态变量去跟它对齐，那才是漂移的开始。 */
  function openViewer() {
    if (panel.open || historyPending) return;
    document.activeElement?.blur();
    autoRequested = false;
    updating = true;
    if (!pipBox) pipBox = loadPipBox() || defaultPipBox();
    syncDisplays();
    panel.show();
    paintPanel();
    capture();
    syncCursorSubscription();
    history.pushState({ ...history.state, pocketdeskScreen: true }, '');
    document.body.classList.add('screen-viewing');
  }

  function closeViewer(fromHistory = false) {
    stop();
    releaseImage();
    panel.close();
    paintPanel();
    syncCursorSubscription();
    document.body.classList.remove('screen-viewing');
    open.focus({ preventScroll: true });
    if (!fromHistory && ownsHistory()) {
      historyPending = true;
      history.back();
    }
  }

  open.addEventListener('click', openViewer);
  close.addEventListener('click', () => closeViewer());
  // 全屏按钮：在 PiP 浮窗与整层全屏之间切换，几何交 paintPanel 处理（清/写 inline 定位）。
  // 全屏态不叠鼠标、只支持点按（见 paintCursor / syncCursorSubscription 的 isFullscreen 守卫）。
  fullscreenBtn.addEventListener('click', () => {
    panel.classList.toggle('fullscreen');
    paintPanel();
    syncCursorSubscription();   // 进全屏退订 30Hz 光标采样；出全屏按当前意愿重新订阅
  });
  // 非模态 dialog 不拦 Esc：自己补一个，整层关闭回主页面（与关闭按钮等价）。
  window.addEventListener('keydown', event => {
    if (event.key === 'Escape' && panel.open) { event.preventDefault(); closeViewer(); }
  });
  // 模态态下的 cancel（Esc / requestClose）：与上面 keydown 二选一生效，互不冲突。
  panel.addEventListener('cancel', event => { event.preventDefault(); closeViewer(); });
  window.addEventListener('popstate', () => {
    historyPending = false;
    if (panel.open) closeViewer(true);
    // 浏览器前进不恢复旧截图，也不保留一个无对应画面的历史标记。
    if (ownsHistory()) history.replaceState({ ...history.state, pocketdeskScreen: false }, '');
  });
  // 刷新页面时只显示主界面，清理上一页留下的查看标记。
  if (ownsHistory()) history.replaceState({ ...history.state, pocketdeskScreen: false }, '');
  // 视口尺寸变化（横竖屏切换、地址栏显示/隐藏）：clamp 一次浮窗，防飘出屏幕。
  window.addEventListener('resize', () => {
    if (!panel.open) return;
    pipBox = clampPipBox(pipBox);
    paintPanel();
    savePipBox(pipBox);
  });
  document.addEventListener('visibilitychange', () => {
    stop();
    if (visible()) capture(); else releaseImage();
    // 切后台就退订：不让 Mac 为一个看不见的页面继续采样。
    syncCursorSubscription();
  });
  window.addEventListener('pagehide', () => { stop(); releaseImage(); });
  window.addEventListener('pageshow', () => { if (visible()) capture(); });
  // 刷新 = 重新拉一帧，并把出错时停掉的表一并恢复——停表之后就是靠它救回来的。
  // 刷新按钮不设"获取中"文字、只留图标（点一下即重拉），状态条早已去掉。
  refresh.addEventListener('click', () => { updating = true; capture(); });
  displays.addEventListener('change', () => { syncDisplays(); stop(); releaseImage(); capture(); });
  displaySwitch.addEventListener('click', () => switchDisplay(1));
  // 换屏后旧坐标属于别的显示器，立刻擦掉，等新屏的第一帧到达再画。
  image.addEventListener('load', paintCursor);
  // 手动点按钮时允许重喊一次（force）：自动那次可能用户没看见电脑上的弹窗。
  permission.addEventListener('click', () => askPermission(true, true));
})();
