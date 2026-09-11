/**
 * [INPUT]: 依赖 Foundation 的 Codable 与 CoreGraphics 的 CGEventFlags/CGKeyCode。
 * [OUTPUT]: 对外提供传输与配置层的全部值类型：SendCommand/LiveInputCommand/LiveInputReceipt（草稿 ID、整值/选区/暂存模式、显式核验重试、提交动作确认）/PendingImage/ActivateCommand/IconUpload
 *           请求体、ShortcutConfig/TargetConfig 配置实体（TargetConfig 含按应用专属快捷键、默认打开面板、叠加全局组开关）、
 *           ShortcutKeys 语义串解析器（resolve 解析、canonicalize 别名归一、legacyHotkey 旧格式迁移）、
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

// 全文快照：草稿 ID 在首页和全屏之间保持一致，提交完成后才创建下一轮。
struct LiveInputCommand: Decodable {
    let draftId: String?
    let expectedMode: String? // 已确认 replace/selection 后不能在会话丢失时降级并重发全文。
    let session: String?
    let context: String?
    let text: String
    let targetId: String?
    let submit: Bool?
    let usePendingImage: Bool?
    let imageBatchId: String?
    let imageIds: [String]?
    let reset: Bool? // 仅用于拒绝旧式基线重置，不再接受未经核验的远端文本。
    let retry: Bool? // 用户再次发送时请求核对原会话；不允许直接重置或重放全文。
    // 只读恢复探测：只核验控制租约/目标应用/原编辑位置/电脑内容，不写入任何字符。
    // 手机端在弹窗关闭、页面回前台、输入框重新聚焦时发它，据此决定能否自动续接。
    let probe: Bool?
}

struct LiveInputReceipt {
    let feedback: ExecutionFeedback
    let mode: String
    let committed: Bool // 仅表示提交动作执行过，不表示第三方服务收到了消息。
    // 结构化状态码，前端据它决定"继续写 / 冻结 / 提示用户点一下"，而不是解析人话文案。
    let state: String
    let note: String
    var dictionary: [String: Any] {
        ["ok": true, "outcome": feedback.outcome.rawValue, "detail": feedback.detail,
         "mode": mode, "committed": committed, "state": state, "note": note]
    }
}

/// 草稿路径的结构化失败：人类文案与状态码分开，Server 原样透传两者。
struct LiveInputFailure: Error {
    let message: String
    let state: String
}

// 手机选图后立即预上传的请求体。
struct PendingImage: Decodable {
    let data: String
    let batchId: String?
    let imageId: String?
}

struct ActivateCommand: Decodable {
    let targetId: String
    // 显式定位意图：只在手机**手动选择应用**时置位。默认关闭以兼容旧客户端——
    // 自动跟随、发送文本的隐式激活、恢复探针都不会带它，也就不会有鼠标副作用。
    let locate: Bool?
    // 选择代际：只有不早于已执行最大代际的定位才会生效，乱序回执不得抢走最新一次选择。
    let generation: Int?
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
    // 语义动作 id（如 "system.lock"）。非空时优先于 hotkey：hotkey 只是当前平台的展示/回退值，
    // 实际按键由 ShortcutAction 按平台展开。旧存档无此字段时解码为 nil，行为不变。
    var action: String?

    // 实际要发的按键串：动作项按当前平台展开，普通项用录制值。
    var effectiveHotkey: String {
        action.flatMap(ShortcutAction.find)?.hotkey(.current) ?? hotkey
    }

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
        // Windows 的 GUI 键：Mac 键盘发往 Windows 时 Cmd 位置即对应 Win，故归一到同一 flag。
        "win": .maskCommand, "super": .maskCommand,
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
    // 应用专属快捷键：非空时整组覆盖全局（手机端只展示这组，全局不显示）。
    // nil/空 = 用全局组；保留默认三条让用户在应用里复用常见操作而无需重录。
    var shortcuts: [ShortcutConfig]?
    // 激活此应用时手机默认打开的面板："input" 输入框（默认）/ "pad" 触控板；nil = input。
    var openPanel: String?
    // 应用专属组启用时是否叠加全局组（手机端前排专属、后排全局）。
    // nil/true = 叠加（默认，常用键改一处全应用受益）；false = 只显应用组。
    var showGlobal: Bool?
}
