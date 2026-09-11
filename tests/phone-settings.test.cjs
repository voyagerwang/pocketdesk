/**
 * [INPUT]: 依赖 Node 内建断言与文件系统，读取 Web/index.html、Web/settings.js 与 Sources/Server.swift。
 * [OUTPUT]: 验证手机设置只有一个入口、触控板内无齿轮、三个旧控件 ID 与存储键未复制第二份、翻腕默认关闭且只留开关与灵敏度、新脚本已进入静态白名单；
 *           并锁住免证书降级：翻腕组在环境不过关时整组隐藏（#wrist-group 默认 hidden），证书向导（CA 下载/描述文件/完全信任/探测跳转）与独立授权按钮一律不得存在于手机端设置面板与体感模块。
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
// 保留项：开关与带度数的灵敏度档位仍在（标定信息不随练习一起丢掉）。
// 独立授权按钮已撤销：免证书方案要求权限在用户点开关的那一次交互里请求，不能分两步。
assert.ok(/id="wrist-sensitivity"/.test(html), '灵敏度档位应保留');
for (const deg of ['低 30°', '中 22°', '高 15°']) {
  assert.ok(html.includes(deg), `灵敏度档位应仍带度数：${deg}`);
}

// 新脚本必须真的能被服务到：白名单与页面引用同时核对。
assert.ok(server.includes('"settings.js"'), 'Server.swift 静态白名单需包含 settings.js');
assert.ok(/<script src="\/settings\.js\?v=/.test(html), 'index.html 需带版本号引用 settings.js');

/* ---------- 免证书降级：翻腕不再要求用户安装或信任 CA ---------- */

// 整组默认隐藏：环境层（安全上下文 + 传感器接口）过关才由 settings.js 打开。
// 目的不是"少显示一行字"，而是"非安全上下文下不能出现证书下载、灰色开关或维修教程"。
assert.ok(/<section id="wrist-group"[^>]*hidden>/.test(html), '翻腕组必须能整组隐藏，且默认隐藏');
assert.ok(settings.includes("wristGroup.hidden"), '设置面板必须按能力整组显隐翻腕');
assert.ok(settings.includes("'unsupported'"), '设置面板必须消费 motion-send 的 unsupported 状态');
// 证书向导整条链路必须消失：不能再有任何一步要求用户下载、安装或信任 CA。
for (const gone of ['wrist-links', 'wrist-authorize']) {
  assert.ok(!html.includes(gone), `页面不应再保留 ${gone} 节点`);
}
for (const gone of ['PocketDesk-CA', 'caCertificatePath', 'probeSecure', 'detectAndOpenSecure',
                    'renderWristActions', 'VPN 与设备管理', '证书信任设置', '完全信任']) {
  assert.ok(!settings.includes(gone) && !motionSend.includes(gone),
    `手机端不得再出现证书/系统配置引导：${gone}`);
}
assert.ok(!motionSend.includes("':46487'"), '体感模块不得再拼 HTTPS 端口去引导用户换地址');
// 失败只给一句人话，不要求系统配置、不循环弹权限。
assert.ok(settings.includes('暂时无法使用翻腕发送，请使用发送按钮'), '失败提示必须是那句固定人话');
assert.ok(/wristToggle\.disabled = true/.test(settings), '验证期间必须锁住开关，避免重复弹权限');
// 四级状态与数据层探测：能不能用，取决于真的收到有效传感器数据，而不是接口存在。
for (const state of ['unsupported', 'needs-permission', 'unverified', 'running']) {
  assert.ok(motionSend.includes(`'${state}'`), `motion-send 缺少状态 ${state}`);
}
assert.ok(/PROBE_WINDOW_MS = 3000/.test(motionSend), '初始探测窗口应为 3 秒（待真机校准）');
assert.ok(/PROBE_MIN_SAMPLES/.test(motionSend) && motionSend.includes('isUsableSample'),
  '必须以有效样本证明传感器在出数');
assert.ok(fs.readFileSync(path.join(root, 'Web/motion-recognizer.js'), 'utf8').includes('function isUsableSample'),
  '有效样本判定应是识别器里的纯函数，便于单测');
// 挂起/恢复：切后台、断线、失去租约都要停识别，恢复后重新验证。
assert.ok(motionSend.includes("suspend('hidden')") && motionSend.includes("suspend('offline')"),
  '切后台与断网必须停识别');
assert.ok(fs.readFileSync(path.join(root, 'Web/pad.js'), 'utf8').includes('pocketdeskMotionSuspend'),
  '控制通道失去租约时必须停识别');

// 控制台：地址仍是可点链接，安全连接整块保持移除（它就是用户点名要去掉的"大二维码"那张卡）。
const consoleHtml = fs.readFileSync(path.join(root, 'Web/console.html'), 'utf8');
for (const id of ['url', 'ipUrl', 'remoteUrl']) {
  assert.ok(new RegExp(`<a id="${id}"[^>]*class="[^"]*url-link`).test(consoleHtml), `控制台 #${id} 应是链接`);
}
assert.ok(!/id="secureQrItem"/.test(consoleHtml), '控制台不应再出现安全连接二维码整块');
assert.ok(!/id="caDownload"/.test(consoleHtml), '控制台不再承载证书下载');
// CA 路由保留：它不是翻腕的入口，而是锁屏 HTTPS 通道（另有自身安全门禁）需要的证书分发。
// 免证书方案只说"不为翻腕要求装 CA"，没说要拆掉已有信任基础设施。
assert.ok(/case \("GET", "\/PocketDesk-CA\.cer"\)/.test(server), 'Server.swift 需保留 CA 下载路由（锁屏 HTTPS 通道）');
assert.ok(server.includes('application/x-x509-ca-cert'), 'CA 需用证书 MIME 触发系统安装流程');

console.log('phone settings: single entry, migrated controls, default-off wrist guard, no-certificate degradation passed');
