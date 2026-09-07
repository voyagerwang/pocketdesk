# Web/
> L2 | 父级: ../CLAUDE.md

成员清单

index.html: 面向手机的单页工作台，无模式切换也无模式按钮：应用 Dock + 触控板卡片（收起 96px 精简条）+ 输入区（输入框下方的历史发送面板：清空带二次确认、收起按钮；图片预览）；触碰触控板自动展开、点输入框自动收起。
console.html: 电脑端控制台（自包含样式与脚本）。四步引导：系统授权（一键跳转设置）、手机扫码连接（局域网 QR + 自动探测的 Tailscale 跨网 QR + 在线状态）、目标应用搜索/增删/排序/自定义图标 + 每个目标的设置展开区（默认打开输入框/触控板偏好、应用专属快捷键组、叠加全局组开关 showGlobal 默认开、内置常用快捷键下拉框 BUILTIN_PRESETS 一键添加刷新/粘贴/复制/撤销/回车/锁屏/关闭等）、快捷键管理（录制产出语义串 hotkey 如 "Cmd+Shift+Z"/"Return"：主键只认 event.code 物理键位、不回退 IME 可污染的 event.key，拦截 isComposing 与纯修饰键；录制器为作用域模型 recordCtx，全局与应用专属共用同一 keydown 监听，录完即存，反馈就地显示在触发按钮上；键位标签用 .keycap 样式、label 与键位展示重复时只显示一个；支持重录/排序/删除）；默认经典蓝主题，:root[data-theme="muji"] 按需切换米白克制风；头部"经典蓝/米白"分段开关 POST /api/theme 写 Mac 本机，手机页自动跟随。
style.css: 手机页唯一样式来源（控制台样式内联在各自 HTML，令牌取值与本文件保持一致）。:root 里的设计令牌（颜色/间距/圆角/字号/动效）之外不允许出现硬编码色值。经典蓝玻璃主题为默认，:root[data-theme="muji"] 覆盖为米白克制风（米白 #f5f3ee 底 + 深炭字 + 赭红 #b74127 单一点缀、去发光去渐变去毛玻璃、方正小圆角）。两个主题共用同一套令牌名与选择器，切换零结构改动。主题是服务端状态，默认 classic（经典蓝）：电脑控制台头部"经典蓝/米白"分段开关 POST /api/theme 写 Mac 本机，手机页无按钮、经 /api/status 轮询跟随（≤5s），localStorage 只存上次已知值缓解刷新闪烁。
app.js: 手机页交互与本地 API 客户端。点击唤醒、发送命令（文字 + 可选图片：选图压缩到 2048px JPEG 预览，图片经 /api/image 预上传，发送时 SendCommand 携带文本与 usePendingImage 标记；服务端先输入文字，再经 Mac 剪贴板 Cmd+V 粘贴图片并统一提交）；手动激活目标后按其 openPanel 偏好自动切触控板/输入区（前台自动跟随不切，避免抢键盘）；触碰触控板自动进入 pad 模式（收键盘、面板长大），点输入框/发送自动退出并收起设置面板；每 5 秒轮询 /api/status：上报 /api/pair 心跳、让选中态边沿跟随 Mac 前台应用（滑动 Dock 4 秒内、手动激活 2.5 秒内抑制），伪目标态记住前台应用名 frontmostLabel，"发送到 X"一律显示识别到的真实应用名；触控板 Pointer Events 手势状态机（单指移动/点按/长按拖动、双指滚动/右键），增量经 rAF 合并后发往 ws:46388；历史面板展开时按钮高亮、相同内容去重、清空需二次确认（3.5s 自动还原）；快捷键按钮条随选中目标切换：有专属组时前排专属 + 后排全局（showGlobal=false 只显专属，默认叠加），无专属组用全局组（过滤默认 undo/copy/paste 示例），心跳边沿比对 targets 与 shortcuts 5 秒内跟随服务端，Enter/Return 等别名归一显示同一符号、名称与键位重复时只显示一个，点击 POST /api/shortcut-trigger 注入 Mac 前台；配对 token 管理（URL ?token= → localStorage → 写请求 Authorization 头与 WS 首帧 auth）、主题跟随（applyTheme 在 boot 与心跳里应用 /api/status 下发的 theme）。

<conventions>
图标分两类，不混用：目标应用一律用系统真实图标（服务端 /api/icon，取不到时露出首字兜底，控制台支持上传自定义图标覆盖）；界面控件一律用内联 24×24 线条符号，stroke-width 固定 1.75，颜色走 currentColor。
不使用 emoji、不使用第三方图标 CDN（页面要能离线跑）。
</conventions>

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
