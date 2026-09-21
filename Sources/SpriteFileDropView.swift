/**
 * [INPUT]: AppKit 文件拖放粘贴板，仅接收 file URL；外部注入准备回调。
 * [OUTPUT]: 桌面小精灵多文件拖入入口与拖入反馈；不接收网页文本或远程 URL。
 * [POS]: SpriteFeedbackPanel 的原生容器；文件执行交给 PhoneFileStore，视觉层不读取文件内容。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

final class SpriteFileDropView: NSView {
    var receive: (([String]) -> Void)?
    var allowed: () -> Bool = { true }
    /// 面板 isMovableByWindowBackground 依赖这一位：容器是拖放目标，但空白区域仍要能拖动面板。
    override var mouseDownCanMoveWindow: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func paths(_ sender: NSDraggingInfo) -> [String] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(\.isFileURL).map(\.path)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard allowed(), !paths(sender).isEmpty else { return [] }
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 16
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        let selected = paths(sender)
        guard allowed(), !selected.isEmpty else { return false }
        receive?(selected)
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }
}
