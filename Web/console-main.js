/**
 * [INPUT]: 依赖 console.html 的 DOM 与内联 applyTheme，消费 console-connection.js 的连接渲染入口及状态、设备、接收者、目标应用、快捷键 HTTP 接口。
 * [OUTPUT]: 控制台设备与接收者管理、目标应用和快捷键编辑、最近动作轮询；保留 refresh/post 与页面状态的经典脚本全局契约。
 * [POS]: Web 的电脑控制台主业务入口；主题和连接模块先加载，模型与本机管理事务分别交给后续 console-agent.js、console-actions.js，不包 IIFE 以保持共享作用域。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

const $ = id => document.getElementById(id);
let state = { targets: [], recipients: [], platform: 'macOS', status: null };
let configRevision = 0, savingTargets = false, savingShortcuts = false;
// 内置接收者：小精灵不是应用，不进 /api/targets 的普通应用列表，只参与接收者排序（方案 §3）。
const SPRITE_ID = '__sprite__';
let iconTargetId = null;
let lastActivityLog = [];

function esc(text) { const div = document.createElement('div'); div.textContent = text ?? ''; return div.innerHTML; }

async function post(url, body) {
  const response = await fetch(url, {method: 'POST', headers: {'Content-Type': 'application/json'},
                                      body: body ? JSON.stringify(body) : '{}'});
  if (!response.ok) { const e = await response.json().catch(() => ({})); throw new Error(e.error || '请求失败'); }
  return response.json();
}

const deviceMenu = $('device-menu');
document.addEventListener('click', event => { if (!deviceMenu.contains(event.target)) { deviceMenu.open = false; deviceMenu.querySelectorAll('[data-editing]').forEach(form => { delete form.dataset.editing; form.hidden = true; }); } });
document.addEventListener('keydown', event => { if (event.key === 'Escape' && deviceMenu.open) { deviceMenu.open = false; deviceMenu.querySelectorAll('[data-editing]').forEach(form => { delete form.dataset.editing; form.hidden = true; }); $('device-count').focus(); } });
function deviceRow(device, historical = false) {
  const row = document.createElement('div'); row.className = 'device-row';
  const title = document.createElement('strong');
  title.textContent = device.name || device.model || device.platform || '未知设备';
  row.append(title);
  const rename = document.createElement('button'); rename.type = 'button'; rename.className = 'btn'; rename.textContent = '改名';
  rename.style.marginLeft = '.5rem'; rename.setAttribute('aria-label', `修改 ${title.textContent} 的名称`);
  const form = document.createElement('form'); form.hidden = true;
  const input = document.createElement('input'); input.maxLength = 60; input.value = device.name || ''; input.setAttribute('aria-label', '设备显示名称'); input.placeholder = '留空恢复自动名称';
  const save = document.createElement('button'); save.type = 'submit'; save.className = 'btn'; save.textContent = '保存';
  const cancel = document.createElement('button'); cancel.type = 'button'; cancel.className = 'btn'; cancel.textContent = '取消';
  const error = document.createElement('p'); error.setAttribute('role', 'status');
  form.append(input, save, cancel, error); row.append(rename, form);
  rename.onclick = () => { form.hidden = false; form.dataset.editing = 'true'; input.focus(); input.select(); };
  cancel.onclick = () => { form.hidden = true; delete form.dataset.editing; rename.focus(); };
  form.onsubmit = async event => {
    event.preventDefault(); save.disabled = true;
    try {
      await post('/api/devices/name', { id: device.id, name: input.value.trim() });
      delete form.dataset.editing; await refreshDevices();
    } catch (e) { error.textContent = e.message; }
    finally { save.disabled = false; }
  };
  const subtitle = document.createElement('p');
  subtitle.textContent = [...new Set([device.model, device.platform, device.browser].filter(Boolean))].join(' · ') + ' · ' + device.id.slice(0, 6);
  row.append(subtitle);
  const status = document.createElement('p');
  const time = value => new Date(value * 1000).toLocaleString();
  status.textContent = historical ? `${time(device.started)} → ${device.ended ? time(device.ended) : '仍在线'}` : `${device.controlling ? '控制中' : '页面在线 · 未控制'} · ${time(device.started)} 连接`;
  row.append(status); return row;
}
async function refreshDevices() {
  try {
    const response = await fetch('/api/devices', { cache: 'no-store' });
    if (!response.ok) throw new Error('无法读取');
    const { devices } = await response.json();
    const online = devices.filter(d => d.online);
    const count = $('device-count');
    count.textContent = online.length ? `${online.length} 台设备已连接` : '暂无设备连接';
    count.className = online.length ? 'pill ready' : 'pill';
    count.title = online.map(d => `${d.name} · ${d.controlling ? '控制中' : '页面在线'}`).join('\n') || '点击查看连接记录';
    if (deviceMenu.querySelector('[data-editing]')) return;
    $('device-current').replaceChildren(...online.map(d => deviceRow(d)));
    if (!online.length) $('device-current').textContent = '暂无设备连接';
    $('device-history').replaceChildren(...devices.map(d => deviceRow(d, true)));
    if (!devices.length) $('device-history').textContent = '暂无连接记录';
  } catch {
    $('device-count').textContent = '设备状态不可用';
    $('device-count').className = 'pill'; $('device-count').title = '';
    $('device-current').textContent = '无法读取，请在电脑本机打开控制台。';
    $('device-history').replaceChildren();
  }
}

async function refresh() {
  const revision = configRevision;
  refreshDevices();
  try {
    const response = await fetch('/api/status', { cache: 'no-store' });
    if (!response.ok) throw new Error('无法读取连接状态');
    const status = await response.json();
    window.PocketDeskConsoleConnection.render(status);
    state.status = status;
    $('conn').textContent = '已就绪'; $('conn').classList.add('ready');
    // 主题以服务端为准：其他途径改动后 3 秒内自动校正（开关写入请求进行中则跳过避免回跳）。
    if (!themeSwitch.dataset.busy && status.theme) applyTheme(status.theme);
    const granted = status.accessibility;
    const authState = $('authState');
    authState.textContent = granted ? '已授权' : '未授权';
    authState.className = granted ? 'ok' : 'bad';
    $('openSettings').disabled = granted;
    if (status.platform !== 'macOS') { $('authHint').textContent = '在系统设置中允许 VoiceDeck 获得输入控制权限。'; }
    const configFresh = revision === configRevision && !savingTargets && !savingShortcuts;
    if (configFresh) state.targets = status.targets;
    // 接收者顺序每次刷新都拉：新增/删除应用后服务端会归一化，控制台必须跟着走。
    await refreshRecipients();
    if (!$('current').children.length) renderTargets();
    const incoming = status.shortcuts || [];
    if (revision === configRevision && !savingTargets && !savingShortcuts && JSON.stringify(incoming) !== JSON.stringify(shortcuts)) { shortcuts = incoming; renderShortcuts(); }
    if (JSON.stringify(status.actions || []) !== JSON.stringify(presetActions)) {
      presetActions = status.actions || [];
      renderPresetActions();
    }
    // 动作日志同样做变化检测：3 秒一轮询，无脑重绘会打断正在阅读/选中的用户。
    const incomingLog = status.log || [];
    if (JSON.stringify(incomingLog) !== JSON.stringify(lastActivityLog)) {
      lastActivityLog = incomingLog;
      renderActivity(incomingLog);
    }
  } catch {
    window.PocketDeskConsoleConnection.unavailable();
    $('conn').textContent = '服务未响应'; $('conn').classList.remove('ready');
  }
}

let dragFrom = null;   // { key, index }：key 区分不同列表，免得跨列表误判落点

function clearDropHints() {
  document.querySelectorAll('.drop-before,.drop-after').forEach(el => el.classList.remove('drop-before', 'drop-after'));
}

// 把 from 处的元素移到"第 to 位之前"（to 取 0..count）。取出后 to 之后的下标要减一。
// 原地放下（to==from 或 to==from+1）返回 false，调用方据此跳过一次无谓的保存。
function reorder(list, from, to) {
  if (from === to || from === to - 1) return false;
  const [item] = list.splice(from, 1);
  list.splice(to > from ? to - 1 : to, 0, item);
  return true;
}

// 给一行挂拖拽排序：key 标识所属列表；zone 是投放区（应用行传外层 wrap，好让展开的设置面板
// 也算投放区）；commit(from, to) 负责按新顺序落盘。
function attachDragSort(row, { key, index, zone, commit }) {
  const dropZone = zone || row;
  row.draggable = true;
  row.addEventListener('dragstart', event => {
    dragFrom = { key, index };
    row.classList.add('dragging');
    event.dataTransfer.effectAllowed = 'move';
    event.dataTransfer.setData('text/plain', String(index));   // Firefox 无数据不触发 drop
  });
  row.addEventListener('dragend', () => {
    dragFrom = null;
    row.classList.remove('dragging');
    clearDropHints();
  });
  dropZone.addEventListener('dragover', event => {
    if (!dragFrom || dragFrom.key !== key) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'move';
    clearDropHints();
    // 上下半只按 row 的高度算：用 zone 的话，展开的设置面板会把中心点带偏。
    const rect = row.getBoundingClientRect();
    dropZone.classList.add(event.clientY < rect.top + rect.height / 2 ? 'drop-before' : 'drop-after');
  });
  dropZone.addEventListener('drop', async event => {
    if (!dragFrom || dragFrom.key !== key) return;
    event.preventDefault();
    clearDropHints();
    const rect = row.getBoundingClientRect();
    const to = event.clientY < rect.top + rect.height / 2 ? index : index + 1;
    const from = dragFrom.index;
    dragFrom = null;
    await commit(from, to);
  });
}

// 接收者行 = 小精灵 + 已配置应用，顺序以服务端保存的 recipients 为准。
// 顺序里没有的项按原相对顺序追加；小精灵缺失时补到首位（首次迁移，只发生一次）。
function recipientRows() {
  const byId = new Map(state.targets.map(target => [target.id, target]));
  const rows = [];
  const seen = new Set();
  for (const id of state.recipients) {
    if (id === SPRITE_ID) {
      if (!seen.has(id)) { rows.push({ id, target: null }); seen.add(id); }
      continue;
    }
    const target = byId.get(id);
    if (target && !seen.has(id)) { rows.push({ id, target }); seen.add(id); }
  }
  state.targets.forEach(target => { if (!seen.has(target.id)) { rows.push({ id: target.id, target }); seen.add(target.id); } });
  if (!seen.has(SPRITE_ID)) rows.unshift({ id: SPRITE_ID, target: null });
  return rows;
}

function buildSpriteRow(index) {
  const wrap = document.createElement('div'); wrap.className = 'target-wrap';
  const row = document.createElement('div'); row.className = 'target-row';
  row.innerHTML = `<span class="drag-handle" aria-hidden="true">⠿</span>
    <span class="sprite-badge" aria-hidden="true"><svg viewBox="-15 -15 259 259" width="100%" height="100%" role="img" aria-label="AI 表情小球" style="display:block;overflow:visible"><defs><radialGradient id="eb0g" cx="38%" cy="32%" r="75%"><stop offset="0%" stop-color="#f6f3ef"></stop><stop offset="62%" stop-color="#F3F0EA"></stop><stop offset="100%" stop-color="#d6d3ce"></stop></radialGradient></defs><g pointer-events="none"></g><g transform="translate(114.27 114.27) rotate(0) scale(1) translate(-114.27 -114.27)"><path d="M228.54 114.27L228.29 121.74L227.55 129.18L226.32 136.56L224.62 143.84L222.45 150.99L219.82 157.99L216.73 164.80L213.20 171.39L209.25 177.73L204.89 183.81L200.15 189.59L195.04 195.04L189.59 200.15L183.81 204.89L177.73 209.24L171.38 213.19L164.78 216.70L157.97 219.78L150.98 222.40L143.82 224.56L136.54 226.25L129.17 227.46L121.74 228.19L114.27 228.44L106.80 228.20L99.37 227.48L91.99 226.27L84.71 224.58L77.56 222.42L70.56 219.79L63.75 216.71L57.16 213.18L50.81 209.24L44.74 204.89L38.96 200.15L33.50 195.04L28.39 189.59L23.65 183.81L19.29 177.73L15.35 171.38L11.82 164.79L8.73 157.99L6.09 150.99L3.92 143.84L2.21 136.56L0.99 129.18L0.25 121.74L0.00 114.27L0.25 106.80L0.98 99.36L2.20 91.98L3.90 84.70L6.06 77.54L8.69 70.54L11.78 63.73L15.30 57.13L19.25 50.78L23.61 44.70L28.35 38.92L33.46 33.46L38.91 28.34L44.69 23.59L50.77 19.24L57.12 15.29L63.72 11.77L70.54 8.69L77.54 6.07L84.70 3.90L91.98 2.21L99.36 1.00L106.80 0.26L114.27 0.01L121.74 0.25L129.19 0.98L136.57 2.19L143.85 3.88L151.01 6.04L158.01 8.68L164.82 11.76L171.42 15.29L177.77 19.24L183.84 23.60L189.62 28.35L195.08 33.46L200.20 38.92L204.94 44.70L209.29 50.78L213.23 57.13L216.76 63.73L219.84 70.54L222.48 77.54L224.65 84.70L226.34 91.98L227.56 99.36L228.29 106.80Z" fill="url(#eb0g)" stroke="none" stroke-width="2" style="stroke:"></path><path fill="#1A1A1A" stroke="none" stroke-width="1.6" d="M130.36 45.98L132.71 46.19L134.98 46.81L137.11 47.83L138.97 49.28L140.47 51.09L141.68 53.12L142.73 55.23L143.76 57.36L144.78 59.49L145.79 61.62L146.79 63.76L147.76 65.91L148.71 68.07L149.63 70.25L150.52 72.43L151.37 74.63L151.99 76.91L152.10 79.26L151.64 81.57L150.59 83.68L149.04 85.45L147.10 86.78L144.90 87.62L142.56 87.93L140.22 87.71L137.98 86.99L135.93 85.82L134.17 84.24L132.78 82.34L131.69 80.25L130.77 78.08L129.87 75.89L128.94 73.72L128.00 71.56L127.03 69.40L126.05 67.26L125.05 65.12L124.03 62.99L122.93 60.90L121.87 58.79L121.03 56.59L120.72 54.26L121.10 51.93L122.15 49.83L123.75 48.10L125.76 46.89L128.01 46.19Z" transform="translate(82.64 66.73) scale(0.95 0.99) translate(-136.62 -66.73)" style="display:;stroke:"></path><path fill="#1A1A1A" stroke="none" stroke-width="1.6" d="M176.61 37.08L178.72 37.59L180.70 38.48L182.52 39.65L184.20 41.03L185.71 42.59L187.03 44.31L188.20 46.14L189.26 48.03L190.27 49.96L191.26 51.89L192.23 53.84L193.16 55.80L194.05 57.78L194.92 59.77L195.74 61.78L196.53 63.80L197.27 65.84L197.97 67.90L198.47 70.01L198.63 72.18L198.40 74.33L197.58 76.33L195.95 77.72L193.83 78.08L191.71 77.65L189.76 76.69L188.03 75.38L186.53 73.82L185.28 72.05L184.25 70.13L183.40 68.14L182.63 66.11L181.87 64.07L181.07 62.05L180.25 60.04L179.39 58.05L178.49 56.07L177.57 54.10L176.61 52.15L175.62 50.22L174.59 48.31L173.53 46.41L172.54 44.48L171.86 42.42L171.76 40.26L172.62 38.30L174.45 37.19Z" transform="translate(130.36 57.21) scale(0.99 0.98) translate(-185.69 -57.21)" style="display:;stroke:"></path></g><g pointer-events="none"></g></svg></span>
    <b style="flex:1;min-width:0">小精灵</b>
    <span class="pill" style="padding:2px 8px;font-size:11px">AI 助手</span>
    <span style="font-size:11px;color:var(--muted)">手机端入口，可拖动排序</span>`;
  attachDragSort(row, {
    key: 'targets', index, zone: wrap,
    commit: async (from, to) => { if (reorder(state.recipients, from, to)) await saveRecipients(state.recipients); },
  });
  wrap.append(row);
  return wrap;
}

/**
 * 保存接收者顺序。小精灵与普通应用共用一套拖拽，但小精灵只落在 recipients 里；
 * 应用顺序随后按同一份顺序重排，两条持久化通道保持一致，避免手机与控制台各显示一套。
 */
