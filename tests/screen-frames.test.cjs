/**
 * [INPUT]: 依赖 Node vm/断言与真实 ScreenFrames，注入虚拟时钟、HTTP/WS 替身。
 * [OUTPUT]: 验证瞬断容忍、错误归因、退避、流恢复、停止与迟到回包隔离。
 * [POS]: tests 的画面传输故障回归，不访问真实网络或桌面。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
function setup() {
  let now = 100, id = 0, reply = async () => ({ok:true, blob:async()=>new Blob(['jpeg'])});
  const timers = new Map(), notices = [], sockets = [];
  class Socket {
    constructor() { sockets.push(this); }
    send() {} close() { this.closed = true; }
  }
  const context = vm.createContext({ AbortController, Blob, ArrayBuffer, DataView, TextDecoder,
    Date, performance:{now:()=>now}, navigator:{onLine:true}, location:{protocol:'http:',hostname:'test'},
    authHeaders:()=>({}), pairToken:()=>'', WebSocket:Socket,
    setTimeout:(fn, ms)=>{timers.set(++id,{fn,at:now+ms});return id;}, clearTimeout:id=>timers.delete(id),
    fetch:(...args)=>reply(...args) });
  vm.runInContext(fs.readFileSync('Web/screen-frames.js','utf8'),context);
  const f = new context.ScreenFrames({present:async()=>{},state:(...args)=>notices.push(args)});
  const flush = async()=>{for(let i=0;i<20;i++)await Promise.resolve();};
  return {f,notices,sockets,context,timers,flush,reply:fn=>{reply=fn;},
    async advance(ms) { now+=ms;const due=[...timers].filter(([,t])=>t.at<=now);for(const [key,t] of due){if(timers.delete(key))t.fn();}await flush(); } };
}
(async()=>{
  const h=setup();h.f.start(1,false,0);await h.flush();assert.ok(h.f.fresh());
  h.reply(async()=>{throw new TypeError('Failed to fetch');});
  await h.advance(1000);assert.equal(h.notices.length,1,'一次瞬断不新增提示');
  assert.equal(h.f.diagnose().lastFailure.kind,'network');
  const due=h.f.due;h.f.interact();assert.equal(h.f.due,due,'交互不能破坏退避');
  await h.advance(5000);assert.equal(h.notices.at(-1)[0],'画面正在恢复…');
  assert.equal(!!h.f.fresh(),false,'静默窗口不放宽陈旧画面的控制门禁');
  await h.advance(10000);assert.match(h.notices.at(-1)[0],/持续中断/);
  const count=h.notices.length;await h.advance(4000);assert.equal(h.notices.length,count,'相同提示不重复发布');
  h.reply(async()=>({ok:true,blob:async()=>new Blob(['jpeg'])}));
  await h.advance(4000);assert.equal(h.notices.at(-1)[0],'');assert.equal(h.f.failures,0);
  h.f.stop();const epoch=h.f.epoch;h.f.interact();await h.advance(30000);assert.equal(h.f.epoch,epoch);assert.equal(h.timers.size,0);

  for(const status of [401,422,503]) {
    const t=setup();t.reply(async()=>({ok:false,status,json:async()=>({error:'屏幕权限缺失'})}));
    t.f.start(1,false,0);await t.flush();
    assert.equal(t.f.diagnose().lastFailure.status,status);
    if(status===503) assert.equal(t.notices.length,0); else assert.match(t.notices[0][0],status===401?/重新扫码/:/权限/);
    t.f.stop();
  }
  const timeout=setup();timeout.reply((url,{signal})=>new Promise((resolve,reject)=>signal.addEventListener('abort',()=>reject(Object.assign(new Error(),{name:'AbortError'})))));
  timeout.f.start(1,false,0);await timeout.advance(6000);assert.equal(timeout.f.diagnose().lastFailure.kind,'timeout');assert.equal(timeout.notices.at(-1)[0],'画面正在恢复…');timeout.f.stop();

  const stale=setup();let reject;stale.reply(()=>new Promise((_,r)=>{reject=r;}));
  stale.f.start(1,false,0);stale.f.stop();reject(new TypeError('Failed to fetch'));await stale.flush();assert.equal(stale.notices.length,0);assert.equal(stale.timers.size,0);

  const stream=setup();stream.f.start(1,true,46389);await stream.flush();assert.equal(stream.sockets.length,1);
  const old=stream.sockets[0];old.onerror();await stream.advance(0);assert.equal(stream.f.failed,true);assert.match(stream.notices.at(-1)[0],/省流画面/);
  await stream.advance(10000);assert.equal(stream.sockets.length,2,'降级后自动尝试恢复流');
  old.onerror();assert.equal(stream.f.socket,stream.sockets[1],'旧 socket 不能打断新连接');
  const meta=Buffer.from(JSON.stringify({display:1,ageMs:0,frameId:1}));
  const bytes=new ArrayBuffer(4+meta.length+1);new DataView(bytes).setUint32(0,meta.length);new Uint8Array(bytes).set(meta,4);
  await stream.sockets[1].onmessage({data:bytes});assert.equal(stream.f.failed,false);assert.equal(stream.notices.at(-1)[0],'');
  stream.f.stop();await stream.advance(30000);assert.equal(stream.timers.size,0);
  console.log('screen-frames: passed');
})().catch(e=>{console.error(e);process.exitCode=1;});
