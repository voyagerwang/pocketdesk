/**
 * [INPUT]: 消费 index.html 的 #phone-settings 面板与 header 齿轮，以及迁来的 #sens / #scroll-speed / #ruler-mode。
 * [OUTPUT]: 提供唯一手机设置面板的开关、遮罩关闭、焦点恢复与偏好读写；翻腕组保存用户意愿与灵敏度档位，
 *           并就地把可用性原因写回 #wrist-note（不弹独立读数面板）；需要用户动手的步骤渲染成
 *           #wrist-links 里可点击的链接（装证书 / 换安全地址），不让用户手抄地址。
 * [POS]: Web 首页的设置边界；不持有业务草稿，不向 Mac 发送点击、滚动或快捷键。
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

// 把"要用户自己去做的动作"渲染成真正的链接：换安全地址、装证书都点一下即可，
// 不该让用户对着一段地址手抄。全部用 createElement + textContent，不拼 innerHTML：
// 地址来自浏览器自身，即使哪天带上参数也不会变成注入点。
function setWristLinks(links) {
  if (!wristLinks) return;
  wristLinks.textContent = '';
  const list = links || [];
  wristLinks.hidden = list.length === 0;
  for (const item of list) {
    const anchor = document.createElement('a');
    anchor.className = 'sheet-btn wrist-link';
    anchor.href = item.href;
    anchor.textContent = item.label;
    if (item.newTab) { anchor.target = '_blank'; anchor.rel = 'noopener'; }
    wristLinks.appendChild(anchor);
  }
}

// 安全上下文缺失时的两步：先装本机 CA（HTTP 就能取），再回安全地址打开同一页。
// 两步都给成可点链接，用户不需要知道端口号，也不需要复制任何东西。
function renderWristActions(avail) {
  if (!avail || !avail.needsSecureContext) { setWristLinks(null); return; }
  const certPath = window.pocketdeskMotion?.caCertificatePath;
  const links = [];
  if (certPath) links.push({ label: '① 安装 PocketDesk 证书', href: certPath });
  if (avail.secureURL) links.push({ label: '② 在安全地址打开', href: avail.secureURL, newTab: true });
  setWristLinks(links);
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
