/**
 * [INPUT]: 只读 Web/*.js、Web/index.html 与 Sources/Server.swift 的静态文本，不起服务、不连电脑。
 * [OUTPUT]: 静态结构回归，验证跨弹窗恢复协议（冻结态只发只读探测、恢复上限有界、绝不重放正文、翻腕门禁）、
 *           应用选择定位意图（locate/generation 与迟到回执隔离）、以及证书四步向导（下载/安装/完全信任/真探测）都已落地。
 * [POS]: tests 的前端契约回归；真实弹窗与真机行为另行验收。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');

const compose = read('Web/compose.js');
const app = read('Web/app.js');
const settings = read('Web/settings.js');
const motion = read('Web/motion-send.js');
const html = read('Web/index.html');
const server = read('Sources/Server.swift');

/* ---------- 跨弹窗恢复协议 ---------- */

// 1) 冻结后只发只读探测：probe 请求必须显式带上 probe: true。
assert.ok(/probe:\s*true/.test(compose), "compose.js 必须发出只读探测（probe: true）");
// 2) 只读探测函数体内不得出现任何写入动作——恢复绝不能靠重放正文。
const probeBody = compose.slice(compose.indexOf('async function probeLive'),
                                compose.indexOf('function scheduleLive', compose.indexOf('async function probeLive')));
assert.ok(probeBody.length > 0, ' 找不到 probeLive 函数体');
for (const forbidden of ['pushLive(', 'flushLive(', 'liveQueue.push(']) {
  assert.ok(!probeBody.includes(forbidden), `只读探测不得调用 ${forbidden}（那就是重放正文）`);
}
assert.ok(/result\.state === 'recoverable'/.test(probeBody), '探测必须只认服务端的 recoverable 才解除冻结');
assert.ok(/liveValue\(\) !== ''/.test(probeBody) && /scheduleLive\(\)/.test(probeBody),
  '恢复后应走正常同步（差分），而不是自行重发');

