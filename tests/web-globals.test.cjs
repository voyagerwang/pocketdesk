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

console.log('web-globals: 全部断言通过');