async function saveRecipients(order) {
  state.recipients = order;
  const rank = new Map(order.map((id, index) => [id, index]));
  state.targets.sort((a, b) => (rank.get(a.id) ?? 9999) - (rank.get(b.id) ?? 9999));
  try {
    await post('/api/recipients', { order });
  } catch (error) {
    alert(error.message);
    return;
  }
  await save();
}

/// 移除应用：应用列表与接收者顺序都要清掉，否则手机端会留着一条已经不存在的应用。
async function removeRecipient(id) {
  state.targets = state.targets.filter(target => target.id !== id);
  state.recipients = state.recipients.filter(item => item !== id);
  await save();
  await saveRecipients(state.recipients);
}

async function refreshRecipients() {
  try {
    const result = await fetch('/api/recipients', { cache: 'no-store' }).then(response => response.json());
    state.recipients = Array.isArray(result.order) ? result.order : [];
  } catch {
    // 读不到就沿用现有顺序：控制台只是排序入口，不该因为一次失败把列表清空。
  }
}

function renderTargets() {
  const box = $('current'); box.innerHTML = '';
  recipientRows().forEach((item, index) => {
    if (!item.target) { box.append(buildSpriteRow(index)); return; }
    const target = item.target;
    const wrap = document.createElement('div'); wrap.className = 'target-wrap';
    const hasCustom = Array.isArray(target.shortcuts) && target.shortcuts.length > 0;
    const row = document.createElement('div'); row.className = 'target-row';
    row.innerHTML = `<span class="drag-handle" aria-hidden="true">⠿</span><img src="/api/icon?id=${encodeURIComponent(target.id)}&t=${Date.now()}" alt="">
      <b style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(target.name)}</b>${target.available === false ? '<span class="missing">未安装</span>' : ''}
      ${hasCustom ? '<span class="pill" style="padding:2px 8px;font-size:11px">专属键</span>' : ''}
      <button class="btn ghost" data-act="settings">${target.openPanel === 'pad' ? '设置·触控板' : '设置'}</button>
      <button class="btn ghost icon-btn danger" data-act="remove" title="移除" aria-label="移除">${TRASH_SVG}<span class="confirm-text">确认移除</span></button>`;
    row.addEventListener('click', async event => {
      const button = event.target.closest('button[data-act]');
      const act = button?.dataset.act; if (!act) return;
      if (act === 'remove') { if (!armConfirm(button)) return; await removeRecipient(target.id); }
      if (act === 'settings') renderTargetSettings(target.id);
    });
    // 拖拽改的是接收者顺序（含小精灵），不再直接改应用数组——小精灵不在里面。
    attachDragSort(row, {
      key: 'targets', index, zone: wrap,   // zone=wrap：展开的设置面板也算投放区
      commit: async (from, to) => { if (reorder(state.recipients, from, to)) await saveRecipients(state.recipients); },
    });
    wrap.append(row);
    // 设置面板（当前展开的那个目标）：默认打开面板 + 专属快捷键组。
    if (settingsOpenId === target.id) wrap.append(buildTargetSettings(target));
    box.append(wrap);
  });
}

