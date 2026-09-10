/**
 * [INPUT]: 依赖 authHeaders/pairToken、浏览器 fetch/WebSocket 与查看器的呈现回调。
 * [OUTPUT]: 提供 ScreenFrames，管理单帧降级、持续 JPEG、呈现确认、有界超时与停止后禁止重启。
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
    this.failed = false; this.activeUntil = 0; this.lastPresented = 0; this.poll();
  }
  fresh() { return this.active && this.lastPresented && performance.now() - this.lastPresented < 2000; }
  interact() {
    if (!this.active) return;
    this.activeUntil = performance.now() + 1500;
    if (!this.socket && !this.abort) this.schedule(80);
  }
  schedule(ms) {
    if (!this.active) return;
    const due = performance.now() + ms;
    if (this.timer && this.due <= due) return;
    clearTimeout(this.timer); this.due = due;
    this.timer = setTimeout(() => { this.timer = null; this.poll(); }, ms);
  }
  async poll() {
    if (!this.active || this.abort || this.socket) return;
    const generation = this.epoch, abort = new AbortController(); this.abort = abort;
    const timeout = setTimeout(() => abort.abort(), 6000);
    try {
      const r = await fetch(`/api/screen/frame?display=${this.display}&cursor=1`, { headers: authHeaders(), signal: abort.signal, cache: 'no-store' });
      if (!r.ok) { const error = await r.json(); throw new Error(error.error || '画面获取失败'); }
      const blob = await r.blob();
      if (generation !== this.epoch) return;
      await this.o.present(blob, { display: this.display, cursorIncluded: true }, generation);
      if (generation !== this.epoch) return;
      this.lastPresented = performance.now(); this.o.state(this.failed ? '省流画面 · 点更多可重试流畅画面' : '');
    } catch (e) {
      if (generation === this.epoch) this.o.state(e.name === 'AbortError' ? '画面超时，正在重试' : e.message, true);
    } finally {
      clearTimeout(timeout);
      if (generation === this.epoch) {
        this.abort = null;
        if (this.fullscreen && this.port && !this.failed) this.stream();
        else this.schedule(performance.now() < this.activeUntil ? 220 : 1000);
      }
    }
  }
  stream() {
    const generation = this.epoch;
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
    const socket = new WebSocket(`${scheme}://${location.hostname}:${this.port}`); this.socket = socket;
    socket.binaryType = 'arraybuffer'; let decoding = false;
    const fallback = () => {
      if (this.epoch !== generation || this.socket !== socket) return;
      this.failed = true; this.socket = null; socket.onclose = null; socket.close();
      clearTimeout(this.streamTimer); this.o.state('流畅画面暂不可用，已切换省流画面'); this.schedule(0);
    };
    this.streamTimer = setTimeout(fallback, 3000);
    socket.onopen = () => socket.send(JSON.stringify({ t: 'watch', token: pairToken(), display: this.display, width: this.width }));
    socket.onerror = fallback; socket.onclose = fallback;
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
        this.o.state(''); socket.send(JSON.stringify({ t: 'presented', frameId: meta.frameId }));
        clearTimeout(this.streamTimer); this.streamTimer = setTimeout(fallback, 2500);
      } catch { fallback(); }
      finally { decoding = false; }
    };
  }
}
globalThis.ScreenFrames = ScreenFrames;
