/**
 * [INPUT]: 消费浮窗、8 个缩放柄与移动结束回调，依赖 Pointer Events/localStorage。
 * [OUTPUT]: 提供 ScreenPip 的位置恢复、拖动缩放、夹取与手势取消。
 * [POS]: Web 的浮窗几何边界；不处理全屏画面手势，拖动尾部不穿透为远端点击。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
class ScreenPip {
  constructor(panel, changed) {
    this.panel = panel; this.changed = changed;
    try { this.box = JSON.parse(localStorage.getItem('voicedeck.pip')); } catch {}
    if (!this.box || !['x','y','w','h'].every(k => Number.isFinite(this.box[k]))) this.box = { x: 24, y: 90, w: 300, h: 169 };
    panel.addEventListener('pointerdown', e => this.down(e));
    window.addEventListener('pointermove', e => this.move(e));
    window.addEventListener('pointerup', e => this.end(e));
    window.addEventListener('pointercancel', () => this.cancel());
  }
  active() { return this.panel.open && this.panel.classList.contains('pip'); }
  clamp() {
    const b = this.box;
    b.w = Math.max(160, Math.min(b.w, innerWidth - 16, (innerHeight - 16) * 16/9)); b.h = b.w * 9/16;
    b.x = Math.max(8, Math.min(b.x, innerWidth - b.w - 8)); b.y = Math.max(8, Math.min(b.y, innerHeight - b.h - 8));
  }
  paint() {
    if (!this.active()) return;
    this.clamp();
    Object.assign(this.panel.style, { left: `${this.box.x}px`, top: `${this.box.y}px`, width: `${this.box.w}px`, height: `${this.box.h}px`, transform: '' });
  }
  down(e) {
    if (!this.active() || this.drag || e.button > 0 || e.target.closest('button,select,textarea')) return;
    const handle = e.target.closest('.screen-resize');
    this.drag = { id: e.pointerId, x: e.clientX, y: e.clientY, box: { ...this.box }, edge: handle?.dataset.edge || '', moved: false };
  }
  move(e) {
    const d = this.drag; if (!d || d.id !== e.pointerId) return;
    const dx = e.clientX - d.x, dy = e.clientY - d.y;
    if (Math.hypot(dx, dy) <= 8 && !d.moved) return;
    e.preventDefault(); d.moved = true;
    if (!d.edge) this.panel.style.transform = `translate3d(${dx}px,${dy}px,0)`;
    else {
      const delta = d.edge.includes('e') ? dx : d.edge.includes('w') ? -dx : (d.edge.includes('n') ? -dy : dy) * 16/9;
      this.box.w = d.box.w + delta; this.clamp();
      this.box.x = d.box.x + (d.edge.includes('w') ? d.box.w - this.box.w : 0);
      this.box.y = d.box.y + (d.edge.includes('n') ? d.box.h - this.box.h : 0); this.paint();
    }
  }
  end(e) {
    const d = this.drag; if (!d || d.id !== e.pointerId) return;
    this.drag = null;
    if (d.moved) {
      if (!d.edge) { this.box.x = d.box.x + e.clientX - d.x; this.box.y = d.box.y + e.clientY - d.y; }
      this.suppressClick = true;
      // 本次 pointerup 的兼容 click 同步抵达；下一轮接触不被时间窗吞掉。
      setTimeout(() => { this.suppressClick = false; }, 0);
    }
    this.paint(); this.changed();
    try { localStorage.setItem('voicedeck.pip', JSON.stringify(this.box)); } catch {}
  }
  cancel() { this.drag = null; this.suppressClick = true; this.paint(); setTimeout(() => { this.suppressClick = false; }, 0); }
}
globalThis.ScreenPip = ScreenPip;
