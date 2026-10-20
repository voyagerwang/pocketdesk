/**
 * [INPUT]: console-mijia 的账号连接状态、本机 homes/home 接口和家庭范围表单；家庭请求独立于扫码轮询。
 * [OUTPUT]: PocketDeskMijiaScope.connectionChanged 接收账号事实，显式选择并保存单个家庭；范围说明限于已适配灯和开关及只读温湿度，草稿/确认范围分离，换账号和迟到结果隔离。
 * [POS]: 米家设备授权范围的控制台边界；只信服务端家庭清单与保存回执，不默认第一户或放宽到所有家庭，不保存账号凭据。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';
  const $ = id => document.getElementById(id);
  if (!$('mijia-scope')) return;
  const requestTimeout = 50000;
  let connected = false, connectionKey = '', data = null, draft = '', message = '', error = false;
  let generation = 0, inFlight = null, pendingRead = false, suspended = false, verificationNeeded = false;

  // ----- 已确认范围与编辑草稿 -----
  function selectedHome() { return data?.homes.find(home => home.id === data.selectedHomeId) || null; }
  function dirty() { return draft !== (selectedHome()?.id || ''); }
  function label(home) {
    const duplicate = data.homes.filter(item => item.name === home.name).length > 1;
    return home.name + (duplicate ? `（${home.id}）` : '');
  }
  function rebuildOptions() {
    const select = $('mijia-home');
    const empty = document.createElement('option'); empty.value = ''; empty.textContent = '请选择允许控制的家庭';
    select.replaceChildren(empty);
    for (const home of data?.homes || []) {
      const option = document.createElement('option'); option.value = home.id; option.textContent = label(home);
      select.append(option);
    }
    select.value = draft;
  }
  function render() {
    const busy = Boolean(inFlight || pendingRead);
    const selected = selectedHome();
    $('mijia-scope-current').textContent = !connected ? '连接米家后，请选择允许控制的家庭。'
      : selected ? `${verificationNeeded ? '上次确认范围' : '当前生效'}：${label(selected)}`
      : '账号已连接，还需选择允许控制的家庭。';
    $('mijia-home').disabled = !connected || busy || !data?.homes.length || verificationNeeded;
    $('mijia-home-save').disabled = !connected || busy || !draft || !dirty() || verificationNeeded;
    $('mijia-home-refresh').disabled = !connected || busy;
    $('mijia-home-save').textContent = inFlight?.kind === 'save' ? '正在保存…' : '保存范围';
    $('mijia-home-refresh').textContent = inFlight?.kind === 'read' ? '正在读取…' : '刷新家庭列表';
    $('mijia-scope-form').setAttribute('aria-busy', String(busy));
    const note = !connected ? '' : inFlight?.kind === 'save' ? '正在保存允许控制的家庭…'
      : busy ? '正在从米家读取家庭列表，请稍候…'
      : message || (dirty() ? '尚未保存。点击「保存范围」后生效。'
      : !data ? '请刷新家庭列表。' : !data.homes.length ? '这个账号还没有可选择的家庭，请在米家 App 中确认后刷新。'
      : !selected ? '请选择允许控制的家庭。' : '小精灵仅控制这个家庭中已支持的灯和开关，并只读查询温湿度。');
    $('mijia-scope-message').textContent = note;
    $('mijia-scope-message').classList.toggle('error', error && !busy && connected);
  }
  function normalize(result) {
    if (!result || !Array.isArray(result.homes)) throw new Error('家庭列表格式异常，请刷新重试。');
    const homes = result.homes.map(home => {
      if (!home || typeof home.id !== 'string' || !home.id || typeof home.name !== 'string')
        throw new Error('家庭列表格式异常，请刷新重试。');
      return { id: home.id, name: home.name || '未命名家庭' };
    });
    if (new Set(homes.map(home => home.id)).size !== homes.length) throw new Error('家庭列表存在重复标识，请刷新重试。');
    const selectedHomeId = result.selectionRequired ? null : result.selectedHomeId;
    return { homes, selectedHomeId: homes.some(home => home.id === selectedHomeId) ? selectedHomeId : null };
  }
  function accept(result, job) {
    const next = normalize(result);
    if (job.kind === 'save' && next.selectedHomeId !== job.homeId)
      throw new Error('保存结果尚未确认，请刷新家庭列表核对。');
    const preserveDraft = job.kind === 'read' && dirty() && next.homes.some(home => home.id === draft)
      && !(selectedHome() && !next.selectedHomeId);
    data = next;
    if (!preserveDraft) draft = next.selectedHomeId || '';
    verificationNeeded = false; error = false;
    message = job.kind === 'save' ? '控制范围已保存。' : '';
    rebuildOptions();
  }

  // ----- 独立慢请求：可取消、单请求在途，旧账号与隐藏期间的结果不回填 -----
  function invalidate(reset = false) {
    generation += 1; pendingRead = false;
    if (inFlight) { clearTimeout(inFlight.deadlineTimer); inFlight.controller.abort(); }
    if (reset) {
      data = null; draft = ''; message = ''; error = false; verificationNeeded = false; rebuildOptions();
    }
  }
  function refresh() {
    if (!connected || document.hidden || suspended) return;
    if (inFlight?.generation === generation) return;
    pendingRead = true; message = ''; error = false; render(); drain();
  }
  async function drain(saveHomeId) {
    if (inFlight || (!pendingRead && !saveHomeId) || !connected || document.hidden || suspended) return;
    const job = { generation, kind: saveHomeId ? 'save' : 'read', homeId: saveHomeId, controller: new AbortController() };
    pendingRead = false; inFlight = job;
    job.deadlineTimer = setTimeout(() => { job.timedOut = true; job.controller.abort(); }, requestTimeout);
    render();
    try {
      const options = { cache: 'no-store', headers: { 'X-PocketDesk-Console': '1' }, signal: job.controller.signal };
      if (job.kind === 'save') {
        options.method = 'POST'; options.headers['Content-Type'] = 'application/json'; options.body = JSON.stringify({ homeId: job.homeId });
      }
      const response = await fetch('/api/console/mijia/' + (job.kind === 'save' ? 'home' : 'homes'), options);
      const result = await response.json();
      if (job.generation !== generation || !connected || document.hidden || suspended) return;
      if (job.timedOut) throw new Error('请求超时');
      if (!response.ok) {
        const issue = new Error(result.error || result.message || '请求失败，请重试。');
        issue.confirmedFailure = true; throw issue;
      }
      accept(result, job);
    } catch (issue) {
      if (job.generation === generation && connected && !document.hidden && !suspended && (job.timedOut || issue.name !== 'AbortError')) {
        error = true;
        verificationNeeded = job.kind === 'save' && !issue.confirmedFailure;
        message = verificationNeeded ? '保存结果尚未确认，请刷新家庭列表核对。'
          : job.timedOut ? '读取家庭列表超时，请刷新重试。'
          : (job.kind === 'save' ? '保存失败：' : '') + (issue.message || '读取家庭列表失败，请刷新重试。');
      }
    } finally {
      clearTimeout(job.deadlineTimer);
      if (inFlight === job) inFlight = null;
      render();
      if (pendingRead) drain();
    }
  }
  function connectionChanged(snapshot) {
    const nextConnected = snapshot.state === 'connected' && Boolean(snapshot.hasCredentials);
    const key = `${snapshot.checkedAt || ''}:${snapshot.revision || ''}`;
    const changed = nextConnected && (!connected || key !== connectionKey);
    if (!nextConnected && connected) invalidate(true);
    connected = nextConnected;
    if (changed) {
      connectionKey = key; invalidate(true); refresh();
    }
    render();
  }
  $('mijia-home').addEventListener('change', () => {
    if ($('mijia-home').disabled) return;
    draft = data?.homes.some(home => home.id === $('mijia-home').value) ? $('mijia-home').value : '';
    message = ''; error = false; render();
  });
  $('mijia-home-refresh').onclick = () => { if (!$('mijia-home-refresh').disabled) refresh(); };
  $('mijia-scope-form').addEventListener('submit', event => {
    event.preventDefault();
    if ($('mijia-home-save').disabled) return;
    message = ''; error = false; drain(draft);
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) { invalidate(); render(); }
    else refresh();
  });
  window.addEventListener('pagehide', () => { suspended = true; invalidate(); render(); });
  window.addEventListener('pageshow', () => { if (suspended) { suspended = false; refresh(); } });
  window.PocketDeskMijiaScope = { connectionChanged };
  render();
})();
