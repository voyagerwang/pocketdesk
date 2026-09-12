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

        // 目标应用名（用于按 owner name 匹配）。Electron 类多进程应用（WorkBuddy/飞书）的窗口常由
        // 渲染子进程持有，主进程 pid 不拥有窗口；CGWindowList 里这些窗口的 owner name 就是应用名，
        // 所以除精确 pid 外，还要按应用名匹配，否则 resolve 会整条失败（光标都不移过去）。
        // 注意：Electron 主进程在 NSRunningApplication 里往往取不到 localizedName（返回 nil），
        // 此时改从可执行路径反推 .app 目录名（CG 窗口 owner name 正是它）。
        let appName = Self.appName(for: pid)
        let matchesApp: (pid_t, String?) -> Bool = { entryPid, entryOwner in
            entryPid == pid || (entryOwner != nil && entryOwner == appName)
        }

        struct Entry { let pid: pid_t; let owner: String?; let layer: Int; let rect: CGRect; let alpha: Double }
        let ownerKey = kCGWindowOwnerPID as String
        let ownerNameKey = kCGWindowOwnerName as String
        let layerKey = kCGWindowLayer as String
        let boundsKey = kCGWindowBounds as String
        let alphaKey = kCGWindowAlpha as String

        var entries: [Entry] = []
        for raw in list {
            guard let owner = raw[ownerKey] as? Int32, let layer = raw[layerKey] as? Int,
                  let dict = raw[boundsKey] as? [String: Any],
                  let x = dict["X"] as? CGFloat, let y = dict["Y"] as? CGFloat,
                  let width = dict["Width"] as? CGFloat, let height = dict["Height"] as? CGFloat else { continue }
            let ownerName = raw[ownerNameKey] as? String
            entries.append(Entry(pid: owner, owner: ownerName, layer: layer,
                                 rect: CGRect(x: x, y: y, width: width, height: height),
                                 alpha: (raw[alphaKey] as? Double) ?? 1))
        }

        // 目标应用自己的普通窗口：layer 0（排除菜单栏、Dock、悬浮面板与桌面元素）、可见、尺寸像样。
        // 匹配条件：pid 相等 或 owner name 等于应用名（覆盖 Electron 子进程持有窗口的情况）。
        let own = entries.enumerated().filter { _, entry in
            matchesApp(entry.pid, entry.owner) && entry.layer == 0 && entry.alpha > minAlpha
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
            .filter { !matchesApp($0.pid, $0.owner) && $0.layer == 0 && $0.alpha > minAlpha
                        && $0.rect.width >= minOccluderSide && $0.rect.height >= minOccluderSide }
            .map { $0.rect }
        return Resolution(rect: rect, occluders: occluders, source: source)
    }

    private static func axWindowFrame(pid: pid_t, focused: Bool) -> CGRect? {
        return axWindowElement(pid: pid, preferFocused: focused).flatMap { frame(of: $0) }
    }

    /// 取目标应用的窗口 AX 元素，按 focused → main → 全部窗口中第一个 的优先级回退。
    /// 这是 findInputBoxCenter 能检到输入框的前提：Electron 在后台/激活时序下 kAXFocusedWindowAttribute
    /// 常取不到，若不回退就会整条跳过、导致"鼠标跟过去了却点不进输入框"。
    private static func axWindowElement(pid: pid_t, preferFocused: Bool = true) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        let attrs: [CFString] = preferFocused
            ? [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString]
            : [kAXMainWindowAttribute as CFString, kAXFocusedWindowAttribute as CFString]
        for attr in attrs {
            var raw: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr, &raw) == .success,
               let window = raw, CFGetTypeID(window) == AXUIElementGetTypeID() {
                return (window as! AXUIElement)
            }
        }
        // 最后回退到 AXWindows 列表的第一个（Electron 的非模态主窗口通常排在最前）。
        var winsRaw: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRaw) == .success,
           let wins = winsRaw as? [AXUIElement], let first = wins.first {
            return first
        }
        return nil
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

    /// 在目标应用的聚焦窗口里定位"主输入框"（聊天 / Agent 工具的撰写框），返回其全局中心点。
    /// 只读 AX 树，不动光标、不改焦点。找不到（无辅助功能权限、窗口无文本框、或 AX 树过大超预算）时返回 nil，
    /// 调用方据此回退为只移动光标——这样非输入类应用完全不受影响，只有聊天/Agent/编辑器这类
    /// 能检出输入框的应用才会被点击聚焦。
    static func findInputBoxCenter(pid: pid_t) -> CGPoint? {
        guard pid > 0 else { return nil }
        guard let window = axWindowElement(pid: pid) else { return nil }

        var best: (center: CGPoint, score: CGFloat)?
        // 浏览器/Electron 整页 AX 树可能极大（长会话几万节点），预算要够大到能走到输入框，
        // 但也不能无限（定位是手动选择时的一次性动作，几百毫秒可接受）。
        var budget = 80000
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 28, budget > 0 else { return }
            budget -= 1
            let role = Self.role(of: element)
            if let frame = Self.frame(of: element), frame.width >= 12, frame.height >= 8,
               (role == "AXTextField" || role == "AXTextArea" || role == "AXSearchField"
                || (Self.isEditable(element) && frame.width >= 60 && frame.height >= 20)) {
                // 面积越大越可能是主撰写框；同面积时偏下（聊天输入框通常在底部）。
                let score = frame.width * frame.height + frame.maxY * 0.01
                if best == nil || score > best!.score {
                    best = (CGPoint(x: frame.midX, y: frame.midY), score)
                }
            }
            var childrenRaw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRaw) == .success,
                  let children = childrenRaw as? [AXUIElement] else { return }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return best?.center
    }

    private static func role(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return (value as! CFString) as String
    }

    private static func isEditable(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &raw) == .success,
              let value = raw else { return false }
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// 取应用的显示名，用于按 owner name 匹配窗口。优先 NSRunningApplication（原生 app 可靠）；
    /// Electron 主进程常被 NSRunningApplication 视为 nil，退而从可执行路径反推 .app 目录名
    ///（CGWindowList 里对应窗口的 owner name 正是它，例如 WorkBuddy.app → "WorkBuddy"）。
    private static func appName(for pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty { return name }
        var buf = [CChar](repeating: 0, count: 4096)
        guard procPidPath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let exe = String(cString: buf)
        guard let r = exe.range(of: ".app/", options: .backwards) else { return nil }
        let appPath = String(exe[..<r.upperBound]) // .../WorkBuddy.app
        let dirName = (appPath as NSString).lastPathComponent // WorkBuddy.app
        return dirName.replacingOccurrences(of: ".app", with: "")
    }
}

/// proc_pidpath 的 Swift 声明（sys/proc_info.h，Darwin 未直接暴露 Swift 签名）。
@_silgen_name("proc_pidpath")
private func procPidPath(_ pid: Int32, _ buf: UnsafeMutablePointer<CChar>, _ size: UInt32) -> Int32
