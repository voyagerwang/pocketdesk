/**
 * [INPUT]: 依赖 LiveDraft 的纯状态机、隔离 DraftEditor 与内存输入框替身 FakeField，不读取真实桌面。
 * [OUTPUT]: 验证整值/选区替换、Unicode、冲突停止、显式重试核验与当前焦点续发均不重复写入、未知结果拒绝恢复、提交封闭；手机已有全文与连续删空保留电脑前后文；
 *           清空按当前实际内容整段删净且幂等，门禁失效/不可读/不可定位三种"证明不了"如实失败，基线分叉后可破冰续写、失败则保留正文。
 * [POS]: tests 的输入事务回归；真实 AX 控件另行验收。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

final class MemoryEditor: DraftEditor {
    var snapshot = DraftSnapshot.end(of: "")
    var focused = true
    var fail = false
    var corrupt = false
    var writes: [String] = []
    func isFocused() -> Bool { focused }
    func read() -> DraftSnapshot? { snapshot }
    func replace(_ text: String) -> Bool {
        writes.append(text)
        if fail { return false }
        snapshot = .end(of: corrupt ? "unexpected" : text)
        return true
    }
}

/// 内存输入框替身：写入落在**光标处**，不是末尾追加。
/// 「光标处」是刻意保留的——实况里"清空后每次还剩第一个字"就出在旧 `update` 从捕获时的光标位
/// 起算选区（`start + offset`）；只有让替身允许光标停在中间，那个偏移才会在测试里现形。
/// 门禁/可读/可选中默认都成立，各自可单独打破以验证"证明不了就如实失败"的分支。
final class FakeField {
    var text: String { didSet { caret = min(caret, text.utf16.count) } }
    var caret: Int
    var selection: Int
    /// 发出去的删除键次数（不是删掉的字数）：用来断言整段清空只按一次，而不是播放连按式键流。
    var deletes = 0
    var permitting = true
    var readable = true
    var selectable = true
    init(_ text: String = "", caret: Int = 0) {
        self.text = text; self.caret = caret; self.selection = 0
    }
    func writer() -> KeyboardDraftWriter {
        KeyboardDraftWriter(read: { [self] in
            readable ? DraftSnapshot(text: text, location: caret, length: selection) : nil
        }, select: { [self] range in
            guard selectable else { return false }
            caret = range.location; selection = range.length
            return true
        }, valid: { [self] in permitting }, key: { [self] code, flags in
            guard permitting else { return false }
            // 退格：有选区整段删，无选区吃光标前一个字——后者是真实控件的行为，
            // 替身不这么写就会在"选区没建立起来"时假装什么都没发生。
            if code == 51 {
                deletes += 1
                let before = (text as NSString)
                let origin = selection > 0 ? caret : max(0, caret - 1)
                let count = selection > 0 ? selection : (caret > 0 ? 1 : 0)
                text = before.replacingCharacters(in: NSRange(location: origin, length: count), with: "")
                caret = origin; selection = 0
                return true
            }
            // Shift+左：光标左移并扩选。clearAll 在"控件不支持设选区"时的退路要用它；
            // 本替身不实现的部分（其余方向键/修饰键组合）一律 false，宁可失败不假装成功。
            if code == 123, flags == .maskShift, caret > 0 {
                caret -= 1; selection += 1
                return true
            }
            return false
        }, insert: { [self] value in
            guard permitting else { return false }
            let current = (text as NSString)
            text = current.replacingCharacters(in: NSRange(location: caret, length: selection), with: value)
            caret += value.utf16.count; selection = 0
            return true
        })
    }
}

@main struct LiveDraftTests {
    static func draft(_ editor: DraftEditor?) -> LiveDraft { LiveDraft(id: "test", context: "same-input", target: "test", editor: editor) }
    static func rejects(_ body: () throws -> Void) {
        do { try body(); fatalError("应拒绝此操作") } catch {}
    }
    static func main() throws {
        let editor = MemoryEditor(), session = draft(nil)
        assert(session.mode == .deferred)
        for value in ["明天三点", "明天下午三点", "明天下午三点继续说"] { try session.update(value) }
        assert(session.text == "明天下午三点继续说")
        let mirror = draft(editor)
        let values = ["明天三点", "明天下午三点", "明天下午三点继续说", "👨‍👩‍👧‍👦 e\u{301}\n第二行", "", "  保留空格  "]
        for value in values { try mirror.update(value); assert(editor.snapshot == .end(of: value)) }
        assert(editor.writes == values, "每次只整值写入一次，不写空串过渡")
        try mirror.update(values.last!)
        assert(editor.writes.count == values.count, "相同值不能重复写入")
        mirror.finish()
        rejects { try mirror.update("重复提交") }
        assert(editor.writes.count == values.count)

        for changed in [DraftSnapshot.end(of: "电脑手动改写"), DraftSnapshot(text: "手机", location: 0, length: 1)] {
            let e = MemoryEditor(), s = draft(e)
            try s.update("手机"); e.snapshot = changed
            rejects { try s.update("手机修订") }; assert(s.stopped && e.writes.count == 1)
            e.snapshot = .end(of: "手机")
            rejects { try s.update("不能偷偷恢复") }
        }
        let e = MemoryEditor(), s = draft(e)
        e.focused = false
        rejects { try s.update("焦点改变") }; assert(e.writes.isEmpty)
        for corrupt in [false, true] {
            let e = MemoryEditor(), s = draft(e)
            e.fail = !corrupt; e.corrupt = corrupt
            rejects { try s.update("写入失败") }
            rejects { try s.update("不重复追加") }
            assert(e.writes.count == 1 && s.stopped)
        }
        let nonempty = MemoryEditor(); nonempty.snapshot = .end(of: "原有内容")
        let deferred = draft(nonempty)
        try deferred.update("手机草稿")
        assert(deferred.mode == .deferred && nonempty.writes.isEmpty && nonempty.snapshot.text == "原有内容")
        // 通用输入：保留原框前后文，只替换本轮区域；修订不产生任何 Delete。
        var actual = DraftSnapshot(text: "前缀后缀", location: 2, length: 0)
        var deletes = 0, inserts: [String] = []
        var allowed = true
        let writer = KeyboardDraftWriter(read: { actual }, select: { range in
            actual = .init(text: actual.text, location: range.location, length: range.length); return true
        }, valid: { allowed }, key: { code, _ in
            guard code == 51 else { return false }
            deletes += 1
            let value = (actual.text as NSString).replacingCharacters(in: NSRange(location: actual.location, length: actual.length), with: "")
            actual = .init(text: value, location: actual.location, length: 0); return true
        }, insert: { text in
            inserts.append(text)
            let value = (actual.text as NSString).replacingCharacters(in: NSRange(location: actual.location, length: actual.length), with: text)
            actual = .init(text: value, location: actual.location + text.utf16.count, length: 0); return true
        })
        let realtime = LiveDraft(id: "realtime", context: "test", target: "test", editor: nil,
                                 selectionWriter: { writer.update(from: $0, to: $1) })
        assert(realtime.mode == .selection)
        for text in ["明天三点", "明天下午三点", "明天下午三点继续说", "👨‍👩‍👧‍👦 e\u{301}\n第二行"] {
            try realtime.update(text)
            assert(actual.text == "前缀" + text + "后缀")
            assert(actual.location == 2 + text.utf16.count)
        }
        assert(deletes == 0 && inserts.count == 4)
        try realtime.update("")
        assert(deletes == 1 && actual.text == "前缀后缀", "主动清空一次删除选区")
        for text in ["手机已有正文", "手机已有", "", "删空后再次输入", ""] {
            try realtime.update(text)
            assert(actual.text == "前缀" + text + "后缀", "连续删除与重新输入只能修改手机段落")
        }
        let writesBeforeLostFocus = inserts.count
        allowed = false
        rejects { try realtime.update("焦点失效不能继续输入") }
        assert(inserts.count == writesBeforeLostFocus)
        // 读取延迟导致失败：稍后确认目标文本已落入，只恢复基线，不再注入一次。
        let snapshot = DraftSnapshot.end(of: "")
        var pending: DraftSnapshot?, readBack = false, insertCount = 0
        let recoveringWriter = KeyboardDraftWriter(read: { readBack ? pending ?? snapshot : snapshot }, select: nil,
            valid: { true }, key: { _,_ in false }, insert: { text in
                insertCount += 1; pending = .end(of: text); return true
            })
        let recovering = LiveDraft(id: "recover", context: "same", target: "test", editor: nil,
            selectionWriter: { recoveringWriter.update(from: $0, to: $1) },
            reconcileSelection: { recoveringWriter.confirmedText(previous: $0, attempted: $1) })
        rejects { try recovering.update("键盘") }
        assert(insertCount == 1 && recovering.stopped)
        rejects { try recovering.recover() }
        readBack = true
        try recovering.recover(); try recovering.update("键盘")
        assert(insertCount == 1 && recovering.text == "键盘" && !recovering.stopped)
        _ = recovering.stop("图片可能已粘贴")
        rejects { try recovering.recover() }

        // 落键前失去权限可在恢复后重试；未知编辑器落键结果不明时仍禁止重放。
        var permitted = false, unknownInserts = 0
        let unknown = KeyboardDraftWriter(read: nil, select: nil, valid: { permitted }, key: { _,_ in false },
            insert: { _ in unknownInserts += 1; return false })
        assert(!unknown.update(from: "", to: "测试"))
        permitted = true
        assert(unknown.confirmedText(previous: "", attempted: "测试") == "")
        assert(!unknown.update(from: "", to: "测试"))
        assert(unknown.confirmedText(previous: "", attempted: "测试") == nil && unknownInserts == 1)

        let retryEditor = MemoryEditor(), retryDraft = draft(retryEditor)
        retryEditor.focused = false
        rejects { try retryDraft.update("重新输入") }
        retryEditor.focused = true
        try retryDraft.recover(); try retryDraft.update("重新输入")
        assert(retryEditor.snapshot.text == "重新输入")
        retryEditor.snapshot = .end(of: "电脑另一段文字")
        rejects { try retryDraft.update("不能覆盖") }
        rejects { try retryDraft.recover() }

        // ---------- 清空：对当前实际内容整段删净 ----------
        // 「清空」不比旧基线、也不拿捕获时的光标位置推算选区，直接对**当前实际内容**全选。
        // 实况（WorkBuddy / ChatGPT）失败的根源正是那两处推算：基线被快捷键通道打乱、
        // 选区按 start 起算导致首位那截删不到——用户看到的就是"清空后每次还剩第一个字"。
        let clearField = FakeField("现有正文手机草稿", caret: 1)
        let clearWriter = clearField.writer()
        assert(clearWriter.clearAll(), "清空必须成功：不比旧基线、按当前实际内容全选")
        assert(clearField.text.isEmpty, "清空后不得残留任何字（曾经每次剩第一个字）")
        assert(clearField.deletes == 1, "整段清空只发一次删除，不播放连按式的键流")
        assert(clearWriter.clearAll() && clearField.deletes == 1, "已空的框幂等认账，不再多按一次删除")

        // 三种"证明不了"的情形都必须如实失败——清空是删除动作，宁可报错也不盲删。
        let gatedField = FakeField("有内容"); gatedField.permitting = false
        assert(!gatedField.writer().clearAll(), "门禁失效时不得声称已清空")
        let blindField = FakeField("有内容"); blindField.readable = false
        assert(!blindField.writer().clearAll(), "读不到控件时不得盲删")
        let stuckField = FakeField("有内容"); stuckField.selectable = false
        assert(!stuckField.writer().clearAll(), "定位不到删除范围时不得乱删")

        // ---------- 清空是冻结态的唯一出路，且不给"结果未知"的停止开后门 ----------
        let field = FakeField("电脑已有正文")
        var writerSlot = field.writer()
        let frozen = LiveDraft(id: "clear", context: "same", target: "workbuddy", editor: nil,
            selectionWriter: { old, new in writerSlot.update(from: old, to: new) })
        try frozen.update("手机草稿")
        assert(field.text == "手机草稿电脑已有正文" && !frozen.stopped, "正常同步插在光标处并保留电脑原文")
        // 外部（快捷键通道）动过输入框 → 基线分叉 → 常规同步从此写不动，用户输入什么都是白打。
        field.text = "被外部清过"
        rejects { try frozen.update("手机草稿改了") }
        assert(frozen.stopped && field.text == "被外部清过")
        rejects { try frozen.update("普通输入救不回来") }
        // 清空能破冰：它本来就不需要基线。删净后**重新捕获**（与 InputExecutor 同构），
        // 这一轮的基线即"空框 @ 光标 0"，后续输入接着走。
        try frozen.clear {
            let ok = field.writer().clearAll()
            writerSlot = field.writer()
            return ok
        }
        assert(field.text.isEmpty && frozen.text.isEmpty && !frozen.stopped, "清空后解冻且电脑侧为空")
        try frozen.update("清空后接着输入")
        assert(field.text == "清空后接着输入", "清空后同一轮必须能继续输入")
        // 对照：删不干净时如实失败，绝不声称已清空，也绝不因此丢掉正文。
        let undeletable = FakeField("删不掉"); undeletable.selectable = false
        rejects { try frozen.clear { undeletable.writer().clearAll() } }
        assert(frozen.stopped && frozen.text == "清空后接着输入", "清空失败要保留正文并停在冻结态")
        // 结果未知的停止（图片已粘贴）不开后门：清空会把可能已生效的内容抹掉。
        let unknownDraft = LiveDraft(id: "unknown", context: "same", target: "workbuddy", editor: nil,
            selectionWriter: { _,_ in false })
        _ = unknownDraft.stop("图片可能已粘贴")
        rejects { try unknownDraft.clear { true } }

        // 应用切回后的显式续发沿用暂停前已输入正文，不能重新调用 selectionWriter。

        var resumedWrites = 0
        let resumed = LiveDraft(id: "resumed", context: "new-input", target: "chrome", editor: nil,
            selectionWriter: { _,_ in resumedWrites += 1; return true }, resumedText: "手机已输入正文")
        try resumed.update("手机已输入正文")
        assert(resumed.mode == .selection && resumed.text == "手机已输入正文" && resumedWrites == 0)
        print("live-draft: 通过（全文修订、Unicode、暂存、焦点/内容/选区冲突、失败停止、提交封闭、清空破冰与幂等）")
    }
}
