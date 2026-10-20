/**
 * [INPUT]: 本机 /api/console/mijia 状态/连接/检查/取消接口与受限二维码图片，console.html 的米家卡片。
 * [OUTPUT]: 显式扫码连接、服务器期限倒计时、连接核验与取消；过期/失败/后台撤下旧码，恢复只读查账；将账号状态交给 console-mijia-scope 独立维护家庭选择。
 * [POS]: 控制台独立闭包；串行请求与意图代际隔离迟到结果，授权仅由服务端保管，不与手机配对或模型配置共享状态。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';
  const $ = id => document.getElementById(id);
  if (!$('mijia-card')) return;
  const requestTimeout = 12000;
  const activeStates = new Set(['checking', 'installing', 'starting', 'waiting', 'authorizing']);
  const labels = { unconfigured: '未连接', checking: '检查中…', connected: '已连接', installing: '准备中…',
    starting: '生成中…', waiting: '等待扫码', authorizing: '确认中…', expired: '二维码已过期', failed: '连接未完成' };
  const defaults = { unconfigured: '连接米家后，小精灵就能查看和操作你的设备。', checking: '正在检查米家连接…',
    connected: '米家账号已连接，请确认下方允许控制的家庭。', installing: '正在准备米家连接组件，请稍候…',
    starting: '正在生成米家二维码…', waiting: '二维码已准备好，请用米家 App 扫码。', authorizing: '正在核验手机确认的授权…',
    expired: '二维码已过期，请重新生成后扫码。', failed: '暂时无法连接米家，请检查网络后重试。' };
  let snapshot = { state: 'checking', hasCredentials: false, qrReady: false };
  let generation = 0, sequence = 0, appliedSequence = 0, inFlight = null, pending = null;
  let pollTimer = null, expiryTimer = null, qrKey = '', fresh = false, suspended = false;

  // ----- 状态与图片 -----
  function clearQR() {
    qrKey = '';
    $('mijia-qr').hidden = true;
    $('mijia-qr').onload = null;
    $('mijia-qr').onerror = null;
    $('mijia-qr').removeAttribute('src');
    $('mijia-qr-panel').hidden = true;
    $('mijia-countdown').textContent = '';
  }
  function remainingSeconds() { return Math.max(0, Math.ceil(Number(snapshot.expiresAt) - Date.now() / 1000)); }
  function hasLiveQR() {
    return fresh && snapshot.state === 'waiting' && snapshot.qrReady && typeof snapshot.sessionId === 'string'
      && snapshot.sessionId.length > 0 && Number.isFinite(snapshot.expiresAt) && remainingSeconds() > 0;
  }
  function showQR() {
    if (!hasLiveQR() || document.hidden || suspended) { clearQR(); return; }
    $('mijia-qr-panel').hidden = false;
    const seconds = remainingSeconds();
    $('mijia-countdown').textContent = `有效期剩余 ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
    const key = snapshot.sessionId + ':' + (snapshot.revision || 0);
    if (key === qrKey) return;
    clearQR();
    qrKey = key;
    $('mijia-qr-panel').hidden = false;
    $('mijia-qr-loading').hidden = false;
    const imageGeneration = generation;
    $('mijia-qr').onload = () => {
      if (imageGeneration !== generation || qrKey !== key || !hasLiveQR() || document.hidden || suspended) return;
      $('mijia-qr').hidden = false;
      $('mijia-qr-loading').hidden = true;
    };
    $('mijia-qr').onerror = () => {
      if (imageGeneration !== generation || qrKey !== key) return;
      fail('二维码加载失败，请重新生成后扫码。');
    };
    $('mijia-qr').src = '/api/console/mijia/qr?sessionId=' + encodeURIComponent(snapshot.sessionId)
      + '&revision=' + encodeURIComponent(snapshot.revision || 0);
    $('mijia-countdown').textContent = `有效期剩余 ${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
  }
  function render() {
    const state = snapshot.state;
    const busy = Boolean(inFlight || pending);
    const active = activeStates.has(state);
    const reconnecting = active && Boolean(snapshot.sessionId);
    $('mijia-state').textContent = labels[state] || labels.failed;
    $('mijia-state').dataset.state = state;
    $('mijia-message').textContent = snapshot.message || defaults[state] || defaults.failed;
    $('mijia-message').classList.toggle('error', state === 'failed' || state === 'expired');
    $('mijia-verified').hidden = state !== 'connected' || !Number.isFinite(snapshot.checkedAt);
    if (!$('mijia-verified').hidden) {
      const count = Number.isInteger(snapshot.deviceCount) && snapshot.deviceCount >= 0 ? ` · ${snapshot.deviceCount} 个设备` : '';
      $('mijia-verified').textContent = '最近检查：' + new Date(snapshot.checkedAt * 1000).toLocaleString('zh-CN',
        { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }) + count;
    }
    $('mijia-connect').hidden = active && state !== 'waiting';
    $('mijia-connect').textContent = state === 'waiting' ? '刷新二维码' : state === 'expired' ? '重新生成二维码' : snapshot.hasCredentials ? '重新连接' : '连接米家';
    $('mijia-connect').classList.toggle('primary', state !== 'connected');
    $('mijia-connect').disabled = busy;
    $('mijia-check').hidden = active || !snapshot.hasCredentials;
    $('mijia-check').classList.toggle('primary', state === 'connected');
    $('mijia-check').disabled = busy;
    $('mijia-cancel').hidden = !reconnecting;
    $('mijia-cancel').disabled = pending?.kind === 'cancel' || inFlight?.kind === 'cancel';
    $('mijia-cancel').textContent = $('mijia-cancel').disabled ? '正在取消…' : '取消连接';
    $('mijia-retained').hidden = !reconnecting || !snapshot.hasCredentials;
    showQR();
    window.PocketDeskMijiaScope?.connectionChanged(snapshot);
  }
  function stopTimers() {
    clearTimeout(pollTimer); clearTimeout(expiryTimer);
    pollTimer = null; expiryTimer = null;
  }
  function abortCurrent() {
    if (!inFlight) return;
    clearTimeout(inFlight.deadlineTimer);
    inFlight.controller.abort();
  }
  function expire() {
    generation += 1; pending = null; abortCurrent(); stopTimers();
    snapshot = { ...snapshot, state: 'expired', qrReady: false, message: defaults.expired };
    render();
  }
  function schedule() {
    stopTimers();
    if (document.hidden || suspended) return;
    if (activeStates.has(snapshot.state) && !inFlight && !pending) pollTimer = setTimeout(() => queue('status'), 2000);
    if (hasLiveQR()) expiryTimer = setTimeout(function tick() {
      if (remainingSeconds() <= 0) expire();
      else { showQR(); expiryTimer = setTimeout(tick, 1000); }
    }, 1000);
  }
  function fail(message) {
    generation += 1; pending = null; fresh = false; abortCurrent();
    snapshot = { ...snapshot, state: 'failed', qrReady: false, message };
    stopTimers(); render();
  }
  function accept(result, job) {
    if (!result || typeof result !== 'object' || !Object.hasOwn(labels, result.state)) throw new Error('米家连接状态异常，请重试。');
    if (job.sequence < appliedSequence) return;
    if (result.sessionId && result.sessionId === snapshot.sessionId && Number.isFinite(result.revision)
        && Number.isFinite(snapshot.revision) && result.revision < snapshot.revision) return;
    appliedSequence = job.sequence;
    snapshot = result; fresh = true;
    if (snapshot.state === 'waiting' && Number.isFinite(snapshot.expiresAt) && remainingSeconds() <= 0) expire();
    else render();
  }

  // ----- 串行请求：取消先作废旧意图，上一请求收尾后才发送下一请求 -----
  function queue(kind, body) {
    if (document.hidden || suspended) return;
    if (kind === 'status' && (pending || inFlight?.generation === generation)) return;
    if (kind !== 'status') {
      generation += 1; clearQR();
      if (kind !== 'cancel') snapshot = { ...snapshot, state: kind === 'check' ? 'checking' : 'starting',
        qrReady: false, sessionId: undefined, message: defaults[kind === 'check' ? 'checking' : 'starting'] };
      else snapshot = { ...snapshot, qrReady: false, message: '正在取消这次连接…' };
    }
    pending = { kind, body, generation, sequence: ++sequence };
    stopTimers();
    abortCurrent();
    render(); drain();
  }
  async function drain() {
    if (inFlight || !pending || document.hidden || suspended) return;
    const job = pending; pending = null;
    job.controller = new AbortController(); inFlight = job;
    render(); schedule();
    job.deadlineTimer = setTimeout(() => { job.timedOut = true; job.controller.abort(); }, requestTimeout);
    try {
      const options = { cache: 'no-store', signal: job.controller.signal,
        headers: { 'X-PocketDesk-Console': '1' } };
      if (job.kind !== 'status') {
        options.method = 'POST'; options.headers['Content-Type'] = 'application/json';
        options.body = JSON.stringify(job.body || {});
      }
      const response = await fetch('/api/console/mijia/' + job.kind, options);
      const result = await response.json();
      if (job.generation !== generation || document.hidden || suspended) return;
      if (job.timedOut) throw new Error('米家连接请求超时，请重试。');
      if (!response.ok) throw new Error(result.error || '米家连接请求失败，请重试。');
      accept(result, job);
    } catch (error) {
      if (job.generation === generation && !document.hidden && !suspended) {
        if (job.timedOut) fail('米家连接请求超时，请重试。');
        else if (error.name !== 'AbortError') fail(error.message || '无法联系 PocketDesk，请确认应用正在运行后重试。');
      }
    } finally {
      clearTimeout(job.deadlineTimer);
      if (inFlight === job) inFlight = null;
      render();
      if (pending) drain();
      else schedule();
    }
  }
  function pause() {
    generation += 1; fresh = false; pending = null;
    abortCurrent(); stopTimers(); clearQR();
  }
  $('mijia-connect').onclick = () => { if (!$('mijia-connect').disabled) queue('connect', {}); };
  $('mijia-check').onclick = () => { if (!$('mijia-check').disabled) queue('check', {}); };
  $('mijia-cancel').onclick = () => {
    if (!$('mijia-cancel').disabled && snapshot.sessionId) queue('cancel', { sessionId: snapshot.sessionId });
  };
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) pause();
    else queue('status');
  });
  window.addEventListener('pagehide', () => { suspended = true; pause(); });
  window.addEventListener('pageshow', () => { if (suspended) { suspended = false; queue('status'); } });
  render(); queue('status');
})();