let settingsOpenId = null; // 当前展开设置面板的目标 id；null = 全收起

function renderTargetSettings(id) {
  settingsOpenId = settingsOpenId === id ? null : id;
  renderTargets();
}

// 展开区：默认面板分段开关 + 叠加开关 + 专属快捷键录制（沿用全局录制器的 recordCtx 作用域模型）。
// macOS 标准组合的内置快捷键库：下拉框快速添加，省去逐个录制。
const BUILTIN_PRESETS = [
  { label: '刷新',     hotkey: 'Cmd+R' },
  { label: '粘贴',     hotkey: 'Cmd+V' },
  { label: '复制',     hotkey: 'Cmd+C' },
  { label: '剪切',     hotkey: 'Cmd+X' },
  { label: '撤销',     hotkey: 'Cmd+Z' },
  { label: '重做',     hotkey: 'Cmd+Shift+Z' },
  { label: '全选',     hotkey: 'Cmd+A' },
  { label: '保存',     hotkey: 'Cmd+S' },
  { label: '回车',     hotkey: 'Return' },
  { label: '删除',     hotkey: 'Delete' },
  { label: '关闭窗口', hotkey: 'Cmd+W' },
  { label: '退出应用', hotkey: 'Cmd+Q' },
  { label: '新建',     hotkey: 'Cmd+N' },
  { label: '查找',     hotkey: 'Cmd+F' },
  { label: '锁屏',     hotkey: 'Ctrl+Cmd+Q' },
];

