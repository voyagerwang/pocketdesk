# Android/app/
> L2 | 父级: ../CLAUDE.md
build.gradle: API 30 下限、API 35 目标，ZXing 离线扫码和 JUnit 测试依赖。
src/main/AndroidManifest.xml: INTERNET、按需 CAMERA、USE_BIOMETRIC；允许局域网工作台 HTTP；禁备份和外部配对深链。
src/main/res/values/styles.xml: 原生系统主题与可读字号/颜色。
src/main/java/dev/pocketdesk/mobile/UnlockActivity.java: 可选快捷解锁页；未配对/待确认/已连接三阶段引导；按需请求相机并提供拒绝、取消、扫错网页码的恢复路径；备用配对链接在帮助中说明电脑获取入口。连接管理按需展开，返回只读刷新状态，不自动执行或重试解锁。
src/main/java/dev/pocketdesk/mobile/DeviceKey.java: AndroidKeyStore 不可导出且每次使用需认证的 P256 密钥；不保存电脑密码。
src/main/java/dev/pocketdesk/mobile/LocalClient.java: 固定证书身份的有界 HTTPS 请求，拒绝重定向与未知证书，不更改系统信任。
src/main/java/dev/pocketdesk/mobile/Pairing.java: 配对载荷、局域网地址校验、两端相同的签名域和核对码编码。
src/test/: 协议和地址边界单元测试。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

src/main/res/xml/data_extraction_rules.xml: 排除云备份及设备迁移中的应用资料，新手机必须重新配对。
src/main/res/drawable/app_icon.png: 复用现有 PocketDesk 品牌图标。
src/main/res/values/strings.xml: 核对码与验证取消的带参数中文文案。
src/test/java/dev/pocketdesk/mobile/PairingTest.java: 地址/邀请/签名域边界与 Swift 核对码向量。
src/test/java/dev/pocketdesk/mobile/LocalClientTest.java: 真实临时 TLS 监听验证固定指纹、自签身份及拒绝跳转/错误指纹。

src/test/java/dev/pocketdesk/mobile/ScannerDependenciesTest.java: 检查 ZXing 所需 AndroidX 类能在测试运行时装载，防止遗漏依赖导致扫码才崩溃。
src/test/java/dev/pocketdesk/mobile/PairingExperienceTest.java: Android 35 沙箱运行真实首页，验证权限拒绝/扫码启动/取消/错误二维码及窄屏大字渲染；不替代真机相机验收。
构建依赖显式补齐 ZXing 4.3.0 POM 遗漏的 core 1.6.0 与 fragment 1.3.6；APK 0.4.1 / versionCode 7。

src/main/java/dev/pocketdesk/mobile/MainActivity.java: 默认完整 Web 工作台；移除低频底部Tab，首页锁定入口经同源顶层真实点击直达解锁；连接后移除原生顶栏与空状态占位，连接管理通过工作台齿轮内的受限用户导航打开；保存扫码连接，提供系统文件选择、下载、受限甩送桥接及可选快捷解锁入口。
src/main/java/dev/pocketdesk/mobile/NativeMotionBridge.java: 仅在当前顶层 URL 属于已保存工作台时启停加速度计与旋转向量，把姿态样本派发给现有 Web 识别器；Activity 离开前台立即停止，不识别手势、不提交内容。
src/main/java/dev/pocketdesk/mobile/WorkspaceConnection.java: 工作台邀请与下载同源边界。
src/main/java/dev/pocketdesk/mobile/SquareCaptureActivity.java: 两类扫码共用方形预览和取景框。
src/test/java/dev/pocketdesk/mobile/WorkspaceExperienceTest.java: 工作台二维码、重启恢复、非法地址、正方形取景集成回归。
src/test/java/dev/pocketdesk/mobile/NativeMotionBridgeTest.java: Android 姿态弧度到 Web 角度及四向屏幕旋转的纯映射回归；不替代真机方向与手感验收。

src/main/java/dev/pocketdesk/mobile/NativePage.java: 原生标题、安全区与工作台主题映射，无底部Tab；返回复用工作台Activity，保留网页草稿。
src/main/java/dev/pocketdesk/mobile/FilesActivity.java: 原生收件列表，单击接收签发票据并交系统下载，回到前台核验系统下载状态。
src/main/java/dev/pocketdesk/mobile/ConnectionActivity.java: 原生设备可达状态、重连/扫描/粘贴与快捷解锁；不自动执行解锁。
src/main/java/dev/pocketdesk/mobile/WorkspaceClient.java: 从本地工作台授权派生同源JSON请求，限制响应尺寸，禁止跳转泄露授权。
src/main/java/dev/pocketdesk/mobile/NativeDownload.java: 网页和原生文件页共用 DownloadManager，不向票据URL附加长期token。
src/main/res/drawable/ic_workspace.xml: 工作台线条图标。
src/main/res/drawable/ic_files.xml: 文件导航线条图标。
src/main/res/drawable/ic_devices.xml: 设备导航线条图标。
src/test/java/dev/pocketdesk/mobile/NativePagesTest.java: 原生导航保留工作台意图、文件/设备页与地址边界回归，截图使用合成数据。

0.4任务优先：工作台首页轮询锁定事实，用户点击才发起手机验证；直接解锁成功返回原工作台，设置入口不自动授权。LocalClient 保留具体失败说明及错误码，不再用泛化文案覆盖。NativePage 语义颜色对齐Web/style.css经典蓝及app-extras.css米白；主题通过受限用户导航携带，不接受任意色值。