// 3) 结构化状态来自服务端，前端不得靠解析人话文案决策。
assert.ok(/error\.state = result\.state/.test(compose), '失败回执必须带出服务端 state');
assert.ok(/liveState = error\.state \|\| 'interrupted'/.test(compose), '失败后必须进入 interrupted 冻结态');
assert.ok(/function liveStateNote\(/.test(compose), '人类文案应集中在边界层 liveStateNote');

// 4) 恢复探测有界：不允许无休止轮询。
assert.ok(/RECOVERY_MAX_ATTEMPTS/.test(compose) && /recoveryAttempts >= RECOVERY_MAX_ATTEMPTS/.test(compose),
  '低频探测必须有次数上限');
// 4b) 恢复链必须能自我续期。probeLive 内部续期时 liveProbing 仍为 true，
//     若 scheduleProbe 这时直接 return，恢复链会在**第一次探测之后**断开——
//     症状就是"弹窗关掉了、手机也回前台了，但只有切一次应用才能恢复"。真机回归抓到的缺陷。
assert.ok(/if \(liveProbing\) \{ recoveryPending = true; recoveryPendingDelay = delay; return; \}/.test(compose),
  'scheduleProbe 在探测进行中必须登记待排期，不能直接丢弃续期请求');
assert.ok(/if \(recoveryPending\) \{/.test(compose) && /scheduleProbe\(delay\);/.test(compose),
  'probeLive 收尾必须补排被登记的探测');
const stopBody = compose.slice(compose.indexOf('function stopRecovery'),
                              compose.indexOf('function scheduleProbe'));
assert.ok(/recoveryPending = false/.test(stopBody) && /recoveryPendingDelay = 0/.test(stopBody),
  'stopRecovery 必须清空待排期，避免恢复成功后误续期');
// 4c) 状态提示必须有落点：paintLive 写 #live-flag，页面里却不存在该元素时
//     "已同步 / 已恢复同步"会静默消失，用户无从判断实时同步到底有没有在跑。
assert.ok(/<div id="live-flag"/.test(html), 'index.html 必须提供 #live-flag 作为实时同步状态落点');
assert.ok(/getElementById\('live-flag'\)|querySelector\('#live-flag'\)/.test(compose),
  'compose.js 必须把同步状态写到 #live-flag');
// 5) 恢复触发来源：页面回前台、窗口聚焦、输入框重新聚焦。
for (const event of ["'visibilitychange'", "'focus'", "'focusin'"]) {
  assert.ok(compose.includes(`addEventListener(${event}`), `缺少恢复触发来源 ${event}`);
}
// 6) 中断/探测/提交收尾中，翻腕候选一律不发。
assert.ok(/if \(livePaused \|\| liveProbing\) return false/.test(compose),
  '翻腕门禁必须挡掉冻结与探测中的候选');

// 7) 下一轮首字允许短暂等待编辑器出现，但必须有上限。
assert.ok(/CONTEXT_RETRY_LIMIT/.test(compose) && /remaining > 0/.test(compose),
  '输入位置绑定需要有上限的重试，让新编辑器出现后自动绑定');

/* ---------- 应用选择后鼠标就位 ---------- */

assert.ok(/let selectGeneration = 0/.test(app), 'app.js 必须维护选择代际');
assert.ok(/body: JSON\.stringify\(\{ targetId, locate, generation \}\)/.test(app),
  '激活请求必须带上定位意图与代际');
assert.ok(/if \(generation !== selectGeneration\) return false;/.test(app),
  '迟到的激活/定位回执不得改动面板、提示或草稿');
assert.ok(/activateTarget\(selected, true\)/.test(app), '只有手动选择应用才请求鼠标就位');
assert.ok(!/async function activateTarget\(targetId, locate = true\)/.test(app),
  '定位意图默认必须关闭，以兼容旧调用点');

// 服务端：定位必须有控制租约，且激活结果与定位结果分开回报。
assert.ok(/command\.locate == true/.test(server) && /controlAuthorized\(session\)/.test(server),
  '服务端必须在控制租约下才允许定位');
assert.ok(/private func performLocate\(/.test(server), '服务端需要有独立的定位编排');
for (const outcome of ['"moved"', '"unchanged"', '"skipped"', '"locateReason"']) {
  assert.ok(server.includes(outcome), `定位回执必须区分 ${outcome}`);
}
assert.ok(/var pointerExecutor: PointerExecutor\?/.test(server),
  '鼠标注入只能经 PointerExecutor，且由装配处注入');
// 定位实现里不得自己发鼠标事件——注入必须留在 PointerExecutor 的同一条队列上。
const locateBody = server.slice(server.indexOf('private func performLocate'),
                                server.indexOf('private func respond', server.indexOf('private func performLocate')));
assert.ok(locateBody.length > 0, '找不到 performLocate 函数体');
assert.ok(!/CGEvent\(mouseEventSource|\.post\(tap:/.test(locateBody),
  'performLocate 不得自行注入鼠标事件，必须交给 PointerExecutor');
assert.ok(/pointer\.locate\(to: point, generation: generation, anchor: anchor\)/.test(locateBody),
  '定位必须经 PointerExecutor.locate 并带上代际与锚点');

/* ---------- 证书四步向导 ---------- */

assert.ok(/① 安装 PocketDesk 证书/.test(settings), '向导必须有第①步：可点下载');
assert.ok(/VPN 与设备管理/.test(settings), '向导必须说明描述文件安装路径（下载≠安装）');
assert.ok(/证书信任设置/.test(settings) && /PocketDesk Local Device CA/.test(settings),
  '向导必须说明开启完全信任，且用证书实际名称');
assert.ok(/④ 检测并打开安全连接/.test(settings), '向导必须有第④步：先检测再跳转');
assert.ok(/window\.pocketdeskMotion\.probeSecure/.test(settings), '第④步必须用真实 HTTPS 探测');
assert.ok(!/target = '_blank'[\s\S]{0,120}secureURL/.test(settings), '不再直接引导用户跳进可能不受信任的 HTTPS 页');
assert.ok(/证书通常只需设置一次/.test(settings), '向导必须说明证书通常只需设置一次');
assert.ok(/运动与方向权限是另一件事/.test(settings), '证书信任与运动权限必须作为两件事解释');

// 探测器本身：真实握手 + 四种失败分流。
assert.ok(/probeSecure: probeSecure/.test(motion), 'probeSecure 必须对外暴露');
for (const code of ['server-unreachable', 'https-not-started', 'host-mismatch', 'not-trusted']) {
  assert.ok(motion.includes(`'${code}'`), `探测器缺少分流分支 ${code}`);
}
assert.ok(/fetchWithTimeout\('https:\/\/'/.test(motion), '必须真的去握一次 HTTPS，而不是伪造结果');

// 证书下载仍走 HTTP 也能取到的路径（信任之前只有 HTTP）。
assert.ok(/CA_CERT_PATH = '\/PocketDesk-CA\.cer'/.test(motion), 'CA 下载路径必须保持 HTTP 可达');

/* ---------- 页面引用（改过的资源必须换版本号，否则手机会用缓存） ---------- */

for (const asset of ['app.js?v=3.0.24', 'settings.js?v=3.0.6', 'compose.js?v=3.0.26',
                     'motion-send.js?v=3.0.4', 'app-extras.css?v=3.0.6', 'screen.css?v=3.1.1']) {
  assert.ok(html.includes(asset), `index.html 应引用 ${asset}`);
}
assert.ok(server.includes('"compose.js"') && server.includes('"settings.js"') && server.includes('"motion-send.js"'),
  'Server.swift 静态白名单必须仍然放行这些脚本');

console.log('live recovery: 冻结/只读探测/有界恢复/不重放正文、定位意图与代际隔离、证书四步向导 全部通过');
