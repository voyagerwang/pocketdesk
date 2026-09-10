/**
 * [INPUT]: 依赖 InputFocus 的真实焦点、DraftSnapshot、AppKit AX；按键和文本事件由 InputExecutor 注入。
 * [OUTPUT]: 提供 KeyboardDraftWriter；追加实时输入、选区修订及不含正文的失败诊断，失败后只依据原控件快照或未落键证据恢复。
 * [POS]: Sources 的通用编辑器兼容通道；可读 AX 时校验原文和选区，未知编辑器沿用绑定和有序键流，不伪造读回。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
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
            // 真实 AX 选区能一次定位，不用播放选中字的键流；不可写时只选择已有的本轮尾部。
            if selectRange?(selection) == true {
                guard waitForSelection(selection) else { return false }
            } else {
                guard matchesExpected() else { return false }
                guard removed <= 8_000 else { return false }
                for _ in 0..<removed {
                    guard valid(), key(123, .maskShift) else { return false }
                }
                if readSnapshot != nil && !waitForSelection(selection) { return false }
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
            return false
        }
        uncertainWrite = false
        diagnostic = ""
        return true
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