function buildTargetSettings(target) {
  const panel = document.createElement('div'); panel.className = 'target-settings';
  const shortcuts = Array.isArray(target.shortcuts) ? target.shortcuts : [];
  const panelChoice = target.openPanel === 'pad' ? 'pad' : 'input';
  // showGlobal：nil/true = 叠加（默认开），false = 只显应用组。
  const showGlobal = target.showGlobal !== false;
  const presetOptions = BUILTIN_PRESETS
    .filter(p => !shortcuts.some(s => s.hotkey === p.hotkey))
    .map(p => `<option value="${p.hotkey}">${p.label} ${hotkeyDisplay(p.hotkey)}</option>`).join('');
  panel.innerHTML = `
    <div class="row" style="margin-bottom:10px">
      <span class="hint" style="flex:1">图标默认取自应用本身，可上传图片覆盖</span>
      <button class="btn" data-act="icon" style="flex:0 0 auto">换图标</button>
    </div>
    <div class="row" style="margin-bottom:10px">
      <span class="hint" style="flex:0 0 auto">手机激活此应用时默认打开</span>
      <div class="theme-switch" data-panel-switch>
        <button type="button" data-panel="input" class="${panelChoice === 'input' ? 'on' : ''}">输入框</button>
        <button type="button" data-panel="pad" class="${panelChoice === 'pad' ? 'on' : ''}">触控板</button>
      </div>
    </div>
    <div class="row" style="margin-bottom:8px">
      <span class="hint" style="flex:1">专属快捷键：前排显示。${shortcuts.length ? '' : '留空 = 只用全局组。'}</span>
      <label class="row" style="gap:6px;flex:0 0 auto">
        <input type="checkbox" data-act="show-global" ${showGlobal ? 'checked' : ''}>
        <span class="hint">叠加全局组</span>
      </label>
      <button class="btn" data-act="record-sc" style="flex:0 0 auto">录制</button>
    </div>
    <div class="row" style="margin-bottom:8px">
      <select class="btn" data-act="add-preset" style="flex:1">
        <option value="">添加常用快捷键…</option>
        ${presetOptions || '<option value="">（常用键已全部添加）</option>'}
      </select>
    </div>
    <div class="sc-mini" data-sc-list></div>`;
  panel.querySelector('[data-panel-switch]').addEventListener('click', async event => {
    const button = event.target.closest('button[data-panel]');
    if (!button || button.classList.contains('on')) return;
    const t = state.targets.find(item => item.id === target.id);
    if (!t) return;
    t.openPanel = button.dataset.panel === 'input' ? null : 'pad';
    await save();
  });
  panel.querySelector('[data-act="show-global"]').addEventListener('change', async event => {
    const t = state.targets.find(item => item.id === target.id);
    if (!t) return;
    t.showGlobal = event.target.checked ? null : false; // 默认叠加用 nil 表达，省字段
    await save();
  });
  panel.querySelector('[data-act="add-preset"]').addEventListener('change', async event => {
    const hotkey = event.target.value;
    if (!hotkey) return;
    const preset = BUILTIN_PRESETS.find(p => p.hotkey === hotkey);
    if (!preset) return;
    const t = state.targets.find(item => item.id === target.id);
    if (!t) return;
    t.shortcuts = [...(t.shortcuts || []), { id: '', label: preset.label, hotkey: preset.hotkey }];
    event.target.value = '';
    await save();
  });
  panel.querySelector('[data-act="record-sc"]').addEventListener('click', (event) => {
    startRecording({ scope: 'target', targetId: target.id }, `为「${target.name}」按快捷键…`, event.currentTarget);
  });
  // 文件选择是异步的：先把目标 id 记在 iconTargetId，#iconFile 的 change 里再取用。
  panel.querySelector('[data-act="icon"]').addEventListener('click', () => {
    iconTargetId = target.id;
    $('iconFile').click();
  });
  const list = panel.querySelector('[data-sc-list]');
  renderScopedShortcuts(list, shortcuts, 'target', target.id);
  return panel;
}

