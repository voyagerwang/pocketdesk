/**
 * [INPUT]: 依赖 authHeaders/pairToken、浏览器 fetch/WebSocket 与查看器的呈现回调。
 * [OUTPUT]: 提供 ScreenFrames，管理单帧降级、持续 JPEG、呈现确认、有界退避、分级提示、自动恢复流畅画面与只读诊断。
 * [POS]: Web 的画面传输边界；状态时钟仅在真实帧呈现后更新，关闭销毁全部在途资源。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
class ScreenFrames {
  constructor(options) { this.o = options; this.epoch = 0; this.width = 1280; }
  stop() {
    this.active = false; this.lastPresented = 0;
    this.epoch++; clearTimeout(this.timer); clearTimeout(this.streamTimer);
    this.timer = null; this.due = Infinity; this.abort?.abort(); this.abort = null;
    if (this.socket) { this.socket.onclose = null; this.socket.close(); this.socket = null; }
  }
  start(display, fullscreen, port) {
    this.stop(); this.active = true; this.display = display; this.fullscreen = fullscreen; this.port = port;
    this.failed = false; this.activeUntil = 0; this.lastPresented = 0;
    this.failures = 0; this.failureSince = null; this.lastFailure = null;
    this.streamFailures = 0; this.streamRetryAt = 0; this.notice = null; this.poll();
  }
  fresh() { return this.active && this.lastPresented && performance.now() - this.lastPresented < 2000; }
  interact() {
    if (!this.active) return;
    this.activeUntil = performance.now() + 1500;
    if (!this.socket && !this.abort && !this.failures) this.schedule(80);
  }
  schedule(ms) {
    if (!this.active) return;
    const due = performance.now() + ms;
    if (this.timer && this.due <= due) return;
    clearTimeout(this.timer); this.due = due;
    this.timer = setTimeout(() => { this.timer = null; this.poll(); }, ms);
  }
  // 诊断只留最后一次故障事实，不保存画面、配对 token 或服务端正文。
  diagnose() {
    return { active: !!this.active, transport: this.socket ? 'stream' : 'snapshot',
      fresh: !!this.fresh(), failures: this.failures, streamFailures: this.streamFailures,
      lastFailure: this.lastFailure ? { ...this.lastFailure } : null };
  }
  state(text, error = false) {
    const key = `${error}:${text}`;
    if (key === this.notice) return;
    this.notice = key; this.o.state(text, error);
  }
  recovered() {
    this.failures = 0; this.failureSince = null;
    this.state(this.failed ? '省流画面 · 正在自动恢复流畅画面' : '');
  }
  failure(error, started) {
    this.failures++;
    this.failureSince ??= started;
    const status = error.httpStatus || null;
    const kind = status ? 'http' : error.name === 'AbortError' ? 'timeout' : error.frameStage;
    this.lastFailure = { at: Date.now(), kind, status };
    // 权限、配对及协议问题不可被瞬断容忍窗口掩盖。
    if (status && status < 500) {
      this.state(status === 401 ? '配对已失效，请重新扫码连接' : error.message, true); return;
    }
    if (kind === 'decode') { this.state('画面解码失败，正在重新获取', true); return; }
    const gap = performance.now() - this.failureSince;
    if (gap < 5000) return;
    const offline = typeof navigator !== 'undefined' && navigator.onLine === false;
    this.state(gap < 15000 ? '画面正在恢复…' : offline ? '手机当前离线，联网后将自动恢复画面'
      : status ? `电脑端画面暂不可用（HTTP ${status}），正在重试`
      : '画面连接持续中断，请检查网络或电脑端；正在自动重试', gap >= 15000);
  }
  async poll() {
    if (!this.active || this.abort || this.socket) return;
    const generation = this.epoch, abort = new AbortController(); this.abort = abort;
    const started = performance.now(); let stage = 'network';
    const timeout = setTimeout(() => abort.abort(), 6000);
    try {
      const r = await fetch(`/api/screen/frame?display=${this.display}&cursor=1`, { headers: authHeaders(), signal: abort.signal, cache: 'no-store' });
      if (!r.ok) {
        const body = await r.json().catch(() => ({}));
        const error = new Error(body.error || `画面获取失败（HTTP ${r.status}）`);
        error.httpStatus = r.status; throw error;
      }
      const blob = await r.blob();
      if (generation !== this.epoch) return;
      stage = 'decode';
      await this.o.present(blob, { display: this.display, cursorIncluded: true }, generation);
      if (generation !== this.epoch) return;
      this.lastPresented = performance.now(); this.recovered();
    } catch (e) {
      if (generation === this.epoch) { e.frameStage = stage; this.failure(e, started); }
    } finally {
      clearTimeout(timeout);
      if (generation === this.epoch) {
        this.abort = null;
        if (this.fullscreen && this.port && !this.failures && performance.now() >= this.streamRetryAt) this.stream();
        else this.schedule(this.failures ? Math.min(4000, 500 * 2 ** Math.min(this.failures - 1, 3))
          : performance.now() < this.activeUntil ? 220 : 1000);
      }
    }
  }
  stream() {
    const generation = this.epoch;
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    const socket = new WebSocket(`${scheme}://${location.hostname}:${this.port}`); this.socket = socket;
    socket.binaryType = 'arraybuffer'; let decoding = false;
    const fallback = (kind, code = null) => {
      if (this.epoch !== generation || this.socket !== socket) return;
      this.failed = true; this.socket = null; socket.onclose = null; socket.close();
      this.streamFailures++;
      this.lastFailure = { at: Date.now(), kind, status: null, code };
      this.streamRetryAt = performance.now() + Math.min(30000, 10000 * this.streamFailures);
      clearTimeout(this.streamTimer); this.schedule(0);
    };
    this.streamTimer = setTimeout(() => fallback('stream-timeout'), 3000);
    socket.onopen = () => socket.send(JSON.stringify({ t: 'watch', token: pairToken(), display: this.display, width: this.width }));
    socket.onerror = () => fallback('stream-network');
    socket.onclose = event => fallback('stream-close', event.code);
    socket.onmessage = async event => {
      if (generation !== this.epoch || this.socket !== socket || decoding) return;
      try {
        const bytes = event.data;
        if (!(bytes instanceof ArrayBuffer) || bytes.byteLength < 5 || bytes.byteLength > 8 * 1024 * 1024) throw new Error('无效画面');
        const size = new DataView(bytes).getUint32(0);
        if (size > 4096 || size + 4 >= bytes.byteLength) throw new Error('无效帧头');
        const meta = JSON.parse(new TextDecoder().decode(bytes.slice(4, size + 4)));
        if (meta.display !== this.display || !Number.isFinite(meta.ageMs) || meta.ageMs > 1500) throw new Error('画面已过期');
        decoding = true;
        const started = performance.now();
        await this.o.present(new Blob([bytes.slice(size + 4)], { type: 'image/jpeg' }), meta, generation);
        if (generation !== this.epoch || this.socket !== socket) return;
        this.lastPresented = performance.now() - meta.ageMs - (performance.now() - started);
        this.failed = false; this.streamFailures = 0; this.recovered(); socket.send(JSON.stringify({ t: 'presented', frameId: meta.frameId }));
        clearTimeout(this.streamTimer); this.streamTimer = setTimeout(() => fallback('stream-timeout'), 2500);
      } catch { fallback('stream-frame'); }
      finally { decoding = false; }
    };
  }
}
globalThis.ScreenFrames = ScreenFrames;
