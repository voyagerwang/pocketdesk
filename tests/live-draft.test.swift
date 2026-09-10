/**
 * [INPUT]: 依赖 LiveDraft 的纯状态机与隔离 DraftEditor，不读取真实桌面。
 * [OUTPUT]: 验证整值/选区替换、Unicode、冲突停止、显式重试核验与当前焦点续发均不重复写入、未知结果拒绝恢复、提交封闭；手机已有全文与连续删空保留电脑前后文。
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

        // 应用切回后的显式续发沿用暂停前已输入正文，不能重新调用 selectionWriter。
        var resumedWrites = 0
        let resumed = LiveDraft(id: "resumed", context: "new-input", target: "chrome", editor: nil,
            selectionWriter: { _,_ in resumedWrites += 1; return true }, resumedText: "手机已输入正文")
        try resumed.update("手机已输入正文")
        assert(resumed.mode == .selection && resumed.text == "手机已输入正文" && resumedWrites == 0)
        print("live-draft: 通过（全文修订、Unicode、暂存、焦点/内容/选区冲突、失败停止、提交封闭）")
    }
}