// 作用域快捷键子列表（应用专属组）：一行一键 + 删除。
function renderScopedShortcuts(box, list, scope, targetId) {
  box.innerHTML = '';
  if (!list.length) { box.hidden = false; return; }
  list.forEach((shortcut, index) => {
    const display = hotkeyDisplay(shortcut.hotkey);
    const label = shortcut.label === display ? '' : shortcut.label;
    const row = document.createElement('div'); row.className = 'target-row';
    row.innerHTML = `<span class="drag-handle" aria-hidden="true">⠿</span><b style="flex:0 0 auto;min-width:48px">${esc(label || display)}</b>
      ${label && display ? `<span class="keycap">${esc(display)}</span>` : ''}
      <button class="btn ghost icon-btn danger" data-act="remove-sc" style="margin-left:auto" title="移除" aria-label="移除">${TRASH_SVG}<span class="confirm-text">确认移除</span></button>`;
    row.querySelector('[data-act="remove-sc"]').addEventListener('click', async event => {
      if (savingTargets) return;
      const t = state.targets.find(item => item.id === targetId);
      if (!t) return;
      const previous = t.shortcuts;
      t.shortcuts = (t.shortcuts || []).filter(item => item.id !== shortcut.id);
      if (!t.shortcuts.length) t.shortcuts = null; // 清空即回退全局
      if (!await save()) { t.shortcuts = previous; renderTargets(); }
    });
    attachDragSort(row, {
      key: 'sc:' + targetId, index,   // 每个应用一组，key 里带 id 免得跨应用串台
      commit: async (from, to) => {
        const t = state.targets.find(item => item.id === targetId);
        if (!t || !Array.isArray(t.shortcuts)) return;
        if (reorder(t.shortcuts, from, to)) await save();
      },
    });
    box.append(row);
  });
}

