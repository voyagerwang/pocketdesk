/**
 * [INPUT]: 依赖 Foundation；产出的按键串交由 Models 的 ShortcutKeys 解析（同一链路，不另起炉灶）。
 * [OUTPUT]: 对外提供 Platform（按键投递目标平台）与 ShortcutAction（预设动作库：语义 id ↔ 各平台按键串 ↔ 中文名）。
 * [POS]: Sources 的动作定义层，纯数据无副作用；InputExecutor 触发时查表展开按键，
 *        Server 在 /api/shortcuts 校验并在 /api/status 下发可选列表给控制台。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

// 按键投递的目标平台。同一个语义动作在不同系统上按键不同（锁屏：Mac Cmd+Ctrl+Q / Windows Win+L）。
enum Platform: String, Codable, CaseIterable {
    case macOS
    case windows

    // 当前宿主平台。PocketDesk 现只跑 macOS；windows 串用于跨平台配置的正确表达与远程通道。
    static let current: Platform = .macOS
}

// 预设动作：浏览器录制不到、但高频需要的系统/应用操作。
// 录不到的原因是这些组合按下即被浏览器或系统本身消费（Cmd+Q 退出浏览器、Cmd+Ctrl+Q 真的锁屏），
// 捕获器拿不到 keydown——不是实现问题，是平台边界。故改为点选添加，不经过录制。
enum ShortcutAction: String, CaseIterable {
    case lockScreen = "system.lock"
    case quitApp = "app.quit"
    case closeWindow = "window.close"
    case hideApp = "app.hide"
    case switchApp = "app.switch"

    var label: String {
        switch self {
        case .lockScreen: return "锁屏"
        case .quitApp: return "退出应用"
        case .closeWindow: return "关闭窗口"
        case .hideApp: return "隐藏应用"
        case .switchApp: return "切换应用"
        }
    }

    // 各平台按键串。与录制得到的 hotkey 同语法，最终都交给 ShortcutKeys.resolve。
    // Windows 的 Win 键在 ShortcutKeys.modifierMap 中归一到 Cmd（GUI 键同义），
    // 因为 Mac 键盘发往 Windows 时 Cmd 位置即对应 Win。
    func hotkey(_ platform: Platform) -> String {
        switch (self, platform) {
        case (.lockScreen, .macOS): return "Cmd+Ctrl+Q"
        case (.lockScreen, .windows): return "Win+L"
        case (.quitApp, .macOS): return "Cmd+Q"
        case (.quitApp, .windows): return "Alt+F4"
        case (.closeWindow, .macOS): return "Cmd+W"
        case (.closeWindow, .windows): return "Ctrl+W"
        case (.hideApp, .macOS): return "Cmd+H"
        case (.hideApp, .windows): return "Win+Down"   // Windows 无"隐藏"概念，最接近的是最小化当前窗口
        case (.switchApp, .macOS): return "Cmd+Tab"
        case (.switchApp, .windows): return "Alt+Tab"
        }
    }

    static func find(_ id: String) -> ShortcutAction? { ShortcutAction(rawValue: id) }
}

// 投递通道。实测三条路各有边界，才有这张表的必要：
// 1) CGEvent 注入到不了系统快捷键守护进程（有辅助功能授权时发 Cmd+Space 仍弹不出 Spotlight）；
// 2) 交给 System Events 代发要额外勾「自动化」授权（实测报"未获得授权将Apple事件发送给System Events"），
//    让用户为锁屏再授权一次不值得；
// 3) 应用内菜单键并非所有应用都实现：实测微信在前台时注入 Cmd+W 毫无反应（官方快捷键表列了 Cmd+W，
//    但主窗口不响应合成按键），故"关闭窗口"改为直接用辅助功能按窗口的关闭按钮。
// 故系统级动作改为「直接调用系统能力」，窗口级动作走 AX，只有纯应用内菜单键才依赖 CGEvent。
enum ActionDelivery {
    case keyEvent          // CGEvent 注入前台应用：退出应用
    case systemCommand     // 直接跑系统命令：锁屏（关屏 + 系统"需要密码"即等效锁）
    case switchPreviousApp // AppKit 按窗口 z-order 切到上一个应用，不碰系统快捷键
    case axCloseWindow     // 辅助功能按前台窗口的关闭按钮；取不到按钮时回退 keyEvent（Cmd+W）
    case hideFrontApp      // AppKit 隐藏前台应用：不经按键也不经 AX，任何应用都吃
}

extension ShortcutAction {
    var delivery: ActionDelivery {
        switch self {
        case .lockScreen: return .systemCommand
        case .switchApp: return .switchPreviousApp
        case .closeWindow: return .axCloseWindow
        case .hideApp: return .hideFrontApp
        case .quitApp: return .keyEvent
        }
    }

    // 系统命令形式的实现（与按键无关，故不经过 ShortcutKeys）。
    // macOS 关屏即锁（需系统已开启"需要密码"）；Windows 用标准的 LockWorkStation。
    func command(_ platform: Platform) -> String? {
        switch (self, platform) {
        case (.lockScreen, .macOS): return "/usr/bin/pmset displaysleepnow"
        case (.lockScreen, .windows): return "rundll32.exe user32.dll,LockWorkStation"
        default: return nil
        }
    }
}

extension ShortcutConfig {
    // 落盘前的唯一规范化点：动作项按平台重写 hotkey（以服务端为准，前后端不可能不一致），
    // 普通项沿用录制值但必须可解析；不合法返回 nil 由调用方丢弃。
    // /api/shortcuts 与 /api/targets 的专属快捷键共用，避免两处校验逻辑走偏。
    func normalized(platform: Platform = .current) -> ShortcutConfig? {
        var next = self
        if let actionId = action, !actionId.isEmpty, let action = ShortcutAction.find(actionId) {
            next.action = actionId
            next.hotkey = action.hotkey(platform)
            return next
        }
        next.action = nil
        guard ShortcutKeys.resolve(next.hotkey) != nil else { return nil }
        return next
    }
}
