/**
 * [INPUT]: Node VM 与隔离 DOM/网络模拟，加载正式 unlock.js。
 * [OUTPUT]: 验证明文阻断、提交清空、取消、一次提交不重试。
 * [POS]: tests 的锁屏凭据边界回归；不连接桌面或发送真实密码。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const {test}=require('node:test'), assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
function harness(https=true, responder=async()=>({ok:true,json:async()=>({challenge:'one',sent:true})})) {
 const elements={}; for(const id of ['unlock-form','unlock-password','unlock-note','unlock-submit']) elements[id]={value:'',hidden:false,disabled:false,handlers:{},blur(){},addEventListener(t,f){this.handlers[t]=f;}};
 const calls=[],sent=[];let owner=true;
 const window={isSecureContext:https,pocketdeskControlReady:()=>owner,pocketdeskControlInfo:()=>({session:'session'}),pocketdeskSend:m=>sent.push(m),addEventListener(){}};
 const context={window,location:{protocol:https?'https:':'http:'},document:{getElementById:id=>elements[id],addEventListener(){}},authHeaders:()=>({Authorization:'Bearer test'}),onWSMessage:f=>window.ws=f,AbortController,setTimeout,clearTimeout,fetch:async(path,options)=>{calls.push({path,body:options.body});return responder(path,options)}};
 vm.runInNewContext(fs.readFileSync('Web/unlock.js','utf8'),context);
 return {window,elements,calls,sent,submit:()=>elements['unlock-form'].handlers.submit({preventDefault(){}}),lose(){owner=false;window.ws({t:'control',controller:false});}};
}
test('HTTP 页面禁止密码请求',async()=>{const h=harness(false);h.window.pocketdeskLockState('locked');h.elements['unlock-password'].value='dummy';await h.submit();assert.equal(h.calls.length,0);assert.equal(h.elements['unlock-password'].hidden,true);});
test('HTTPS 单次挑战提交后清空且不重试',async()=>{const h=harness();h.window.pocketdeskLockState('locked');h.elements['unlock-password'].value='dummy';await h.submit();assert.equal(h.calls.length,2);assert.equal(JSON.parse(h.calls[1].body).password,'dummy');assert.equal(h.elements['unlock-password'].value,'');h.window.pocketdeskLockState('unlocked');assert.equal(h.elements['unlock-form'].hidden,true);});
test('准备期间失去控制权则清空并取消，不提交密码',async()=>{let resolve;const h=harness(true,()=>new Promise(r=>resolve=r));h.window.pocketdeskLockState('locked');h.elements['unlock-password'].value='dummy';const pending=h.submit();h.lose();resolve({ok:true,json:async()=>({challenge:'one'})});await pending;assert.equal(h.calls.length,1);assert.equal(h.elements['unlock-password'].value,'');assert.equal(h.sent[0].t,'unlock-cancel');});
test('关闭画面清空密码',()=>{const h=harness();h.window.pocketdeskLockState('locked');h.elements['unlock-password'].value='dummy';h.window.pocketdeskClearUnlock();assert.equal(h.elements['unlock-password'].value,'');});
test('服务拒绝不自动重试',async()=>{const h=harness(true,async()=>({ok:false,json:async()=>({error:'拒绝'})}));h.window.pocketdeskLockState('locked');h.elements['unlock-password'].value='dummy';await h.submit();assert.equal(h.calls.length,1);assert.equal(h.elements['unlock-password'].value,'');});
