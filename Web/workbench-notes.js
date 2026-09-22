/**
 * [INPUT]: app.js 的配对请求头、compose 当前草稿、默认关闭的 Workbench Bridge G1 接口。
 * [OUTPUT]: 显式存随手记、固定请求编号重试、刷新查账与成果查看；不发送桌面输入。
 * [POS]: 手机增量业务入口；未确认快照仅存当前配对主体的本地日志，确认后删除正文，不切换旧 Agent。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
(function () {
  'use strict';
  const base = '/api/v1/workbench';
  const panel = document.getElementById('workbench-notes');
  if (!panel) return;
  const status = document.getElementById('workbench-note-status');
  const output = document.getElementById('workbench-note-content');
  const save = document.getElementById('workbench-note-save');
  const recover = document.getElementById('workbench-note-recover');
  const retry = document.getElementById('workbench-note-retry');
  const view = document.getElementById('workbench-note-view');
  const snapshot = document.getElementById('workbench-note-snapshot');
  const snapshotText = document.getElementById('workbench-note-original');
  let owner = '', scope = '', journal = null, busy = false, connected = false;
  let notice = '', artifactText = '', lastSavedBody = null;
  const token = () => { try { return pairToken(); } catch { return ''; } };
  const prefix = () => 'pocketdesk.workbench-note.v1:' + scope + ':';
  const key = id => prefix() + id;
  const pending = () => journal && journal.state !== 'succeeded';
  const draft = () => typeof liveValue === 'function' ? liveValue() : '';
  const identityCurrent = () => owner === token();

  // 请求只允许固定同源路径；配对变化后迟到结果不得显示或覆盖新主体的日志。
  async function request(path, body) {
    const auth = token();
    if (!auth || auth !== owner) throw new Error('配对已变化，请重新检查连接。');
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(base + path, {
        method: body ? 'POST' : 'GET', headers: authHeaders(), cache: 'no-store',
        redirect: 'error', signal: controller.signal,
        ...(body ? { body: JSON.stringify(body) } : {})
      });
      const result = await response.json();
      if (auth !== token()) throw new Error('配对已变化，请重新检查连接。');
      if (!response.ok) throw Object.assign(new Error(result.error || '工作台请求未完成。'), { status: response.status });
      return result;
    } finally { clearTimeout(timer); }
  }

  function journals() {
    return Object.keys(localStorage).filter(name => name.startsWith(prefix())).flatMap(name => {
      const raw = localStorage.getItem(name);
      if (raw === null) return []; // 另一标签页可能刚清理了已确认记录。
      const item = JSON.parse(raw);
      if (!item || !/^[A-Za-z0-9_-]{1,120}$/.test(item.requestId) || name !== key(item.requestId)
        || !['pending', 'succeeded'].includes(item.state)
        || (item.state === 'pending' && (typeof item.body !== 'string' || typeof item.title !== 'string')))
        throw new Error('本机保存记录损坏，请先在工作台核对；未发起新请求。');
      return [item];
    });
  }
  function readJournal() {
    const all = journals().sort((a, b) => (a.createdAt || 0) - (b.createdAt || 0));
    return all.find(item => item.state === 'pending') || all.at(-1) || null;
  }

  function writeJournal(item) {
    // 存储不可用时不开始副作用：刷新后无法查账比“暂时不能保存”更危险。
    // 一请求一键：两个标签页即使同时通过准入，也不会覆写对方的恢复凭据。
    localStorage.setItem(key(item.requestId), JSON.stringify(item));
    journal = item;
  }

  function render() {
    panel.hidden = !window.pocketdeskIsSpriteSelected?.();
    if (!identityCurrent()) {
      connected = false; journal = null; artifactText = ''; notice = '配对已变化，请检查连接。';
    }
    const blocked = !connected || busy;
    save.hidden = Boolean(pending());
    save.disabled = blocked || !draft().trim() || draft() === lastSavedBody;
    save.textContent = busy && !pending() ? '正在确认…' : '存到工作台随手记';
    recover.disabled = busy;
    recover.textContent = connected && journal ? '查询保存结果' : '检查连接';
    retry.hidden = !pending(); retry.disabled = blocked;
    view.hidden = journal?.state !== 'succeeded'; view.disabled = blocked;
    status.textContent = notice || (connected ? '只保存文字，草稿保留；不会发送给应用。' : '随手记未连接，原有发送不受影响。');
    snapshot.hidden = !pending();
    snapshotText.textContent = pending() ? journal.body : '';
    output.hidden = !artifactText; output.textContent = artifactText;
    panel.setAttribute('aria-busy', String(busy));
  }

  async function accept(receipt) {
    const artifact = receipt?.artifacts?.find(item => item.type === 'note' && /^\d+$/.test(item.id));
    if (receipt?.requestId !== journal?.requestId || receipt.state !== 'succeeded'
      || receipt.capabilityId !== 'note.create' || receipt.operationId !== 'note-' + journal.requestId
      || receipt.invocationId !== 'invoke-' + journal.requestId || !artifact)
      throw new Error('回执身份或成果不匹配，请查询原请求；未宣告保存成功。');
    lastSavedBody = journal.body ?? lastSavedBody;
    const confirmed = { requestId: journal.requestId, state: 'succeeded', artifactId: artifact.id, createdAt: journal.createdAt };
    // 服务端已确认后即使清理存储失败，也不得再显示成未提交；旧日志重载仍只查同一编号。
    journal = confirmed;
    try { writeJournal(confirmed); }
    catch { notice = '工作台已保存，但手机未能清理待确认副本。请查询同一请求，勿另发一份。'; return; }
    const remaining = journals().filter(item => item.state === 'pending').length;
    notice = '已存到工作台随手记。输入框草稿已保留。'
      + (remaining ? '另有 ' + remaining + ' 条待确认，请继续查询保存结果。' : '');
  }

  async function lookup() {
    if (!journal) return;
    try { await accept(await request('/requests/' + encodeURIComponent(journal.requestId))); }
    catch (error) {
      if (error.status === 404) notice = '尚未查到保存记录；可重试原请求，不会创建第二个编号。';
      else throw error;
    }
  }

  async function run(action) {
    if (busy) return;
    busy = true; render();
    try { await action(); }
    catch (error) {
      notice = error.name === 'AbortError' ? '连接超时，保存结果待确认。请查询保存结果。' : error.message;
    } finally { busy = false; render(); }
  }

  async function connect() {
    owner = token(); scope = ''; connected = false; journal = null; artifactText = ''; lastSavedBody = null;
    if (!owner) throw new Error('请先配对手机，再连接工作台随手记。');
    const result = await request('/capabilities');
    const capability = result.capabilities?.find(item => item.capabilityId === 'note.create'
      && item.bindingId === 'workbench-note-default' && /^pocketdesk:.+:[a-f0-9]{64}$/.test(item.authorizationRef));
    if (!capability) throw new Error('工作台尚未开放随手记保存。');
    scope = capability.authorizationRef;
    journal = readJournal(); connected = true; notice = '';
    if (journal) { notice = '正在查询上次保存结果…'; render(); await lookup(); }
  }

  async function submitOriginal() {
    if (!pending()) return;
    notice = '正在保存，请稍候；输入框草稿不会被清空。'; render();
    try { await accept(await request('/notes', { requestId: journal.requestId, title: journal.title, body: journal.body })); }
    catch (error) {
      // 网络丢包、HTTP 失败都不能变成新请求；只读恢复失败后保留原快照供显式重试。
      notice = '未收到可靠回执，正在查询原请求…'; render();
      try { await lookup(); } catch { throw error; }
    }
  }

  save.addEventListener('click', () => run(async () => {
    if (!connected || !identityCurrent() || pending()) return;
    if (!window.pocketdeskIsSpriteSelected?.()) throw new Error('请先选择小精灵。');
    if (typeof liveComposing !== 'undefined' && liveComposing) throw new Error('请先完成输入法选字。');
    if (typeof submittingDraft !== 'undefined' && submittingDraft) throw new Error('另一条发送尚未结束，请稍候。');
    if (typeof pendingImages !== 'undefined' && pendingImages.length) throw new Error('随手记当前只接收文字。请先移除附件，避免漏存。');
    const body = draft();
    if (!body.trim()) throw new Error('请先在输入框写下要保存的文字。');
    if (new TextEncoder().encode(body).length > 100000) throw new Error('文字过长，请缩短至 100 KB 以内。');
    // 另一标签页尚有未确认请求时先继承它，不覆盖其日志或把新正文套到旧编号。
    const old = readJournal();
    if (old?.state === 'pending') { journal = old; notice = '有一条待确认保存，请先查询它的结果。'; return; }
    const requestId = 'note-' + Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(36)).join('-');
    writeJournal({ requestId, title: body.trim().split(/\r?\n/)[0].slice(0, 80), body, state: 'pending', createdAt: Date.now() });
    artifactText = ''; await submitOriginal();
  }));
  recover.addEventListener('click', () => run(async () => {
    if (!connected || !identityCurrent()) await connect();
    else {
      if (!pending()) journal = readJournal();
      notice = journal ? '正在查询保存结果…' : '随手记已连接。'; render(); await lookup();
    }
  }));
  retry.addEventListener('click', () => run(async () => {
    if (!connected || !identityCurrent()) throw new Error('请先重新检查连接。');
    await submitOriginal();
  }));
  view.addEventListener('click', () => run(async () => {
    const note = await request('/artifacts/' + encodeURIComponent(journal.artifactId));
    if (String(note.id) !== journal.artifactId || typeof note.content !== 'string') throw new Error('成果身份不匹配。');
    artifactText = (note.title || '随手记') + '\n\n' + note.content;
    notice = '以下是工作台当前保存的正文。';
  }));
  document.addEventListener('input', event => { if (['text', 'kb-proxy'].includes(event.target.id)) render(); });
  window.addEventListener('storage', event => { if (event.key === 'voicedeck.pair-token') render(); });
  window.pocketdeskWorkbenchNotes = { render };
  // 启动只读探测和查账，不自动重提；连接失败保留清晰的人工重试入口。
  run(connect);
})();
