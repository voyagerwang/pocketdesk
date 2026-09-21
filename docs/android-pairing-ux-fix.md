# 安卓配对体验修复 · 0.1.1

用户报告：点击扫码退出、找不到配对邀请码来源、不理解“打开普通网页功能”。本次只修配对与连接体验，不扩大原生 App 的能力边界。

## 原因与证据

旧 APK 的扫码库引用 `androidx.core.content.ContextCompat`、`androidx.core.app.ActivityCompat` 和 Fragment 类，但构建依赖未包含它们。`jdeps` 确认扫码库引用，旧 APK DEX 未包含这些类；新版显式声明依赖并检查最终 DEX。旧单测只覆盖协议与 TLS，没有覆盖 Activity 启动。

ZXing 4.3.0 官方构建声明 core 1.6.0 / fragment 1.3.6，但发布 POM 只遍历 api 依赖，未列出这两个 implementation 依赖：[官方源码](https://github.com/journeyapps/zxing-android-embedded/blob/v4.3.0/zxing-android-embedded/build.gradle)。因此此次补齐运行依赖，不用扩大捕获 Exception 掩盖缺类。

没有连接用户安卓真机、没有取得该手机崩溃堆栈；上述为已证实的包内缺陷，不能声称已排除厂商相机兼容性问题。

当前 ~/Applications/PocketDesk.app 的控制台没有 quOpen 快捷解锁入口。安卓与电脑安装版不配套，也是用户找不到邀请来源的原因；修复包必须成套交付。

## 最终流程

- 未配对：首页说明电脑端获取二维码的路径，主要操作为“扫码连接电脑”；帮助内提供“粘贴配对链接”，明确是完整链接、不是数字邀请码。
- 相机：点扫码才请求权限。拒绝后仍在 App，可去权限设置或粘贴链接；取消扫码与扫码页启动异常原地提示。扫码结果是普通网页地址时解释正确二维码位置，不执行网页地址。
- 待确认：显示核对码，用户在 Mac 确认后点“我已在电脑上确认”。保存核对码，重进 App 不丢失确认指引。
- 已连接：显示电脑状态及解锁入口。返回只读刷新，不自动解锁或重试失败命令。更新地址和移除连接放入“连接设置”。
- 删除“打开普通网页功能”按钮：原按钮打开未携带网页配对身份的 HTTP 地址，容易制造另一条断路。连接设置内说明语音输入/触控板/画面由浏览器扫描控制台网页二维码使用；本次没有实现原生网页身份交接。
- Mac 设置：生成配对码后才启用“复制配对链接”，显示与手机一致的获取/粘贴说明；增大窗口以容纳二维码及核对确认。

## 验证与交付

构建命令：JDK 17 + Gradle 8.11.1，`assembleDebug testDebugUnitTest lintDebug`；Mac 使用 `bash scripts/build-android-test-host.sh`。开发机 Java 直连 Google Maven 握手失败时，仅本次构建通过回环代理使用 curl 从官方仓库获取，不修改项目仓库配置。

安卓版本 0.1.1 / versionCode 2，沿用已有调试签名。构建包与测试证据在本次交付目录；不把模拟相机或模拟解锁当成真机通过。

真机仍需核验：相机首次允许/拒绝、实际二维码识别、系统认证、两端确认、锁屏后实际解锁；此前解锁安全边界保持不变。本次未保存密码、未执行真实锁屏/解锁。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

### 本次最终验证结果

- `assembleDebug testDebugUnitTest lintDebug`：退出 0，13 项测试全部通过、无跳过。含 7 项 Android 35 Activity/渲染测试、扫码依赖装载、4 项协议及 1 项真实临时 TLS 测试。
- 相机 Activity 在 Robolectric 沙箱中完成生命周期启动；硬件摄像头仍未验证。权限拒绝/扫码取消/错误网页二维码均有恢复路径。
- 320×640 与 390×844（字体 1.3 倍）真实 Android View 渲染已检查；主操作可见，无文字遮挡；第二轮确认背景填满页面和禁用按钮样式。
- 电脑控制台配对卡已由 Playwright 在全接口替身下渲染；未请求真实控制服务。
- Android lint：0 errors / 5 warnings（含既有自定义固定证书校验提醒与中文字符串本地化提醒）；未隐藏 lint 错误。
- Mac 配套应用全量构建退出 0，签名核验通过；APK v2 签名核验通过。`git diff --check` 通过。
- 交付目录：`/Users/yz/Downloads/PocketDesk-0.1.1-pairing-fix/`，含 APK、Mac 配套 ZIP、说明与三张界面截图。尚未替换正在运行的 Mac 版本，尚未安装到用户手机。
- 本轮代码仍位于 quick-unlock worktree，没有将该分支其他未交付改动合入主仓库。

## 完整版本集成与实际安装

2026-09-20T23:30:43：按用户授权，以当前主工作目录为基线整合原生解锁模块，仅三方合并 Server/main/screen/console 接缝，保留后来完成的 PhoneFilePicker/PhoneFileHTTP/PhoneFileStore 和所有现有网页资源。原始配套包不含最新文件功能，因此未直接安装那个旧包。

Mac 0.3.1（build 4）全量构建及安装退出 0，新 VoiceDeck 已运行；原生配对状态接口 native-lan / configured=true，功能默认仍关闭。文件收件匿名请求 401、已配对只读请求 200，所有安装 Web 字节与当前完整源码一致，应用签名核验通过。文件 HTTP 联测与真实浏览器下载字节核验、原生配对/路由测试、甩送/画面重连/网页门禁回归通过。

旧应用和集成前源码备份：`/Users/yz/.codex/deployments/pairing-full-20260920-232729`。下载目录中的 Mac 配套 ZIP 也替换为此次完整安装版；安卓仍为已验证的 0.1.1。adb 未发现手机，不声称手机安装完成。未保存电脑密码或执行实际锁屏/解锁。
