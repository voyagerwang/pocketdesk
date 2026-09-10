/**
 * [INPUT]: 消费视口矩形、图片尺寸和显示器逻辑尺寸，不读取 DOM。
 * [OUTPUT]: 提供 ScreenGeometry 的适应、含横屏旋转的正反投影/位移换算、锚点缩放和边界夹取。
 * [POS]: Web 画面的纯几何边界；手势与光标共享同一实例，CSS 像素不混入 Retina 倍率。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
class ScreenGeometry {
  constructor() { this.zoom = { scale: 1, x: 0, y: 0 }; this.version = 0; }
  measure(viewport, width, height, display = {}, rotated = false) {
    this.viewport = viewport; this.rotated = rotated;
    const view = rotated ? { left: viewport.left, top: viewport.top, width: viewport.height, height: viewport.width } : viewport;
    this.view = view;
    this.display = display;
    const fit = Math.min(view.width / width, view.height / height);
    this.base = { width: width * fit, height: height * fit };
    this.base.x = (view.width - this.base.width) / 2;
    this.base.y = (view.height - this.base.height) / 2;
    this.version++;
    this.clamp();
  }
  local(x, y) {
    const p = this.viewport;
    return this.rotated ? { x: y - p.top, y: p.width - (x - p.left) } : { x: x - p.left, y: y - p.top };
  }
  client(x, y) {
    const p = this.viewport;
    return this.rotated ? { x: p.left + p.width - y, y: p.top + x } : { x: p.left + x, y: p.top + y };
  }
  vector(x, y) { return this.rotated ? { x: y, y: -x } : { x, y }; }
  ratio(x, y, clamp = false) {
    if (!this.base || !Number.isFinite(x + y) || !this.base.width || !this.base.height) return null;
    const p = this.local(x, y), z = this.zoom, b = this.base;
    const rx = ((p.x - z.x) / z.scale - b.x) / b.width;
    const ry = ((p.y - z.y) / z.scale - b.y) / b.height;
    if (!clamp && (rx < 0 || rx > 1 || ry < 0 || ry > 1)) return null;
    return { rx: Math.max(0, Math.min(1, rx)), ry: Math.max(0, Math.min(1, ry)) };
  }
  project(rx, ry) {
    const b = this.base, z = this.zoom;
    return { x: (b.x + rx * b.width) * z.scale + z.x, y: (b.y + ry * b.height) * z.scale + z.y };
  }
  clamp() {
    if (!this.base || !this.view) return;
    const b = this.base, v = this.view, z = this.zoom;
    z.scale = Math.max(1, Math.min(6, z.scale));
    for (const [axis, size] of [['x', 'width'], ['y', 'height']]) {
      const extent = b[size] * z.scale;
      z[axis] = extent <= v[size] ? (v[size] - extent) / 2 - b[axis] * z.scale
        : Math.max(v[size] - extent, Math.min(0, b[axis] * z.scale + z[axis])) - b[axis] * z.scale;
    }
  }
  transform(start, origin, current, factor) {
    const scale = Math.max(1, Math.min(6, start.scale * factor));
    this.zoom = { scale, x: current.x - (origin.x - start.x) / start.scale * scale,
      y: current.y - (origin.y - start.y) / start.scale * scale };
    this.clamp();
  }
  reset() { this.zoom = { scale: 1, x: 0, y: 0 }; this.clamp(); this.version++; }
}
globalThis.ScreenGeometry = ScreenGeometry;
