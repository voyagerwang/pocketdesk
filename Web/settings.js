/**
 * [INPUT]: 消费 index.html 的 #phone-settings 面板与 header 齿轮，以及迁来的 #sens / #scroll-speed / #ruler-mode。
 * [OUTPUT]: 提供唯一手机设置面板的开关、遮罩关闭、焦点恢复与偏好读写；翻腕组保存用户意愿与灵敏度档位，
 *           并就地把可用性原因写回 #wrist-note（不弹独立读数面板）；证书接入渲染成四步向导
 *           （①可点下载 ②描述文件安装 ③完全信任 ④真实 HTTPS 探测通过后才跳转），
 *           全部动作都是可点控件，不让用户手抄地址、也不把用户直接丢到"不受信任"页。
 * [POS]: Web 首页的设置边界；不持有业务草稿，不向 Mac 发送点击、滚动或快捷键。
 *        证书信任与运动权限作为两件不同的事分别解释。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/* ---------- 节点 ---------- */

const settingsDialog = document.querySelector('#phone-settings');
const settingsOpenBtn = document.querySelector('#phone-settings-open');
const settingsCloseBtn = document.querySelector('#phone-settings-close');
const wristToggle = document.querySelector('#wrist-toggle');
const wristNote = document.querySelector('#wrist-note');
const wristLinks = document.querySelector('#wrist-links');

/* ---------- 翻腕偏好：只存用户意愿，不存授权态或运行态 ---------- */

const MOTION_PREF_KEY = 'pd-motion-send';
const MOTION_PREF_VERSION = 1;

function readMotionPref() {
  try {
    const raw = JSON.parse(localStorage.getItem(MOTION_PREF_KEY) || '{}');
    return raw && raw.v === MOTION_PREF_VERSION ? raw : { v: MOTION_PREF_VERSION, enabled: false };
  } catch (error) {
    return { v: MOTION_PREF_VERSION, enabled: false };   // 无痕或数据损坏时退回默认关闭
  }
}

function writeMotionPref(patch) {
  const next = { ...readMotionPref(), ...patch, v: MOTION_PREF_VERSION };
  try {
    localStorage.setItem(MOTION_PREF_KEY, JSON.stringify(next));
  } catch (error) {
    /* 存储被拒时内存态仍可用，不阻断本次操作 */
  }
  return next;
}

// 失败原因只在用户真的尝试开启后就地显示；默认关闭时不预先铺陈一堆红字。
function setWristNote(text, warn = false) {
  wristNote.textContent = text;
  wristNote.className = warn ? 'sheet-hint is-warn' : 'sheet-hint';
}

// 把"要用户自己去做的动作"渲染成真正的链接/按钮：装证书、检测并打开安全连接都点一下即可，
// 不该让用户对着一段地址手抄。全部用 createElement + textContent，不拼 innerHTML：
// 地址来自浏览器自身，即使哪天带上参数也不会变成注入点。
function wristActionNode(item) {
  let node;
  if (item.kind === 'link') {
    node = document.createElement('a');
    node.className = 'sheet-btn wrist-link';
    node.href = item.href;
    if (item.newTab) { node.target = '_blank'; node.rel = 'noopener'; }
  } else if (item.kind === 'action') {
    node = document.createElement('button');
    node.type = 'button';
    node.className = 'sheet-btn wrist-link';
    if (item.onClick) node.addEventListener('click', item.onClick);
  } else {
    node = document.createElement('p');
    node.className = item.kind === 'hint' ? 'sheet-hint wrist-step' : 'wrist-step';
  }
  node.textContent = item.label;
  return node;
}

function setWristLinks(items) {
  if (!wristLinks) return;
  wristLinks.textContent = '';
  const list = items || [];
  wristLinks.hidden = list.length === 0;
  for (const item of list) wristLinks.appendChild(wristActionNode(item));
}

