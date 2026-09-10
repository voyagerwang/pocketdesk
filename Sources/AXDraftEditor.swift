/**
 * [INPUT]: 依赖 AppKit Accessibility 和 LiveDraft 的 DraftEditor；只访问当前聚焦元素。
 * [OUTPUT]: 提供 AXDraftEditor；对受支持的空白 TextEdit .txt 文档直接设置 AXValue，读回全文并定位 UTF-16 文末。
 * [POS]: Sources 的整值替换适配器；其他应用走 KeyboardDraftWriter 的正常输入事件，避免绕过编辑器模型。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

final class AXDraftEditor: DraftEditor {
    private let pid: pid_t
    private let element: AXUIElement
    private init(pid: pid_t, element: AXUIElement) { self.pid = pid; self.element = element }

    static func capture(_ app: NSRunningApplication) -> AXDraftEditor? {
        // 只开放可确认是纯文本文件的原生编辑器。Electron/网页的 AX 值可能绕开应用模型，
        // 即使报告可写也不自动开放整值写入；它们通过选区和正常输入事件实时更新。
        guard app.bundleIdentifier == "com.apple.TextEdit",
              let element = focused(app.processIdentifier),
              string(element, kAXRoleAttribute) == kAXTextAreaRole,
              string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              let window = attribute(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID(),
              let document = string(window as! AXUIElement, kAXDocumentAttribute),
              let url = URL(string: document), url.isFileURL, url.pathExtension.lowercased() == "txt",
              settable(element, kAXValueAttribute), settable(element, kAXSelectedTextRangeAttribute) else { return nil }
        return AXDraftEditor(pid: app.processIdentifier, element: element)
    }

    func isFocused() -> Bool {
        guard let current = Self.focused(pid) else { return false }
        return CFEqual(current, element)
    }

    func read() -> DraftSnapshot? {
        guard let text = Self.string(element, kAXValueAttribute),
              let raw = Self.attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        return .init(text: text, location: range.location, length: range.length)
    }

    func replace(_ text: String) -> Bool {
        guard isFocused(), AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else { return false }
        // 只读等待系统应用新值；不重放写入，失败也不退格或追加。
        for _ in 0..<6 {
            guard isFocused() else { return false }
            if Self.string(element, kAXValueAttribute) == text {
                var range = CFRange(location: text.utf16.count, length: 0)
                guard let value = AXValueCreate(.cfRange, &range) else { return false }
                return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
            }
            usleep(15_000)
        }
        return false
    }

    private static func focused(_ pid: pid_t) -> AXUIElement? {
        guard let raw = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
    private static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        var value: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &value) == .success && value.boolValue
    }
}
