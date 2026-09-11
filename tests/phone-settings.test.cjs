/**
 * [INPUT]: 依赖 Node 内建断言与文件系统，读取 Web/index.html、Web/settings.js 与 Sources/Server.swift。
 * [OUTPUT]: 验证手机设置只有一个入口、触控板内无齿轮、三个旧控件 ID 与存储键未复制第二份、翻腕默认关闭且只留授权与灵敏度、新脚本已进入静态白名单、需要用户动手的步骤一律是可点链接（控制台地址与手机端证书/安全地址，且地址不再以散文形式出现）。
 * [POS]: tests 的静态结构回归；不启动服务、不发网络请求、不注入系统事件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'Web/index.html'), 'utf8');
const settings = fs.readFileSync(path.join(root, 'Web/settings.js'), 'utf8');
const server = fs.readFileSync(path.join(root, 'Sources/Server.swift'), 'utf8');

// 首页设置入口总数必须为 1：触控板内部、发送行、全屏 HUD 都不得再出现齿轮或体感开关。
const entryIds = ['phone-settings-open', 'pad-settings'];
const presentEntries = entryIds.filter(id => html.includes(`id="${id}"`));
assert.deepEqual(presentEntries, ['phone-settings-open'], `设置入口应只剩 header 一个，实际：${presentEntries.join(', ')}`);
assert.equal((html.match(/class="gear-btn"/g) || []).length, 1, 'header 齿轮只能有一个');

// 触控板区块内不得残留设置节点。
const padSection = html.slice(html.indexOf('id="pad"'), html.indexOf('class="compose"'));
assert.ok(!padSection.includes('gear-btn'), '触控板内不应再有齿轮');
assert.ok(!padSection.includes('pad-tuning'), '触控板内不应再挂 .pad-tuning');

// 三个既有控件整迁：ID 唯一、范围与默认值不变。
for (const [id, attrs] of [
  ['sens', 'min="0.6" max="3" step="0.1" value="1.5"'],
  ['scroll-speed', 'min="0.5" max="4" step="0.1" value="1.5"'],
]) {
  assert.equal((html.match(new RegExp(`id="${id}"`, 'g')) || []).length, 1, `#${id} 应唯一存在`);
  assert.ok(html.includes(attrs), `#${id} 的范围与默认值不应被改动`);
}
assert.equal((html.match(/id="ruler-mode"/g) || []).length, 1, '#ruler-mode 应唯一存在');

// 存储键仍在 pad.js，不在 settings.js 复制第二份；翻腕偏好只存用户意愿。
assert.ok(/localStorage\.setItem\('pd-sens'/.test(fs.readFileSync(path.join(root, 'Web/pad.js'), 'utf8')));
assert.ok(!settings.includes("'pd-sens'"), 'settings.js 不应复制触控板偏好');
assert.ok(settings.includes("'pd-motion-send'"), '翻腕偏好应有独立版本化存储键');
assert.ok(settings.includes('MOTION_PREF_VERSION'), '翻腕偏好必须带版本号');
assert.ok(!/localStorage\.setItem\([^)]*'已授权'|localStorage\.setItem\([^)]*'ready'/.test(settings),
  '不得持久化授权态或运行态');

// 面板契约：原生 dialog、遮罩关闭、Esc 后焦点恢复、翻腕默认关闭。
assert.ok(/<dialog id="phone-settings"/.test(html), '设置面板应为原生 dialog');
assert.ok(settings.includes('showModal'), '应使用 showModal 以获得焦点限制与 Esc 关闭');
assert.ok(/event\.target === settingsDialog/.test(settings), '遮罩点击应按 dialog 自身判定，避免穿透');
assert.ok(settings.includes("addEventListener('close'"), '关闭后应恢复焦点');
assert.ok(/id="wrist-toggle"[^>]*>/.test(html) && !/id="wrist-toggle"[^>]*checked/.test(html),
  '翻腕开关默认必须关闭');
assert.ok(!/id="wrist-toggle"[^>]*disabled/.test(html),
  '翻腕开关不应写死 disabled：用户尝试开启后才就地说明原因');

// 翻腕练习已移除：页面不留按钮/读数条/仪表，控制器不再暴露练习通道。
const motionSend = fs.readFileSync(path.join(root, 'Web/motion-send.js'), 'utf8');
for (const gone of ['wrist-practice', 'wrist-meter', 'wrist-meter-fill', 'wrist-meter-mark', 'wrist-gauge', 'wrist-angle', 'wrist-meta', 'wrist-status']) {
  assert.ok(!html.includes(gone), `练习相关节点 ${gone} 应已从页面移除`);
}
assert.ok(!fs.readFileSync(path.join(root, 'Web/app-extras.css'), 'utf8').includes('wrist-meter'),
  '练习仪表样式应一并删除');
for (const gone of ['startPractice', 'stopPractice', 'isPracticing', 'onSample']) {
  assert.ok(!motionSend.includes(gone), `motion-send.js 不应再保留练习通道 ${gone}`);
}
assert.ok(!settings.includes('Practice'), 'settings.js 不应再持有练习逻辑');
// 保留项：授权按钮、灵敏度档位与开关仍在，且档位仍带度数（标定信息不随练习一起丢掉）。
assert.ok(/id="wrist-authorize"/.test(html) && /id="wrist-sensitivity"/.test(html), '授权与灵敏度应保留');
for (const deg of ['低 30°', '中 22°', '高 15°']) {
  assert.ok(html.includes(deg), `灵敏度档位应仍带度数：${deg}`);
}

// 新脚本必须真的能被服务到：白名单与页面引用同时核对。
assert.ok(server.includes('"settings.js"'), 'Server.swift 静态白名单需包含 settings.js');
assert.ok(/<script src="\/settings\.js\?v=/.test(html), 'index.html 需带版本号引用 settings.js');

// 需要用户动手的步骤必须是可点链接：地址不能只以纯文本出现，否则用户只能手抄。
assert.ok(/id="wrist-links"/.test(html), '翻腕组需要 #wrist-links 容器承载可点动作');
assert.ok(settings.includes("createElement('a')"), '设置面板应用 createElement 造链接');
assert.ok(settings.includes('renderWristActions'), '设置面板需把不可用原因渲染成动作');
assert.ok(!/wristNote\.innerHTML/.test(settings), '不得用 innerHTML 拼地址，避免注入');
// 地址改为结构化字段 + 可点动作，不再塞进原因散文里。
assert.ok(motionSend.includes('needsSecureContext') && motionSend.includes('secureURL'),
  'motion-send 应回结构化原因与安全地址');
assert.ok(motionSend.includes('caCertificatePath'), 'motion-send 应提供 CA 路径给设置面板');
assert.ok(!/请在手机浏览器访问 https:\/\//.test(motionSend), '不应再把地址写进散文让用户手抄');
assert.ok(motionSend.includes("':46487'"), '安全地址必须显式换到 HTTPS 端口 46487');
// 控制台的地址同样不做成纯文本；证书下载是 HTTP 就能走的入口。
const consoleHtml = fs.readFileSync(path.join(root, 'Web/console.html'), 'utf8');
for (const id of ['url', 'ipUrl', 'remoteUrl', 'secureUrl']) {
  assert.ok(new RegExp(`<a id="${id}"[^>]*class="[^"]*url-link`).test(consoleHtml), `控制台 #${id} 应是链接`);
}
assert.ok(/id="caDownload"[^>]*href="\/PocketDesk-CA\.cer"/.test(consoleHtml), '控制台需提供证书下载入口');
// 服务端必须能经 HTTP 提供 CA：手机在信任证书之前只有 HTTP 可用。
assert.ok(/case \("GET", "\/PocketDesk-CA\.cer"\)/.test(server), 'Server.swift 需提供 CA 下载路由');
assert.ok(server.includes('application/x-x509-ca-cert'), 'CA 需用证书 MIME 触发系统安装流程');

console.log('phone settings: single entry, migrated controls, default-off wrist guard, no practice UI passed');