// iPhone 的证书接入是四步，其中第 2–4 步都在系统设置里——网页看不到进度，
// 所以只能把系统步骤写清楚，再用一次**真实 HTTPS 握手**判断到底装好没有（不许伪造"已完成"）。
// 引导做三件事：不让用户手抄地址、不让下载被误当成安装、不把用户直接丢到 Safari 走不下去的
// "不受信任"页（第 4 步先探测、成功才跳转）。
async function detectAndOpenSecure(event) {
  const button = event.currentTarget;
  button.disabled = true;
  setWristNote('正在检测电脑上的 HTTPS 服务…');
  let result = { ok: false, reason: '检测能力尚未就绪，请下拉刷新页面后重试。' };
  try {
    if (window.pocketdeskMotion?.probeSecure) result = await window.pocketdeskMotion.probeSecure();
  } catch (error) {
    result = { ok: false, reason: error.message };
  }
  button.disabled = false;
  if (result.ok) {
    setWristNote('证书已就绪，正在打开安全连接…');
    window.location.assign(result.url);
    return;
  }
  setWristNote(result.reason, true);
}

// 安全上下文缺失时的完整向导：①下载证书 → ②安装描述文件 → ③开启完全信任 → ④检测并打开。
function renderWristActions(avail) {
  if (!avail || !avail.needsSecureContext) { setWristLinks(null); return; }
  const certPath = window.pocketdeskMotion?.caCertificatePath;
  const items = [];
  if (certPath) items.push({ kind: 'link', label: '① 安装 PocketDesk 证书', href: certPath });
  items.push({ kind: 'step', label: '下载完会离开浏览器。到「设置 → 通用 → VPN 与设备管理 → 已下载的描述文件 → PocketDesk → 安装」，点完两遍安装。' });
  items.push({ kind: 'step', label: '再开完全信任：「设置 → 通用 → 关于本机 → 证书信任设置」，为「PocketDesk Local Device CA」打开开关。这一步不做，HTTPS 依然进不去。' });
  items.push({ kind: 'action', label: '④ 检测并打开安全连接', onClick: detectAndOpenSecure });
  items.push({ kind: 'hint', label: '证书通常只需设置一次：只有证书被删除、手机还原网络/全部设置、电脑局域网地址变化或证书过期时才要重做。运动与方向权限是另一件事，进入安全页面后再授权。' });
  setWristLinks(items);
}

// 能力判定交给 motion-send.js（注册 pocketdeskWristAvailable）。没有该模块时一律不可用：
// 这是第 9 节第 1 步的真实状态——设置整合先行，体感尚未验证，不能让用户开出一个假开关。
function wristAvailability() {
  return window.pocketdeskWristAvailable?.() ?? { ok: false, reason: '翻腕发送尚未完成传感器与真机验证，暂不可用；请先使用发送按钮。' };
}

wristToggle.checked = readMotionPref().enabled === true && wristAvailability().ok === true;

wristToggle.addEventListener('change', () => {
  if (!wristToggle.checked) {
    writeMotionPref({ enabled: false });
    window.pocketdeskMotion?.stopActive();
    setWristNote('手机向前轻翻，停住片刻后发送。');
    return;
  }
  const probe = wristAvailability();
  if (probe.ok) {
    writeMotionPref({ enabled: true });
    setWristNote(probe.note || '已开启：翻腕后会自动发送。');
    window.pocketdeskMotion?.startActive();
    return;
  }
  // 门禁不通过：立刻回到关闭，不留下"看起来开了"的开关。
  wristToggle.checked = false;
  writeMotionPref({ enabled: false });
  setWristNote(probe.reason, true);
  renderWristActions(probe);
});

/* ---------- 面板生命周期 ---------- */

let settingsReturnFocus = null;

function openPhoneSettings() {
  if (settingsDialog.open) return;
  settingsReturnFocus = document.activeElement;
  // showModal 自带焦点限制与 Esc 关闭；不在这里额外做键盘监听。
  if (typeof settingsDialog.showModal === 'function') settingsDialog.showModal();
  else settingsDialog.setAttribute('open', '');
  updateWristUI();
}

