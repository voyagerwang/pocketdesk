/**
 * [INPUT]: 依赖浏览器 fetch 与 index.html 的目标按钮、文本框、状态节点。
 * [OUTPUT]: 提供本地 API 状态加载和一次 send 命令提交。
 * [POS]: Web 的交互适配层；与未来 WebSocket transport 共享 SendCommand JSON 形状。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const targetsEl = document.querySelector('#targets');
const textEl = document.querySelector('#text');
const sendEl = document.querySelector('#send');
const messageEl = document.querySelector('#message');
const connectionEl = document.querySelector('#connection');
let selected = 'codex';

function message(text, error = false) { messageEl.textContent = text; messageEl.className = error ? 'error' : ''; }
function renderTargets(targets) {
  targetsEl.innerHTML = '';
  targets.forEach(target => {
    const button = document.createElement('button'); button.type = 'button'; button.className = `target${target.id === selected ? ' selected' : ''}`;
    button.setAttribute('role', 'radio'); button.setAttribute('aria-checked', String(target.id === selected));
    const detail = target.available ? (target.id === 'feishu' ? 'Feishu / Lark' : '打开后输入') : '当前未检测到';
    button.innerHTML = `${target.name}<small>${detail}</small>`;
    button.onclick = () => { selected = target.id; renderTargets(targets); };
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
