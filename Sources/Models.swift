/**
 * [INPUT]: 依赖 Foundation 的 Codable 与 CoreGraphics 的 CGEventFlags/CGKeyCode。
 * [OUTPUT]: 对外提供传输与配置层的全部值类型：SendCommand/PendingImage/ActivateCommand/IconUpload
 *           请求体、ShortcutConfig/TargetConfig 配置实体、ShortcutKeys 语义串解析器（resolve 解析、canonicalize 别名归一、legacyHotkey 旧格式迁移）、
 *           ShortcutError/InputError 错误类型。
 * [POS]: Sources 的协议层；Server 反序列化请求体、TargetStore 持久化配置、InputExecutor 消费命令，全部以此为词汇表。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CoreGraphics
import Foundation

struct SendCommand: Decodable {
    let targetId: String
    let text: String
    // 可选：内联 base64 图片（兼容旧客户端）。新流程走 usePendingImage。
    let image: String?
    // true = 图片已随 /api/image 预先上传，发送时由服务端取出。
    let usePendingImage: Bool?
}

// 手机选图后立即预上传的请求体。
struct PendingImage: Decodable {
    let data: String
}

struct ActivateCommand: Decodable {
    let targetId: String
}

struct IconUpload: Decodable {
    let id: String
    let data: String
}

// 手机快捷键按钮：label 显示在按钮上，hotkey 是语义串（"Cmd+Shift+Z"、"Return"、"F5"），
// 布局无关、单一真源；注入前由 ShortcutKeys.resolve 统一解析为 CGEvent 键码与修饰 flags。
struct ShortcutConfig: Codable, Equatable {
    var id: String
    var label: String
    var hotkey: String

    // 历史版本 id 按序号生成，存在撞车（两条 shortcut-4 导致触发永远命中第一条）。
    static func dedupeIds(_ list: [ShortcutConfig]) -> [ShortcutConfig] {
        var seen = Set<String>()
        return list.map { shortcut in
            var next = shortcut
            if next.id.isEmpty || seen.contains(next.id) { next.id = UUID().uuidString }
            seen.insert(next.id)
            return next
        }
    }
}

enum ShortcutError: Error { case message(String) }

// 快捷键语义串 → CGKeyCode/CGEventFlags 的唯一解析真源（macOS ANSI 虚拟键码）。
// 语法对齐 Easy Input："+" 分隔 token，空白/大小写宽松；Ctrl/Control、Opt/Option、Cmd/Meta 等同义词归一。
enum ShortcutKeys {
    // macOS ANSI 虚拟键码并非字母顺序；语义串字母 token → 键码。
    static let letterKeycodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]
    static let digitKeycodes: [String: CGKeyCode] = [
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
    static let modifierMap: [String: CGEventFlags] = [
        "command": .maskCommand, "cmd": .maskCommand, "meta": .maskCommand, "gui": .maskCommand,
        "shift": .maskShift,
        "option": .maskAlternate, "opt": .maskAlternate, "alt": .maskAlternate,
        "control": .maskControl, "ctrl": .maskControl,
    ]
    static let keyMap: [String: CGKeyCode] = [
        "up": 126, "down": 125, "left": 123, "right": 124,
        "return": 36, "enter": 36, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "space": 49, "tab": 48,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
    // 解析结果：主键键码 + 已合成的修饰 flags，供 CGEvent 直接使用。
    struct Resolved {
        let keycode: CGKeyCode
        let flags: CGEventFlags
    }

    static func normalize(_ token: String) -> String {
        token.lowercased().filter { $0 != " " && $0 != "_" && $0 != "-" }
    }

    // 解析整条语义串；任一 token 无法识别（含纯修饰键、fn、多主键）返回 nil。
    static func resolve(_ hotkey: String) -> Resolved? {
        var flags = CGEventFlags()
        var keycode: CGKeyCode?
        for raw in hotkey.split(separator: "+") {
            let token = normalize(String(raw))
            guard !token.isEmpty else { continue }
            if let flag = modifierMap[token] { flags.insert(flag); continue }
            guard let code = keyMap[token] ?? letterKeycodes[token] ?? digitKeycodes[token], keycode == nil else { return nil }
            keycode = code
        }
        guard let keycode else { return nil }
        return Resolved(keycode: keycode, flags: flags)
    }

    // 旧 shortcuts.json（modifiers 数组 + keycode 数字）迁移到语义串的唯一翻译点。
    static func legacyHotkey(modifiers: [String], keycode: Int) -> String? {
        // 主键反查：36/51/53 各有两个别名（return/enter、delete/backspace、escape/esc），
        // 优先取录制端 KEY_TOKENS 产物的规范名（Return/Delete/Escape），保证迁移结果与重录一致。
        let canonicalKeys = ["return", "delete", "escape"]
        var main: String? = nil
        if let named = canonicalKeys.first(where: { Int(keyMap[$0] ?? 0) == keycode }) { main = named }
        if main == nil, let letter = letterKeycodes.first(where: { Int($0.value) == keycode }) { main = letter.key }
        if main == nil, let digit = digitKeycodes.first(where: { Int($0.value) == keycode }) { main = digit.key }
        if main == nil { main = keyMap.first { Int($0.value) == keycode && !canonicalKeys.contains($0.key) }?.key }
        guard var mainName = main else { return nil }
        let names = modifiers.compactMap { Self.canonicalModifiers[normalize($0)] }
            .sorted { (Self.modifierOrder[$0] ?? 9) < (Self.modifierOrder[$1] ?? 9) }
        mainName = mainName.prefix(1).uppercased() + mainName.dropFirst()
        return (names + [mainName]).joined(separator: "+")
    }

    // 修饰键 token → 规范显示名（Cmd/Shift/Opt/Ctrl）；legacyHotkey 与 canonicalize 共用。
    static let canonicalModifiers: [String: String] = [
        "command": "Cmd", "cmd": "Cmd", "meta": "Cmd", "gui": "Cmd",
        "shift": "Shift", "option": "Opt", "opt": "Opt", "alt": "Opt",
        "control": "Ctrl", "ctrl": "Ctrl",
    ]
    // 规范输出序：Cmd → Shift → Opt → Ctrl，与录制端展示顺序一致。
    static let modifierOrder = ["Cmd": 0, "Shift": 1, "Opt": 2, "Ctrl": 3]

    // 语义串归一化：别名（Enter/Backspace/Esc）收敛到规范名（Return/Delete/Escape）、
    // 修饰键统一规范序与拼写。用于启动时清洗迁移残留与手写别名；不可解析原样返回，由保存校验兜底。
    static func canonicalize(_ hotkey: String) -> String {
        let canonicalKeys = ["return", "delete", "escape"]
        var mods: [String] = []
        var main: String?
        for raw in hotkey.split(separator: "+") {
            let token = normalize(String(raw))
            guard !token.isEmpty else { continue }
            if let canonical = canonicalModifiers[token] {
                if !mods.contains(canonical) { mods.append(canonical) }
                continue
            }
            guard main == nil,
                  let code = keyMap[token] ?? letterKeycodes[token] ?? digitKeycodes[token] else { return hotkey }
            // 反查主键规范名：36/51/53 优先规范别名，其余（字母/数字/F 键/方向）原样保留。
            if let named = canonicalKeys.first(where: { keyMap[$0] == code }) { main = named }
            else if let letter = letterKeycodes.first(where: { $0.value == code })?.key { main = letter }
            else if let digit = digitKeycodes.first(where: { $0.value == code })?.key { main = digit }
            else if let other = keyMap.first(where: { $0.value == code && !canonicalKeys.contains($0.key) })?.key { main = other }
        }
        guard var mainName = main else { return hotkey }
        let sortedMods = mods.sorted { (modifierOrder[$0] ?? 9) < (modifierOrder[$1] ?? 9) }
        mainName = mainName.prefix(1).uppercased() + mainName.dropFirst()
        return (sortedMods + [mainName]).joined(separator: "+")
    }
}

enum InputError: Error { case message(String) }

// MARK: - 目标应用配置（电脑端为唯一事实来源，顺序与成员都存在本机）

struct TargetConfig: Codable, Equatable {
    var id: String
    var name: String
    var bundleID: String?
    var path: String?
}
