/**
 * [INPUT]: 依赖 AppKit 的 NSWorkspace 与 ApplicationServices 的 AXUIElement；读取前台浏览器的可访问性树。
 * [OUTPUT]: 对外提供 PageReader.currentPage——返回当前网页的绑定引用（浏览器/URL/标题）与可读正文。
 * [POS]: Sources 的 BrowserAdapter 自有实现：**只做只读读取**，不点击、不填表、不执行脚本。
 *        M1 用它替代 tt-bridge 承担网页正文读取（方案 §8.1 v1.1 决策走 tt-bridge，但其 CC BY-NC
 *        许可与内置分发冲突且未实测；在许可结论出来前用零依赖的 AX 路径交付真实只读能力）。
 *        接口与 tt-bridge 版一致，替换实现不动 TaskService。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

struct PageContent {
    var binding: PageBinding
    var text: String
    /// 正文是否被预算截断——截断必须如实告知，否则模型会以为读到了全文。
    var truncated: Bool
}

enum PageReaderError: LocalizedError {
    case permissionDenied
    case noBrowser(String)
    case noWebArea
    case emptyPage

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有辅助功能授权，读不到网页内容。请在系统设置 → 隐私与安全性 → 辅助功能里允许 PocketDesk。"
        case .noBrowser(let name):
            return "当前前台应用（\(name)）不是浏览器，无法读取网页。请把 Chrome 或 Safari 切到前台再试。"
        case .noWebArea:
            return "浏览器里没有找到网页内容区域，可能是新建标签页或浏览器窗口没有打开页面。"
        case .emptyPage:
            return "读到了网页区域但没有可提取的文字，可能是纯图片页面或内容尚未加载完成。"
        }
    }
}

enum PageReader {
    /// 浏览器 bundleID → 展示名。只认真正的浏览器，不把任何"带网页视图的应用"算进来。
    private static let browsers: [String: String] = [
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.canary": "Chrome Canary",
        "com.apple.Safari": "Safari",
        "com.apple.SafariTechnologyPreview": "Safari TP",
        "com.microsoft.edgemac": "Edge",
        "com.microsoft.Edge": "Edge",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
    ]

    /// 遍历预算：大页面的 AX 树可以到几十万节点，不设上限会让一次读取卡住主线程。
    private static let maxNodes = 6000
    private static let maxDepth = 40
    static let defaultCharacterBudget = 24000

    /// 辅助功能授权状态。放在这里是为了让不含 AppKit 的模块（TaskService）也能问到同一事实源。
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func currentPage(maxCharacters: Int = defaultCharacterBudget) -> Result<PageContent, PageReaderError> {
        guard isTrusted else { return .failure(.permissionDenied) }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier,
              let name = browsers[bundleID] else {
            return .failure(.noBrowser(NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用"))
        }
        let pid = front.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        guard let windows = Self.children(of: app, attribute: kAXWindowsAttribute), !windows.isEmpty else {
            return .failure(.noWebArea)
        }
        // 先看焦点窗口，其次按顺序找：多窗口时"用户正在看的那页"通常在焦点窗口。
        var ordered = windows
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focused = focusedValue, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            ordered = [focused as! AXUIElement] + windows
        }
        for window in ordered {
            guard let area = Self.findWebArea(element: window, depth: 0) else { continue }
            let url = Self.attribute(kAXURLAttribute, of: area) ?? Self.firstURL(in: window) ?? ""
            let title = Self.attribute(kAXTitleAttribute, of: window) ?? Self.attribute(kAXTitleAttribute, of: area) ?? ""
            var budget = maxCharacters
            var nodes = 0
            let text = Self.collectText(element: area, depth: 0, budget: &budget, nodes: &nodes)
            guard !text.isEmpty else { return .failure(.emptyPage) }
            let binding = PageBinding(browser: name, windowId: nil, tabId: nil,
                                      url: url, title: title, observedAt: Date().timeIntervalSince1970)
            return .success(PageContent(binding: binding, text: text, truncated: budget <= 0))
        }
        return .failure(.noWebArea)
    }

    // MARK: AX 遍历

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return nil }
        return array
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        if let text = value as? String, !text.isEmpty { return text }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }

    // HIServices 没有把这些角色导出成 Swift 可见的 CFString 常量，直接用官方角色名字符串。
    private static let webAreaRole = "AXWebArea"
    private static let ignoredRoles: Set<String> = ["AXToolbar", "AXMenuBar", "AXMenu", "AXMenuBarItem", "AXScrollBar", "AXSplitter", "AXGrowArea"]

    private static func findWebArea(element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        if role(of: element) == webAreaRole { return element }
        for child in children(of: element, attribute: kAXChildrenAttribute) ?? [] {
            if let found = findWebArea(element: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// 兜底取 URL：有些浏览器的 AXWebArea 不带 URL 属性，就从可见的静态文本里找第一个 http(s) 串。
    /// 只在地址栏文本暴露给 AX 时才有效，找不到就返回空——URL 为空时上层会如实显示「未知地址」。
    private static func firstURL(in element: AXUIElement) -> String? {
        if let text = attribute(kAXValueAttribute, of: element) ?? attribute(kAXDescriptionAttribute, of: element),
           let match = text.range(of: "https?://[^\\s\"'<>]+", options: .regularExpression) {
            return String(text[match])
        }
        for child in children(of: element, attribute: kAXChildrenAttribute) ?? [] {
            if let found = firstURL(in: child) { return found }
        }
        return nil
    }

    /// 递归收集可读文本。跳过按钮/工具栏类的噪音，保留标题、正文、链接文字。
    private static func collectText(element: AXUIElement, depth: Int, budget: inout Int, nodes: inout Int) -> String {
        guard depth < maxDepth, nodes < maxNodes, budget > 0 else { return "" }
        nodes += 1
        if let currentRole = role(of: element), ignoredRoles.contains(currentRole) { return "" }
        var parts: [String] = []
        let candidates = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        for name in candidates {
            guard let text = attribute(name, of: element) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // 同一个元素上三个属性经常返回同一串，去重后再收。
            if trimmed.count > 1, !parts.contains(trimmed) { parts.append(trimmed) }
        }
        for child in children(of: element, attribute: kAXChildrenAttribute) ?? [] {
            guard budget > 0 else { break }
            let piece = collectText(element: child, depth: depth + 1, budget: &budget, nodes: &nodes)
            if !piece.isEmpty { parts.append(piece) }
        }
        let joined = parts.joined(separator: "\n")
        if joined.utf8.count > budget {
            let limited = String(joined.prefix(budget))
            budget = 0
            return limited
        }
        budget -= joined.utf8.count
        return joined
    }
}
