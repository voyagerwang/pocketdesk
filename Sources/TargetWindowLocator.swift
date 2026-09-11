/**
 * [INPUT]: 依赖 AppKit/ApplicationServices 的 AXUIElement 窗口属性与 CoreGraphics 的 CGWindowListCopyWindowInfo。
 * [OUTPUT]: 提供 TargetWindowLocator.resolve(pid:)：目标应用的目标窗口矩形与位于其之上的其他应用遮挡窗口矩形，
 *           优先 AX focused window、其次 AX main window、再退到该 PID 最前的普通可见窗口。
 * [POS]: Sources 的窗口解析层；只读窗口服务器与辅助功能属性，不移动光标、不改变焦点。与 PointerGeometry 组合使用。
 *        所有矩形都是 CoreGraphics 全局桌面点（左上原点），与 AXPosition 同坐标系，不做 NSScreen 翻转。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import ApplicationServices
import CoreGraphics

enum TargetWindowLocator {
    struct Resolution {
        let rect: CGRect
        /// z 序在目标窗口之前的其他应用普通窗口；明显遮挡落点时会跳过定位。
        let occluders: [CGRect]
        /// 目标窗口的来源：ax-focused / ax-main / frontmost-window。仅用于诊断。
        let source: String
    }

    /// 只有当窗口两边都够大才算"像样的窗口"：排除零尺寸、工具条残留与不可见辅助窗。
    private static let minSide: CGFloat = 40
    private static let minOccluderSide: CGFloat = 24
    private static let minAlpha = 0.05

    static func resolve(pid: pid_t) -> Resolution? {
        guard pid > 0 else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }

        struct Entry { let pid: pid_t; let layer: Int; let rect: CGRect; let alpha: Double }
        let ownerKey = kCGWindowOwnerPID as String
        let layerKey = kCGWindowLayer as String
        let boundsKey = kCGWindowBounds as String
        let alphaKey = kCGWindowAlpha as String

        var entries: [Entry] = []
        for raw in list {
            guard let owner = raw[ownerKey] as? Int32, let layer = raw[layerKey] as? Int,
                  let dict = raw[boundsKey] as? [String: Any],
                  let x = dict["X"] as? CGFloat, let y = dict["Y"] as? CGFloat,
                  let width = dict["Width"] as? CGFloat, let height = dict["Height"] as? CGFloat else { continue }
            entries.append(Entry(pid: owner, layer: layer, rect: CGRect(x: x, y: y, width: width, height: height),
                                 alpha: (raw[alphaKey] as? Double) ?? 1))
        }

        // 目标应用自己的普通窗口：layer 0（排除菜单栏、Dock、悬浮面板与桌面元素）、可见、尺寸像样。
        let own = entries.enumerated().filter { _, entry in
            entry.pid == pid && entry.layer == 0 && entry.alpha > minAlpha
                && entry.rect.width >= minSide && entry.rect.height >= minSide
        }
        guard let frontmostOwn = own.first else { return nil }

        // 优先 AX focused window，其次 AX main window；用矩形把它匹配回窗口列表里的那一条，
        // 因为窗口列表带 z 序信息（判定遮挡必须靠它），而 AX 带"哪个是用户正在用的窗口"。
        var rect = frontmostOwn.element.rect
        var source = "frontmost-window"
        let axCandidates: [(CGRect?, String)] = [
            (axWindowFrame(pid: pid, focused: true), "ax-focused"),
            (axWindowFrame(pid: pid, focused: false), "ax-main"),
        ]
        for (candidate, name) in axCandidates {
            guard let candidate else { continue }
            if let match = own.first(where: { framesMatch($0.element.rect, candidate) }) {
                rect = match.element.rect; source = name; break
            }
        }

        let occluders = entries.prefix(frontmostOwn.offset)
            .filter { $0.pid != pid && $0.layer == 0 && $0.alpha > minAlpha
                        && $0.rect.width >= minOccluderSide && $0.rect.height >= minOccluderSide }
            .map { $0.rect }
        return Resolution(rect: rect, occluders: occluders, source: source)
    }

    private static func axWindowFrame(pid: pid_t, focused: Bool) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let attribute = focused ? kAXFocusedWindowAttribute : kAXMainWindowAttribute
        guard AXUIElementCopyAttributeValue(app, attribute as CFString, &raw) == .success,
              let window = raw, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return frame(of: window as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copy(element, kAXPositionAttribute), let sizeValue = copy(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        guard size.width >= 1, size.height >= 1 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copy(_ element: AXUIElement, _ name: String) -> AXValue? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    /// AX 与窗口服务器的矩形偶尔差一两个像素（边框/缩放），按容差比对。
    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 4 && abs(lhs.height - rhs.height) <= 4
    }
}
