# Sources/
> L2 | 父级: ../CLAUDE.md

成员清单

Models.swift: 传输与配置的值类型词汇表——SendCommand/PendingImage/ActivateCommand/IconUpload 请求体、ShortcutConfig/TargetConfig 配置实体、ShortcutKeys 键码翻译表、ShortcutError/InputError 错误，纯 Codable/Equatable 无系统依赖（仅 CoreGraphics 键码类型）。
TargetStore.swift: 目标应用、快捷键与主题三份配置的持久化层，~/Library/Application Support/VoiceDeck 下的 targets.json/shortcuts.json/theme 读写，含 appURL 定位、自定义图标路径与孤儿图标清理；Server 与 InputExecutor 共用。主题是产品级外观决策，唯一写入点在电脑端控制台（POST /api/theme），手机页只读跟随。
AppDiscovery.swift: 无状态的应用发现层，扫描 /Applications 等目录做名称/路径搜索，并为新增目标生成安全 slug；/api/apps 搜索与 /api/targets id 补齐依赖它。
Util.swift: 无状态渲染工具层——主局域网 IP、macOS utun 上的 Tailscale 100.64.0.0/10 地址探测、稳定 .local 主机名、QR PNG、应用图标 PNG 提取；Server 的地址与图标端点调用它。
Auth.swift: 鉴权层——配对 token 的首次生成（SecRandomCopyBytes 32 字节 base64url）、持久化到 Application Support/VoiceDeck/token、写请求 Bearer 校验与 WS 首帧校验（恒定时间比较）；Server 与 WSServer 共用。
InputExecutor.swift: 键盘输入执行层，串行队列跑 activate → Unicode → 粘贴图片 → Return（文字先落入编辑器，避免附件挂载打断输入焦点） 注入序列，含图片预上传暂存与快捷键组合注入；与 PointerExecutor 平行。
PointerExecutor.swift: 指针执行层，虚拟光标 + 双屏包围盒钳制，move/drag/click/scroll/zoom 手势到 CGEvent 的映射；仅被 WSServer 消费。
Server.swift: HTTP 传输层 :46387，全部端点路由与静态页面服务，向控制台暴露局域网及 Tailscale 私网地址并生成带配对 token 的二维码；只翻译协议不做系统调用，写操作委托 InputExecutor；与 WSServer 平行。
WSServer.swift: 触控板传输层 :46388，WebSocket 监听、首帧 token 鉴权、会话重置与消息转发到 PointerExecutor。
main.swift: 唯一入口与组装根，web 根定位、端口选择（VOICE_DECK_PORT）、辅助功能授权提示、双服务启动、AppDelegate 的 Dock 应用身份；不再含业务逻辑。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
