/**
 * [INPUT]: 依赖 app.js 的 authHeaders 与 window.pocketdeskSend / window.pocketdeskOnWSMessage（下行订阅）、浏览器 dialog/fetch/Blob/history 与 index.html 的画面节点（#screen-view 整块可拖、.screen-resize[*] 缩放、.screen-hud-* 浮层控件、#screen-image / #screen-cursor / #screen-display）。
 * [OUTPUT]: 电脑画面查看层，两种形态：可拖可缩的 PiP 浮窗（默认）与整层全屏（点全屏按钮进入，几何交 paintPanel 处理）；非模态 dialog——开着浮窗时主页触控板仍可操作，不独占手势。
 *           可拖可缩：position/size 落 localStorage（STORAGE_KEY='voicedeck.pip'），位置尺寸 clamp 到视口内、宽高比保持 16:9；
 *           整块浮窗任意位置（按钮与 8 个缩放 handle 除外）都能拖，8 个 .screen-resize handle 改尺寸（Pointer Events 统一手势）。
 *           全屏态另有一套**画面内容**缩放（不是窗口缩放）：双指捏合 1x–6x（1x = object-fit 适应态）、按住拖动平移、双指同拖也能平移；退出全屏 / 关闭 / 换屏 / 转屏都重置或 clamp 回合法范围。
 *           panel.open 是唯一真值源，不另设状态机跟它对齐；resize 时重 clamp 一次防飘出屏幕。
 *           浮层只留两样：多显示器时的切屏键（左）、刷新与关闭两个圆形图标按钮（右）。
 *           **触屏没有 hover**，所以 HUD 靠 revealHud() 点一下浮窗加 .hud-visible 显形、2.6s 后自淡出。
 *           没有状态条：取帧失败只停表 + 在画面区给一句话，不把逐帧状态挂到 UI 上刷。
 *           撞到录屏权限墙时自动喊电脑端弹窗并轮询等结果，授权生效即自动接上画面。
 *           鼠标叠加层：画面是 1fps 的 JPEG、光标是 30Hz 的坐标，两条通路各走各的；
 *           与点击映射共用 baseContentRect() 一份几何（各算一遍迟早算出两个点）；
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
  const touchDot = document.querySelector('#screen-touch');   // 本地触点环：手指接触即时反馈（§6 层1）
  const screenRightClick = document.querySelector('#screen-rightclick');  // 全屏右键工具（§3）
  const screenScroll = document.querySelector('#screen-scroll');          // 全屏滚动工具（§3）
  let touchHideTimer = 0;
  const viewport = document.querySelector('.screen-viewport');

  const DRAG_THRESHOLD = 8;      // 位移超过这么多像素才算"在拖"——否则就是点，留给画面上的点击
  const DRAG_CLICK_GUARD = 400;  // 拖完这次之后多久内不把 click 当作点画面（ms）
  const DOUBLE_TAP_MS = 350;      // 双击判定窗口（与 NSEvent.doubleClickInterval 同量级）
  const DOUBLE_TAP_SLOP = 28;     // 两次轻点的位置容差（CSS px，手抖不至于被判成不同位置）
  const FRAME_AFTER_TAP = 80;     // 点完之后多久补一帧：给 Mac 一点时间把结果画出来

  const STORAGE_KEY = 'voicedeck.pip';
  const PIP_RATIO = 16 / 9;
  const PIP_MIN = 180;            // 浮窗最短边下限，再小看不清字
  const PIP_MAX_RATIO = 0.98;     // 单边不超过视口的 98%（留 2% 给边缘，够自由又不至于贴死）

  let timer;
  let permissionTimer;      // 等待电脑端授权期间的轮询
  let autoRequested = false; // 本次会话是否已替用户喊过一次
  let pipBox = null;         // {x, y, w, h}：localStorage 持久化
  let controller;
  let imageURL;
  let generation = 0;
  let updating = true;       // 自动更新是否在跑；取帧彻底失败时停表，等人点刷新
  let wakeRetried = false;   // "唤醒屏幕后重试"只做一次，别在真故障上空转
  let historyPending = false;
  let dragState = null;      // 整块拖动：{kind, startX, startY, originX, originY, originW, originH, edge}
  let lastDragEndAt = 0;     // 上次拖动结束的时刻：用来吃掉拖动尾巴上那次 click
  let dragClickPending = false;  // 是否还欠着一次"待吃掉的 click"（只消费一次，见 sendTap）
  let lastScreenTap = null;  // 全屏双击检测：{ts, x, y, display}
  let frameWanted = false;   // 交互后想要新一帧：若此刻已有截图在途，等它结束立刻再来一帧
  // 全屏态的画面内容缩放：scale=1 就是 object-fit 适应态（不缩小，只放大）。
  // tx/ty 是相对画面元素左上角的平移，配合 CSS 的 transform-origin: 0 0 使用。
  let zoomState = { scale: 1, tx: 0, ty: 0 };
  const zoomPointers = new Map();   // 正在参与画面手势的指针：pointerId → {x, y}
  let pinchState = null;            // 双指捏合中：{startDist, startMidX, startMidY, startScale, startTx, startTy}
  let panState = null;              // 单指平移中：{pointerId, startX, startY, startTx, startTy, moved}
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
    // 16:9 是硬约束，所以宽的上限要**按高反推**一次：否则会出现"宽没超上限、高却顶出屏幕"，
    // 下一行再把高掰回 16:9 时窗口就会跳一下（看起来也像回弹）。
    const wLimit = Math.max(minSide, Math.min(maxW, Math.round(maxH * PIP_RATIO)));
    let w = Math.max(minSide, Math.min(wLimit, box.w || minSide));
    let h = Math.round(w / PIP_RATIO);
    let x = Math.min(Math.max(margin, box.x ?? 0), window.innerWidth - w - margin);
    let y = Math.min(Math.max(margin, box.y ?? 0), window.innerHeight - h - margin);
    return { x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(h) };
  }

  // 全屏与否只认 class，不另立变量跟 DOM 对齐——那才是漂移的开始。
  const isFullscreen = () => panel.classList.contains('fullscreen');

  // 把浮窗盒写到 panel 的 inline style 上；全屏态则把这些痕迹全部清掉，
  // 交还给 CSS 基类的 inset:0 铺满。dialog 关着时同样收干净。
  // 只在值真的变了时才写内联样式。拖动时 paintPanel 每帧都被调用，
  // 无差别的重新赋值会反复让样式失效（拖整块时宽高根本没变），白白喂给重排。
  function setStyle(node, props) {
    for (const key in props) {
      if (node.style[key] !== props[key]) node.style[key] = props[key];
    }
  }

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
      panel.style.transform = '';
      revealHud(0);        // 整屏都有地方放控件，不用再淡出
      paintCursor();
      return;
    }
    panel.classList.add('pip');
    const box = clampPipBox(pipBox);
    pipBox = box;
    // 关键是清掉 inset:0 带来的 right/bottom 与 margin:auto：
    // 否则 fixed 定位下 left/right/width 同时非 auto，实际宽度会被 right 约束、位置会被 margin 平分。
    // 逐个比对再写：拖整块时宽高根本没变，逐帧重写等于白白多给重排出机会。
    // 读 panel.style.xxx 是读内联样式表，不触发布局，可以放心比对。
    setStyle(panel, {
      left: `${box.x}px`, top: `${box.y}px`, width: `${box.w}px`, height: `${box.h}px`,
      right: 'auto', bottom: 'auto', margin: '0', transform: 'none',
    });
    // 刚打开时把控件亮一下：否则 280px 的小窗看着就是一块纯画面。
    // 拖动中不再重复点亮——revealHud 每次都重置 2.6s 定时器，拖多久就亮多久，没有意义。
    if (!dragState) revealHud();
    // 拖动中不画光标叠加：paintCursor → baseContentRect 会读 image.offsetWidth/offsetHeight，
    // 而上面几行刚写完 width/height——写完立刻读就是强制同步重排（layout thrashing）。
    // 每个 pointermove 来一次，60Hz 下足以让拖动明显掉帧，这正是"拖动很慢"的根因。
    if (!dragState) paintCursor();
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
  // 动态取帧频率（P1）：空闲 1fps，交互期间短时提高到 ~4-5fps，减少"点了没反应"的等待。
  // 仍遵守"同一时刻只有一个截图在途"——只是把下一轮的间隔从固定 1s 改成可变。
  let fpsBoostUntil = 0;
  const FPS_IDLE_MS = 1000;
  const FPS_BOOST_MS = 220;
  function scheduleNext(ms = null) {
    clearTimeout(timer);
    timer = null;
    if (!visible() || !updating) return;
    const interval = ms != null ? ms : (Date.now() < fpsBoostUntil ? FPS_BOOST_MS : FPS_IDLE_MS);
    timer = setTimeout(() => { timer = null; capture(); }, interval);
  }
  // 交互（点/移/滚/拖/缩放）时把提帧窗口往后延，已挂着的空闲计时器立即缩短。
  function boostFps() {
    fpsBoostUntil = Date.now() + 1500;
    if (timer && visible() && updating) scheduleNext();
  }

  function stop() {
    generation += 1;
    lastScreenTap = null;   // 换屏/关闭后旧落点作废，不能拿旧几何凑成双击
    dragClickPending = false;
    frameWanted = false;
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

  /* ---------- 锁屏与显示器唤醒 ----------
     macOS 出于安全不允许 App 读取锁屏画面（否则任何 App 都能偷看密码框），
     ScreenCaptureKit 在锁屏时只会给黑帧或报错——这条限制绕不过去。
     但"只是显示器睡了 / 进了屏保"导致的没画面是**可以唤醒**的，
     两者在手机上都表现为"没有画面"，必须问清楚再决定怎么引导，
     否则一律显示"暂时无法获取画面"，用户根本不知道该去输密码还是该点刷新。 */
  async function queryLocked() {
    try {
      const response = await request('/api/screen/state');
      const data = await response.json().catch(() => ({}));
      return data.locked === true;
    } catch { return false; }   // 问不出来就按未锁处理，退回原来的报错文案
  }

  // 唤醒显示器：仅对"没锁屏、只是屏幕睡了"有效，真锁屏时它只会把锁屏界面点亮。
  async function wakeDisplay() {
    try { await request('/api/screen/wake', undefined, 'POST'); } catch { /* 唤醒失败不影响后续取帧 */ }
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
        // 同时把分辨率写进 option.dataset，供远端拖动把比例差换算成鼠标像素位移。
        const opts = result.displays.map(display => {
          const opt = new Option(display.name, String(display.id));
          if (display.width) opt.dataset.w = display.width;
          if (display.height) opt.dataset.h = display.height;
          return opt;
        });
        displays.replaceChildren(...opts);
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
        // 锁屏是独立端点问的：锁屏时取帧本身就失败，把状态混在这次响应里等于永远问不出来。
        const locked = needsPermission ? false : await queryLocked();
        if (locked) {
          emptyTitle.textContent = '电脑已锁屏';
          emptyHelp.textContent = '出于安全，macOS 不允许 App 读取锁屏画面。请在电脑上输入密码解锁，再点右上角刷新。';
          permission.hidden = true;
          displays.replaceChildren();
          syncDisplays();
        } else if (!needsPermission && !wakeRetried) {
          // 有授权、也没锁屏，却拿不到画面：多半只是显示器睡了或进了屏保。
          // 唤醒一次再自动重试一轮——只试一次，真故障就别空转。
          wakeRetried = true;
          emptyTitle.textContent = '正在唤醒电脑屏幕…';
          emptyHelp.textContent = '屏幕可能睡着了，正在帮你叫醒它，稍等一下。';
          permission.hidden = true;
          await wakeDisplay();
          updating = true;          // 交给 finally 的 scheduleNext 排下一轮
        } else {
          emptyTitle.textContent = needsPermission ? '先允许查看电脑屏幕' : '暂时无法获取画面';
          emptyHelp.textContent = error.name === 'AbortError' ? '连接超时。请检查手机和电脑的网络，再点右上角刷新。' : error.message;
          permission.hidden = !needsPermission;
          displays.replaceChildren();
          syncDisplays();
          // 手机一点就替用户喊一声：让电脑把系统授权窗弹出来，然后自己等结果。
          if (needsPermission) askPermission(error.payload?.canRequest !== false, error.message);
        }
      }
    } finally {
      clearTimeout(timeout);
      if (current === generation) {
        controller = null;
        // 交互期间有人想要新一帧（比如刚点了一下）：这一帧是点击**之前**开始抓的，
        // 不能拿它冒充点击结果——立刻再补一帧，而不是照常歇 1 秒。
        if (frameWanted) { frameWanted = false; scheduleNext(0); }
        else scheduleNext();
      }
    }
  }

  // 交互后尽快拿到新画面：点完最多等 FRAME_AFTER_TAP 毫秒就抓一帧，
  // 不再干等下一个 1 秒周期——"点下去半天没反应"多半是等在这一秒上。
  // 硬约束：同一时刻只允许一个截图在途，所以已有请求时只标记 frameWanted。
  function requestFrameAfterInteraction() {
    if (!visible() || !updating) return;
    boostFps();   // 刚交互过，先提一会儿帧率
    clearTimeout(timer);
    timer = null;
    timer = setTimeout(() => {
      timer = null;
      if (!visible() || !updating) return;
      if (controller) { frameWanted = true; return; }   // 等它结束，由 finally 立刻补一帧
      capture();
    }, FRAME_AFTER_TAP);
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
  // 画面几何只有一份真值：下面这个 baseContentRect() —— **未经缩放**的元素局部矩形。
  // object-fit: contain 会在元素框内留黑边，真正的画面只占中间一块，先剔除黑边，
  // 否则缩放后的定位是偏的。点击映射与光标叠加都必须从这一份出发——
  // 各算一遍迟早算出两个不同的点。
  // 几何只有一份真值：未缩放的元素局部矩形（object-fit contain 剔除黑边后的画面块）。
  // **缓存**：只在其输入（natural 尺寸 / 元素布局尺寸）变化时重算，连续光标帧只读取缓存，
  // 不再每帧读 image.offsetWidth（强制同步重排，是"拖动很慢"的帮凶，见 §4）。
  // 输入改变点：image 'load'（natural 尺寸）、window resize（offsetWidth 变）、切屏（natural 可能变）。
  let cachedBaseRect = null;
  let cachedBaseKey = '';
  function baseContentRect() {
    if (!image.naturalWidth || !image.naturalHeight || image.hidden) { cachedBaseRect = null; cachedBaseKey = ''; return null; }
    const key = `${image.naturalWidth}x${image.naturalHeight}x${image.offsetWidth}x${image.offsetHeight}`;
    if (key === cachedBaseKey && cachedBaseRect) return cachedBaseRect;
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
    cachedBaseRect = { x: offsetX, y: offsetY, width, height };
    cachedBaseKey = key;
    return cachedBaseRect;
  }

  // 缩放后的画面矩形（视口坐标系）：给光标叠加层用。
  // 点击映射**不能**用这个——event.offsetX 是元素局部坐标、不受 transform 影响
  // （整层转 90° 时换算依然正确，靠的就是这个性质），所以那边走 baseContentRect。
  function contentRect() {
    const base = baseContentRect();
    if (!base) return null;
    const { scale, tx, ty } = zoomState;
    return {
      x: base.x * scale + tx,
      y: base.y * scale + ty,
      width: base.width * scale,
      height: base.height * scale,
    };
  }

  // 点画面 = 光标移过去 + 左键单击：tap 命令自带 click 参数，一条消息原子执行，
  // 不用"先 move 再 click"两条消息去赌顺序。
  // 以前刻意只移不点（怕误触），但全屏时整块画面就是给人点的，不点等于这屏白给。
  function sendTap(event) {
    if (isFullscreen()) return;   // 全屏点按改由状态机处理；否则 preventDefault 没拦住的兼容 click 会重复发
    // 拖动/平移尾巴上那次 click **只吃掉一次**：以前是"拖完 400ms 内一律忽略"，
    // 于是拖完窗口想立刻点一下画面会被吞掉。改成消费一次就放行，下一次新轻点立即可用。
    if (dragClickPending && Date.now() - lastDragEndAt < DRAG_CLICK_GUARD) {
      dragClickPending = false;
      return;
    }
    // 画面放大后照样准：offsetX 与 baseContentRect 同在元素局部坐标系里，
    // transform 不参与这一侧的换算（同一套坐标，不需要再除 scale）。
    const rect = baseContentRect();
    if (!rect) return;
    const rx = (event.offsetX - rect.x) / rect.width;
    const ry = (event.offsetY - rect.y) / rect.height;
    if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return;
    // 通道没连上时静默放过：状态条已经去掉了，不为一条提示再把 toast 加回来。
    // 画面上点不动本身就是反馈——真要看原因，控制台里有一条 warn。
    if (!window.pocketdeskSend) { console.warn('[screen] 触控板通道未连接，点画面移动光标未发送'); return; }
    // 双击：**第一下立刻发出**（不等双击窗口，否则每次单击都凭空多 350ms 延迟），
    // 第二下在时间、位置、显示器都对得上时才带 clickState=2 —— 这正是 Mac 真双击的事件序列。
    const display = Number(displays.value);
    const now = Date.now();
    const isDouble = !!lastScreenTap && now - lastScreenTap.ts < DOUBLE_TAP_MS
      && lastScreenTap.display === display
      && Math.hypot(event.offsetX - lastScreenTap.x, event.offsetY - lastScreenTap.y) < DOUBLE_TAP_SLOP;
    lastScreenTap = isDouble ? null : { ts: now, x: event.offsetX, y: event.offsetY, display };
    window.pocketdeskSend({ t: 'tap', rx, ry, display, click: true, clickState: isDouble ? 2 : 1 });
    // 点完尽快拿新画面：这是“点了没反应”体感的主因——以前要干等下一个 1 秒周期。
    // 全屏键盘不再随点画面自动弹（避免切换窗口时点一下就蹦键盘）：改为全屏里的键盘图标
    // 显式唤起，见 app.js 的 #kb-toggle。
    requestFrameAfterInteraction();
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
    // 全屏也画权威光标（§6 层2）：几何已缓存，不再逐帧读 offsetWidth，叠加层开销可控。
    const drawable = rect && cursorState && updating && !image.hidden
      && cursorState.displayId === watching && cursorLinkLive();
    if (!drawable) { cursorDot.hidden = true; return; }
    cursorDot.hidden = false;
    cursorDot.style.transform =
      `translate(${rect.x + cursorState.rx * rect.width}px, ${rect.y + cursorState.ry * rect.height}px)`;
  }

  // 光标叠加层：仅在全屏控制态订阅 30Hz 坐标并关掉画面烘焙鼠标（cursor=0），
  // 避免屏幕上出现两个指针；PiP 小窗沿用烘焙鼠标（cursor=1），不恢复其高频开销（§6）。
  // 链路断了 / 不可见 / 非全屏时退订并画回含鼠标的截图——宁旧不能没有。
  let cursorSubscribed = false;
  function syncCursorSubscription() {
    const wanted = isFullscreen() && panel.open && updating && !document.hidden;
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


  // 本地触点环（§6 层1）：只代表"手机收到了这次触摸"，不表示 Mac 已执行。
  // 用局部坐标定位，落在 viewport 内、随 .rotated 一起转，不需要单独处理旋转。
  function showTouch(clientX, clientY) {
    if (!touchDot || !isFullscreen()) return;
    const lp = toLocal(clientX, clientY);
    touchDot.hidden = false;
    touchDot.style.transform = `translate(${lp.x}px, ${lp.y}px) translate(-50%, -50%)`;
    clearTimeout(touchHideTimer);
    touchHideTimer = setTimeout(() => { touchDot.hidden = true; }, 140);
  }
  function hideTouch() {
    clearTimeout(touchHideTimer);
    if (touchDot) touchDot.hidden = true;
  }

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
    // 已有拖动进行中：忽略后续手指。否则第二根手指的 pointerdown 会覆盖
    // dragState.pointerId，后续 moveDrag 因 pointerId 对不上直接 return，
    // 拖动瞬间失联——表现就是"不跟手 / 卡住"。手机上多指很常见，必须挡掉。
    if (dragState) return;
    dragState = {
      pointerId: event.pointerId,
      edge,                                    // null = 拖整块；'nw' | 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w'
      startX: event.clientX,
      startY: event.clientY,
      originX: pipBox.x,
      originY: pipBox.y,
      originW: pipBox.w,
      originH: pipBox.h,
      lastX: pipBox.x,                         // 拖动中实时位移的最终落点（松手时烤回 left/top）
      lastY: pipBox.y,
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
      // 拖整块：用 transform 做实时位移——纯合成、不触发布局/重绘，
      // 大图浮窗在手机上也跟手。真实的 left/top 只在松手时落定一次（endDrag → paintPanel）。
      const minVisible = 56; // 至少露 56px，否则整块飘出屏幕外就抓不回来了
      let nx = originX + dx;
      let ny = originY + dy;
      nx = Math.min(Math.max(-(originW - minVisible), nx), window.innerWidth - minVisible);
      ny = Math.min(Math.max(-(originH - minVisible), ny), window.innerHeight - minVisible);
      dragState.lastX = nx; dragState.lastY = ny;
      panel.style.transform = `translate3d(${nx - originX}px, ${ny - originY}px, 0)`;
      return;   // 整块拖动走 transform，不碰 left/top、不调 paintPanel——否则会清掉刚写的 transform 让窗口弹回
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
    const edge = dragState.edge;
    // 松手在 paintPanel 之前把落点烤回基线，避免跟后续 paintPanel 抢着写 inline style。
    const lastX = dragState.lastX, lastY = dragState.lastY;
    const w = dragState.originW, h = dragState.originH;
    dragState = null;
    panel.classList.remove('dragging');
    try { event.currentTarget.releasePointerCapture(event.pointerId); } catch { /* 上面已说明 */ }
    if (!moved) {
      // 纯点按：清掉不应存在的 transform（保险），基线不动。
      panel.style.transform = '';
      return;
    }
    // 缩放（8 个 handle）：moveDrag 每帧已经把新尺寸写进 pipBox，并按 left/top/width/height
    // 真实渲染过——这里**绝不能**再拿 originW/originH 覆盖回去，那正是"放大一点松手就弹回原样"的根因。
    // （lastX/lastY 同理：它们是整块拖动专用的落点，缩放时从未更新过。）
    if (edge) {
      pipBox = clampPipBox(pipBox);
      panel.style.transform = '';
      paintPanel();
      savePipBox(pipBox);
      lastDragEndAt = Date.now();   // 吃掉缩放尾巴上那次 click，免得误触发点画面
      dragClickPending = true;
      return;
    }
    // 拖整块：落点此前只写在 transform 上，此刻才烤回 left/top。
    pipBox = clampPipBox({ x: lastX, y: lastY, w, h });
    panel.style.transform = '';
    paintPanel();
    savePipBox(pipBox);
    lastDragEndAt = Date.now();
    dragClickPending = true;
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

  /* ---------- 指针坐标：全屏竖屏旋转态的逆变换 ----------
     竖屏全屏时 panel 被 CSS 旋转 90°（.rotated）。指针的 clientX/clientY 是页面坐标，
     直接拿去算双指捏合/平移会被旋转带偏。toLocal() 把页面坐标逆旋转成 panel 的
     局部坐标——与 baseContentRect / clampZoom 用的 offset / client 布局坐标同一套，
     于是缩放平移全程在局部系里算，旋转对它透明。 */
  function toLocal(clientX, clientY) {
    if (!isFullscreen() || !panel.classList.contains('rotated')) return { x: clientX, y: clientY };
    const W = panel.clientWidth, H = panel.clientHeight;   // 布局尺寸，旋转不影响
    const cx = window.innerWidth / 2, cy = window.innerHeight / 2;
    const px = clientX - cx, py = clientY - cy;
    // CSS rotate(90deg) 顺时针：local(绕中心) → page 为 (x,y) ↦ (-y, x)；逆变换 page→local 即 (py, -px) 平移回中心。
    return { x: W / 2 + py, y: H / 2 - px };
  }

  /* ---------- 画面缩放与平移（仅全屏态） ----------
     全屏态没有"拖窗口 / 改窗口尺寸"这回事，整块画面就是给人看细节的，
     所以这里缩的是**画面内容本身**（#screen-image 的 transform），不是窗口。
     1x = object-fit 适应态（不缩小，只放大），上限 6x。

     为什么必须自己写：.screen-view 上有 touch-action: none（不让浏览器手势抢画面），
     浏览器自带的双指捏合因此完全失效——指望它等于没有，只能自己接 Pointer Events。

     两条换算纪律：
       1) 锚点缩放按 CSS 的 transform-origin: 0 0 推导：屏幕点 p 对应内容点 c = (p - t) / s，
          要让 p 处的内容不动，缩放后 t' = p - c * s'。改 CSS 的 origin 必须同步改这里。
       2) 平移一律过 clampZoom()：内容比视口大时不允许露黑边，比视口小时居中。

     与"点画面移光标"共存：单指轻点（位移不过 DRAG_THRESHOLD）仍然是 tap；
     放大后单指拖动变成平移画面，抬起时用 lastDragEndAt 吃掉那次尾巴 click。 */
  const ZOOM_MIN = 1;
  const ZOOM_MAX = 6;
  const ZOOM_SNAP = 0.02;   // 捏到离 1x 这么近就吸附回适应态，免得卡在 1.01x 这种尴尬位置

  function resetZoom() {
    zoomState = { scale: 1, tx: 0, ty: 0 };
    pinchState = null;
    panState = null;
    zoomPointers.clear();
    applyZoom();
  }

  function applyZoom() {
    const { scale, tx, ty } = zoomState;
    const identity = scale === 1 && tx === 0 && ty === 0;
    image.style.transform = identity ? '' : `translate(${tx}px, ${ty}px) scale(${scale})`;
    panel.classList.toggle('zoomed', !identity);
    paintCursor();
  }

  // 单个方向的平移夹取：保证画面不会整块滑出视口（内容比视口小时居中）。
  function clampAxis(baseStart, baseSize, viewSize, scale, translate) {
    const size = baseSize * scale;
    if (size <= viewSize) return (viewSize - size) / 2 - baseStart * scale;
    const start = baseStart * scale + translate;
    const clamped = Math.max(viewSize - size, Math.min(0, start));
    return clamped - baseStart * scale;
  }

  function clampZoom(next) {
    const base = baseContentRect();
    let scale = Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, next.scale));
    if (scale < ZOOM_MIN + ZOOM_SNAP) scale = ZOOM_MIN;   // 吸附回适应态
    if (!base) return { scale, tx: 0, ty: 0 };
    return {
      scale,
      tx: clampAxis(base.x, base.width, viewport.clientWidth, scale, next.tx),
      ty: clampAxis(base.y, base.height, viewport.clientHeight, scale, next.ty),
    };
  }

  // 单指平移只在放大后有意义：1x 时画面本来就完整铺着，那根手指要留给"点画面"。
  function beginPan(pointerId, x, y) {
    panState = zoomState.scale > 1
      ? { pointerId, startX: x, startY: y, startTx: zoomState.tx, startTy: zoomState.ty, moved: false }
      : null;
  }

  function beginPinch() {
    const [a, b] = [...zoomPointers.values()];
    pinchState = {
      // 距离旋转不变，mid 用局部坐标（viewport 在 rotated 下仍是 inset:0，局部原点即 panel 原点）。
      startDist: Math.hypot(a.x - b.x, a.y - b.y) || 1,
      startMidX: (a.x + b.x) / 2,
      startMidY: (a.y + b.y) / 2,
      startScale: zoomState.scale,
      startTx: zoomState.tx,
      startTy: zoomState.ty,
    };
    panState = null;
  }

  function updatePinch() {
    const [a, b] = [...zoomPointers.values()];
    const dist = Math.hypot(a.x - b.x, a.y - b.y) || 1;
    const midX = (a.x + b.x) / 2;
    const midY = (a.y + b.y) / 2;
    const scale = pinchState.startScale * (dist / pinchState.startDist);
    // 起点中点下的那个内容点，缩放前后钉在同一个屏幕位置上；再叠加中点的位移，平移也就顺带完成了。
    const cx = (pinchState.startMidX - pinchState.startTx) / pinchState.startScale;
    const cy = (pinchState.startMidY - pinchState.startTy) / pinchState.startScale;
    zoomState = clampZoom({ scale, tx: midX - cx * scale, ty: midY - cy * scale });
    applyZoom();
  }

  /* ---------- 全屏手势状态机（§3/§4/§5）----------
     单指：轻点=远端立即单击（第一下不等待双击窗口）；快速两下=双击(clickState 2)；
           小移=绝对跟随移动鼠标（不按左键）；按住过阈值=远端拖动（按下/移动/释放）。
     双指：只缩放/平移手机上的画面（view transform），不给 Mac 发点击或滚动。
     用 setPointerCapture 收尾；全屏 pointerdown 即 preventDefault 取消兼容 click，
     避免 pointerup 与旧 img.click 各发一次（PiP 仍走 img.click→sendTap，不受影响）。
     单指语义与旧版相反：旧版单指平移本地画面，本版单指直接控制电脑（方案§3）。 */
  const FS_MOVE_THRESHOLD = 8;   // 超过即视为移动/拖动而非点
  const FS_LONG_PRESS = 400;     // 按住不动超过即进入远端拖动
  const FS_SCROLL_GAIN = 1.3;    // 手指位移 → 滚动像素增益

  let fsState = null;            // 当前全屏手势：null | {mode, pointerId, ...}
  let fsScrollMode = false;      // 滚动工具开启时单指拖=滚动
  let lastRx = 0.5, lastRy = 0.5;   // 最近一次远端光标比例坐标（右键工具作用点）
  const displaySize = new Map(); // displayId → {w, h} 逻辑分辨率，远端拖动换算像素用

  // 显示器列表带上了分辨率（Server.swift displays()）：存下来供拖动换算像素位移。
  function syncDisplaySizes() {
    for (const opt of displays.options) {
      const w = Number(opt.dataset?.w), h = Number(opt.dataset?.h);
      if (w && h) displaySize.set(opt.value, { w, h });
    }
  }

  // 页面坐标 → 比例坐标（逆旋转 + object-fit 留白剔除），单击/移动/拖动/右键/滚动共用（§4 统一几何）。
  function clientToRatio(clientX, clientY) {
    const local = toLocal(clientX, clientY);
    const base = baseContentRect();
    if (!base) return null;
    const rx = (local.x - base.x) / base.width;
    const ry = (local.y - base.y) / base.height;
    if (rx < -0.6 || rx > 1.6 || ry < -0.6 || ry > 1.6) return null;  // 留白/HUD 外不发电
    return { rx: Math.min(1, Math.max(0, rx)), ry: Math.min(1, Math.max(0, ry)) };
  }

  // 远端点按（含双击序列）：复用 lastScreenTap / DOUBLE_TAP_* 判定，与 PiP 的 sendTap 同源。
  function fsSendTap(rx, ry) {
    const display = Number(displays.value);
    const now = Date.now();
    const isDouble = !!lastScreenTap && now - lastScreenTap.ts < DOUBLE_TAP_MS
      && lastScreenTap.display === display
      && Math.hypot(rx * 100 - lastScreenTap.rx * 100, ry * 100 - lastScreenTap.ry * 100) < DOUBLE_TAP_SLOP;
    lastScreenTap = isDouble ? null : { ts: now, rx, ry, display };
    window.pocketdeskSend?.({ t: 'tap', rx, ry, display, click: true, clickState: isDouble ? 2 : 1 });
    lastRx = rx; lastRy = ry;
    requestFrameAfterInteraction();
  }

  function fsSendMove(rx, ry) {
    const display = Number(displays.value);
    window.pocketdeskSend?.({ t: 'tap', rx, ry, display, click: false });
    lastRx = rx; lastRy = ry;
  }

  function onFsPointerDown(event) {
    if (!panel.open || !isFullscreen()) return;
    if (event.button) return;
    // 键盘抬起时点画面 = 收起键盘（解决"点屏幕反而把键盘顶出来 / 卡在开着"）。
    // 这一下只负责收键盘、不顺便点 Mac，避免误触；键盘关掉后再点画面才控制 Mac。
    if (window.pocketdeskKeyboardActive?.()) {
      window.pocketdeskHideKeyboard?.();
      return;
    }
    event.preventDefault();   // 取消兼容 click；PiP 不进此分支，不受影响
    const p = clientToRatio(event.clientX, event.clientY);
    if (!p) return;
    // 第二根手指加入：本次接触永不回到 tap，转 view transform（捏合/平移）。
    if (zoomPointers.size >= 1) {
      const lp = toLocal(event.clientX, event.clientY);
      zoomPointers.set(event.pointerId, { x: lp.x, y: lp.y });
      beginPinch();
      fsState = { mode: 'view' };
      return;
    }
    try { viewport.setPointerCapture?.(event.pointerId); } catch { /* 捕获失败不影响逻辑 */ }
    // 第一根手指也要登记进 zoomPointers：第二根落下时靠 zoomPointers.size>=1 判定进入捏合，
    // 漏登的话双指永远进不了 pinch 分支 → 全屏放大/缩小整段失效（v2.9.19 回归）。
    zoomPointers.set(event.pointerId, toLocal(event.clientX, event.clientY));
    fsState = {
      mode: 'idle', pointerId: event.pointerId,
      startX: event.clientX, startY: event.clientY,
      startRx: p.rx, startRy: p.ry,
      lastRx: p.rx, lastRy: p.ry,
      moved: false, dragging: false, longPressTimer: null,
    };
    showTouch(event.clientX, event.clientY);
    // 按住过阈值且没怎么动 → 远端拖动：先移到起点，再按下左键。
    fsState.longPressTimer = setTimeout(() => {
      if (fsState && fsState.mode === 'idle' && !fsState.moved) {
        fsState.mode = 'drag';
        fsState.dragging = true;
        fsSendMove(fsState.startRx, fsState.startRy);
        window.pocketdeskSend?.({ t: 'down' });
      }
    }, FS_LONG_PRESS);
  }

  function onFsPointerMove(event) {
    // view transform：交给已有 pinch/pan 逻辑。
    if (fsState && fsState.mode === 'view') {
      const point = zoomPointers.get(event.pointerId);
      if (!point) return;
      const lp = toLocal(event.clientX, event.clientY);
      point.x = lp.x; point.y = lp.y;
      if (pinchState && zoomPointers.size >= 2) { updatePinch(); event.preventDefault(); return; }
      if (panState && panState.pointerId === event.pointerId) {
        const dx = lp.x - panState.startX, dy = lp.y - panState.startY;
        if (Math.hypot(dx, dy) > DRAG_THRESHOLD) panState.moved = true;
        zoomState = clampZoom({ scale: zoomState.scale, tx: panState.startTx + dx, ty: panState.startTy + dy });
        applyZoom(); event.preventDefault();
      }
      return;
    }
    if (!fsState || fsState.pointerId !== event.pointerId) return;
    const p = clientToRatio(event.clientX, event.clientY);
    if (!p) return;
    showTouch(event.clientX, event.clientY);
    const dx = event.clientX - fsState.startX, dy = event.clientY - fsState.startY;
    if (fsState.mode === 'idle') {
      if (Math.hypot(dx, dy) > FS_MOVE_THRESHOLD) {
        fsState.moved = true;
        if (fsScrollMode) { fsState.mode = 'scroll'; }
        else { fsState.mode = 'move'; fsSendMove(p.rx, p.ry); }
      }
      return;
    }
    if (fsState.mode === 'move') { fsSendMove(p.rx, p.ry); boostFps(); return; }
    if (fsState.mode === 'drag') {
      const size = displaySize.get(String(displays.value)) || { w: 1920, h: 1080 };
      const ddx = (p.rx - fsState.lastRx) * size.w;
      const ddy = (p.ry - fsState.lastRy) * size.h;
      window.pocketdeskSend?.({ t: 'drag', dx: ddx, dy: ddy });
      fsState.lastRx = p.rx; fsState.lastRy = p.ry; boostFps(); return;
    }
    if (fsState.mode === 'scroll') {
      window.pocketdeskSend?.({ t: 'scroll', dx: -dx * FS_SCROLL_GAIN, dy: -dy * FS_SCROLL_GAIN });
      fsState.startX = event.clientX; fsState.startY = event.clientY;   // 增量式：每帧以位移差发
      boostFps(); return;
    }
  }

  function onFsPointerUp(event) {
    if (fsState && fsState.mode === 'view') {
      if (!zoomPointers.delete(event.pointerId)) return;
      if (zoomPointers.size < 2) pinchState = null;
      if (panState && panState.pointerId === event.pointerId) {
        // 真平移过就吃掉随后那次 click：否则"平移画面"会顺手在 Mac 上点一下。
        // 只吃一次（dragClickPending），拖完立刻点画面不会被时间窗误杀。
        if (panState.moved) { lastDragEndAt = Date.now(); dragClickPending = true; }
        panState = null;
      }
      // 双指松掉一根：剩下那根接着当平移用，手感不断档。
      if (zoomPointers.size === 1 && zoomState.scale > 1) {
        const [id] = [...zoomPointers.keys()];
        const rest = zoomPointers.get(id);
        beginPan(id, rest.x, rest.y);
      }
      if (zoomPointers.size === 0) fsState = null;
      return;
    }
    zoomPointers.delete(event.pointerId);   // 单指（未进 view 分支）松手时清掉登记，免残留让下次误判成第二指
    if (!fsState || fsState.pointerId !== event.pointerId) return;
    clearTimeout(fsState.longPressTimer);
    try { viewport.releasePointerCapture?.(event.pointerId); } catch { /* 无所谓 */ }
    hideTouch();
    if (fsState.mode === 'drag') {
      window.pocketdeskSend?.({ t: 'up' });
    } else if (fsState.mode === 'scroll') {
      window.pocketdeskSend?.({ t: 'scrollEnd' });
    } else if (fsState.mode === 'idle') {
      // 没怎么动、很快抬起 = 单击（双击序列由 fsSendTap 内部判定，第一下不等待）。
      fsSendTap(fsState.startRx, fsState.startRy);
    }
    // mode === 'move'：只是移动鼠标，松手不补单击（方案§3）。
    fsState = null;
  }

  viewport.addEventListener('pointerdown', onFsPointerDown);
  window.addEventListener('pointermove', onFsPointerMove);
  window.addEventListener('pointerup', onFsPointerUp);
  window.addEventListener('pointercancel', onFsPointerUp);

  // 全屏操作反馈 toast：右键 / 滚动等动作在 Mac 执行，手机端无可见反馈会像"没反应"。
  // 动态建到 body 上、fixed 定位，不受 .rotated 旋转影响，始终正立居中于底部。
  let toastEl = null, toastTimer = 0;
  function showToast(msg) {
    if (!toastEl) {
      toastEl = document.createElement('div');
      toastEl.className = 'screen-toast';
      toastEl.setAttribute('role', 'status');
      toastEl.setAttribute('aria-live', 'polite');
      document.body.appendChild(toastEl);
    }
    toastEl.textContent = msg;
    // 重置动画：先去掉 show 触发过渡，下一帧再加回，避免连点不重播。
    toastEl.classList.remove('show');
    void toastEl.offsetWidth;
    toastEl.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toastEl.classList.remove('show'), 1100);
  }

  // 右键工具（§3）：作用于最近一次远端光标位置（lastRx/lastRy，随点/移/拖更新）。
  function onRightClick() {
    if (!isFullscreen()) return;
    fsSendMove(lastRx, lastRy);                 // 先把光标移到目标点
    window.pocketdeskSend?.({ t: 'click', button: 'right', clickState: 1 });
    boostFps();
    showToast('已发送右键');
  }
  // 滚动工具（§3）：开启后单指拖=滚动，不与"单指=远端控制"抢同一根手指。
  function onScrollToggle() {
    if (!isFullscreen()) return;
    fsScrollMode = !fsScrollMode;
    screenScroll?.classList.toggle('active', fsScrollMode);
    showToast(fsScrollMode ? '滚动模式：开（单指拖=滚动）' : '滚动模式：关');
  }
  screenRightClick?.addEventListener('click', onRightClick);
  screenScroll?.addEventListener('click', onScrollToggle);

  /* ---------- 全屏自动横铺 ----------
     电脑画面是 16:9 的，竖屏手机上只占中间一条。不依赖浏览器的方向锁
     （iOS Safari 压根没有 screen.orientation.lock，网页锁不了方向），
     而是直接在竖屏全屏时给 panel 加 .rotated 类做 CSS 90° 旋转——
     画面整层转过去铺满横屏，iPhone/安卓都生效，也不用弹"请横屏"的提示。
     旋转前的设计本就为此预留：点画面用 offsetX、光标用 offsetWidth，
     都是不受 transform 影响的局部坐标，整层转 90° 换算依然正确；
     只有双指缩放/平移的 clientX/Y 在 toLocal() 里逆旋转一把即可。 */
  async function enterFullscreenLayout() {
    try {
      // 原生全屏只为藏掉浏览器地址栏/底栏，拿到更多画面面积；锁方向不求它。
      if (document.fullscreenEnabled && !document.fullscreenElement) {
        await panel.requestFullscreen?.({ navigationUI: 'hide' });
      }
    } catch { /* 不支持就靠 CSS inset:0 铺满，不影响旋转逻辑 */ }
    updateRotation();
  }

  function exitFullscreenLayout() {
    try { if (document.fullscreenElement) document.exitFullscreen?.(); } catch { /* 无所谓 */ }
    updateRotation();
  }

  // 全屏且手机仍是竖屏（innerWidth < innerHeight）才需要把整层转 90°；
  // 已是横屏（安卓原生全屏把设备转过去了）就保持原样，不画蛇添足。
  function updateRotation() {
    const rotated = panel.open && isFullscreen() && window.innerWidth < window.innerHeight;
    panel.classList.toggle('rotated', rotated);
  }
  // 转屏 / 尺寸变化后 innerWidth/Height 更新有延迟，晚一拍再判。
  // 键盘抬起同样会派发 resize，但那不是转屏——跳过，免得画面跟着抖一下。
  window.addEventListener('orientationchange', () => setTimeout(updateRotation, 250));
  window.addEventListener('resize', () => {
    if (window.pocketdeskKeyboardActive?.()) return;
    updateRotation();
  });

  /* ---------- 查看器开关 ----------
     两种形态：可拖可缩的 PiP 浮窗 + 整层全屏（点全屏按钮切换）。开 = show()（非模态），
     所以浮窗开着时主页触控板仍能操作，不抢手势。panel.open 是唯一真值，
     不另设一个状态变量去跟它对齐，那才是漂移的开始。 */
  function openViewer() {
    if (panel.open || historyPending) return;
    document.activeElement?.blur();
    autoRequested = false;
    wakeRetried = false;
    updating = true;
    if (!pipBox) pipBox = loadPipBox() || defaultPipBox();
    syncDisplays();
    syncDisplaySizes();   // 显示器分辨率缓存，远端拖动换算像素用
    panel.show();
    paintPanel();
    // 一打开就先叫醒显示器：没锁屏的话画面立刻回来，省得用户以为坏了。
    // 锁屏时唤醒只会点亮锁屏界面、取帧依旧失败，随后由 capture 的失败分支给出"已锁屏"提示。
    wakeDisplay();
    capture();
    syncCursorSubscription();
    history.pushState({ ...history.state, pocketdeskScreen: true }, '');
    document.body.classList.add('screen-viewing');
  }

  function closeViewer(fromHistory = false) {
    stop();
    releaseImage();
    panel.close();
    resetZoom();          // 缩放是全屏态的产物，关掉就别留着（下次打开从适应态开始）
    exitFullscreenLayout();  // 同理：横屏是查看器的产物，退出就把旋转/原生全屏一并撤掉
    window.pocketdeskHideKeyboard?.();  // 全屏键盘是查看器的产物，关掉画面一并收掉
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
    // 进/出全屏都把画面缩放归位：进出各看各的场景，残留的 3x 平移换到另一态只会让人找不着北。
    resetZoom();
    updateRotation();   // 同步先把 .rotated 加上/撤掉，避免切全屏那一帧闪一下竖屏
    // 全屏：竖屏时 CSS 整层转 90° 把画面横铺满；退出：把旋转/原生全屏一并撤掉（不撤的话主页会卡在横屏）。
    if (isFullscreen()) enterFullscreenLayout(); else { exitFullscreenLayout(); window.pocketdeskHideKeyboard?.(); }
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
  // 键盘抬起引起的那次 resize 要**跳过**：那不是用户转屏，重排只会让画面跟着键盘缩一下又弹回来，
  // 看着就是"整页被顶上去"。键盘落下后由 window.pocketdeskKeyboardClosed 补一次真实重排。
  function relayoutAfterViewportChange() {
    if (!panel.open) return;
    updateRotation();   // 转屏/尺寸变化可能改变横竖屏，重新决定要不要整层转 90°
    // 全屏态：转屏后视口尺寸变了，旧的 tx/ty 可能已经越界（画面被推出屏幕外），重夹一次。
    if (isFullscreen()) { zoomState = clampZoom(zoomState); applyZoom(); }
    pipBox = clampPipBox(pipBox);
    paintPanel();
    savePipBox(pipBox);
  }
  window.addEventListener('resize', () => {
    if (window.pocketdeskKeyboardActive?.()) return;
    relayoutAfterViewportChange();
  });
  window.pocketdeskKeyboardClosed = relayoutAfterViewportChange;
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
  // 点刷新重置"唤醒重试"计数：万一上次唤醒后仍未成功（例如刚解锁），再给一次机会。
  refresh.addEventListener('click', () => { wakeRetried = false; updating = true; capture(); });
  // 换显示器 = 换了另一块画面（分辨率都可能不同），旧的缩放与平移没有意义，一律归位。
  displays.addEventListener('change', () => { resetZoom(); syncDisplays(); syncDisplaySizes(); stop(); releaseImage(); capture(); });
  displaySwitch.addEventListener('click', () => switchDisplay(1));
  // 换屏后旧坐标属于别的显示器，立刻擦掉，等新屏的第一帧到达再画。
  image.addEventListener('load', paintCursor);
  // 手动点按钮时允许重喊一次（force）：自动那次可能用户没看见电脑上的弹窗。
  permission.addEventListener('click', () => askPermission(true, true));
})();