// 垃圾桶图标（24×24 线条风，与手机页控件图标同族）。
const TRASH_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 7h16"/><path d="M9 7V5a1.5 1.5 0 0 1 1.5-1.5h3A1.5 1.5 0 0 1 15 5v2"/><path d="M6.5 7l.8 12a2 2 0 0 0 2 1.9h5.4a2 2 0 0 0 2-1.9l.8-12"/><path d="M10 11v6M14 11v6"/></svg>';

// 删除按钮二次确认：第一次点进入"确认移除"态，再点才真删；3.5 秒不动自动还原。
function armConfirm(button) {
  if (button.classList.contains('armed')) return true;
  document.querySelectorAll('.icon-btn.armed').forEach(other => other.classList.remove('armed'));
  button.classList.add('armed');
  setTimeout(() => button.classList.remove('armed'), 3500);
  return false;
}

async function save() {
  if (savingTargets) return false;
  savingTargets = true; configRevision++;
  $('current').inert = true;
  $('saveState').textContent = '保存中…';
  try {
    // 整表序列化：必须带上 shortcuts/openPanel/showGlobal，否则服务端收到的是无偏好旧形态、覆盖存储丢配置。
    await post('/api/targets', state.targets.map(t => {
      const out = { id: t.id, name: t.name, bundleID: t.bundleID ?? null, path: t.path ?? null };
      if (Array.isArray(t.shortcuts) && t.shortcuts.length) out.shortcuts = t.shortcuts;
      if (t.openPanel) out.openPanel = t.openPanel;
      if (t.showGlobal === false) out.showGlobal = false;
      return out;
    }));
    $('saveState').textContent = '已保存到本机';
    savingTargets = false;
    await refresh(); renderTargets();
    setTimeout(() => { $('saveState').textContent = ''; }, 2500);
    return true;
  } catch (error) { $('saveState').textContent = '保存失败：' + error.message; return false; }
  finally { savingTargets = false; configRevision++; $('current').inert = false; }
}

let searchTimer = 0;
$('search').addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(async () => {
    const query = $('search').value.trim();
    if (!query) { $('results').classList.remove('open'); $('results').innerHTML = ''; return; }
    const data = await fetch('/api/apps?q=' + encodeURIComponent(query)).then(r => r.json()).catch(() => ({apps: []}));
    const box = $('results'); box.innerHTML = ''; box.classList.add('open');
    (data.apps || []).forEach(app => {
      const row = document.createElement('div'); row.className = 'app-row';
      row.innerHTML = `<img src="/api/app-icon?path=${encodeURIComponent(app.path)}" alt="">
        <span class="meta"><b>${esc(app.name)}</b><small>${esc(app.path)}</small></span>`;
      // 已在列表里的应用不再常驻"添加"按钮：添加成功后按钮收起，避免重复添加同一路径。
      if (state.targets.some(t => t.path && t.path === app.path)) {
        row.insertAdjacentHTML('beforeend', '<span class="app-added idle">已添加</span>');
      } else {
        const button = document.createElement('button');
        button.className = 'btn';
        button.textContent = '添加';
        button.onclick = async () => {
          button.disabled = true; button.textContent = '添加中…';
          state.targets.push({id: '', name: app.name, bundleID: null, path: app.path, available: true});
          renderTargets();
          if (await save()) {
            // 只留一次性提示，2.5s 后淡出——成功之后不再需要常驻的添加入口。
            const tip = document.createElement('span');
            tip.className = 'app-added done';
            tip.textContent = '添加成功';
            button.replaceWith(tip);
            setTimeout(() => { tip.classList.add('fade'); setTimeout(() => tip.remove(), 400); }, 2500);
          } else {
            state.targets.pop(); renderTargets();   // 保存失败：撤掉刚加的这条，按钮恢复
            button.disabled = false; button.textContent = '添加';
          }
        };
        row.append(button);
      }
      box.append(row);
    });
    if (!(data.apps || []).length) box.innerHTML = '<div class="app-row"><span class="meta">没有匹配的应用</span></div>';
  }, 250);
});

$('iconFile').addEventListener('change', () => {
  const file = $('iconFile').files[0]; if (!file || !iconTargetId) return;
  const reader = new FileReader();
  reader.onload = async () => {
    const data = String(reader.result).split(',')[1];
    try { await post('/api/target-icon', {id: iconTargetId, data}); renderTargets(); } catch (error) { alert(error.message); }
  };
  reader.readAsDataURL(file);
  $('iconFile').value = '';
});

$('openSettings').onclick = () => post('/api/open-accessibility');

/* ---------- 快捷键设置：键盘录制语义串（"Cmd+Shift+Z"/"Return"），保存到 /api/shortcuts ---------- */

const MOD_NAMES = { command: '⌘', shift: '⇧', option: '⌥', control: '⌃' };
const COMMON_SHORTCUT_LABELS = { '⌘C': '复制', '⌘V': '粘贴', '⌘X': '剪切', '⌘Z': '撤销',
  '⌘⇧Z': '重做', '⌘A': '全选', '⌘S': '保存', '⌘F': '查找', '⌘N': '新建',
  '⌘O': '打开', '⌘P': '打印', '⌘W': '关闭', '⌘Q': '退出', '⌘T': '新建标签页' };
