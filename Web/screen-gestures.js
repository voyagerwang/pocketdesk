/**
 * [INPUT]: 依赖 ScreenGeometry 的方向/位移换算、Pointer Events 合并采样与动画帧；由查看器注入可控状态、发令和界面反馈。
 * [OUTPUT]: 提供 ScreenGestures，统一触屏/指针/独立纵向滚动/滚轮/视野调整的点击、跟手滚动/可取消惯性、按住放大瞄准与缩放、拖动与取消。
 * [POS]: Web 的全屏手势仲裁器；不持有网络连接，取消路径永远不合成点击。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
class ScreenGestures {
  constructor(element, options) {
    this.el = element; this.o = options; this.points = new Map(); this.mode = 'touch'; this.lastTap = null;
    element.addEventListener('pointerdown', e => this.down(e));
    element.addEventListener('pointermove', e => {
      const samples = e.getCoalescedEvents?.() || [];
      for (const sample of samples.length ? samples : [e]) this.move(sample);
    });
    element.addEventListener('wheel', e => this.wheel(e), { passive: false });
    element.addEventListener('pointerup', e => this.up(e));
    element.addEventListener('pointercancel', () => this.cancel());
    element.addEventListener('lostpointercapture', e => { if (this.points.has(e.pointerId)) this.cancel(); });
    element.addEventListener('contextmenu', e => { if (this.o.active()) e.preventDefault(); });
  }
  setMode(mode) { this.cancel(); this.mode = mode; }
  arm(point) { this.cancel(); this.armed = point; this.armTimer = setTimeout(() => this.cancel(), 5000); }
  cancel() {
    this.o.aim?.(null);
    this.stopMomentum();
    clearTimeout(this.holdTimer); clearTimeout(this.armTimer); clearTimeout(this.wheelTimer);
    if (this.wheeling) { this.o.send({ t: 'scrollEnd' }); this.wheeling = false; }
    if (this.state === 'drag') this.o.send({ t: 'up' });
    if (this.state === 'scroll') this.o.send({ t: 'scrollEnd' });
    const ids = [...this.points.keys()]; this.points.clear();
    this.state = null; this.armed = null; this.lastTap = null;
    for (const id of ids) { try { this.el.releasePointerCapture(id); } catch {} }
    this.o.feedback('');
  }
  down(e) {
    if (!this.o.active() || e.button > 0) return;
    this.stopMomentum();
    e.preventDefault();
    if (this.o.dismissKeyboard?.() || this.state === 'dismiss') {
      this.state = 'dismiss'; this.points.set(e.pointerId, { x: e.clientX, y: e.clientY });
      this.el.setPointerCapture(e.pointerId); return;
    }
    if (!this.o.ready() && this.mode !== 'view') { this.o.feedback(this.o.blockedReason?.() || '画面或控制尚未就绪'); return; }
    const g = this.o.geometry, p = g.ratio(e.clientX, e.clientY);
    if (!p && !this.points.size && this.mode !== 'view') return;
    this.el.setPointerCapture(e.pointerId);
    this.points.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (this.points.size > 2) { this.cancel(); return; }
    if (this.points.size === 2) {
      this.o.aim?.(null);
      clearTimeout(this.holdTimer);
      if (this.state === 'drag') this.o.send({ t: 'up' });
      if (this.state === 'scroll') this.o.send({ t: 'scrollEnd' });
      this.lastTap = null; this.armed = null;
      this.state = 'two'; this.two = this.pair(); this.two.zoom = { ...g.zoom };
      this.two.at = performance.now(); this.two.last = this.two.mid; return;
    }
    this.start = { x: e.clientX, y: e.clientY, ...p, version: g.version, at: performance.now() };
    this.previous = { x: e.clientX, y: e.clientY };
    this.scrollVelocity = { x: 0, y: 0 }; this.scrollAt = e.timeStamp || performance.now();
    this.flingAllowed = e.pointerType === 'touch' || e.pointerType === 'pen';
    this.state = this.mode === 'view' ? 'view' : 'pending';
    this.o.touch?.(e.clientX, e.clientY);
    if (this.armed) {
      this.dragOrigin = this.armed; this.armed = null; clearTimeout(this.armTimer);
      this.state = 'drag'; this.absolute('down', this.dragOrigin); this.o.feedback('拖动中'); return;
    }
    if (this.mode === 'view' || this.mode === 'scroll') return;
    this.holdTimer = setTimeout(() => {
      if (this.state !== 'pending') return;
      this.lastTap = null;
      if (this.mode === 'touch') {
        this.state = 'aim'; this.aimPoint = { ...this.start };
        this.o.aim?.(this.aimPoint); this.o.feedback('微调位置，松手点击');
      } else {
        this.state = 'drag'; this.o.send({ t: 'down' }); this.o.feedback('拖动中');
      }
    }, 450);
  }
  pair() {
    const [a, b] = [...this.points.values()];
    return { mid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }, dist: Math.hypot(a.x - b.x, a.y - b.y) || 1 };
  }
  absolute(action, p, extra = {}) {
    return this.o.send({ t: 'pointer', action, ...p, display: this.o.display(), ...extra });
  }
  move(e) {
    if (!this.points.has(e.pointerId)) return;
    e.preventDefault();
    if (this.state === 'dismiss' || this.state === 'context') return;
    const g = this.o.geometry;
    this.points.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (this.points.size === 2) {
      const pair = this.pair(), t = this.two;
      const spread = Math.abs(pair.dist - t.dist), travel = Math.hypot(pair.mid.x - t.mid.x, pair.mid.y - t.mid.y);
      if (this.state === 'two') {
        if (spread >= Math.max(8, t.dist * .06)) this.state = 'pinch';
        else if (travel >= 10) this.state = ['pointer', 'scroll'].includes(this.mode) ? 'scroll' : 'pinch';
      }
      if (this.state === 'pinch') {
        g.transform(t.zoom, g.local(t.mid.x, t.mid.y), g.local(pair.mid.x, pair.mid.y), pair.dist / t.dist);
        this.o.paint();
      } else if (this.state === 'scroll') {
        const delta = this.mode === 'scroll' ? { x: 0, y: pair.mid.y - t.last.y } : g.vector(pair.mid.x - t.last.x, pair.mid.y - t.last.y);
        this.scroll(delta.x, delta.y, e.timeStamp || performance.now());
        this.o.interact();
      }
      t.last = pair.mid; return;
    }
    if (this.start && this.start.version !== g.version) { this.cancel(); return; }
    const delta = this.mode === 'scroll' ? { x: 0, y: e.clientY - this.previous.y } : g.vector(e.clientX - this.previous.x, e.clientY - this.previous.y);
    const dx = delta.x, dy = delta.y;
    if (this.state === 'aim') {
      const projected = g.project(this.aimPoint.rx, this.aimPoint.ry);
      const client = g.client(projected.x + dx / 3, projected.y + dy / 3);
      this.aimPoint = g.ratio(client.x, client.y, true);
      this.previous = { x: e.clientX, y: e.clientY }; this.o.aim?.(this.aimPoint); return;
    }
    if (this.state === 'pending') {
      if (Math.hypot(e.clientX - this.start.x, e.clientY - this.start.y) <= 8) return;
      clearTimeout(this.holdTimer); this.lastTap = null;
      this.state = this.mode !== 'pointer' ? 'scroll' : 'move';
      if (this.state === 'scroll') this.absolute('move', this.start);
    }
    if (this.state === 'view') {
      g.zoom.x += dx; g.zoom.y += dy; g.clamp(); this.o.paint();
    } else if (this.state === 'scroll') this.scroll(dx, dy, e.timeStamp || performance.now());
    else if (this.state === 'move') this.o.send({ t: 'move', dx: dx * this.o.sensitivity(), dy: dy * this.o.sensitivity() });
    else if (this.state === 'drag') {
      if (this.mode === 'touch') {
        const origin = g.project(this.dragOrigin.rx, this.dragOrigin.ry);
        const travel = g.vector(e.clientX - this.start.x, e.clientY - this.start.y);
        const client = g.client(origin.x + travel.x, origin.y + travel.y);
        this.absolute('drag', g.ratio(client.x, client.y, true));
      } else this.o.send({ t: 'drag', dx: dx * this.o.sensitivity(), dy: dy * this.o.sensitivity() });
    }
    this.previous = { x: e.clientX, y: e.clientY }; this.o.interact();
  }
  up(e) {
    if (!this.points.has(e.pointerId)) return;
    e.preventDefault(); clearTimeout(this.holdTimer);
    if (this.state === 'aim') this.move(e);
    const hadTwo = this.points.size === 2;
    this.points.delete(e.pointerId);
    if (hadTwo) {
      if (this.state === 'two' && this.mode === 'touch' && performance.now() - this.two.at < 350) this.o.context(this.start);
      if (this.state === 'two' && this.mode === 'pointer' && performance.now() - this.two.at < 350) {
        this.o.send({ t: 'click', button: 'right', clickState: 1 }); this.o.interact();
      }
      if (this.state === 'scroll') this.finishScroll(e.timeStamp || performance.now());
      this.state = this.mode === 'pointer' || this.state === 'scroll' ? 'dismiss' : 'view';
      this.previous = [...this.points.values()][0]; return;
    }
    if (this.state === 'aim') {
      if (this.o.ready()) this.absolute('click', this.aimPoint, { clickState: 1 });
      this.o.aim?.(null);
    }
    if (this.state === 'pending' && this.o.ready() && this.mode !== 'scroll') this.tap(e);
    if (this.state === 'drag') this.o.send({ t: 'up' });
    if (this.state === 'scroll') this.finishScroll(e.timeStamp || performance.now());
    this.state = null; this.o.feedback(''); this.o.interact();
    try { this.el.releasePointerCapture(e.pointerId); } catch {}
  }
  scroll(dx, dy, now) {
    const g = this.o.geometry;
    // 直接触摸按显示比例换算，手指移动与所见内容的移动接近一致。
    if (this.mode !== 'pointer' && g.base) {
      dx *= (g.display.width || g.base.width) / (g.base.width * g.zoom.scale);
      dy *= (g.display.height || g.base.height) / (g.base.height * g.zoom.scale);
    }
    const dt = now - this.scrollAt;
    if (dt > 0 && dt < 100) {
      const weight = 1 - Math.exp(-dt / 40);
      const limit = 3; // 远端逻辑像素/ms，避免异常采样放大甩动。
      this.scrollVelocity.x += (Math.max(-limit, Math.min(limit, dx / dt)) - this.scrollVelocity.x) * weight;
      this.scrollVelocity.y += (Math.max(-limit, Math.min(limit, dy / dt)) - this.scrollVelocity.y) * weight;
    } else if (dt >= 100) this.scrollVelocity = { x: 0, y: 0 };
    this.scrollAt = now;
    this.o.send({ t: 'scroll', dx, dy });
  }
  finishScroll(now) {
    const velocity = this.scrollVelocity || { x: 0, y: 0 };
    if (!this.flingAllowed || now - this.scrollAt > 90 || Math.hypot(velocity.x, velocity.y) < .12) {
      this.o.send({ t: 'scrollEnd' }); return;
    }
    // 按时间衰减，而非按帧衰减：60/120Hz 上滑行距离保持一致。
    const decayMs = 220, started = now;
    let last = now;
    const step = time => {
      if (!this.o.active() || !this.o.ready() || time - last > 100 || time - started > 1400) { this.stopMomentum(); return; }
      const dt = Math.max(0, time - last), decay = Math.exp(-dt / decayMs);
      const distance = decayMs * (1 - decay);
      if (!this.o.send({ t: 'scroll', dx: velocity.x * distance, dy: velocity.y * distance })) { this.stopMomentum(); return; }
      velocity.x *= decay; velocity.y *= decay; last = time; this.o.interact();
      if (Math.hypot(velocity.x, velocity.y) < .04) { this.stopMomentum(); return; }
      this.momentum = requestAnimationFrame(step);
    };
    this.momentum = requestAnimationFrame(step);
  }
  stopMomentum() {
    if (!this.momentum) return;
    cancelAnimationFrame(this.momentum); this.momentum = 0;
    this.o.send({ t: 'scrollEnd' });
  }
  wheel(e) {
    if (!this.o.active()) return;
    this.stopMomentum();
    e.preventDefault();
    if (!this.o.ready() || this.mode === 'view' || this.points.size || this.o.dismissKeyboard?.()) return;
    const p = this.o.geometry.ratio(e.clientX, e.clientY);
    if (!p) return;
    // 滚轮正方向与手指拖动相反；先定位到所查看内容，避免滚到另一台显示器。
    if (!this.wheeling) this.absolute('move', p);
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? this.el.clientHeight : 1;
    this.o.send({ t: 'scroll', dx: -e.deltaX * unit, dy: -e.deltaY * unit });
    this.wheeling = true; this.o.interact(); clearTimeout(this.wheelTimer);
    this.wheelTimer = setTimeout(() => { this.wheeling = false; this.o.send({ t: 'scrollEnd' }); }, 150);
  }
  tap(e) {
    const now = performance.now(), old = this.lastTap, g = this.o.geometry;
    const point = g.ratio(e.clientX, e.clientY);
    if (!point) return;
    const p = { ...this.start, ...point };
    const remote = old ? Math.hypot((p.rx - old.rx) * (g.display.width || 1920),
      (p.ry - old.ry) * (g.display.height || 1080)) : Infinity;
    const double = old && now - old.at < (this.o.doubleClickMs?.() || 350)
      && old.display === this.o.display() && old.version === g.version
      && Math.hypot(e.clientX - old.x, e.clientY - old.y) < 12
      && (this.mode === 'pointer' || remote < 8);
    this.lastTap = double ? null : { ...p, x: e.clientX, y: e.clientY, at: now, display: this.o.display() };
    if (this.mode === 'touch') this.absolute('click', p, { clickState: double ? 2 : 1 });
    else this.o.send({ t: 'click', clickState: double ? 2 : 1 });
  }
}
globalThis.ScreenGestures = ScreenGestures;
