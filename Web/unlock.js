/**
 * [INPUT]: 依赖已配对的 HTTPS 页面、共享控制租约和锁屏状态通知。
 * [OUTPUT]: 仅锁屏时出现的解锁表单；密码不写入草稿、历史或存储，提交后立即清除，不自动重试。
 * [POS]: Web 的独立凭据输入边界，系统状态恢复后自动关闭，HTTP 页面只显示需要安全连接。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(() => {
  const form = document.getElementById('unlock-form'), input = document.getElementById('unlock-password');
  const note = document.getElementById('unlock-note'), submit = document.getElementById('unlock-submit');
  let locked = false, busy = false, generation = 0, controller;
  function clear() { if (busy) window.pocketdeskSend?.({t:'unlock-cancel'}); input.value = ''; input.blur(); generation++; controller?.abort(); controller = null; busy = false; }
  window.pocketdeskClearUnlock = clear;
  const secure = () => location.protocol === 'https:' && window.isSecureContext;
  function render() {
    form.hidden = !locked;
    const allowed = secure() && window.pocketdeskControlReady();
    input.hidden = submit.hidden = !allowed; input.disabled = submit.disabled = busy || !allowed;
    if (!allowed) { clear(); note.textContent = secure() ? '请先取得控制权' : '请使用电脑控制台中的 HTTPS 地址解锁'; }
  }
  window.pocketdeskLockState = state => {
    const next = state === 'locked';
    if (next !== locked) { clear(); note.textContent = ''; }
    locked = next; render();
  };
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy || !locked || !secure() || !window.pocketdeskControlReady() || !input.value) return;
    const session = window.pocketdeskControlInfo().session, current = ++generation;
    busy = true; render(); note.textContent = '正在提交…';
    controller = new AbortController();
    const timeout = setTimeout(() => { window.pocketdeskSend?.({t:'unlock-cancel'}); controller?.abort(); }, 10000);
    const headers = { ...authHeaders(), 'Content-Type': 'application/json', 'X-PocketDesk-Session': session };
    const request = async (path, body) => {
      const response = await fetch(path, { method:'POST', headers, body: JSON.stringify(body), signal: controller.signal, cache:'no-store' });
      const data = await response.json(); if (!response.ok || data.error) throw Error(data.error || '提交失败'); return data;
    };
    try {
      const { challenge } = await request('/api/unlock/prepare', {});
      if (generation !== current || !locked || window.pocketdeskControlInfo().session !== session) return;
      const body = { challenge, password: input.value }; input.value = '';
      const pending = request('/api/unlock/submit', body); body.password = '';
      await pending;
      if (generation === current) note.textContent = '已发送，等待电脑解锁；若仍锁定，请核对后再试';
    } catch (error) {
      if (generation === current) note.textContent = error.name === 'AbortError' ? '连接中断，请先查看电脑状态；不会自动重试' : error.message;
    } finally {
      clearTimeout(timeout);
      if (generation === current) { input.value = ''; busy = false; controller = null; render(); }
    }
  });
  onWSMessage(message => { if (message.t === 'closed' || (message.t === 'control' && !message.controller)) clear(); render(); });
  document.addEventListener('visibilitychange', () => { if (document.hidden) { clear(); render(); } });
  window.addEventListener('pagehide', clear);
})();
