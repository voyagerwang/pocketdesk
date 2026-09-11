/**
 * [INPUT]: 依赖 LiveDraft 的纯状态机与隔离 DraftEditor，不读取真实桌面、不注入任何事件。
 * [OUTPUT]: 验证五态（active/interrupted/recoverable/needs-user-focus/committed）的判定与迁移：
 *           临时失焦可只读探测恢复、目标应用离场只报 interrupted、电脑内容被手改一律 needs-user-focus、
 *           写入结果未知的停止永不自动续接、提交后封闭；只读探测本身不产生任何写入。
 * [POS]: tests 的跨弹窗恢复协议回归；真实 AX 控件与系统弹窗另行真机验收。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

final class StateEditor: DraftEditor {
    var snapshot = DraftSnapshot.end(of: "")
    var focused = true
    var writes: [String] = []
    func isFocused() -> Bool { focused }
    func read() -> DraftSnapshot? { snapshot }
    func replace(_ text: String) -> Bool { writes.append(text); snapshot = .end(of: text); return true }
}

/// 落键了但读回仍是旧值：模拟目标应用还没处理完这次输入（迟到落地）。
final class LaggingEditor: DraftEditor {
    var committed = ""
    var visible = ""
    var focused = true
    func isFocused() -> Bool { focused }
    func read() -> DraftSnapshot? { .end(of: visible) }
    func replace(_ text: String) -> Bool { committed = text; return true }
}

@main struct DraftStateTests {
    static func rejects(_ label: String, _ body: () throws -> Void) {
        do { try body(); fatalError("\(label)：本应被拒绝") } catch {}
    }

    static func main() {
        var frontmost = true
        func draft(_ editor: DraftEditor?) -> LiveDraft {
            LiveDraft(id: "d", context: "same-input", target: "workbuddy", editor: editor,
                      targetFrontmost: { frontmost })
        }

        // 1) 正常同步：全程 active，且每次只整值写一次。
        let editor = StateEditor()
        let live = draft(editor)
        assert(live.classify() == .active)
        try! live.update("第一轮")
        assert(live.state == .active && live.classify() == .active && editor.writes == ["第一轮"])

        // 2) 焦点被弹窗抢走后回到原输入框：interrupted → recoverable → 续接只补差量。
        editor.focused = false
        rejects("失焦时写入") { try live.update("第一轮加字") }
        assert(live.state == .interrupted && live.stopped)
        assert(live.classify() == .interrupted, "目标应用还在前台、只是元素失焦 → interrupted")
        editor.focused = true
        let focusedBack = live.probe()
        assert(focusedBack.state == .recoverable && !live.stopped)
        try! live.update("第一轮加字")
        assert(editor.writes == ["第一轮", "第一轮加字"], "恢复后只补差量，不重放全文")

        // 3) 目标应用离场：interrupted，探测在它回来之前不给可续接。
        frontmost = false
        editor.focused = false
        rejects("应用离场后写入") { try live.update("第二轮") }
        assert(live.classify() == .interrupted)
        let gone = live.probe()
        assert(gone.state == .interrupted && live.stopped, "应用没回来就不许自动续接")
        frontmost = true
        editor.focused = true
        assert(live.probe().state == .recoverable, "应用与原焦点都回来 → 可续接")

        // 4) 电脑正文被手改：一律 needs-user-focus，绝不自动恢复、也不整段重放。
        let edited = StateEditor()
        let changed = draft(edited)
        try! changed.update("手机草稿")
        edited.snapshot = .end(of: "用户手改了电脑内容")
        rejects("电脑正文被改后写入") { try changed.update("手机草稿加字") }
        assert(changed.state == .needsUserFocus)
        assert(changed.classify() == .needsUserFocus)
        assert(changed.probe().state == .needsUserFocus, "内容对不上就不能自动续接")
        rejects("内容不一致时显式重试") { try changed.recover() }
        assert(changed.stopped, "拒绝之后必须仍是冻结态")

        // 5) 迟到落地：写入确实发出、读回稍后才一致 → 允许只读探测判定可续接。
        let lagging = LaggingEditor()
        let lag = draft(lagging)
        rejects("迟到落地时立即写入") { try lag.update("键盘") }
        assert(lag.state == .interrupted && lagging.committed == "键盘")
        assert(lag.classify() == .interrupted, "读回还没落地，先报中断")
        lagging.visible = "键盘"
        let landed = lag.probe()
        assert(landed.state == .recoverable && !lag.stopped)
        assert(lagging.visible == "键盘", "只读探测不产生任何写入")

        // 6) selection 通道：能核对原控件才可续接；不能核对时归到需要用户点一下。
        var confirmable = false
        let selection = LiveDraft(id: "s", context: "c", target: "chrome", editor: nil,
                                  selectionWriter: { _, _ in false },
                                  reconcileSelection: { previous, _ in confirmable ? previous : nil },
                                  targetFrontmost: { true })
        rejects("selection 通道写入失败") { try selection.update("文本") }
        assert(selection.state == .interrupted)
        assert(selection.probe().state == .needsUserFocus, "核对不了原控件就必须等用户")
        confirmable = true
        assert(selection.probe().state == .recoverable && !selection.stopped)

        // 7) 结果未知的停止（图片可能已粘贴、提交未确认）永不自动续接。
        let uncertain = StateEditor()
        let risky = draft(uncertain)
        try! risky.update("abc")
        _ = risky.stop("图片可能已粘贴；请检查电脑内容，勿重复发送。")
        assert(risky.classify() == .needsUserFocus)
        assert(risky.probe().state == .needsUserFocus, "写入结果未知不能靠核对消除")
        rejects("未知写入的显式重试") { try risky.recover() }

        // 8) 提交后封闭：新输入必须建立全新草稿，探测也只报 committed。
        let done = StateEditor()
        let committed = draft(done)
        try! committed.update("本轮")
        committed.finish()
        assert(committed.state == .committed && committed.classify() == .committed)
        rejects("提交后继续写") { try committed.update("不该继承") }
        assert(committed.probe().state == .committed)

        // 9) 探测前更新"手机期望文本"不得写入电脑。
        let untouched = StateEditor()
        let probeOnly = draft(untouched)
        try! probeOnly.update("已输入")
        untouched.focused = false
        rejects("失焦后写入") { try probeOnly.update("已输入更多") }
        let before = untouched.writes.count
        probeOnly.noteProbe("已输入更多")
        _ = probeOnly.probe()
        assert(untouched.writes.count == before, "只读探测绝不写电脑")

        print("draft-state: 五态判定与迁移通过（中断/恢复/需用户聚焦/提交封闭/未知结果/迟到落地/只读探测）")
    }
}