let shortcuts = [];
// 服务端下发的预设动作目录（/api/status.actions）：录不到的系统/应用操作，点选即添加。
let presetActions = [];
let recording = false;
// 作用域录制模型：recordCtx 说清这次录给谁。scope=global → 全局快捷键；scope=target → 应用专属组。
let recordCtx = null; // { scope: 'global'|'target', targetId?: string, index?: number }
let recordButton = null; // 触发录制的按钮，就地显示"按下按键…"反馈

// 事件 → 语义串主键 token（与 Swift ShortcutKeys.keyMap 的键名对齐）。
// event.code 是物理键位的唯一可信来源；event.key 在输入法/修饰键下会被改写（⌘Z 曾被污染成 9），
// 只用于功能键名（F1-F12 的 key 与 code 一致，不受 IME 影响）。
const KEY_TOKENS = { ArrowUp: 'Up', ArrowDown: 'Down', ArrowLeft: 'Left', ArrowRight: 'Right',
  Enter: 'Return', NumpadEnter: 'Return', Backspace: 'Delete', Escape: 'Escape',
  Space: 'Space', Tab: 'Tab' };

function hotkeyToken(event) {
  const code = event.code || '';
  const key = event.key || '';
  const named = KEY_TOKENS[code];                       // 命名键：只认物理 code
  const letter = /^Key([A-Z])$/.exec(code)?.[1] || null; // 字母：只认物理 code，不回退 key
  const digit = /^Digit([0-9])$/.exec(code)?.[1] || null; // 数字：只认物理 code
  const fn = /^F([1-9]|1[0-2])$/.exec(key)?.[0];        // 功能键：key 与 code 同形，取 key 即可
  return named || letter || digit || fn || null;
}

// 语义串展示：最后一个 token 是主键，其余是修饰键（服务端下发的是规范序串）。
// enter/backspace/esc 等别名也归一到同一符号，迁移残留与重录产物显示一致。
function hotkeyDisplay(hotkey) {
  const named = { up: '↑', down: '↓', left: '←', right: '→', return: '⏎', enter: '⏎',
    delete: '⌫', backspace: '⌫', escape: 'esc', space: '空格', tab: '⇥' };
  const mods = { cmd: '⌘', shift: '⇧', opt: '⌥', ctrl: '⌃' };
  const parts = (hotkey || '').split('+').map(part => part.trim());
  const shown = parts.map((hotkey, index) => {
    const token = hotkey.toLowerCase();
    return index < parts.length - 1 ? (mods[token] || hotkey) : (named[token] || hotkey.toUpperCase());
  });
  return shown.join('');
}
function automaticShortcutLabel(hotkey) {
  const display = hotkeyDisplay(hotkey);
  return COMMON_SHORTCUT_LABELS[display] || display;
}

// 录制器唯一入口：ctx 指明录给谁（全局 / 应用专属组 / 重录某行），提示文案随作用域给。
// 视觉反馈就地显示在触发录制的按钮上（页面下方的 scRecord 或展开区内的录制按钮），
// 否则用户在目标设置区点录制却看到页面下方按钮变字，会以为没反应。
function startRecording(ctx, hint, button) {
  recordCtx = ctx;
  recording = true;
  recordButton = button || $('scRecord');
  recordButton.dataset.recording = '1';
  recordButton.textContent = hint || '按下按键…';
  recordButton.classList.add('recording');
}
function stopRecording() {
  recording = false;
  recordCtx = null;
  if (recordButton) {
    recordButton.dataset.recording = '0';
    recordButton.classList.remove('recording');
    // 全局按钮恢复"录制按键"，应用专属按钮恢复"录制"
    recordButton.textContent = recordButton === $('scRecord') ? '录制按键' : '录制';
  }
  recordButton = null;
}

document.addEventListener('keydown', event => {
  if (!recording) return;
  event.preventDefault();
  event.stopPropagation();
  // 输入法合成中的 keydown 不是真实按键（回车常被 IME 吞掉或变形），一律忽略。
  if (event.isComposing || event.keyCode === 229) return;
  // Esc 且未带修饰键 = 取消录制。
  if (event.key === 'Escape' && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey) {
    stopRecording();
    return;
  }
  const main = hotkeyToken(event);
  if (!main) return; // 忽略纯修饰键与不可识别键
  const mods = [];
  if (event.metaKey) mods.push('Cmd');
  if (event.shiftKey) mods.push('Shift');
  if (event.altKey) mods.push('Opt');
  if (event.ctrlKey) mods.push('Ctrl');
  const hotkey = [...mods, main].join('+');
  const label = automaticShortcutLabel(hotkey);
  const ctx = recordCtx;
  stopRecording();
  if (!ctx) return;
  // 三种作用域：重录全局某行 / 应用专属组追加 / 全局追加。录完即存。
  if (ctx.scope === 'rerecord-global') {
    shortcuts[ctx.index].hotkey = hotkey;
    shortcuts[ctx.index].label = label;
    saveShortcuts();
  } else if (ctx.scope === 'target') {
    const t = state.targets.find(item => item.id === ctx.targetId);
    if (!t) return;
    t.shortcuts = [...(t.shortcuts || []), { id: '', label, hotkey }];
    save(); // 走 /api/targets，服务端补 UUID 并校验
  } else {
    shortcuts.push({ id: '', label, hotkey });
    saveShortcuts();
  }
}, true);

$('scRecord').onclick = (event) => startRecording({ scope: 'global' }, '按下按键…', event.currentTarget);

