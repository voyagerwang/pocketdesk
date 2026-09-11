/**
 * [INPUT]: 消费 index.html 的 #phone-settings 面板与 header 齿轮，以及迁来的 #sens / #scroll-speed / #ruler-mode。
 * [OUTPUT]: 提供唯一手机设置面板的开关、遮罩关闭、焦点恢复与偏好读写；翻腕组保存用户意愿与灵敏度档位，
 *           按 motion-send 的四级状态（unsupported / needs-permission / unverified / running）渲染：
 *           环境不过关整组隐藏，其余状态就地写回 #wrist-note，失败只给一句「暂时无法使用翻腕发送，
 *           请使用发送按钮」。
 * [POS]: Web 首页的设置边界；不持有业务草稿，不向 Mac 发送点击、滚动或快捷键。
 *        不为翻腕提供任何证书/端口/系统配置引导——那是免证书方案明令撤除的门槛。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/* ---------- 节点 ---------- */

const settingsDialog = document.querySelector('#phone-settings');
const settingsOpenBtn = document.querySelector('#phone-settings-open');
const settingsCloseBtn = document.querySelector('#phone-settings-close');
const wristGroup = document.querySelector('#wrist-group');
const wristToggle = document.querySelector('#wrist-toggle');
const wristNote = document.querySelector('#wrist-note');
const wristSensitivity = document.querySelector('#wrist-sensitivity');

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

/* ---------- 翻腕文案：三句人话，不出现端口、证书或系统设置路径 ---------- */

const WRIST_IDLE_NOTE = '手机向前轻翻，停住片刻后发送。';
const WRIST_ACTIVE_NOTE = '监听中：说完话轻翻手腕即可发送。';
const WRIST_CHECKING_NOTE = '正在确认这台手机能不能用翻腕…';
// 失败只有这一句：不循环弹权限、不要求系统配置、不提怎么修。
const WRIST_FAIL_NOTE = '暂时无法使用翻腕发送，请使用发送按钮';

function setWristNote(text, warn = false) {
  wristNote.textContent = text;
  wristNote.className = warn ? 'sheet-hint is-warn' : 'sheet-hint';
}

// 能力判定交给 motion-send.js（注册 pocketdeskMotion.status()）。没有该模块时一律按不可用处理：
// 不给出一个"开了也没用"的假开关。
function wristStatus() {
  return window.pocketdeskMotion?.status?.() ?? 'unsupported';
}

// 整组可见性只有环境层说了算：非安全上下文或浏览器没给传感器接口 → 整组隐藏。
// 曾经这里挂着一套四步证书向导（下载 CA → 系统里安装 → 开启信任 → 跳 HTTPS 地址），
// 那是要求用户为一个手势功能承担安装与信任成本，已按免证书方案撤除。
function updateWristUI() {
  const state = wristStatus();
  if (wristGroup) wristGroup.hidden = state === 'unsupported';
  if (state === 'unsupported') return;   // 隐藏时不写提示，避免留下孤儿文案
  const running = state === 'running';
  if (wristToggle && wristToggle.checked !== running) wristToggle.checked = running;
  labelSensitivityOptions();
  if (running) setWristNote(WRIST_ACTIVE_NOTE);
  else if (state === 'verifying') setWristNote(WRIST_CHECKING_NOTE);
  else if (readMotionPref().enabled === true) setWristNote(WRIST_FAIL_NOTE, true);
  else setWristNote(WRIST_IDLE_NOTE);
}

// 后台恢复/失去控制权会让运行态在面板打开时发生变化，跟着刷新一次，别让开关停在旧状态。
window.addEventListener('pocketdesk-motion-status', () => {
  if (settingsDialog.open) updateWristUI();
});

wristToggle.addEventListener('change', async () => {
  if (!wristToggle.checked) {
    writeMotionPref({ enabled: false });
    window.pocketdeskMotion?.disable();
    setWristNote(WRIST_IDLE_NOTE);
    return;
  }
  // 授权与出数验证必须发生在这一次点按里：iOS 的权限请求要用户激活，且不能弹第二次。
  wristToggle.disabled = true;
  setWristNote(WRIST_CHECKING_NOTE);
  let result = { ok: false, code: 'unavailable' };
  try {
    result = (await window.pocketdeskMotion?.enable?.()) ?? result;
  } catch (error) {
    result = { ok: false, code: 'unavailable' };
  }
  wristToggle.disabled = false;
  if (result?.ok) {
    writeMotionPref({ enabled: true });
    setWristNote(WRIST_ACTIVE_NOTE);
    return;
  }
  // 门禁不通过：立刻回到关闭，不留下"看起来开了"的开关。
  wristToggle.checked = false;
  writeMotionPref({ enabled: false });
  setWristNote(WRIST_FAIL_NOTE, true);
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
// 供 motion-send 判断“用户是否开启了翻腕发送”（只是意愿，不等于当前能跑）。
window.pocketdeskMotionEnabled = () => readMotionPref().enabled === true;

/* ---------- 翻腕灵敏度 ---------- */

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
