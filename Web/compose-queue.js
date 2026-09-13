/**
 * [INPUT]: 消费异步文本写入函数；请求包含目标、正文与是否提交。
 * [OUTPUT]: 提供 ComposeQueue；生命周期取消以 ComposeCancelledError 拒绝，写入失败仍传播真实错误；合并同草稿快照，提交独立完成；前次失败时仅保留已排队的同草稿显式删除，并要求核验恢复。
 * [POS]: Web 输入的顺序边界；首页和全屏共用，不包含 DOM 或输入法逻辑。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
class ComposeQueue {
  constructor(write) { this.write = write; this.pending = []; this.running = false; }
  push(value) {
    return new Promise((resolve, reject) => {
      const tail = this.pending.at(-1);
      if (!value.submit && tail && !tail.value.submit && tail.value.targetId === value.targetId
          && tail.value.draftId === value.draftId && tail.value.contextPromise === value.contextPromise) {
        tail.value = value; tail.waiters.push({ resolve, reject });
      } else this.pending.push({ value, waiters: [{ resolve, reject }] });
      this.drain();
    });
  }
  clear(reason = '输入位置已变化，请重新确认', cancelled = true) {
    const error = new Error(reason);
    if (cancelled) error.name = 'ComposeCancelledError';
    for (const item of this.pending.splice(0)) for (const w of item.waiters) w.reject(error);
  }
  async drain() {
    if (this.running) return;
    this.running = true;
    while (this.pending.length) {
      const item = this.pending.shift();
      try { const result = await this.write(item.value); for (const w of item.waiters) w.resolve(result); }
      catch (error) {
        for (const w of item.waiters) w.reject(error);
        // 用户已要求删除，而前一次落字的失败回执此刻才到。保留这次删除意图，
        // 交由服务端核验原草稿；绝不重放失败的写入，也不跨目标恢复。
        const deletion = this.pending.at(-1);
        const canReconcile = deletion?.value.reconcileOnFailure && !deletion.value.submit
          && deletion.value.draftId === item.value.draftId && deletion.value.targetId === item.value.targetId
          && deletion.value.contextPromise === item.value.contextPromise;
        if (canReconcile) this.pending.pop();
        this.clear('前次输入未完成，请确认电脑内容后继续', false);
        if (canReconcile) { deletion.value.retry = true; this.pending.push(deletion); }
      }
    }
    this.running = false;
  }
}
globalThis.ComposeQueue = ComposeQueue;