async function saveShortcuts() {
  if (savingShortcuts) return false;
  savingShortcuts = true; configRevision++;
  $('scList').inert = true;
  $('scPresetChips').inert = true;
  $('scRecord').disabled = true;
  $('scSaveState').textContent = '保存中…';
  try {
    await post('/api/shortcuts', shortcuts.map(s => ({ id: s.id, label: s.label, hotkey: s.hotkey, action: s.action || null })));
    savingShortcuts = false;
    await refresh(); renderShortcuts();
    $('scSaveState').textContent = '已保存到本机';
    return true;
  } catch (error) {
    $('scSaveState').textContent = '保存失败：' + error.message;
    return false;
  } finally {
    savingShortcuts = false; configRevision++;
    $('scList').inert = false; $('scPresetChips').inert = false; $('scRecord').disabled = false;
  }
}

// 预设动作：录不到的系统/应用操作，点选即添加（服务端按平台展开按键串）。
// 已添加的置灰，避免重复添加同一动作。
function renderPresetActions() {
  const row = $('scPresetRow');
  const box = $('scPresetChips');
  row.hidden = presetActions.length === 0;
  box.innerHTML = '';
  presetActions.forEach(action => {
    const added = shortcuts.some(s => s.action === action.id);
    const chip = document.createElement('button');
    chip.className = 'btn ghost';
    chip.disabled = added;
    chip.textContent = added ? `${action.label} · 已添加` : action.label;
    // 没有按键的动作（「清空会话」由手机执行）不要在提示里留一个孤零零的分隔符。
    const keyLabel = hotkeyDisplay(action.hotkey);
    chip.title = keyLabel ? `${action.label} · ${keyLabel}` : action.label;
    chip.addEventListener('click', async () => {
      shortcuts.push({ id: '', label: action.label, hotkey: action.hotkey, action: action.id });
      await saveShortcuts();
    });
    box.append(chip);
  });
}

function renderShortcuts() {
  const box = $('scList'); box.innerHTML = '';
  shortcuts.forEach((shortcut, index) => {
    const display = hotkeyDisplay(shortcut.hotkey);
    // label 与键位展示重复时只显示一个（如 label=↑、hotkey=Up 都显示 ↑），避免同列两个相同符号。
    const label = shortcut.label === display ? '' : shortcut.label;
    // 预设动作不可重录：它们在网页里按下去就被系统消费，录制器拿不到。故不挂 rerecord。
    const preset = Boolean(shortcut.action);
    const row = document.createElement('div'); row.className = 'target-row';
    row.innerHTML = `<span class="drag-handle" aria-hidden="true">⠿</span><b${preset ? '' : ' class="sc-editable" data-act="rerecord" title="点击重新录制按键"'} style="flex:0 0 auto;min-width:48px">${esc(label || display)}</b>
      ${label && display ? `<span class="keycap"${preset ? '' : ' data-act="rerecord" title="点击重新录制组合键"'}>${esc(display)}</span>` : ''}
      ${preset ? '<span class="pill" style="padding:2px 8px;font-size:11px">预设</span>' : ''}
      <button class="btn ghost icon-btn danger" data-act="remove" style="margin-left:auto" title="移除" aria-label="移除">${TRASH_SVG}<span class="confirm-text">确认移除</span></button>`;
    row.addEventListener('click', async event => {
      const act = event.target.closest('[data-act]')?.dataset?.act;
      if (!act) return;
      if (act === 'remove') {
        if (savingShortcuts) return;
        const previous = shortcuts;
        shortcuts = shortcuts.filter(item => item.id !== shortcut.id);
        if (!await saveShortcuts()) { shortcuts = previous; renderShortcuts(); }
      }
      // 重录反馈显示在全局录制按钮上（重录发生在全局列表，与按钮同卡片）。
      if (act === 'rerecord') startRecording({ scope: 'rerecord-global', index }, `为「${shortcuts[index].label}」按新按键…`);
    });
    attachDragSort(row, {
      key: 'shortcuts', index,
      commit: async (from, to) => { if (reorder(shortcuts, from, to)) await saveShortcuts(); },
    });
    box.append(row);
  });
  renderPresetActions();   // 增删会改变"已添加"置灰状态，随列表一起刷新
}

// 最近动作：把"发出去了"与"生效了"分开显示，不确定态用琥珀色单独标出。
// 这是排查"手机点了没反应"的第一现场——日志里明确失败与仅发出未确认，排查方向完全不同。
function renderActivity(log) {
  const box = $('activityLog');
  if (!box) return;
  if (!log || !log.length) {
    box.innerHTML = '<p class="hint" style="margin:0">还没有记录。用手机点一下快捷键或发一条消息，结果会实时出现在这里。</p>';
    return;
  }
  box.innerHTML = log.map(item => {
    const time = (item.time || '').slice(11, 19) || '--:--:--';
    const front = item.frontApp ? `<span class="act-front">前台 ${esc(item.frontApp)}</span>` : '';
    return `<div class="act-row" data-outcome="${esc(item.outcome)}">
      <span class="act-time">${esc(time)}</span>
      <span class="act-badge">${esc(item.outcomeLabel || item.outcome)}</span>
      <span class="act-body"><span class="act-label">${esc(item.label)}</span>${front}</span>
      <span class="act-detail">${esc(item.detail)}</span>
    </div>`;
  }).join('');
}

refresh(); setInterval(refresh, 3000);

