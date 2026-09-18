/**
 * [INPUT]: 依赖 InputFocus 的真实焦点、DraftSnapshot、AppKit AX；按键和文本事件由 InputExecutor 注入。
 * [OUTPUT]: 提供 KeyboardDraftWriter；追加实时输入、选区修订及不含正文的失败诊断；Electron 整页 AX 文本在非编辑区漂移时，以本次插入片段+光标的局部证据认账。
 * [POS]: Sources 的通用编辑器兼容通道；可读 AX 时校验原文和选区，未知编辑器沿用绑定和有序键流，不伪造读回。
 * [PROTOCOL]: update 的删除路径三级降级且全部读回门控：AX 选区仍是首选（连败退避制——失败不再一票否决永久禁用，连败 3 次才放弃）；键盘路径先试 Cmd+A 单和弦整框全选（仅限“旧文本恰为整个输入框且光标在文末”，读回确认选区后交由注入覆盖，没立住先按 Right 还原光标并读回确认）；都没立住才逐字 Backspace（不依赖选区、每次独立删光标前一字）。空替换只补一次退格删选区，逐字路径已删净不再补刀（旧版多发一次退格把共同前缀多删一字，读回永远对不上目标而冻结草稿）。落键读回与 confirmedText 均以“电脑实际内容 == 手机目标”为权威成功判据；选区“立住”后读回仍对不上即视为 AX 读数说谎，AX 与 Cmd+A 本会话一并停用。clearAll 以“读回为空”为唯一成功判据：AX 设全选读回确认后一次退格，选区假成功或“落了却删不净”时改发真实键盘 Cmd+A + 退格并按结果核验（实测 ZCode），证明不了就如实失败；变更时更新此头部，然后检查 CLAUDE.md
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
    // AX 选区与 Cmd+A 和弦的连败计数：失败未必是永久状态（读回迟滞、快照越界都会误伤），
    // 连败达上限才在本次会话停用；任何一次读回确认成功即清零。
    private var axFailStreak = 0
    private var chordFailStreak = 0
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
        // 选区是否已被 AX / Cmd+A 立住：立住了就保持选中，空替换补一次退格、
        // 非空替换由注入文本直接覆盖；没立住才走逐字 Backspace。
        var selectionLaid = false
        if removed > 0 {
            diagnostic = "修订选区未能建立"
            uncertainWrite = true
            // 越界检测：建立绑定时的 start（光标位置）与手机端 diff 的 offset 直接相加得到的
            // location 可能超出电脑端实际文本长度。Chromium 对越界 setRange 常“夹取到边界并假成功”，
            // 使 waitForSelection 读回位置不符却已干扰选区，最终删不干净。越界即放弃 AX 路径。
            let textLen = expected?.text.utf16.count ?? Int.max
            let inBounds = selection.location >= 0 && selection.length >= 0
                && selection.location + selection.length <= textLen
            // AX 选区一次定位仍是首选（原生应用无感，成功即整段批量替换，零退格）。但失败
            // 未必是永久状态——读回迟滞、快照越界都会误伤，故按连败退避：连败 3 次本会话
            // 才放弃，任何一次读回确认成功即清零。
            let axEligible = axFailStreak < 3
            if axEligible, inBounds, selectRange != nil,
               selectRange?(selection) == true, waitForSelection(selection) {
                axFailStreak = 0
                selectionLaid = true
            } else {
                if axEligible, inBounds, selectRange != nil { axFailStreak += 1 }
                guard matchesExpected() else { return false }
                guard removed <= 8_000 else { return false }
                // 键盘路径先试 Cmd+A 整框全选：仅限“手机旧文本恰为整个输入框内容、光标在文末”
                // （空框起听写、整句改写最常见的形态）。单和弦一次选中，不被受控组件的重渲染
                // 中途重置；读回确认选区恰好覆盖全文后保持选中，交由下方注入覆盖。
                if removed > 2, chordFailStreak < 3, readSnapshot != nil,
                   start == 0, offset == 0,
                   let expected, old == expected.text,
                   expected.location == expected.text.utf16.count, expected.length == 0 {
                    // Swift 6.1 下 Bool? 的 `case true/false` 表达式模式不再被判为穷尽，
                    // 显式写 .some/.none 保持与原语义一致。
                    switch selectAllByChord(text: expected.text) {
                    case .some(true): selectionLaid = true; chordFailStreak = 0
                    case .none: chordFailStreak += 1        // 没立住但光标已确认还原，退回逐字
                    case .some(false): return false         // 光标还原不了，状态不明，如实失败
                    }
                }
                if !selectionLaid {
                    // 受控输入框（Electron/React）下 Shift+Left 逐字扩展选区会被组件重渲染重置，
                    // 实际只选到最后一格 → 删不干净。改用「逐字 Backspace」：Backspace（key 51，无字符）
                    // 不依赖选区，每次独立删光标前一字，对受控组件可靠。同步时光标本就在文末，
                    // 逐字退格即对齐手机末尾删除；每次之间等待组件消化，避免连续退格被吞。
                    for _ in 0..<removed {
                        guard valid(), key(51, []) else { return false }
                        usleep(20_000)
                    }
                }
            }
        }
        diagnostic = "落键前：输入绑定或控制租约失效"
        guard valid() else { return false }
        uncertainWrite = true
        diagnostic = "文本事件未能发出"
        // 空替换是用户主动删除：选区路径（AX/Cmd+A）一次删除整个选区；逐字路径已删净，不再补刀
        // （旧版在此多发一次 Backspace，把共同前缀多删一字，读回永远对不上目标而冻结草稿）。
        if replacement.isEmpty {
            if selectionLaid { guard key(51, []) else { return false } }
        } else if !insert(replacement) { return false }
        first = false
        if let readSnapshot {
            let desired = DraftSnapshot(text: prefix + new + suffix, location: start + new.utf16.count, length: 0)
            for _ in 0..<12 {
                guard valid() else { diagnostic = "落键后：输入绑定或控制租约失效"; return false }
                let actual = readSnapshot()
                // 权威判据：电脑实际内容已等于手机端目标 new，即视为同步成功。
                // desired 坐标（prefix+new+suffix）仅在“空框 + 仅追加”时正确；输入框已有内容或发生删除时
                // 会错位，把本已正确的内容判成失败并冻结草稿（表现即“删不干净→手机再输入不同步→切应用才恢复”）。
                // 以内容相等为最终裁决，可断掉这条冻结链；只有确实没落到 new 才继续等待/失败。
                if actual?.text == new { expected = .end(of: new); uncertainWrite = false; diagnostic = ""; return true }
                if actual == desired { expected = desired; uncertainWrite = false; diagnostic = ""; return true }
                // WorkBuddy 等 Electron 编辑器把整个会话 WebArea 暴露为一个 AXValue：
                // 输入框已落字时，输入框之外的时间/状态文字也可能同时改变，全文比较因此假失败。
                // 放宽只接受可证明的局部写入：总长度不变、光标精确落在预期位置、
                // 且光标前恰好是本次非空插入片段。删除不走此分支，避免把“没删掉”误认成成功。
                if let actual, Self.matchesLocalWrite(actual: actual, desired: desired, inserted: replacement) {
                    expected = actual
                    uncertainWrite = false
                    diagnostic = ""
                    return true
                }
                diagnostic = Self.describe("落键后读回", expected: desired, actual: actual)
                usleep(15_000)
            }
            // 选区"立住"了但读回始终对不上，说明 AX 读数在说谎（选区报成功却没真落 DOM）——
            // AX 与依赖同一读回校验的 Cmd+A 本会话一并停用，之后（只读探测恢复后）删除改走键盘，
            // 避免永久删不全。
            if selectionLaid { axFailStreak = 3; chordFailStreak = 3 }
            return false
        }
        uncertainWrite = false
        diagnostic = ""
        return true
    }

    /// 键盘兜底里的「Cmd+A 整框全选」：唯一与词序/换行无关的单和弦精确选区，一次性的选区
    /// 变化不会被受控组件的重渲染中途重置。返回 true = 全选已读回确认（保持选中，交由注入
    /// 覆盖）；nil = 没立住但已按 Right 收回并读回确认光标还原（可安全退回逐字）；false =
    /// 光标收不回、状态不明（必须如实失败，绝不盲删）。调用方需保证光标在文末且无选区。
    private func selectAllByChord(text: String) -> Bool? {
        let len = text.utf16.count
        guard valid(), key(0, .maskCommand) else { return nil }   // 键未送达，状态未变
        let selected = DraftSnapshot(text: text, location: 0, length: len)
        for _ in 0..<8 {
            guard valid() else { return false }
            if let actual = readSnapshot?(), actual == selected { return true }
            usleep(10_000)
        }
        // 全选没立住：Right 把光标折回文末（无选区时在文末是空操作）；读回确认还原后
        // 才允许继续逐字退格，否则逐字将删到未知位置。
        guard valid(), key(124, []) else { return false }
        let restored = DraftSnapshot(text: text, location: len, length: 0)
        for _ in 0..<8 {
            guard valid() else { return false }
            if let actual = readSnapshot?(), actual == restored { return nil }
            usleep(10_000)
        }
        diagnostic = "全选和弦读回失败且光标未还原"
        return false
    }

    /// 整段清空（手机把草稿删空 = 两边一起清）。
    /// 与 `update` 的两点关键差别，都是为"清空之后再不同步"这个死法准备的：
    /// 1) **不校验创建时的基线**。基线是捕获那一刻按 `prefix/suffix` 算出来的，快捷键通道
    ///    （全选/删除）或应用自身重建编辑器都会让它永久分叉；拿它当门槛就永远过不去。
    ///    清空是幂等的——删光的结果与当前内容无关，所以放宽这条没有重复输入的风险。
    /// 2) **用当前实际内容算选区**，不拿旧的 prefix/suffix 反推"本轮那一段"。
    /// 两条执行路径，成功判据始终是"读回为空"，证明不了就如实失败：
    /// ① AX 设全选并读回确认（原生应用无感，一次退格解决）；
    /// ② ①的选区读不回或"落了却删不净"时（Chromium 对 AX 写选区"报告成功却不落 DOM"是实况，
    ///    实测 ZCode 选区读回通过、退格却删不动），改发**真实键盘 Cmd+A**——它与应用自身的全选
    ///    同源，必然落 DOM；焦点全程受同一绑定与可编辑角色约束（读得到快照才进得来），每轮
    ///    删后读回，两轮删不动就停手，如实失败并保留电脑内容。
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
        let empty = DraftSnapshot(text: "", location: 0, length: 0)
        // 路径一：AX 全选。选区读回对得上才按退格——不拿假成功当真。
        if selectRange?(CFRange(location: 0, length: count)) == true {
            let desired = DraftSnapshot(text: current.text, location: 0, length: count)
            var landed = false
            for _ in 0..<8 {
                guard valid() else { diagnostic = "清空：输入绑定或控制租约失效"; return false }
                if let actual = readSnapshot(), actual == desired { landed = true; break }
                diagnostic = Self.describe("清空选区读回", expected: desired, actual: readSnapshot())
                usleep(10_000)
            }
            if landed, deleteAndVerifyEmpty(readSnapshot) { return true }
            // 落了却删不净（Chromium 假成功）或压根没落：交给键盘路径兜底，不在这里赌。
        }
        // 路径二：键盘 Cmd+A + 退格，读回为空才算成功；删不动重试一轮后如实失败。
        for _ in 0..<2 {
            guard valid() else { diagnostic = "清空：输入绑定或控制租约失效"; return false }
            guard key(0, .maskCommand) else { diagnostic = "清空：全选键未能发出"; return false }
            usleep(60_000)
            guard valid(), key(51, []) else { diagnostic = "清空：删除未能发出"; return false }
            for _ in 0..<12 {
                guard valid() else { diagnostic = "清空后：输入绑定或控制租约失效"; return false }
                if let actual = readSnapshot(), actual.text.isEmpty {
                    uncertainWrite = false; diagnostic = ""
                    return true
                }
                diagnostic = Self.describe("清空后读回", expected: empty, actual: readSnapshot())
                usleep(15_000)
            }
        }
        return false
    }

    /// 按一次退格并读回确认删净；删了却读不到空（含退格被应用吞掉）返回 false，由调用方兜底。
    private func deleteAndVerifyEmpty(_ readSnapshot: () -> DraftSnapshot?) -> Bool {
        guard valid(), key(51, []) else { diagnostic = "清空：删除未能发出"; return false }
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
        // 与 update 一致：电脑实际内容已等于手机端目标即认账，避免 desired 坐标错位（输入框已有内容/删除场景）
        // 把正确的内容误判失败。只有确实没落到 attempted 才拒绝。
        if actual.text == attempted { expected = .end(of: attempted); first = false; uncertainWrite = false; return attempted }
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
    private static func matchesLocalWrite(actual: DraftSnapshot, desired: DraftSnapshot, inserted: String) -> Bool {
        let insertedLength = inserted.utf16.count
        guard insertedLength > 0,
              actual.text.utf16.count == desired.text.utf16.count,
              actual.location == desired.location, actual.length == desired.length,
              actual.location >= insertedLength else { return false }
        let range = NSRange(location: actual.location - insertedLength, length: insertedLength)
        return (actual.text as NSString).substring(with: range) == inserted
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
