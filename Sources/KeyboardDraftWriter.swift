/**
 * [INPUT]: 依赖 InputFocus 的真实焦点、DraftSnapshot、AppKit AX；按键和文本事件由 InputExecutor 注入。
 * [OUTPUT]: 提供 KeyboardDraftWriter；追加实时输入、选区修订及不含正文的失败诊断，失败后只依据原控件快照或未落键证据恢复。
 * [POS]: Sources 的通用编辑器兼容通道；可读 AX 时校验原文和选区，未知编辑器沿用绑定和有序键流，不伪造读回。
 * [PROTOCOL]: update 的删除路径对 Electron/受控输入框自适应降级（AX 选区“假成功”时改走键盘 Shift+Left）；变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

final class KeyboardDraftWriter {
    private let valid: () -> Bool
    private let key: (CGKeyCode, CGEventFlags) -> Bool
    private let insert: (String) -> Bool
    private let readSnapshot: (() -> DraftSnapshot?)?
    private let selectRange: ((CFRange) -> Bool)?
    private var expected: DraftSnapshot?
    private let prefix: String
    private let suffix: String
    private let start: Int
    private let initialSelection: Int
    private var first = true
    private var uncertainWrite = false
    private var axSelectionReliable = true
    private var lastRemoved = 0
    private(set) var diagnostic = ""

    convenience init(pid: pid_t, valid: @escaping () -> Bool,
         key: @escaping (CGKeyCode, CGEventFlags) -> Bool, insert: @escaping (String) -> Bool) {
        let focused = InputFocus.focusedElement(pid: pid)
        self.init(read: focused.map { element in { Self.read(element) } },
                  select: focused.map { element in { Self.setRange(element, $0) } }, valid: valid, key: key, insert: insert)
    }

    // 系统读取与输入执行分离，隔离测试可验证选区边界，不需要真实桌面权限。
    init(read: (() -> DraftSnapshot?)?, select: ((CFRange) -> Bool)?, valid: @escaping () -> Bool,
         key: @escaping (CGKeyCode, CGEventFlags) -> Bool, insert: @escaping (String) -> Bool) {
        self.valid = valid; self.key = key; self.insert = insert
        let snapshot = read?()
        readSnapshot = snapshot == nil ? nil : read
        selectRange = snapshot == nil ? nil : select
        expected = snapshot
        if let snapshot {
            let value = snapshot.text as NSString
            start = snapshot.location; initialSelection = snapshot.length
            prefix = value.substring(to: snapshot.location)
            suffix = value.substring(from: snapshot.location + snapshot.length)
        } else { start = 0; initialSelection = 0; prefix = ""; suffix = "" }
    }

    func update(from old: String, to new: String) -> Bool {
        diagnostic = "写入前：输入绑定或控制租约失效"
        guard valid(), matchesExpected() else { return false }
        if old == new { return true }
        let before = Array(old), after = Array(new)
        var common = 0
        while common < before.count && common < after.count && before[common] == after[common] { common += 1 }
        let removed = before.count - common
        let replacement = String(after[common...])
        let offset = String(before[..<common]).utf16.count
        let selection = CFRange(location: start + offset,
                                length: first ? initialSelection : old.utf16.count - offset)
        if removed > 0 {
            diagnostic = "修订选区未能建立"
            uncertainWrite = true
            lastRemoved = removed
            // 真实 AX 选区能一次定位，优先用它；但 Electron/受控输入框常“报告成功却不落 DOM”，
            // 故一旦 waitForSelection 失败就标记本写入器不再信任 AX 选区，后续删除改走键盘 Shift+Left。
            // 首帧走 AX 快路径，原生应用无感；受控应用首次失败后永久切键盘，避免每次删除卡顿。
            if axSelectionReliable, selectRange?(selection) == true, waitForSelection(selection) {
                // AX 选区已立住，进入落键阶段。
            } else {
                axSelectionReliable = false
                guard matchesExpected() else { return false }
                guard removed <= 8_000 else { return false }
                for _ in 0..<removed {
                    guard valid(), key(123, .maskShift) else { return false }
                }
            }
        }
        diagnostic = "落键前：输入绑定或控制租约失效"
        guard valid() else { return false }
        uncertainWrite = true
        diagnostic = "文本事件未能发出"
        // 空替换是用户主动删除：一次删除整个选区；纠正文字时完全不发送 Delete。
        if replacement.isEmpty {
            guard key(51, []) else { return false }
        } else if !insert(replacement) { return false }
        first = false
        if let readSnapshot {
            let desired = DraftSnapshot(text: prefix + new + suffix, location: start + new.utf16.count, length: 0)
            for _ in 0..<12 {
                guard valid() else { diagnostic = "落键后：输入绑定或控制租约失效"; return false }
                let actual = readSnapshot()
                if actual == desired { expected = desired; uncertainWrite = false; diagnostic = ""; return true }
                diagnostic = Self.describe("落键后读回", expected: desired, actual: actual)
                usleep(15_000)
            }
            // 若本轮确有删除且读回始终对不上，多半是 AX 选区“假成功”没真落 DOM；
            // 标记后下次（只读探测恢复后）删除改走键盘，避免永久删不全。
            if lastRemoved > 0 { axSelectionReliable = false }
            return false
        }
        uncertainWrite = false
        diagnostic = ""
        return true
    }

    /// 整段清空（手机把草稿删空 = 两边一起清）。
    /// 与 `update` 的两点关键差别，都是为"清空之后再不同步"这个死法准备的：
    /// 1) **不校验创建时的基线**。基线是捕获那一刻按 `prefix/suffix` 算出来的，快捷键通道
    ///    （全选/删除）或应用自身重建编辑器都会让它永久分叉；拿它当门槛就永远过不去。
    ///    清空是幂等的——删光的结果与当前内容无关，所以放宽这条没有重复输入的风险。
    /// 2) **用当前实际内容算选区**，不拿旧的 prefix/suffix 反推"本轮那一段"。
    /// 纸面放宽不换取凭空认账：只有读回为空才算成功，否则一律返回 false 交给上层冻结。
    func clearAll() -> Bool {
        guard valid() else { diagnostic = "清空前：输入绑定或控制租约失效"; return false }
        guard let readSnapshot, let current = readSnapshot() else {
            diagnostic = "清空前：原控件快照不可读"
            return false
        }
        let count = current.text.utf16.count
        // 已经是空的：幂等认账，也覆盖"外部（快捷键/应用自己）已经替我们删好了"。
        if count == 0 { uncertainWrite = false; diagnostic = ""; return true }
        uncertainWrite = true
        diagnostic = "清空：修订选区未能建立"
        if selectRange?(CFRange(location: 0, length: count)) == true {
            // 只读等待选区落地；不重放、不追加。
            let desired = DraftSnapshot(text: current.text, location: 0, length: count)
            var landed = false
            for _ in 0..<8 {
                guard valid() else { diagnostic = "清空：输入绑定或控制租约失效"; return false }
                if let actual = readSnapshot(), actual == desired { landed = true; break }
                diagnostic = Self.describe("清空选区读回", expected: desired, actual: readSnapshot())
                usleep(10_000)
            }
            guard landed else { return false }
        } else {
            // 选区设不了：只有"光标停在文末且无选中"才敢播退格流，否则无从确定删的是什么。
            guard current.length == 0, current.location == count, count <= 8_000 else {
                diagnostic = "清空：无法确定删除范围（控件不支持设置选区）"
                return false
            }
            for _ in 0..<count {
                guard valid(), key(123, .maskShift) else { return false }
            }
        }
        diagnostic = "清空：删除未能发出"
        guard valid(), key(51, []) else { return false }
        let empty = DraftSnapshot(text: "", location: 0, length: 0)
        for _ in 0..<12 {
            guard valid() else { diagnostic = "清空后：输入绑定或控制租约失效"; return false }
            if let actual = readSnapshot(), actual.text.isEmpty {
                uncertainWrite = false; diagnostic = ""
                return true
            }
            diagnostic = Self.describe("清空后读回", expected: empty, actual: readSnapshot())
            usleep(15_000)
        }
        return false
    }

    // 不重新捕获另一个输入框；只核对本轮原控件，已落入的文字绝不再追加。
    func confirmedText(previous: String, attempted: String) -> String? {
        guard valid() else { return nil }
        guard let readSnapshot else { return uncertainWrite ? nil : previous }
        guard let actual = readSnapshot() else { return nil }
        // 曾发出写入但仍读到旧值，不等于没有落字；可能只是目标应用尚未处理。
        if actual == expected && !uncertainWrite { return previous }
        let desired = DraftSnapshot(text: prefix + attempted + suffix, location: start + attempted.utf16.count, length: 0)
        guard actual == desired else { return nil }
        expected = desired; first = false; uncertainWrite = false
        return attempted
    }

    private func matchesExpected() -> Bool {
        guard let readSnapshot, let expected else { return true }
        let actual = readSnapshot()
        if actual == expected { return true }
        diagnostic = Self.describe("写入前基线", expected: expected, actual: actual)
        return false
    }
    // 只保留长度、选区和相等关系；错误记录不得包含用户正文。
    private static func describe(_ stage: String, expected: DraftSnapshot, actual: DraftSnapshot?) -> String {
        guard let actual else { return "\(stage)：原控件快照不可读" }
        return "\(stage)：textEqual=\(actual.text == expected.text)，utf16=\(actual.text.utf16.count)/\(expected.text.utf16.count)，selection=\(actual.location):\(actual.length)/\(expected.location):\(expected.length)"
    }
    private func waitForSelection(_ range: CFRange) -> Bool {
        guard let readSnapshot, let expected else { return false }
        for _ in 0..<8 {
            guard valid() else { return false }
            let desired = DraftSnapshot(text: expected.text, location: range.location, length: range.length)
            let actual = readSnapshot()
            if actual == desired { return true }
            diagnostic = Self.describe("选区读回", expected: desired, actual: actual)
            usleep(10_000)
        }
        return false
    }
    private static func setRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
    static func read(_ element: AXUIElement) -> DraftSnapshot? {
        func attr(_ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        guard let role = attr(kAXRoleAttribute) as? String, [kAXTextAreaRole, kAXTextFieldRole].contains(role),
              (attr(kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole,
              let text = attr(kAXValueAttribute) as? String,
              let raw = attr(kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return nil }
        return .init(text: text, location: range.location, length: range.length)
    }
}
