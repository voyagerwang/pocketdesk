/**
 * [INPUT]: 依赖 Foundation 的 FileManager/Codable 与 AppKit 的 NSWorkspace；消费 Models 的 TargetConfig/ShortcutConfig。
 * [OUTPUT]: 对外提供 TargetStore（targets.json/shortcuts.json 读写、目标解析、appURL 定位、自定义图标路径与孤儿图标清理）。
 * [POS]: Sources 的配置持久化层；Server 把它暴露为 /api/targets 等端点，InputExecutor 用 resolve/appURL 定位应用。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

final class TargetStore {
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoiceDeck", isDirectory: true)
    static let configFile = supportDirectory.appendingPathComponent("targets.json")
    static let iconDirectory = supportDirectory.appendingPathComponent("icons", isDirectory: true)
    static let defaultTargets: [TargetConfig] = [
        .init(id: "chatgpt", name: "ChatGPT", bundleID: "com.openai.chat", path: "/Applications/ChatGPT.app"),
        .init(id: "feishu", name: "飞书", bundleID: "com.electron.lark", path: "/Applications/Feishu.app"),
        .init(id: "chrome", name: "Chrome", bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app"),
        .init(id: "zcode", name: "ZCode", bundleID: "dev.zcode.app", path: "/Applications/ZCode.app"),
        .init(id: "workbody", name: "Workbody", bundleID: nil, path: "/Applications/Workbody.app"),
        .init(id: "wechat", name: "微信", bundleID: "com.tencent.xinWeChat", path: "/Applications/WeChat.app"),
        .init(id: "uu", name: "UU远程", bundleID: "com.netease.uuremote", path: "/Applications/UURemote.app"),
    ]

    private(set) var targets: [TargetConfig] = TargetStore.defaultTargets

    init() {
        if let data = try? Data(contentsOf: TargetStore.configFile),
           let decoded = try? JSONDecoder().decode([TargetConfig].self, from: data), !decoded.isEmpty {
            targets = decoded
        }
    }

    func save(_ list: [TargetConfig]) {
        targets = list
        try? FileManager.default.createDirectory(at: TargetStore.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: TargetStore.configFile, options: .atomic)
        }
        // 清理已删除目标遗留的自定义图标。
        let live = Set(list.map { $0.id })
        if let files = try? FileManager.default.contentsOfDirectory(atPath: TargetStore.iconDirectory.path) {
            for file in files where file.hasSuffix(".png") && !live.contains(String(file.dropLast(4))) {
                try? FileManager.default.removeItem(at: TargetStore.iconDirectory.appendingPathComponent(file))
            }
        }
    }

    func resolve(_ id: String) -> TargetConfig? { targets.first { $0.id == id } }

    func appURL(_ config: TargetConfig) -> URL? {
        if let path = config.path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bundleID = config.bundleID {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        return nil
    }

    func customIconURL(_ id: String) -> URL { TargetStore.iconDirectory.appendingPathComponent("\(id).png") }

    // MARK: 快捷键配置（与目标应用同一支持目录，独立文件）
    static let shortcutFile = supportDirectory.appendingPathComponent("shortcuts.json")
    static let defaultShortcuts: [ShortcutConfig] = [
        .init(id: "undo", label: "撤销", modifiers: ["command"], keycode: 7),   // Cmd+Z
        .init(id: "copy", label: "复制", modifiers: ["command"], keycode: 8),   // Cmd+C
        .init(id: "paste", label: "粘贴", modifiers: ["command"], keycode: 9),  // Cmd+V
    ]

    private(set) var shortcuts: [ShortcutConfig] = TargetStore.defaultShortcuts

    func loadShortcuts() {
        if let data = try? Data(contentsOf: TargetStore.shortcutFile),
           let decoded = try? JSONDecoder().decode([ShortcutConfig].self, from: data) {
            shortcuts = decoded
        }
    }

    func saveShortcuts(_ list: [ShortcutConfig]) {
        shortcuts = list
        try? FileManager.default.createDirectory(at: TargetStore.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: TargetStore.shortcutFile, options: .atomic)
        }
    }

    // MARK: 主题（classic ↔ muji；电脑端控制台是唯一控制点，手机页经 /api/status 跟随）
    static let themeFile = supportDirectory.appendingPathComponent("theme")

    // 默认经典蓝：Muji 作为可选的克制主题保留。
    private(set) var theme: String = "classic"

    func loadTheme() {
        if let saved = try? String(contentsOf: TargetStore.themeFile, encoding: .utf8) {
            let name = saved.trimmingCharacters(in: .whitespaces)
            if name == "muji" || name == "classic" { theme = name }
        }
    }

    func saveTheme(_ name: String) {
        guard name == "muji" || name == "classic" else { return }
        theme = name
        try? FileManager.default.createDirectory(at: TargetStore.supportDirectory, withIntermediateDirectories: true)
        try? name.write(to: TargetStore.themeFile, atomically: true, encoding: .utf8)
    }
}
