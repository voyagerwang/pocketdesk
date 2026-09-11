# Sources/
> L2 | 父级: ../CLAUDE.md

成员清单

ExecutionTrace.swift: 可观测性层——ExecutionOutcome（delivered 已观察到生效 / sent 已发出无法确认 / blocked 前置条件不满足 / failed 执行出错）与 ExecutionFeedback 回执、ExecutionRecord 与 ExecutionLog（NSLock 守护的进程内环形缓冲，最近 40 条），EnvironmentGate（辅助功能与会话状态门禁；本机验证使用 CGSSessionScreenIsLocked，锁屏或未知会话拒绝普通输入）。InputExecutor 与 Server 共写日志，/api/status 下发最近 30 条给控制台第 5 面板「最近动作」展示；写入与消费同进程但加锁，日志面板只读不重。
ScreenCapture.swift: 按需显示器枚举与单帧 JPEG，用于 PiP 和持续画面失败后的降级，默认包含鼠标。
Models.swift: 传输与配置的值类型词汇表——SendCommand/PendingImage/ActivateCommand/IconUpload 请求体、ShortcutConfig/TargetConfig 配置实体、ShortcutKeys 语义串解析器（resolve：hotkey 串 → CGKeyCode/CGEventFlags；canonicalize：Enter/Backspace/Esc 别名与修饰键序归一；legacyHotkey：旧 modifiers+keycode 迁移翻译）、ShortcutError/InputError 错误，纯 Codable/Equatable 无系统依赖（仅 CoreGraphics 键码类型）。
ImageBatchStore.swift: 图片批次资源层；按 batchId/imageId 幂等暂存，统一执行完整性与解码校验、15 分钟过期及 8 张/40MB 批次、80MB 总量边界，提交成功后消费。
ImagePastePolicy.swift: 图片粘贴时序策略；普通目标沿用既有节奏，Chrome 多图在每次 Cmd+V 前等待剪贴板稳定、之后等待网页异步消费，并只在相邻图片间要求一次插入点点击；策略无桌面副作用并由隔离测试固定边界。
TargetStore.swift: 目标应用、快捷键与主题三份配置的持久化层，~/Library/Application Support/VoiceDeck 下的 targets.json/shortcuts.json/theme 读写，含 appURL 定位、自定义图标路径与孤儿图标清理；快捷键加载双轨：新格式（hotkey 语义串）读后经 ShortcutKeys.canonicalize 归一并按需回写（清洗 Enter 等别名残留），旧格式（modifiers+keycode）经 legacyHotkey 翻译后回写完成迁移；Server 与 InputExecutor 共用。主题是产品级外观决策，唯一写入点在电脑端控制台（POST /api/theme），手机页只读跟随。
AppDiscovery.swift: 无状态的应用发现层，扫描 /Applications 等目录做名称/路径搜索，并为新增目标生成安全 slug；/api/apps 搜索与 /api/targets id 补齐依赖它。扫描覆盖两种安装形态：根目录下平铺的 `.app`，以及 `X.localized/` 包装目录内藏的 `.app`（钉钉即 DingTalk.localized/DingTalk.app）——后者取**包装目录**的 displayName 作为显示名，复用 macOS 的目录名本地化机制（中文系统下得"钉钉"而非 "DingTalk"），不维护自己的中英别名表。
Util.swift: 无状态渲染工具层——主局域网 IP、macOS utun 上的 Tailscale 100.64.0.0/10 地址探测、稳定 .local 主机名、QR PNG、应用图标 PNG 提取；Server 的地址与图标端点调用它。此外承载**前台应用探测**：用 CGWindowList（optionOnScreenOnly，layer 0 的首个有主窗口即用户眼前的应用）；不用 NSWorkspace.frontmostApplication（常驻无窗口进程里其缓存会冻结），**也不要改用 AX 的 kAXFocusedApplicationAttribute**（问的是键盘焦点归谁，窗口在另一块显示器/桌面空间时会答成原应用，与用户视角相反）；pid → 应用对象一律从 NSWorkspace.runningApplications 里取同一 pid 的项，现造的 NSRunningApplication(processIdentifier:) 其 bundleIdentifier/bundleURL 常为 nil，一 nil 就匹配不上任何 Dock 目标。
Auth.swift: 鉴权层——配对 token 的首次生成（SecRandomCopyBytes 32 字节 base64url）、持久化到 Application Support/VoiceDeck/token、写请求 Bearer 校验与 WS 首帧校验（恒定时间比较）；Server 与 WSServer 共用。
InputExecutor.swift: 串行键盘执行与草稿快照事务；受支持空白纯文本框直接替换，通用应用用选区实时替换，UU 特殊通道才暂存；图文共用提交、近期草稿 ID 去重，Chrome 多图逐张等待网页消费，并在相邻图片间点击经当前页面核验的鼠标锚点；应用切回后的显式重试按当前焦点重绑，沿用暂停前已实时输入正文而不重复注入。焦点查找与诊断委托 InputFocus。
PointerExecutor.swift: 指针执行层，move/drag/click/scroll/zoom/tap 与 pointer 绝对手势到 CGEvent 的映射；仅被 WSServer 消费。维护的是**命令期望值** expected，与 CursorMonitor 的**观测值**严格分离、互不写入。三条真实性约束（都是踩过的坑）：① 相对移动的起点用 basePosition()——系统真值与期望值差 <2px 就用期望值，**否则拖动会被 CGEvent 注入的滞后读数每帧往回拽**；差得远说明实体鼠标动过，改以真值为基准，避免跳回旧缓存；② 钳制用有效显示器矩形集合而非所有屏的外接矩形（L 形排列时外接矩形含无屏空洞，光标会停在不存在的区域），越界投影到最近有效边缘，上界取 maxX-1/maxY-1（maxX 是外沿不是可用像素）；③ 显示器 ID 失效/已拔掉时**拒绝执行并 onError 上报**，绝不静默回退主屏——那会把这次点击送到完全错误的应用上。
Server.swift: HTTP :46387 / HTTPS :46487 共用路由，专用解锁强制 TLS、配对和控制租约；，全部端点路由与静态页面服务；/api/screen/* 读写均鉴权、全局单次采集限流，异步读取不阻塞输入，向控制台暴露局域网及 Tailscale 私网地址并生成带配对 token 的二维码；只翻译协议不做系统调用，写操作委托 InputExecutor；/api/status 下发 targets 含 per-app shortcuts/openPanel、/api/targets 保存时对专属快捷键做 resolve 校验 + id 去重、openPanel 白名单清洗；与 WSServer 平行。
CursorMonitor.swift: 光标观测层——仅在有订阅者时以约 30Hz 读 `CGEvent(source: nil)?.location`（**只读位置不需要辅助功能权限，发事件才需要**），对照 CGDisplayBounds 判定显示器归属（矩形语义 minX<=x<maxX 天然避开 maxX 越界），输出 seq + displayId + 归一化 rx/ry；位置未变只发 1 秒心跳，订阅数归零立刻停表。**它只观测、从不写入 PointerExecutor**——观测值与命令期望值混在一起，就会出现实体鼠标一动、手机再发相对移动就跳回旧位置的鬼畜。
WSServer.swift: 控制与光标 WebSocket（HTTP 端口 +1）；认证后一个控制者，其余观看，显式接管及 2 秒心跳租约。可靠消息队列和最新光标分离；断线仅释放控制者按键。isController 供 HTTP 输入在执行前验证。
main.swift: 组装 HTTP、控制和画面三项服务，注入跨通道租约验证，选择端口、资源路径并维护 macOS 应用身份。

InputFocus.swift: AX 三态焦点能力与诊断快照，提供只读探测、带 PID 校验的焦点元素、鼠标命中可编辑元素或当前聚焦窗口同一 WebArea 的核验及首页显式聚焦；以页面矩形容忍 Chromium AX 对象重建，同时排除浏览器控件/后台窗口/其他应用，候选查找有界；只读探针不返回正文。
InputBinding.swift: 10 分钟短期输入上下文；AX 可识别时绑定输入元素并在上下文中返回当前文本，传统编辑元素不可见时仍保留聚焦 WebArea；常规写入校验同一聚焦元素，Chrome 多图锚点允许在同一 PID、聚焦窗口与当前 WebArea 内重新核验，失效后拒绝草稿写入。
NetworkPeer.swift: 基于真实远端地址判断回环，控制与画面握手共用，不信任客户端自报主机名。
ScreenStream.swift: ScreenCaptureKit 持续采样目标 30fps、1280/1920 宽 JPEG；只保留最新待编码帧，捕获器确认 idle 时复用静态画面，不落盘。
FrameServer.swift: 独立画面 WebSocket（HTTP 端口 +2），同屏同质量共享采集器；每客户端一帧在途和一帧最新待发，浏览器呈现 ACK 后续发，超时关闭，最后观看者离开时停采集。

LiveDraft.swift: 单轮文本事务；空框接管、全文/UTF-16 选区核验、replace/selection/deferred 固定模式、冲突停止、显式重试核验原文/上次尝试值与提交封闭，系统访问依赖 DraftEditor 或选区写入回调。
AXDraftEditor.swift: 纯文本 AX 适配；首版限定 TextEdit 已保存的 .txt 空白文档，整值写入并读回，其他应用不能只凭可写标记开放。

KeyboardDraftWriter.swift: 通用实时输入；已有正文和插入选区作为边界，追加立即输入，修订一次选中本轮旧尾部再替换；AX 可读时核验前后文/选区，否则仅有绑定及有序键流证据，回执不能声称已核验；核验恢复只接受原控件已落入尝试全文，或明确未落键且基线相符的状态，不把旧读数视为未输入证明；失败通过 diagnostic 提供阶段、正文是否相等、UTF-16 长度和选区，不记录正文，由 InputExecutor 写入既有动作日志。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

SecureTransport.swift: 从本机私有 DER 证书与私钥在**内存**中装配 TLS 身份（`SecKeyCreateWithData` + `SecIdentityCreate`，全程不进钥匙串，故没有上锁、没有 ACL、没有密码询问），为 HTTP、控制和画面建立 TLS 监听；不修改客户端信任，并对外给出 CA 证书路径供手机下载。
LockScreenInput.swift: 锁屏专用一次性挑战与物理按键执行；绑定租约和会话代际，取消/解锁失效，不经草稿与日志，不自动重试。
