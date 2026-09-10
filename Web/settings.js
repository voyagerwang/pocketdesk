/**
 * [INPUT]: 消费 index.html 的 #phone-settings 面板与 header 齿轮，以及迁来的 #sens / #scroll-speed / #ruler-mode。
 * [OUTPUT]: 提供唯一手机设置面板的开关、遮罩关闭、焦点恢复与偏好读写；翻腕组保存用户意愿与灵敏度档位，
 *           并提供带度数的练习读数（阈值 / 实时倾角 / 本次最大），让灵敏度选择可被真机标定。
 * [POS]: Web 首页的设置边界；不持有业务草稿，不向 Mac 发送点击、滚动或快捷键。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/* ---------- 节点 ---------- */

const settingsDialog = document.querySelector('#phone-settings');
const settingsOpenBtn = document.querySelector('#phone-settings-open');
const settingsCloseBtn = document.querySelector('#phone-settings-close');
const wristToggle = document.querySelector('#wrist-toggle');
const wristNote = document.querySelector('#wrist-note');

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

/* ---------- 翻腕授权 / 练习 / 灵敏度 ---------- */

const wristAuthorize = document.querySelector('#wrist-authorize');
const wristPractice = document.querySelector('#wrist-practice');
const wristSensitivity = document.querySelector('#wrist-sensitivity');
const wristMeterFill = document.querySelector('#wrist-meter-fill');
const wristMeterMark = document.querySelector('#wrist-meter-mark');
const wristAngle = document.querySelector('#wrist-angle');
const wristMeta = document.querySelector('#wrist-meta');
const wristStatus = document.querySelector('#wrist-status');

// 仪表量程 0–45°：覆盖三档阈值（15/22/30）并留出“翻过头”的余量。
const WRIST_SCALE_DEG = 45;
const SENS_LABEL = { low: '低', medium: '中', high: '高' };
const MOTION_EVENT_LABEL = {
  accel: '晃动过大', gamma: '左右扭转', alpha: '屏幕转动',
  'hold-too-long': '倾斜过久', short: '抬起太短', gap: '信号中断',
};
let wristPeak = null;   // 本次练习达到过的最大前倾角，用来判断“够不够阈值”

const wristPct = deg => Math.max(0, Math.min(100, (deg / WRIST_SCALE_DEG) * 100));

function wristLiftDeg() {
  return window.pocketdeskMotion?.getParams?.().liftDeg ?? 22;
}

// 读数文案：始终带上阈值度数，练习后再补上本次最大角度——否则用户没法判断差多少。
function wristMetaText() {
  const liftDeg = wristLiftDeg();
  return wristPeak === null
    ? '阈值 ' + liftDeg + '° · 本次最大 —'
    : '阈值 ' + liftDeg + '° · 本次最大 ' + Math.round(wristPeak) + '°';
}

// 阈值度数写进下拉选项（随 PRESETS 自动同步），用户才知道低/中/高到底差几度。
function labelSensitivityOptions() {
  const presets = window.pocketdeskMotion?.PRESETS;
  if (!wristSensitivity || !presets) return;
  for (const option of wristSensitivity.options) {
    const preset = presets[option.value];
    if (preset) option.textContent = SENS_LABEL[option.value] + ' ' + preset.liftDeg + '°';
  }
}

// 刻度线上的阈值标记 + 读数文案；不练习时也显示，用户才有对标基准。
function updateWristThresholdUI() {
  if (wristMeterMark) wristMeterMark.style.left = wristPct(wristLiftDeg()).toFixed(1) + '%';
  if (wristMeta && !window.pocketdeskMotion?.isPracticing?.()) wristMeta.textContent = wristMetaText();
}

// iOS 13+ 需要一次用户点按触发权限请求；安卓等安全上下文即视为已授权。
function updateWristUI() {
  const avail = window.pocketdeskMotion?.available?.() || { ok: false };
  const needsAuth = Boolean(avail.needsPermission) && !avail.ok;
  if (wristAuthorize) wristAuthorize.hidden = !needsAuth;
  // 开关真身必须与运行态一致：偏好存储只在门禁通过时写 true，这里据此回填。
  const wantOn = readMotionPref().enabled === true && avail.ok === true;
  if (wristToggle && wristToggle.checked !== wantOn) wristToggle.checked = wantOn;
  labelSensitivityOptions();
  updateWristThresholdUI();
  if (wristStatus && !window.pocketdeskMotion?.isPracticing?.()) {
    if (window.pocketdeskMotion?.isActive?.()) wristStatus.textContent = '监听中：说完话轻翻手腕即可发送。';
    else if (avail.ok) wristStatus.textContent = '已就绪，开启上方开关即可使用。';
    else if (avail.reason) wristStatus.textContent = avail.reason;
  }
}

