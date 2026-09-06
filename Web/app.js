/**
 * [INPUT]: 依赖浏览器 fetch 与 index.html 的目标按钮、文本框、状态节点。
 * [OUTPUT]: 提供本地状态加载、应用唤醒、图标长按排序和 send 命令提交。
 * [POS]: Web 的交互适配层；与未来 WebSocket transport 共享 SendCommand JSON 形状。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const targetsEl = document.querySelector('#targets');
const textEl = document.querySelector('#text');
const sendEl = document.querySelector('#send');
const messageEl = document.querySelector('#message');
const connectionEl = document.querySelector('#connection');
const ORDER_KEY = 'voice-deck-target-order-v1';
let selected = 'codex';

function message(text, error = false) { messageEl.textContent = text; messageEl.className = error ? 'error' : ''; }
function orderedTargets(targets) {
  let saved = [];
  try { saved = JSON.parse(localStorage.getItem(ORDER_KEY) || '[]'); } catch { localStorage.removeItem(ORDER_KEY); }
  return [...targets].sort((a, b) => {
    const ai = saved.indexOf(a.id); const bi = saved.indexOf(b.id);
    return (ai < 0 ? Number.MAX_SAFE_INTEGER : ai) - (bi < 0 ? Number.MAX_SAFE_INTEGER : bi);
  });
}
function saveTargetOrder() {
  const order = [...targetsEl.querySelectorAll('.target')].map(element => element.dataset.targetId);
  localStorage.setItem(ORDER_KEY, JSON.stringify(order));
}
function enableLongPressSort(button) {
  let timer; let startX = 0; let startY = 0; let sorting = false; let suppressClick = false;
  const finish = () => {
    clearTimeout(timer);
    if (!sorting) return;
    sorting = false; suppressClick = true; button.classList.remove('dragging'); targetsEl.classList.remove('sorting');
    saveTargetOrder(); message('图标顺序已保存在这台手机上。');
    setTimeout(() => { suppressClick = false; }, 350);
  };
  button.addEventListener('pointerdown', event => {
    startX = event.clientX; startY = event.clientY;
    timer = setTimeout(() => {
      sorting = true; button.classList.add('dragging'); targetsEl.classList.add('sorting');
      button.setPointerCapture(event.pointerId); navigator.vibrate?.(20); message('拖动图标调整位置…');
    }, 450);
  });
  button.addEventListener('pointermove', event => {
    if (!sorting && Math.hypot(event.clientX - startX, event.clientY - startY) > 8) clearTimeout(timer);
    if (!sorting) return;
    event.preventDefault();
    const peer = document.elementFromPoint(event.clientX, event.clientY)?.closest('.target');
    if (!peer || peer === button || peer.parentElement !== targetsEl) return;
    const before = event.clientX < peer.getBoundingClientRect().left + peer.offsetWidth / 2;
    targetsEl.insertBefore(button, before ? peer : peer.nextSibling);
  });
  button.addEventListener('pointerup', finish); button.addEventListener('pointercancel', finish);
  button.addEventListener('contextmenu', event => event.preventDefault());
  return () => suppressClick;
}
function renderTargets(targets) {
  targetsEl.innerHTML = '';
  orderedTargets(targets).forEach(target => {
    const button = document.createElement('button'); button.type = 'button'; button.className = `target${target.id === selected ? ' selected' : ''}`;
    button.dataset.targetId = target.id;
    button.setAttribute('role', 'radio'); button.setAttribute('aria-checked', String(target.id === selected));
    const fallback = target.name.slice(0, 1).toUpperCase();
    button.innerHTML = `<span class="target-icon"><img src="/api/icon?id=${encodeURIComponent(target.id)}" alt=""><span>${fallback}</span></span><small>${target.name}</small>`;
    const image = button.querySelector('img'); image.addEventListener('error', () => image.classList.add('missing'));
    const wasLongPress = enableLongPressSort(button);
    button.onclick = async () => {
      if (wasLongPress()) return;
      selected = target.id; renderTargets(targets); message(`正在唤醒 ${target.name}…`);
      try {
        const response = await fetch('/api/activate', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({targetId:selected})});
        const result = await response.json(); if (!response.ok) throw new Error(result.error || '无法唤醒应用。');
        message(`${target.name} 已置于电脑前台，可以开始输入。`); textEl.focus();
      } catch (error) { message(error.message, true); }
    };
    targetsEl.append(button);
  });
}
async function boot() {
  try {
    const status = await fetch('/api/status').then(response => response.json());
    renderTargets(status.targets); connectionEl.textContent = status.accessibility ? '已就绪' : '需授权'; connectionEl.classList.add('ready');
    if (!status.accessibility) message('请先在 Mac 上授予辅助功能权限，页面仍可输入。', true);
  } catch { connectionEl.textContent = '未连接'; message('无法连接本机服务。确认手机与 Mac 在同一网络。', true); }
}
async function send() {
  const text = textEl.value.trim(); if (!text) { message('先输入一点内容。', true); textEl.focus(); return; }
  sendEl.disabled = true; message('正在打开应用并输入…');
  try {
    const response = await fetch('/api/send', {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify({targetId:selected, text})});
    const result = await response.json(); if (!response.ok) throw new Error(result.error || '发送失败。');
    textEl.value = ''; message('已发送。');
  } catch (error) { message(error.message, true); } finally { sendEl.disabled = false; }
}
sendEl.onclick = send;
textEl.addEventListener('keydown', event => { if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); send(); } });
boot();
