# 工作台连接恢复与 Android 0.2.0

## 根因与修复
Mac 崩溃报告明确指出 NSWindow 操作不在主线程：HTTP quickUnlockPanel 回调直接创建 AppKit 窗口，导致整个服务 SIGTRAP。main.swift 已将窗口回调交回主线程，实际 POST 打开窗口后再次请求 status 成功。
控制台曾因存在自签名 HTTPS 地址而隐藏普通工作台二维码；现保留 App/浏览器共用的局域网二维码，HTTPS 单独标注。status 仅向本机回环提供带授权 workspaceURL，使复制链接与二维码相同；局域网 status 不含该值。
Android 0.1.1 是解锁专用壳，错误拒绝工作台二维码。0.2.0 默认承载完整现有 Web 工作台，扫码保存后启动自动恢复；快捷解锁迁到独立 UnlockActivity，旧凭据保留。相机预览与取景框为正方形。保留 Web 文件选择，下载交给系统下载器，正确解析 UTF-8 附件名。未对 HTTPS 证书错误放行。
Android 源码已从专项 worktree 整合进主仓库 Android/，避免仅交付脱离主项目的客户端。

## 已验证
- 全量 Swift 构建并安装 ~/Applications/PocketDesk.app；原有文件传输、输入、画面与其他任务代码保留。
- 实际打开原生解锁设置，随后网页 status 200；服务不再退出。
- Vision 实际解码运行服务的 QR PNG，与工作台授权链接严格一致。
- 运行服务首页、控制台、文件脚本及样式、甩送脚本字节等于当前源码。
- Android assembleDebug、18 项单测、lintDebug 通过（lint 0 errors，存在弃用等 warnings）。覆盖扫码生命周期、方形预览、工作台扫码加载、重启恢复、非法地址、附件名；两轮沙箱截图核对。
- phone-files、phone-settings、web-globals 和 motion-recognizer 34 项合成轨迹通过。
- 文件 HTTP 联测和真实 Chromium 点击下载后逐字节比对通过。
- 实际电脑“文件 → 发送文件到手机”选择 PocketDesk-0.2.0.apk，弹窗确认准备完成，已鉴权收件列表核对名称与 2325678 字节。尚未替用户在手机确认下载。

## 边界
adb 无连接设备，未声称手机已经安装。相机画面、安卓系统下载器和真机手感仍待实测。HTTP 工作台的翻腕仍受安全上下文限制，不等于甩送已在真机修复。既有网页功能由同源 WebView 复用，不能以“复用”代替所有功能的真机验收。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
