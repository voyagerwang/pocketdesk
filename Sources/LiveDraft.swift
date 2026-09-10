/**
 * [INPUT]: 依赖 Foundation；DraftEditor 提供绑定编辑器的焦点、文本及 UTF-16 选区读写。
 * [OUTPUT]: 提供 LiveDraft 单轮草稿状态机与 DraftSnapshot；失败停手，显式重试可核对原控件或由用户在当前焦点继续已输入正文，提交后封闭。
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

struct LiveDraftFailure: LocalizedError {
    let message: String
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
    private var attempted = ""
    private var retryable = false
    private var writeUncertain = false
    private var expected = DraftSnapshot.end(of: "")
    private(set) var stopped = false
    private(set) var committed = false
    private(set) var text = ""

    init(id: String, context: String, target: String, editor: DraftEditor?, selectionWriter: ((String, String) -> Bool)? = nil,
         reconcileSelection: ((String, String) -> String?)? = nil, resumedText: String? = nil) {
        self.id = id; self.context = context; self.target = target
        self.selectionWriter = selectionWriter
        self.reconcileSelection = reconcileSelection
        // 能力探测之后再读一次，只有空白且光标在起点的框可以被本轮接管。
        if let resumedText {
            self.editor = nil; mode = selectionWriter == nil ? .deferred : .selection
            text = resumedText; attempted = resumedText
        } else if let editor, editor.isFocused(), editor.read() == .end(of: "") {
            self.editor = editor; mode = .replace
        } else { self.editor = nil; mode = selectionWriter == nil ? .deferred : .selection }
    }

    func update(_ value: String) throws {
        guard !stopped else { throw failure("同步已暂停，草稿已保留；请确认电脑内容后清空手机草稿，开始新一轮。") }
        guard !committed else { throw failure("本轮已经提交，请开始新的草稿。") }
        attempted = value
        // 应用切回后的续发以 resumedText 建立已输入基线。正文没有变化时不再调用
        // selectionWriter 核对旧控件，也不产生任何键盘事件，只继续附件与提交。
        if value == text { return }
        guard let editor else {
            if let selectionWriter, !selectionWriter(text, value) {
                throw stop("输入位置或替换结果无法确认，已停止同步；请核对电脑内容。", retryable: true)
            }
            text = value; return
        }
        guard editor.isFocused(), editor.read() == expected else {
            throw stop("电脑输入位置或内容已变化，已停止同步并保留手机草稿。", retryable: true)
        }
        guard value != expected.text else { text = value; return }
        writeUncertain = true
        guard editor.replace(value), editor.isFocused(), editor.read() == .end(of: value) else {
            throw stop("未能确认文本替换结果，已停止同步；请检查电脑内容，避免重复输入。", retryable: true)
        }
        expected = .end(of: value)
        writeUncertain = false
        text = value
    }

    func recover() throws {
        guard stopped, !committed else { return }
        guard retryable else { throw failure("上次提交或输入位置发生变化，无法安全重试；请核对电脑内容。") }
        if let editor {
            guard editor.isFocused(), let actual = editor.read(),
                  (!writeUncertain && actual == expected) || actual == .end(of: attempted) else {
                throw failure("电脑内容与本轮草稿不一致，请切回原输入框后重试；手机文字已保留。")
            }
            expected = actual; text = actual.text
            writeUncertain = false
        } else if mode == .selection {
            guard let confirmed = reconcileSelection?(text, attempted) else {
                throw failure("还不能核对原输入框，请切回原输入位置后重试；手机文字已保留，未重复输入。")
            }
            text = confirmed
        } else {
            // 暂存后的最终粘贴可能已执行，不能从 stopped 状态重复提交。
            throw failure("上次提交结果未确认，请核对电脑内容；手机文字已保留。")
        }
        stopped = false
    }

    func finish() { committed = true }
    func stop(_ message: String, retryable: Bool = false) -> LiveDraftFailure {
        stopped = true; self.retryable = retryable; return failure(message)
    }
    private func failure(_ message: String) -> LiveDraftFailure { .init(message: message) }
}
