/**
 * [INPUT]: 依赖 Foundation；DraftEditor 提供绑定编辑器的焦点、文本及 UTF-16 选区读写；targetFrontmost 提供目标应用是否仍在前台。
 * [OUTPUT]: 提供 LiveDraft 单轮草稿状态机与 DraftSnapshot；失败停手并给出可证明的状态（interrupted/recoverable/needs-user-focus/committed），
 *           只读 probe() 就地核验原绑定后允许续接，绝不整段重放；提交后封闭。
 * [POS]: Sources 输入的文本事务边界；AXDraftEditor/KeyboardDraftWriter 实现写入，InputExecutor 串行调用并负责最终提交动作。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

struct DraftSnapshot: Equatable {
    let text: String
    let location: Int
    let length: Int
    static func end(of text: String) -> DraftSnapshot {
        .init(text: text, location: text.utf16.count, length: 0)
    }
}

protocol DraftEditor: AnyObject {
    func isFocused() -> Bool
    func read() -> DraftSnapshot?
    func replace(_ text: String) -> Bool
}

/// 草稿状态：外部据此决定"能不能继续写"，而不是靠人话文案猜。
/// 这是"跨弹窗安全恢复"协议的词汇表——临时焦点中断与"原位置无法证明"必须分开，
/// 否则用户会被要求切应用来重置内部状态（那正是本次要修掉的行为）。
enum DraftState: String {
    /// 绑定有效，可同步。
    case active
    /// 焦点暂时丢失（目标应用不在前台，或元素暂时失焦）：冻结队列、保留手机全文与已确认电脑前缀，可只读探测恢复。
    case interrupted
    /// 原目标应用与原编辑位置重新出现，且电脑内容仍等于最后确认状态：可安全续接，只补差量。
    case recoverable
    /// 目标应用回来了，但无法证明是原输入位置（内容被改、元素被换）：需要用户点一下电脑输入框。
    case needsUserFocus = "needs-user-focus"
    /// 上一轮已提交封闭：新输入必须建立全新草稿与绑定，绝不继承旧编辑器对象。
    case committed
}

struct LiveDraftFailure: LocalizedError {
    let message: String
    let state: DraftState
    init(message: String, state: DraftState = .needsUserFocus) {
        self.message = message
        self.state = state
    }
    var errorDescription: String? { message }
}

final class LiveDraft {
    enum Mode: String { case replace, selection, deferred }
    let id: String
    let context: String
    let target: String
    let mode: Mode
    private let editor: DraftEditor?
    private let selectionWriter: ((String, String) -> Bool)?
    private let reconcileSelection: ((String, String) -> String?)?
    /// 目标应用是否仍在前台。探测要靠它区分"焦点短暂中断"与"用户已经去了别处"。
    private let targetFrontmost: (() -> Bool)?
    private var attempted = ""
    /// 本轮是否允许 probe/recover 解除暂停。写入结果未知（图片可能已粘贴、提交结果未确认）时为 false：
    /// 这类停止不能靠"再核对一次"消除，只能由用户核对电脑内容后新建草稿。
    private var resumable = false
    private var writeUncertain = false
    private var expected = DraftSnapshot.end(of: "")
    private(set) var stopped = false
    private(set) var committed = false
    private(set) var state: DraftState = .active
    private(set) var text = ""
    /// 停止时的人话说明（不含用户正文），供边界层原样转述给用户。
    private(set) var lastMessage = ""

    init(id: String, context: String, target: String, editor: DraftEditor?, selectionWriter: ((String, String) -> Bool)? = nil,
         reconcileSelection: ((String, String) -> String?)? = nil, targetFrontmost: (() -> Bool)? = nil, resumedText: String? = nil) {
        self.id = id; self.context = context; self.target = target
        self.selectionWriter = selectionWriter
        self.reconcileSelection = reconcileSelection
        self.targetFrontmost = targetFrontmost
        // 能力探测之后再读一次，只有空白且光标在起点的框可以被本轮接管。
        if let resumedText {
            self.editor = nil; mode = selectionWriter == nil ? .deferred : .selection
            text = resumedText; attempted = resumedText
        } else if let editor, editor.isFocused(), editor.read() == .end(of: "") {
            self.editor = editor; mode = .replace
        } else { self.editor = nil; mode = selectionWriter == nil ? .deferred : .selection }
    }

    func update(_ value: String) throws {
        guard !committed else { throw failure("本轮已经提交，请开始新的草稿。", .committed) }
        guard !stopped else { throw failure(lastMessage.isEmpty ? "同步已暂停，草稿已保留。" : lastMessage, state) }
        attempted = value
        // 应用切回后的续发以 resumedText 建立已输入基线。正文没有变化时不再调用
        // selectionWriter 核对旧控件，也不产生任何键盘事件，只继续附件与提交。
        if value == text { return }
        guard let editor else {
            if let selectionWriter, !selectionWriter(text, value) {
                throw stop("输入位置或替换结果无法确认，已停止同步；请核对电脑内容。", .interrupted, resumable: true)
            }
            text = value; return
        }
        guard editor.isFocused(), editor.read() == expected else {
            throw stopPaused("电脑输入位置或内容已变化，已暂停同步并保留手机草稿。")
        }
        guard value != expected.text else { text = value; return }
        writeUncertain = true
        guard editor.replace(value), editor.isFocused(), editor.read() == .end(of: value) else {
            throw stop("未能确认文本替换结果，已停止同步；请检查电脑内容，避免重复输入。", .interrupted, resumable: true)
        }
        expected = .end(of: value)
        writeUncertain = false
        text = value
    }

    /// 只读状态判定：不注入任何键盘/鼠标事件，只回答"现在处于哪一态"。
    func classify() -> DraftState {
        if committed { return .committed }
        guard stopped else { return .active }
        // 结果未知的停止（图片已粘贴、提交未确认）无法靠核对消除，一律归到需要用户确认。
        guard resumable else { return .needsUserFocus }
        if let targetFrontmost, !targetFrontmost() { return .interrupted }
        guard let editor else {
            // selection 通道能靠原控件读回核对，deferred 通道从未写过电脑正文；两者都可续接。
            return .recoverable
        }
        if !editor.isFocused() { return .interrupted }
        guard let actual = editor.read() else { return .needsUserFocus }
        if !writeUncertain && actual == expected { return .recoverable }
        if actual == .end(of: attempted) { return .recoverable }   // 上一次写入迟到落地
        // 写入已发出、但读回既不是原基线也不是本轮文本：多半只是目标应用还没处理完。
        // 元素仍聚焦时按"暂时无法核验"处理，继续只读探测——不要为一次读回延迟就要求用户去点输入框。
        if writeUncertain && editor.isFocused() { return .interrupted }
        return .needsUserFocus
    }

    /// 探测前更新"手机期望文本"，**不写入电脑**；仅用于判断上一次写入是否迟到落地。
    func noteProbe(_ value: String) { if stopped { attempted = value } }

    /// 只读恢复探测：核验目标应用是否回到前台、原编辑位置是否仍在、电脑内容是否等于最后确认状态。
    /// 全部成立才推进到 recoverable 并解除暂停；任何情况下都只读，**绝不重放正文**。
    /// 成功后调用方只发送最后确认版本之后的差量（由 KeyboardDraftWriter 的公共前缀算法完成）。
    @discardableResult
    func probe() -> (state: DraftState, note: String) {
        if committed { state = .committed; return (.committed, "本轮已提交，请开始新的草稿。") }
        guard stopped else { state = .active; return (.active, "") }
        guard resumable else {
            state = .needsUserFocus
            return (.needsUserFocus, lastMessage.isEmpty ? "上次结果未确认，请核对电脑内容。" : lastMessage)
        }
        var next = classify()
        if next == .recoverable {
            if let editor {
                if let actual = editor.read() { expected = actual; text = actual.text; writeUncertain = false }
                else { next = .needsUserFocus }
            } else if mode == .selection {
                if let reconcileSelection, let confirmed = reconcileSelection(text, attempted) { text = confirmed }
                else { next = .needsUserFocus }
            }
            // mode == .deferred：从未向电脑写过草稿，无需核对即可续接。
        }
        state = next
        switch next {
        case .recoverable:
            stopped = false; lastMessage = ""
            return (next, "")
        case .interrupted:
            return (next, "还没回到原输入框；草稿已冻结，稍后自动续接。")
        case .needsUserFocus:
            return (next, "请在电脑上点一下原输入框即可继续；手机文字已保留。")
        case .active, .committed:
            return (next, "")
        }
    }

    /// 用户显式重试（再次点发送）：代表他已确认电脑输入位置。仍不重放全文，只接管后续。
    func recover() throws {
        guard stopped, !committed else { return }
        guard resumable else { throw failure("上次提交或输入位置发生变化，无法安全重试；请核对电脑内容。") }
        if let editor {
            guard editor.isFocused(), let actual = editor.read(),
                  (!writeUncertain && actual == expected) || actual == .end(of: attempted) else {
                throw failure("电脑内容与本轮草稿不一致，请点一下电脑输入框后重试；手机文字已保留。")
            }
            expected = actual; text = actual.text
            writeUncertain = false
        } else if mode == .selection {
            guard let confirmed = reconcileSelection?(text, attempted) else {
                throw failure("还不能核对原输入框，请点一下电脑输入框后重试；手机文字已保留，未重复输入。")
            }
            text = confirmed
        } else {
            // 暂存后的最终粘贴可能已执行，不能从 stopped 状态重复提交。
            throw failure("上次提交结果未确认，请核对电脑内容；手机文字已保留。")
        }
        stopped = false
        state = .active
        lastMessage = ""
    }

    func finish() { committed = true; state = .committed; stopped = false }

    func stop(_ message: String, _ state: DraftState = .needsUserFocus, resumable: Bool = false) -> LiveDraftFailure {
        stopped = true
        self.state = state
        self.resumable = resumable
        lastMessage = message
        return failure(message, state)
    }

    /// 基线不一致时的分流：焦点不在或上一次写入迟到落地 → 可自动续接；内容被改/元素被换 → 需要用户点一下。
    private func stopPaused(_ message: String) -> LiveDraftFailure {
        if let editor, !editor.isFocused() { return stop(message, .interrupted, resumable: true) }
        if let editor, editor.isFocused(), let actual = editor.read(), actual == .end(of: attempted) {
            return stop(message, .interrupted, resumable: true)
        }
        return stop(message, .needsUserFocus, resumable: true)
    }

    private func failure(_ message: String, _ state: DraftState? = nil) -> LiveDraftFailure {
        .init(message: message, state: state ?? self.state)
    }
}