if (wristAuthorize) {
  wristAuthorize.addEventListener('click', async () => {
    const result = await window.pocketdeskMotion.requestPermission();
    updateWristUI();
    if (result.ok) setWristNote('已授权，现在可开启翻腕发送。');
    else setWristNote(result.reason, true);
  });
}

if (wristPractice) {
  wristPractice.addEventListener('click', () => {
    const motion = window.pocketdeskMotion;

    // 停止练习：把本次结果说出来，并保留最大角度供对照。
    if (motion?.isPracticing?.()) {
      motion.stopPractice();
      wristPractice.setAttribute('aria-pressed', 'false');
      wristPractice.textContent = '练习（不发消息）';
      if (wristMeterFill) {
        wristMeterFill.style.width = '0%';
        wristMeterFill.classList.remove('is-lift');
      }
      if (wristAngle) {
        wristAngle.textContent = '0°';
        wristAngle.classList.remove('is-lift');
      }
      if (wristStatus) {
        const liftDeg = wristLiftDeg();
        if (wristPeak === null) wristStatus.textContent = '没读到角度：确认用 HTTPS 打开并已授权传感器。';
        else if (wristPeak >= liftDeg) wristStatus.textContent = '本次最大 ' + Math.round(wristPeak) + '°，已达 ' + liftDeg + '° 阈值，这一档可用。';
        else wristStatus.textContent = '本次最大 ' + Math.round(wristPeak) + '°，差 ' + Math.round(liftDeg - wristPeak) + '° 才到阈值：翻大一点，或把灵敏度调高。';
      }
      updateWristThresholdUI();
      return;
    }

    // 传感器不可用时说清原因，不让用户对着一个永远不动的读数猜。
    const avail = motion?.available?.() || { ok: false };
    if (!avail.ok) {
      setWristNote(avail.reason || '运动传感器不可用，无法练习。', true);
      return;
    }

    wristPeak = null;
    motion.startPractice(({ sample, result, state }) => {
      const tilt = state.baseline == null ? 0 : sample.beta - state.baseline;
      if (state.baseline != null && (wristPeak === null || tilt > wristPeak)) wristPeak = tilt;
      if (wristMeterFill) {
        wristMeterFill.style.width = wristPct(tilt).toFixed(0) + '%';
        wristMeterFill.classList.toggle('is-lift', state.phase === 'lift');
      }
      if (wristAngle) {
        wristAngle.textContent = Math.round(tilt) + '°';
        wristAngle.classList.toggle('is-lift', state.phase === 'lift');
      }
      if (wristMeta) wristMeta.textContent = wristMetaText();
      if (wristStatus) {
        const last = result.events.length ? result.events[result.events.length - 1] : null;
        if (last && last.type === 'fire') {
          wristStatus.textContent = '已触发发送：' + wristLiftDeg() + '° 阈值，本次最大 ' + Math.round(wristPeak) + '°。';
        } else if (last && (last.type === 'reject' || last.type === 'reset')) {
          wristStatus.textContent = '未发送：' + (MOTION_EVENT_LABEL[last.reason] || last.reason);
        } else if (state.phase === 'lift') {
          wristStatus.textContent = '保持住…';
        } else {
          wristStatus.textContent = '等待抬起（需超过 ' + wristLiftDeg() + '°）';
        }
      }
    });
    wristPractice.setAttribute('aria-pressed', 'true');
    wristPractice.textContent = '停止练习';
    if (wristStatus) wristStatus.textContent = '保持自然握姿，向前轻翻手腕试一次。';
    updateWristThresholdUI();
  });
}

if (wristSensitivity) {
  wristSensitivity.addEventListener('change', () => {
    window.pocketdeskMotion?.setPreset(wristSensitivity.value);
    writeMotionPref({ sens: wristSensitivity.value });   // 档位持久化，重开仍是标定好的那一档
    wristPeak = null;
    updateWristThresholdUI();
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
