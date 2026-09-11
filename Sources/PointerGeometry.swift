/**
 * [INPUT]: 依赖 CoreGraphics 的 CGRect/CGPoint/CGDirectDisplayID；纯几何，不读焦点、不发事件、不持有状态。
 * [OUTPUT]: 提供 PointerGeometry：有效显示器矩形集合、窗口与显示器的最大相交可见区域、未被明显遮挡的落点选择、以及"当前光标是否已在目标窗口可见区域内"的判定。
 * [POS]: Sources 的定位几何层；TargetWindowLocator 提供窗口与遮挡者，Server 组合两者，PointerExecutor 负责真正注入。
 *        全部坐标一律使用 CoreGraphics 全局桌面点（左上原点），与 AXPosition / CGWindowList 同一坐标系，
 *        不混用 NSScreen 左下原点，也不使用 Retina 像素。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CoreGraphics
import Foundation

enum PointerGeometry {
    /// 跳过定位的原因。回执里原样透出，便于区分"没窗口/被遮挡/屏幕没交集"。
    enum SkipReason: String, Error {
        case degenerateWindow = "degenerate-window"
        case noScreenOverlap = "no-screen-overlap"
        case occluded = "occluded"
    }

    private static let minWindowSide: CGFloat = 8

    static func centerOf(_ rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    /// 有效显示器矩形集合。L 形排列时不能用外接矩形——外接矩形包含没有屏幕的空洞，
    /// 光标会被允许停在不存在的区域。取不到时退回主屏（这是唯一允许的兜底，且只用于"屏幕都不认识"的异常态）。
    static func activeDisplayRects() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        let rects = (0..<Int(count)).map { CGDisplayBounds(ids[$0]) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        return rects.isEmpty ? [CGDisplayBounds(CGMainDisplayID())] : rects
    }

    /// 窗口与某块显示器的最大相交区域。窗口跨屏时取面积最大的那块，天然支持负坐标、纵向与 L 形排列。
    static func visibleRect(window: CGRect, screens: [CGRect]) -> CGRect? {
        guard !window.isNull, window.width >= minWindowSide, window.height >= minWindowSide else { return nil }
        var best: CGRect?
        var bestArea: CGFloat = 0
        for screen in screens where !screen.isNull {
            let intersection = window.intersection(screen)
            guard !intersection.isNull, intersection.width >= 1, intersection.height >= 1 else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea { bestArea = area; best = intersection }
        }
        return best
    }

    /// 光标是否已在目标窗口的可见区域内且未被明显遮挡——在窗口内就保持原位，不做无谓移动。
    static func isCursorSettled(at current: CGPoint, window: CGRect, screens: [CGRect], occluders: [CGRect]) -> Bool {
        guard let visible = visibleRect(window: window, screens: screens), visible.contains(current) else { return false }
        return !occluders.contains { $0.contains(current) }
    }

    /// 选择落点：优先窗口自身中心（若它本就可见且未被遮挡），否则取最大可见相交区域的中心，
    /// 再退到可见区域内的三分点网格。**无法证明可见就不给落点**，绝不回退主屏中心。
    static func landing(window: CGRect, screens: [CGRect], occluders: [CGRect]) -> Result<CGPoint, SkipReason> {
        guard let visible = visibleRect(window: window, screens: screens) else { return .failure(.noScreenOverlap) }
        var candidates: [CGPoint] = []
        let windowCenter = centerOf(window)
        if visible.contains(windowCenter) { candidates.append(windowCenter) }
        candidates.append(centerOf(visible))
        for fy in [0.25, 0.5, 0.75] as [CGFloat] {
            for fx in [0.25, 0.5, 0.75] as [CGFloat] {
                candidates.append(CGPoint(x: visible.minX + visible.width * fx, y: visible.minY + visible.height * fy))
            }
        }
        for candidate in candidates {
            guard visible.contains(candidate) else { continue }
            let point = clampInside(candidate, visible)
            if !occluders.contains(where: { $0.contains(point) }) { return .success(point) }
        }
        return .failure(.occluded)
    }

    /// 收进可见区域内部：矩形外沿不是可用像素，贴边会让落点落在窗口边框上。
    private static func clampInside(_ point: CGPoint, _ rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX + 0.5), rect.maxX - 1),
                y: min(max(point.y, rect.minY + 0.5), rect.maxY - 1))
    }
}
