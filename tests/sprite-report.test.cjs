/**
 * [INPUT]: vm 隔离的 sprite-report.js 与可控网络/控制连接替身。
 * [OUTPUT]: 验证连续输入不饥饿、串行上报、草稿合并、提交票据不可变、重连恢复和旧租约隔离。
 * [POS]: 展示链路回归；不联网、不执行任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
(async () => {
  const sent = [], pending = [], timers = new Map();
  let serial = 0, text = '旧草稿', connection = 'one', wsListener, heartbeat;
  const window = {
    pocketdeskControlState: () => 'ready',
    pocketdeskControlInfo: () => ({ session: connection })
  };
  vm.runInNewContext(fs.readFileSync('Web/sprite-report.js', 'utf8'), {
    window, Date, Math, AbortController,
    liveValue: () => text, authHeaders: () => ({}),
    onWSMessage: fn => { wsListener = fn; },
    setInterval: fn => { heartbeat = fn; },
    setTimeout: (fn, delay) => { timers.set(++serial, { fn, delay }); return serial; },
    clearTimeout: id => timers.delete(id),
    fetch: (_, options) => { sent.push(JSON.parse(options.body)); return new Promise(resolve => pending.push(resolve)); }
  });
  async function drain() {
    for (let i = 0; i < 30 && pending.length; i++) {
      pending.shift()({ ok: true }); await new Promise(resolve => setImmediate(resolve));
    }
  }
  function flushDraft() {
    window.pocketdeskSpriteDraft();
    window.pocketdeskSpriteDraft();
    assert.equal([...timers.values()].filter(t => t.delay === 150).length, 1, "连续输入共用同一个节流窗口");
    const timer = [...timers].find(([, t]) => t.delay === 150);
    timers.delete(timer[0]); timer[1].fn();
  }
  window.pocketdeskSpriteSelect();
  assert.equal(sent.length, 1, 'select 与草稿不能并发');
  text = '新版一'; flushDraft(); text = '新版二'; flushDraft();
  await drain();
  assert.equal(sent.filter(x => x.action === 'draft').length, 1);
  assert.equal(sent.at(-1).text, '新版二');
  const old = window.pocketdeskSpriteSubmitting('第一条');
  const next = window.pocketdeskSpriteSubmitting('第二条');
  window.pocketdeskSpriteSubmitted('old-task', old);
  await drain();
  assert.equal(sent.at(-1).version, old.version);
  assert.equal(sent.at(-1).requestId, old.requestId);
  assert.notEqual(old.requestId, next.requestId);
  connection = 'two'; wsListener({ t: 'auth_ok' }); await drain();
  assert.equal(sent.at(-1).session, 'two');
  assert.equal(sent.at(-1).text, '新版二');
  const count = sent.length;
  window.pocketdeskSpriteSubmitted('late', next); await drain();
  assert.equal(sent.length, count, '旧连接回执不能进入新连接');
  heartbeat(); await drain();
  assert.equal(sent.at(-1).action, 'heartbeat');
  window.pocketdeskSpriteDeselect(); await drain();
  const afterDeselect = sent.length;
  text = '普通应用正文'; flushDraft(); await drain();
  assert.equal(sent.length, afterDeselect);
  console.log('sprite report: 串行/合并/票据/重连/心跳/切走隔离全部通过');
})().catch(error => { console.error(error); process.exitCode = 1; });
