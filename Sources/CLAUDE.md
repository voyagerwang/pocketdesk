# Sources/
> L2 | 父级: ../CLAUDE.md

成员清单

ExecutionTrace.swift: 可观测性层——ExecutionOutcome（delivered 已观察到生效 / sent 已发出无法确认 / blocked 前置条件不满足 / failed 执行出错）与 ExecutionFeedback 回执、ExecutionRecord 与 ExecutionLog（NSLock 守护的进程内环形缓冲，最近 40 条），EnvironmentGate（执行前门禁，仅查 AXIsProcessTrusted；锁屏判据——CGWindowList layer≥1000 的 loginwindow 窗口常驻存在会误报，CGSessionScreenIsLocked 在 macOS 15 实测亦不可信——一律不放进门禁，由事后验证 + 日志承担）。InputExecutor 与 Server 共写日志，/api/status 下发最近 30 条给控制台第 5 面板「最近动作」展示；写入与消费同进程但加锁，日志面板只读不重。
ShortcutActions.swift: 预设动作库——Platform（按键投递目标平台，当前恒为 macOS，windows 列供跨平台正确表达）与 ShortcutAction（锁屏/退出应用/关闭窗口/隐藏应用/切换应用：语义 id ↔ 中文名 ↔ 各平台按键串），以及每个动作的投递通道 ActionDelivery（keyEvent=CGEvent 注入前台应用，仅退出应用；systemCommand=直接跑系统命令，锁屏走 pmset 关屏不模拟按键；switchPreviousApp=按 CGWindowList z-order 找上一个常规应用用 openApplication 激活；axCloseWindow=辅助功能按前台窗口的关闭按钮，取不到按钮才回退 keyEvent；hideFrontApp=AppKit 隐藏前台应用，不经按键也不经 AX）。**通道选择是实测结论，别改回按键模拟**：CGEvent 到不了系统快捷键守护进程（有 AX 授权时发 Cmd+Space 弹不出 Spotlight）；交给 System Events 代发又要用户额外勾「自动化」授权（报"未获得授权将Apple事件发送给System Events"）；应用内菜单键也并非所有 app 都实现——实测微信在前台时注入 Cmd+W 毫无反应（官方快捷键表列了，主窗口不响应合成按键），故关闭窗口改按 AX 关闭按钮、并另给隐藏应用兜底。ShortcutConfig.normalized(platform:) 是落盘前唯一规范化点，/api/shortcuts 与 /api/targets 共用。
Models.swift: 传输与配置的值类型词汇表——SendCommand/PendingImage/ActivateCommand/IconUpload 请求体、ShortcutConfig/TargetConfig 配置实体、ShortcutKeys 语义串解析器（resolve：hotkey 串 → CGKeyCode/CGEventFlags；canonicalize：Enter/Backspace/Esc 别名与修饰键序归一；legacyHotkey：旧 modifiers+keycode 迁移翻译）、ShortcutError/InputError 错误，纯 Codable/Equatable 无系统依赖（仅 CoreGraphics 键码类型）。
TargetStore.swift: 目标应用、快捷键与主题三份配置的持久化层，~/Library/Application Support/VoiceDeck 下的 targets.json/shortcuts.json/theme 读写，含 appURL 定位、自定义图标路径与孤儿图标清理；快捷键加载双轨：新格式（hotkey 语义串）读后经 ShortcutKeys.canonicalize 归一并按需回写（清洗 Enter 等别名残留），旧格式（modifiers+keycode）经 legacyHotkey 翻译后回写完成迁移；Server 与 InputExecutor 共用。主题是产品级外观决策，唯一写入点在电脑端控制台（POST /api/theme），手机页只读跟随。
AppDiscovery.swift: 无状态的应用发现层，扫描 /Applications 等目录做名称/路径搜索，并为新增目标生成安全 slug；/api/apps 搜索与 /api/targets id 补齐依赖它。扫描覆盖两种安装形态：根目录下平铺的 `.app`，以及 `X.localized/` 包装目录内藏的 `.app`（钉钉即 DingTalk.localized/DingTalk.app）——后者取**包装目录**的 displayName 作为显示名，复用 macOS 的目录名本地化机制（中文系统下得"钉钉"而非 "DingTalk"），不维护自己的中英别名表。
Util.swift: 无状态渲染工具层——主局域网 IP、macOS utun 上的 Tailscale 100.64.0.0/10 地址探测、稳定 .local 主机名、QR PNG、应用图标 PNG 提取；Server 的地址与图标端点调用它。
Auth.swift: 鉴权层——配对 token 的首次生成（SecRandomCopyBytes 32 字节 base64url）、持久化到 Application Support/VoiceDeck/token、写请求 Bearer 校验与 WS 首帧校验（恒定时间比较）；Server 与 WSServer 共用。
InputExecutor.swift: 键盘输入执行层，串行队列跑 activate → Unicode → 粘贴图片 → Return（文字先落入编辑器，避免附件挂载打断输入焦点） 注入序列，含图片预上传暂存与快捷键注入；快捷键有二态：普通项 hotkey 经 ShortcutKeys.resolve → postKey（真实 CGEventSource + characters 补齐 + down/up 间隔，Zed 终端按 characters 取键、无源合成事件的 Return 会被其丢弃），预设动作项先经 ShortcutAction 查表决定通道（走命令/AppKit/AX 时根本不碰按键）；与 PointerExecutor 平行。
PointerExecutor.swift: 指针执行层，虚拟光标 + 双屏包围盒钳制，move/drag/click/scroll/zoom 手势到 CGEvent 的映射；仅被 WSServer 消费。
Server.swift: HTTP 传输层 :46387，全部端点路由与静态页面服务，向控制台暴露局域网及 Tailscale 私网地址并生成带配对 token 的二维码；只翻译协议不做系统调用，写操作委托 InputExecutor；/api/status 下发 targets 含 per-app shortcuts/openPanel、/api/targets 保存时对专属快捷键做 resolve 校验 + id 去重、openPanel 白名单清洗；与 WSServer 平行。
WSServer.swift: 触控板传输层 :46388，WebSocket 监听、首帧 token 鉴权、会话重置与消息转发到 PointerExecutor。
main.swift: 唯一入口与组装根，web 根定位、端口选择（VOICE_DECK_PORT）、辅助功能授权提示、双服务启动、AppDelegate 的 Dock 应用身份；不再含业务逻辑。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