function closePhoneSettings() {
  if (settingsDialog.open && typeof settingsDialog.close === 'function') settingsDialog.close();
  else settingsDialog.removeAttribute('open');
}

settingsOpenBtn.addEventListener('click', openPhoneSettings);
settingsCloseBtn.addEventListener('click', closePhoneSettings);

// 遮罩点击：dialog 自身铺满视口，点到它而不是 .phone-sheet 才算遮罩。
// 只消费本次指针序列，不穿透到下面的触控板或发送行。
settingsDialog.addEventListener('click', event => {
  if (event.target === settingsDialog) closePhoneSettings();
});

// Esc 与关闭按钮走同一条收尾：焦点回到齿轮，不自动弹键盘。
settingsDialog.addEventListener('close', () => {
  if (settingsReturnFocus && settingsReturnFocus.isConnected) settingsReturnFocus.focus({ preventScroll: true });
  settingsReturnFocus = null;
});

// 体感模块可在发送门禁里查询面板是否打开，避免设置期间误触发翻腕发送。
window.pocketdeskSettingsOpen = () => settingsDialog.open === true;
// 供 motion-send 判断“用户是否开启了翻腕发送”。
window.pocketdeskMotionEnabled = () => readMotionPref().enabled === true;

/* ---------- 翻腕授权 / 灵敏度 ---------- */

const wristAuthorize = document.querySelector('#wrist-authorize');
const wristSensitivity = document.querySelector('#wrist-sensitivity');

const SENS_LABEL = { low: '低', medium: '中', high: '高' };

// 阈值度数写进下拉选项（随 PRESETS 自动同步），用户才知道低/中/高到底差几度。
function labelSensitivityOptions() {
  const presets = window.pocketdeskMotion?.PRESETS;
  if (!wristSensitivity || !presets) return;
  for (const option of wristSensitivity.options) {
    const preset = presets[option.value];
    if (preset) option.textContent = SENS_LABEL[option.value] + ' ' + preset.liftDeg + '°';
  }
}

// iOS 13+ 需要一次用户点按触发权限请求；安卓等安全上下文即视为已授权。
// 状态就地写回 #wrist-note，不再往面板里塞读数条与仪表。
function updateWristUI() {
  const avail = window.pocketdeskMotion?.available?.() || { ok: false };
  const needsAuth = Boolean(avail.needsPermission) && !avail.ok;
  if (wristAuthorize) wristAuthorize.hidden = !needsAuth;
  // 开关真身必须与运行态一致：偏好存储只在门禁通过时写 true，这里据此回填。
  const wantOn = readMotionPref().enabled === true && avail.ok === true;
  if (wristToggle && wristToggle.checked !== wantOn) wristToggle.checked = wantOn;
  labelSensitivityOptions();
  if (window.pocketdeskMotion?.isActive?.()) setWristNote('监听中：说完话轻翻手腕即可发送。');
  else if (avail.ok) setWristNote('已就绪，开启上方开关即可使用。');
  else if (avail.reason) setWristNote(avail.reason);
  renderWristActions(avail);
}

if (wristAuthorize) {
  wristAuthorize.addEventListener('click', async () => {
    const result = await window.pocketdeskMotion.requestPermission();
    updateWristUI();
    if (result.ok) setWristNote('已授权，现在可开启翻腕发送。');
    else setWristNote(result.reason, true);
  });
}

if (wristSensitivity) {
  wristSensitivity.addEventListener('change', () => {
    window.pocketdeskMotion?.setPreset(wristSensitivity.value);
    writeMotionPref({ sens: wristSensitivity.value });   // 档位持久化，重开仍是标定好的那一档
  });
}

// settings.js 先于 motion-send.js 解析，档位要等全部脚本就绪后才能灌进识别器。
function initWristPanel() {
  const saved = readMotionPref().sens;
  if (wristSensitivity && saved && window.pocketdeskMotion?.PRESETS?.[saved]) {
    wristSensitivity.value = saved;
    window.pocketdeskMotion.setPreset(saved);
  }
  updateWristUI();
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initWristPanel);
else initWristPanel();
