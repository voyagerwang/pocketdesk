/**
 * [INPUT]: 依赖 Node 的 fetch/WebSocket 与已运行的本机 PocketDesk。
 * [OUTPUT]: 验证安装资源、持续 JPEG 协议、呈现确认、背压超时与控制握手。
 * [POS]: tests 的真实服务只读冒烟；不移动鼠标、不注入键盘、不接管已有控制者，不保存画面。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const base = 'http://127.0.0.1:46387';
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function control() {
  const ws = new WebSocket('ws://127.0.0.1:46388');
  const auth = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('control handshake timeout')), 3000);
    ws.onopen = () => ws.send(JSON.stringify({ t:'auth', v:1, token:'' }));
    ws.onmessage = ({data}) => { const m=JSON.parse(data); if(m.t==='auth_ok'){clearTimeout(timer);resolve(m);} };
    ws.onerror = () => { clearTimeout(timer); reject(Error('control connection failed')); };
  });
  const timer = setInterval(() => { if(ws.readyState===1) ws.send(JSON.stringify({t:'heartbeat'})); }, 400);
  return {ws,auth,close(){clearInterval(timer);ws.close();}};
}
(async()=>{
  const status = await (await fetch(base+'/api/status')).json();
  assert.equal(status.accessibility,true);
  const listing = await (await fetch(base+'/api/screen/displays')).json();
  assert.ok(listing.displays?.length);
  const html=await(await fetch(base)).text(); assert.ok(html.includes('3.0.0'));
  const first=await control(), second=await control();
  assert.equal(second.auth.controller,false,'额外客户端应先观看');
  second.close(); await sleep(200);
  assert.equal(first.ws.readyState,1,'观看者退出不能关闭控制连接');
  first.close();
  const frames=[], latencies=[];
  const ws=new WebSocket(`ws://127.0.0.1:${listing.streamPort}`); ws.binaryType='arraybuffer';
  let acknowledge=true, failure;
  ws.onopen=()=>ws.send(JSON.stringify({t:'watch',token:'',display:listing.displays[0].id,width:1280}));
  ws.onerror=()=>{failure=Error('stream connection failed');};
  ws.onmessage=({data})=>{
    try {
      const bytes=new Uint8Array(data), length=new DataView(data).getUint32(0);
      const meta=JSON.parse(new TextDecoder().decode(bytes.slice(4,4+length)));
      assert.equal(meta.display,listing.displays[0].id); assert.equal(meta.cursorIncluded,false);
      assert.equal(bytes[4+length],255); assert.equal(bytes[5+length],216);
      assert.ok(meta.ageMs<1500 && meta.width<=1280);
      frames.push({at:performance.now(),ageMs:meta.ageMs,bytes:bytes.length});
      if(acknowledge) ws.send(JSON.stringify({t:'presented',frameId:meta.frameId}));
    } catch(e) {failure=e;ws.close();}
  };
  for(let i=0;i<24;i++) {
    await sleep(500);
    const start=performance.now(); const r=await fetch(base+'/api/status'); assert.equal(r.status,200);
    await r.arrayBuffer(); latencies.push(performance.now()-start);
    if(failure) throw failure;
  }
  assert.ok(frames.length>=3,`持续捕获帧不足：${frames.length}`);
  acknowledge=false; const before=frames.length; await sleep(3800);
  assert.ok(frames.length-before<=1,'未确认时不能堆积画面');
  assert.equal(ws.readyState,3,'呈现超时应关闭画面连接');
  console.log(JSON.stringify({result:'passed',display:listing.displays[0],frames:frames.length,
    observedFPS:+((frames.length-1)/((frames.at(-1).at-frames[0].at)/1000)).toFixed(2),
    maxFrameAgeMs:+Math.max(...frames.map(f=>f.ageMs)).toFixed(1),
    meanJpegKB:Math.round(frames.reduce((n,f)=>n+f.bytes,0)/frames.length/1024),
    maxStatusResponseMs:+Math.max(...latencies).toFixed(1),noAckCloses:true},null,2));
})().catch(e=>{console.error(e);process.exit(1)});
