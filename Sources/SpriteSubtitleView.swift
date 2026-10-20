/**
 * [INPUT]: 依赖 AppKit TextKit；接收原生编辑器的完整正文与 UTF-16 组合文字范围。
 * [OUTPUT]: 逐行居中的语音字幕；输入法组合文字的蓝色下划线与文字共用换行和滚动布局，确认后清除。
 * [POS]: 桌面小精灵的只读转写展示；由 SpriteFeedbackPanel 投影真实编辑状态，不参与输入法接收或提交。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

final class SpriteSubtitleView: NSTextView {
    private var displayedMarkedRange: NSRange?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        drawsBackground = false
        font = .systemFont(ofSize: 16, weight: .medium)
        textColor = .labelColor
        alignment = .center
        textContainerInset = NSSize(width: 0, height: 2)
        textContainer?.widthTracksTextView = true
        // 字幕文档随内容增高，可见高度由外层滚动区限制。
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("字幕视图仅支持程序化创建") }

    func update(text: String, markedRange: NSRange? = nil) {
        let length = text.utf16.count
        let marked = markedRange.flatMap { range -> NSRange? in
            guard range.location != NSNotFound, range.location >= 0,
                  range.location < length, range.length > 0 else { return nil }
            return NSRange(location: range.location, length: min(range.length, length - range.location))
        }
        let textChanged = string != text
        guard textChanged || displayedMarkedRange != marked else { return }
        if textChanged { string = text }
        displayedMarkedRange = marked
        let fullRange = NSRange(location: 0, length: length)
        textStorage?.beginEditing()
        textStorage?.removeAttribute(.underlineStyle, range: fullRange)
        textStorage?.removeAttribute(.underlineColor, range: fullRange)
        if let marked {
            textStorage?.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: NSColor.controlAccentColor], range: marked)
        }
        textStorage?.endEditing()
        if textChanged { scrollRangeToVisible(NSRange(location: length, length: 0)) }
    }
}
