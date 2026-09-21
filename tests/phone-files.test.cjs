/**
 * [INPUT]: Node 内建 fs；真实 Web/phone-files.js、phone-files.css、index.html 与 Sources/Server.swift、Sources/PhoneFileHTTP.swift、Resources/Info.plist。
 * [OUTPUT]: 静态结构回归：XSS 纯文本渲染、下载链接同源校验、显式下载链接而非程序化 click、
 *           代际序号防迟到轮询复活、容器与资源引用、路由鉴权顺序与静态白名单、Finder 用途声明。
 * [POS]: tests 的文件收件页面静态回归；不启动服务、不请求网络。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const js = fs.readFileSync('Web/phone-files.js', 'utf8');
const css = fs.readFileSync('Web/phone-files.css', 'utf8');
const html = fs.readFileSync('Web/index.html', 'utf8');
const server = fs.readFileSync('Sources/Server.swift', 'utf8');
const http = fs.readFileSync('Sources/PhoneFileHTTP.swift', 'utf8');
const plist = fs.readFileSync('Resources/Info.plist', 'utf8');
const panel = fs.readFileSync('Sources/SpriteFeedbackPanel.swift', 'utf8');
const drop = fs.readFileSync('Sources/SpriteFileDropView.swift', 'utf8');

(async () => {
  // XSS 防线：文件名与清单一律 textContent，不拼接 innerHTML。
  assert.ok(!js.includes('innerHTML') && !js.includes('outerHTML'), 'phone-files.js 不使用 innerHTML');
  assert.ok(js.includes('name.textContent = file.name'), '文件名走 textContent');
  assert.ok(js.includes('item.textContent = value'), '清单成员走 textContent');
  assert.ok(!/new Date\(.*\)\.toLocaleTimeString.*\+ *file\./.test(js), '时间文本独立渲染');

  // 下载安全：同源 + 前缀校验；票据地址不落在长期 token 上。
  assert.ok(js.includes("url.origin !== location.origin"), '下载地址校验同源');
  assert.ok(js.includes("url.pathname.startsWith(base + '/download/')"), '下载地址校验收件前缀');
  assert.ok(!js.includes('Bearer'), '下载不需要页面脚本携带 token');

  // 安卓下载稳健性：确认后给显式 <a download>，不做程序化 click。
  assert.ok(!js.includes('link.click()'), '不做程序化 click（安卓非手势下载会被拦截）');
  assert.ok(js.includes("setAttribute('download'"), '下载链接带 download 属性');
  assert.ok(/function downloadLink/.test(js), '确认后渲染显式下载链接');

  // 迟到轮询防护：列表轮询捕获发起时的代际；确认/拒绝成功推进代际作废旧列表响应。
  // 逐项操作不捕获代际——不同文件并行接收的成功响应互不丢弃。
  assert.ok(/let.*listEpoch = 0/.test(js), '存在列表代际序号');
  assert.ok(/listEpoch \+= 1/.test(js), '确认/拒绝成功后推进列表代际');
  assert.ok(/captured !== listEpoch/.test(js), '迟到列表响应按代际丢弃');
  assert.ok(/request\('', 'GET', true\)/.test(js), '仅列表轮询启用代际检查');
  assert.ok(!/request\('\/' \+ encodeURIComponent\(file\.id\)[^)]*true\)/.test(js), '逐项操作不共用列表代际');

  // 状态文案诚实：未确认前不声称已下载。
  assert.ok(js.includes('等待你确认接收'), '接收前文案明确等待确认');
  assert.ok(js.includes('已发起下载，请在浏览器下载列表查看'), '只有点击下载后才报告已发起');
  assert.ok(!/已保存到手机|已下载到手机/.test(js), '不声称文件已保存手机');

  // 页面接缝：容器、脚本与样式引用，以及 Server 静态白名单。
  assert.ok(html.includes('id="phone-files"'), '首页有收件容器');
  assert.ok(html.includes('id="phone-files-list"') && html.includes('id="phone-files-notice"'), '列表与提示节点存在');
  assert.ok(html.includes('/phone-files.js') && html.includes('/phone-files.css'), '资源引用存在');
  assert.ok(server.includes('"phone-files.js"') && server.includes('"phone-files.css"'), '静态资源白名单注册');

  // HTTP 鉴权边界：非下载操作一律 Bearer，下载仅认票据；不依赖回环豁免。
  const authOrder = http.indexOf('guard isDownload || Auth.verify');
  assert.ok(authOrder > 0, '列表/确认/移除要求配对 token');
  assert.ok(!http.includes('isLoopback'), '文件路由不使用回环豁免');
  assert.ok(http.includes('no-store') && http.includes('nosniff'), '下载响应带 no-store 与 nosniff');
  assert.ok(http.includes("filename*=UTF-8''"), 'UTF-8 文件名头');
  assert.ok(http.includes('streams < maxStreams'), '并发下载上限');

  // 拖入可达性：拖拽期间短暂放行收起的球体，松开恢复；容器不破坏面板拖动。
  assert.ok(panel.includes('dragRevealed'), '拖拽显现状态存在');
  assert.ok(panel.includes('addGlobalMonitorForEvents'), '全局拖拽监听（不消费事件）');
  assert.ok(drop.includes('mouseDownCanMoveWindow'), '拖放容器保留面板拖动能力');
  assert.ok(panel.includes('screenLocked'), '锁屏隐藏逻辑保留');

  // Finder 用途声明。
  assert.ok(plist.includes('NSAppleEventsUsageDescription'), 'Info.plist 声明访达自动化用途');

  // 触控目标与主题令牌。
  assert.ok(css.includes('var(--screen-hit)'), '按钮高度复用 44px 触控令牌');
  assert.ok(css.includes('var(--accent)') && css.includes('var(--accent-ink)'), '主操作复用主题色');
  assert.ok(css.includes('overflow-wrap'), '长文件名可换行');

  console.log('phone-files 静态回归: 全部通过');
})().catch(error => { console.error('FAIL -', error.message); process.exit(1); });
