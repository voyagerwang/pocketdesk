/**
 * [INPUT]: 依赖 Node 内建断言与文件系统，读取 Web/index.html、Web/pad.js、Web/compose.js、Web/motion-send.js、Web/screen.js。
 * [OUTPUT]: 锁定 window.pocketdeskSend 的唯一归属（pad.js 的画面/指针指令通道）与 compose 的独立发送入口
 *           pocketdeskComposeSend，并确认安卓专属的输入补丁不会作用到 iOS。
 * [POS]: tests 的静态结构回归；不启动服务、不发网络请求、不注入系统事件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const read = file => fs.readFileSync(path.join(root, 'Web', file), 'utf8');
const html = read('index.html');
const compose = read('compose.js');
const motion = read('motion-send.js');
const screen = read('screen.js');

// 1) window.pocketdeskSend 只能由 pad.js 写：screen.js 的画面/指针指令全靠它。
//    历史上 compose.js 占用过这个名字，导致画面里每次点按/滚动/订阅光标都变成“发送草稿”。
const writers = ['pad.js', 'compose.js', 'app.js', 'settings.js', 'screen.js', 'motion-send.js']
  .filter(file => /window\.pocketdeskSend\s*=/.test(read(file)));
assert.deepEqual(writers, ['pad.js'], `window.pocketdeskSend 应只由 pad.js 赋值，实际：${writers.join(', ')}`);

// 2) compose 的发送入口必须另起名字，且 motion-send 真的用它。
assert.ok(/window\.pocketdeskComposeSend\s*=\s*send\b/.test(compose), 'compose.js 应以 pocketdeskComposeSend 暴露 send()');
assert.ok(/window\.pocketdeskComposeSend\b/.test(motion), 'motion-send.js 应通过 pocketdeskComposeSend 发送');
assert.ok(!/window\.pocketdeskSend\s*\(/.test(motion), 'motion-send.js 不得调用 window.pocketdeskSend');

// 3) screen.js 仍按 pad 语义使用该全局：改名会静默打断画面控制，属高危回归。
assert.ok(screen.includes('window.pocketdeskSend(command)'), 'screen.js 的画面指令仍应走 window.pocketdeskSend');

// 4) 加载顺序：pad.js 必须先于 compose.js，否则后加载者仍可能覆盖同名全局。
const padAt = html.indexOf('/pad.js');
const composeAt = html.indexOf('/compose.js');
assert.ok(padAt > 0 && composeAt > 0 && padAt < composeAt, 'index.html 中 pad.js 必须先于 compose.js 加载');

// 5) 安卓专属输入补丁必须在 iOS 上关闭：三处都会 blur/focus 编辑框，
//    iPhone 上听写/输入法会因此把同一段内容再落一遍（表现为重复输入）。
assert.ok(/const androidInputPatch = \/Android\/i\.test\(navigator\.userAgent\)/.test(compose), 'compose.js 应有 Android 平台判定');
const guards = (compose.match(/androidInputPatch/g) || []).length;
assert.ok(guards >= 5, `Android 平台判定应覆盖定义与四处调用点（>=5），实际 ${guards}`);
assert.ok(/function releaseStaleFocus[\s\S]{0,240}!androidInputPatch/.test(compose), 'releaseStaleFocus 必须只在 Android 生效');
assert.ok(/if \(androidInputPatch && was > 0 && el\.value === ''\)/.test(compose), '「上滑清空」重建必须只在 Android 生效');
assert.ok(/if \(androidInputPatch && el\.isConnected/.test(compose), 'beforeinput 探针重建必须只在 Android 生效');
assert.ok(/if \(!androidInputPatch \|\| submittingDraft \|\| liveComposing\) return;/.test(compose), '补聚焦必须在非 Android 或组合态下退出');

// 6) 心跳失败必须按原因分流：全站只有一处会宣布"与电脑断连"，且它必须区分
//    配对失效 / 手机离线 / 电脑端 HTTP 异常 / 页面脚本出错。历史上这四种原因共用
//    一句话（"请确认同一 Wi-Fi，或重新扫码"），于是 401 与 Wi-Fi 抖动长得一模一样，
//    用户被引到错误的排查方向。
const app = read('app.js');
assert.ok(/function heartbeatAdvice\(/.test(app), 'app.js 应有心跳失败分类器 heartbeatAdvice');
assert.ok(/error\.httpStatus === 401/.test(app), '401（配对失效）必须与其它失败分开报');
assert.ok(/navigator\.onLine === false/.test(app), '手机离线必须单独报，而不是说成电脑断链');
assert.ok(/error && !error\.isNetwork/.test(app), '页面脚本错误必须与网络错误分开（非网络问题别说成断链）');
assert.ok(/function taggedFetch\(/.test(app), 'fetch 失败要被标记 isNetwork，否则分不出网络错与脚本错');
assert.ok(!/与电脑的连接已断开/.test(app), '含糊的"与电脑的连接已断开"文案应已淘汰，改按原因分别陈述');
// 恢复要快：失败后有补拍节拍，且必须在成功时取消、退后台时取消，避免定时器堆积。
assert.ok(/HEARTBEAT_RETRY_MS = 1200/.test(app), '失败后应有 1.2 秒补拍节拍');
assert.ok(/function scheduleHeartbeatRetry\(/.test(app) && /function cancelHeartbeatRetry\(/.test(app), '补拍定时器需要成对的调度与取消');
assert.ok(/heartbeatFailures = 0;\s*cancelHeartbeatRetry\(\);/.test(app), '心跳成功必须取消补拍，否则残留定时器会持续打服务端');
// 断连时长要出现在恢复提示里：否则用户无法判断"刚才到底断没断"。
assert.ok(/已重新连接到电脑（中断 \$\{humanGap\(gap\)\}）/.test(app), '恢复提示应报出中断时长');
assert.ok(/\/app\.js\?v=\d+\.\d+\.\d+/.test(html), 'index.html 必须给 app.js 带版本号（版本号策略与逐资源校验在 live-recovery.test.cjs）');

console.log('web-globals: 全部断言通过');
