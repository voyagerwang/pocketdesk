/**
 * [INPUT]: An explicit headset request PID, bounded AX reads, and the existing authorized pointer executor.
 * [OUTPUT]: A verified ordinary editor in that PID's original focused window, with its untouched text baseline.
 * [POS]: Voice preparation only: no navigation, new conversation, text/selection writes, or Option events.
 * [PROTOCOL]: The injected driver is for isolated tests; production completion always arrives on main.
 */
import AppKit
import ApplicationServices

final class HeadsetVoiceFocusRequest {
    let pid: pid_t
    private let lock = NSLock()
    private var live = true
    init(pid: pid_t) { self.pid = pid }
    var active: Bool { lock.lock(); defer { lock.unlock() }; return live }
    func cancel() { lock.lock(); live = false; lock.unlock() }
}

struct HeadsetVoiceFocusFailure: Error { let message: String; var reason = "unverified" }

enum HeadsetVoiceFocus {
    struct Prepared { let pid: pid_t; let element: AXUIElement; let original: String }
    struct TargetedResult {
        var candidates: [AXUIElement]
        var complete: Bool
        var unsafe = false
        var count = 0
        var depth = 0
        var pending = 0
        var reason = "targeted-complete"
    }
    struct Diagnostic {
        let pid: pid_t; let reason: String; let route: String; let count: Int; let depth: Int; let scanMs: Double; let pending: Int
        let areas: Int; let fields: Int
        var line: String { String(format: "voice focus: pid=%d reason=%@ route=%@ count=%d depth=%d scanMs=%.0f pending=%d areas=%d fields=%d", pid, reason, route, count, depth, scanMs, pending, areas, fields) }
    }
    struct Node {
        let role: String
        var subrole = ""
        var enabled = true
        var visible = true
        var editable = false
        var readOnly = false
        var secure: Bool { role == "AXSecureTextField" || subrole == kAXSecureTextFieldSubrole }
        var excluded: Bool {
            secure || role == "AXComboBox" || role == "AXSearchField" || subrole.lowercased().contains("search")
        }
        var ordinary: Bool { !excluded && !readOnly && enabled && visible && editable && ["AXTextArea", "AXTextField"].contains(role) }
    }
    /// Drivers expose only the operations this request needs. They never receive dictated text for logging.
    struct Driver {
        var now: () -> TimeInterval
        var sleep: (TimeInterval) -> Void
        var unlocked: () -> Bool
        var trusted: () -> Bool
        var focusedPID: () -> pid_t?
        var window: (pid_t) -> AXUIElement?
        var focus: (pid_t) -> AXUIElement?
        var node: (AXUIElement, AXUIElement) -> Node?
        var children: (AXUIElement) -> [AXUIElement]
        var belongs: (AXUIElement, AXUIElement, pid_t) -> Bool
        var equal: (AXUIElement, AXUIElement) -> Bool
        var supportedTextField: (pid_t) -> Bool
        var text: (AXUIElement) -> String?
        var setFocus: (AXUIElement) -> Bool
        var mouse: () -> CGPoint?
        var clickPoint: (AXUIElement, AXUIElement, pid_t) -> CGPoint?
        var click: ((CGPoint, @escaping () -> Bool, @escaping (Bool) -> Void) -> Void)?
        var warmAccessibility: ((pid_t, @escaping () -> Bool, TimeInterval) -> Void)? = nil
        var targetedLocator: ((pid_t, AXUIElement, @escaping () -> Bool, TimeInterval) -> TargetedResult)? = nil
        var diagnostic: (Diagnostic) -> Void = { HeadsetLog($0.line) }
    }
    static let totalBudget: TimeInterval = 1.25
    static let scanBudget: TimeInterval = 0.8
    static let nodeLimit = 6_000
    /// AXValue being non-settable does not make a controlled Electron editor read-only.
    /// Ordinary text roles describe keyboard input; explicit read-only/editability evidence still wins.
    static func ordinaryEditor(role: String, declaredEditable: Bool?, readOnly: Bool?) -> Bool {
        ["AXTextArea", "AXTextField"].contains(role) && declaredEditable != false && readOnly != true
    }
    private static let queue = DispatchQueue(label: "pocketdesk.headset-voice-focus", qos: .userInitiated)

    static func prepare(request: HeadsetVoiceFocusRequest, pointer: PointerExecutor?,
                        completion: @escaping (Result<Prepared, HeadsetVoiceFocusFailure>) -> Void) {
        prepare(request: request, driver: nativeDriver(pointer: pointer), completion: completion)
    }
    static func prepare(request: HeadsetVoiceFocusRequest, driver: Driver,
                        completion: @escaping (Result<Prepared, HeadsetVoiceFocusFailure>) -> Void) {
        let work = Work(request: request, driver: driver, completion: completion)
        queue.async { work.begin() }
        queue.asyncAfter(deadline: .now() + totalBudget) { work.fail("语音准备超时，请点一下原输入框后重试。", reason: "request-deadline") }
    }

    private final class Work {
        let request: HeadsetVoiceFocusRequest
        let driver: Driver
        let completion: (Result<Prepared, HeadsetVoiceFocusFailure>) -> Void
        let deadline: TimeInterval
        private var window: AXUIElement?
        private var initialFocus: AXUIElement?
        private var anchor: CGPoint?
        private let completionLock = NSLock()
        private var finished = false
        private var route = "existing-focus"
        private var scannedCount = 0
        private var deepest = 0
        private var pendingCount = 0
        private var scanStarted: TimeInterval?
        private var scanFinished: TimeInterval?
        private var areaCount = 0
        private var fieldCount = 0
        init(request: HeadsetVoiceFocusRequest, driver: Driver,
             completion: @escaping (Result<Prepared, HeadsetVoiceFocusFailure>) -> Void) {
            self.request = request; self.driver = driver; self.completion = completion
            deadline = driver.now() + totalBudget
        }
        func valid() -> Bool {
            guard request.active, driver.now() < deadline, driver.unlocked(), driver.trusted(),
                  driver.focusedPID() == request.pid, request.active else { return false }
            if let window {
                guard let current = driver.window(request.pid), driver.equal(current, window) else { return false }
            }
            return request.active && driver.now() < deadline
        }
        private func cheapValid() -> Bool { request.active && driver.now() < deadline }
        func exactFocus(_ element: AXUIElement) -> Bool {
            guard valid(), let window, driver.belongs(element, window, request.pid),
                  let current = driver.focus(request.pid), driver.equal(current, element),
                  driver.node(element, window)?.ordinary == true else { return false }
            return valid()
        }
        func begin() {
            guard request.pid > 0, valid() else {
                fail("未能确认原应用的当前窗口，请先点一下输入框。"); return
            }
            let observedWindow = driver.window(request.pid)
            let observedFocus = driver.focus(request.pid)
            if (observedWindow == nil || observedFocus == nil), let warm = driver.warmAccessibility {
                guard valid() else { fail("应用状态已变化，未准备辅助功能。"); return }
                warm(request.pid, { [self] in valid() }, deadline)
            }
            guard valid(), let captured = driver.window(request.pid) else {
                fail("未能确认原应用的当前窗口，请先点一下输入框。"); return
            }
            if let observedWindow, !driver.equal(observedWindow, captured) {
                fail("辅助功能准备期间窗口已变化，未调整焦点。"); return
            }
            window = captured
            guard valid() else { fail("应用或窗口已变化，未调整焦点。"); return }
            anchor = driver.mouse()
            initialFocus = driver.focus(request.pid)
            if let focus = initialFocus, let info = driver.node(focus, captured) {
                guard !info.secure, !info.readOnly else { fail("当前为密码或只读控件，请选择普通输入框。"); return }
                if info.ordinary {
                    guard driver.belongs(focus, captured, request.pid) else { fail("当前输入焦点不属于原窗口，未调整焦点。"); return }
                    capture(focus); return
                }
            }
            let scanEnd = min(deadline, driver.now() + scanBudget)
            scanStarted = driver.now()
            var locatedTarget: AXUIElement?
            if driver.supportedTextField(request.pid), let locator = driver.targetedLocator {
                route = "agent-region"
                let result = locator(request.pid, captured, { [self] in valid() }, min(scanEnd, deadline - 0.3))
                scannedCount = result.count; deepest = result.depth; pendingCount = result.pending
                guard valid() else { fail("输入框定位期间应用或窗口已变化。", reason: "targeted-state-changed"); return }
                guard result.complete, !result.unsafe else {
                    fail("未能完整核验主输入区域，请手动点一下输入框。", reason: result.reason); return
                }
                var matches: [AXUIElement] = []
                for element in result.candidates {
                    guard let info = driver.node(element, captured), info.role == "AXTextArea", info.ordinary,
                          driver.belongs(element, captured, request.pid) else {
                        fail("主输入区域命中未通过核验，未调整焦点。", reason: "targeted-editor-unsafe"); return
                    }
                    if !matches.contains(where: { driver.equal($0, element) }) { matches.append(element) }
                }
                areaCount = matches.count
                guard matches.count <= 1 else { fail("主输入区域有多个输入框，请明确点选一个。", reason: "targeted-ambiguous"); return }
                locatedTarget = matches.first
            }
            if locatedTarget == nil {
                route = "window-scan"; scannedCount = 0; deepest = 0; pendingCount = 0
                var pending: [(AXUIElement, Int)] = [(captured, 0)]
                var visited: [CFHashCode: [AXUIElement]] = [:]
                var areas: [AXUIElement] = [], fields: [AXUIElement] = []
                while let (element, depth) = pending.popLast() {
                    pendingCount = pending.count + 1; deepest = max(deepest, depth)
                    guard cheapValid() else { fail("输入框检查已取消或超时。", reason: request.active ? "request-deadline" : "cancelled"); return }
                    guard driver.now() < scanEnd else { fail("输入框检查超时，请手动点一下输入框。", reason: "scan-time-limit"); return }
                    guard scannedCount < nodeLimit else { fail("输入框检查超出节点上限。", reason: "scan-node-limit"); return }
                    guard depth <= 32 else { fail("输入框检查超出层级上限。", reason: "scan-depth-limit"); return }
                    if scannedCount % 16 == 0, !valid() { fail("输入框检查期间应用或窗口已变化。", reason: "scan-state-changed"); return }
                    let hash = CFHash(element)
                    if visited[hash]?.contains(where: { driver.equal($0, element) }) == true { continue }
                    visited[hash, default: []].append(element); scannedCount += 1
                    if let info = driver.node(element, captured) {
                        if info.excluded || info.readOnly || !info.visible || !info.enabled { continue }
                        if info.ordinary && driver.belongs(element, captured, request.pid) {
                            if info.role == "AXTextArea" { areas.append(element) } else { fields.append(element) }
                            areaCount = areas.count; fieldCount = fields.count
                        }
                    }
                    let childList = driver.children(element)
                    guard childList.count + pending.count <= nodeLimit - scannedCount else {
                        pendingCount = pending.count + childList.count
                        fail("当前窗口的节点超出检查上限，请手动点一下输入框。", reason: "scan-node-limit"); return
                    }
                    pending.append(contentsOf: childList.reversed().map { ($0, depth + 1) })
                }
                pendingCount = 0
                guard valid() else { fail("输入框检查期间应用或窗口已变化。", reason: "scan-state-changed"); return }
                guard driver.now() < scanEnd else { fail("输入框检查超时。", reason: "scan-time-limit"); return }
                let candidates = areas.isEmpty && driver.supportedTextField(request.pid) ? fields : areas
                guard candidates.count == 1 else {
                    fail(candidates.count > 1 ? "当前窗口有多个输入框，请明确点选一个。" : "未找到可确认的普通输入框，请手动点一下。", reason: candidates.count > 1 ? "scan-ambiguous" : "scan-no-editor"); return
                }
                locatedTarget = candidates[0]
            }
            scanFinished = driver.now()
            guard let target = locatedTarget else { fail("未找到主输入框。", reason: "no-editor"); return }
            guard valid(), mouseUnchanged(), focusHasNotMoved(to: target) else {
                fail("用户焦点或鼠标已变化，未调整输入位置。"); return
            }
            if exactFocus(target) { capture(target); return }
            // No text or selection is changed; a successful AX return is still checked against the exact element.
            guard valid(), mouseUnchanged(), focusHasNotMoved(to: target) else { fail("聚焦前状态已变化，未调整输入位置。"); return }
            let accepted = driver.setFocus(target)
            if accepted && poll(target, until: min(deadline, driver.now() + 0.15)) { capture(target); return }
            guard valid(), mouseUnchanged(), focusHasNotMoved(to: target), let click = driver.click,
                  let capturedWindow = window, let point = driver.clickPoint(target, capturedWindow, request.pid) else {
                fail("未能安全聚焦原输入框，请手动点一下。"); return
            }
            let authorizationLock = NSLock()
            var allowedToMove = false
            let authorized = { [self] in
                guard valid(), focusHasNotMoved(to: target),
                      let fresh = driver.clickPoint(target, capturedWindow, request.pid),
                      hypot(fresh.x - point.x, fresh.y - point.y) <= 1 else { return false }
                authorizationLock.lock(); defer { authorizationLock.unlock() }
                guard let anchor, let cursor = driver.mouse() else { return false }
                let unchanged = hypot(cursor.x - anchor.x, cursor.y - anchor.y) <= 3
                let ownMove = allowedToMove && hypot(cursor.x - point.x, cursor.y - point.y) <= 1.5
                guard unchanged || ownMove else { return false }
                allowedToMove = true
                return valid()
            }
            guard authorized() else { fail("点击前窗口或鼠标已变化，未点击。"); return }
            click(point, authorized) { [self] clicked in
                queue.async { [self] in
                    guard clicked, valid(), poll(target, until: min(deadline, driver.now() + 0.15)) else {
                        fail("未能核实原输入框焦点，未启动语音。"); return
                    }
                    capture(target)
                }
            }
        }
        private func mouseUnchanged() -> Bool {
            guard let anchor else { return true }
            guard let current = driver.mouse() else { return false }
            return hypot(current.x - anchor.x, current.y - anchor.y) <= 3
        }
        private func focusHasNotMoved(to target: AXUIElement) -> Bool {
            guard let current = driver.focus(request.pid) else { return initialFocus == nil }
            if driver.equal(current, target) { return true }
            return initialFocus.map { driver.equal(current, $0) } ?? false
        }
        private func poll(_ target: AXUIElement, until end: TimeInterval) -> Bool {
            repeat {
                if exactFocus(target) { return true }
                guard valid(), driver.now() < end else { return false }
                driver.sleep(min(0.01, max(0, end - driver.now())))
            } while true
        }
        private func capture(_ element: AXUIElement) {
            guard exactFocus(element), let original = driver.text(element), exactFocus(element) else {
                fail("无法核验原输入框和正文，未启动语音。"); return
            }
            finish(.success(Prepared(pid: request.pid, element: element, original: original)))
        }
        func fail(_ message: String, reason: String = "state-or-focus-unverified") { finish(.failure(HeadsetVoiceFocusFailure(message: message, reason: reason))) }
        private func finish(_ result: Result<Prepared, HeadsetVoiceFocusFailure>) {
            completionLock.lock()
            guard !finished else { completionLock.unlock(); return }
            finished = true; completionLock.unlock()
            if case .failure = result { request.cancel() }
            DispatchQueue.main.async { [self] in
                var reported = result
                var reason = "prepared"
                if case .success(let prepared) = result, !exactFocus(prepared.element) {
                    request.cancel()
                    reported = .failure(HeadsetVoiceFocusFailure(message: "返回前焦点已变化，未启动语音。", reason: "completion-state-changed"))
                }
                if case .failure(let failure) = reported { reason = failure.reason }
                let scanMs = scanStarted.map { max(0, (scanFinished ?? driver.now()) - $0) * 1000 } ?? 0
                driver.diagnostic(Diagnostic(pid: request.pid, reason: reason, route: route, count: scannedCount,
                    depth: deepest, scanMs: scanMs, pending: pendingCount, areas: areaCount, fields: fieldCount))
                completion(reported)
            }
        }
    }

    static func nativeDriver(pointer: PointerExecutor?, knownAgent: ((pid_t) -> Bool)? = nil) -> Driver {
        let known = knownAgent ?? { pid in
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }), let bundle = app.bundleIdentifier else { return false }
            return AgentAppProfile.resolve(TargetConfig(id: "voice-focus", name: "", bundleID: bundle, path: nil)) != nil
        }
        return Driver(now: { ProcessInfo.processInfo.systemUptime }, sleep: { Thread.sleep(forTimeInterval: $0) },
               unlocked: { !LockScreenInput.locked }, trusted: { AXIsProcessTrusted() },
               focusedPID: { systemFocusedPID() }, window: { focusedWindow($0) }, focus: { focusedElement($0) },
               node: { describe($0, window: $1) }, children: { children($0) }, belongs: { belongs($0, to: $1, pid: $2) },
               equal: { CFEqual($0, $1) }, supportedTextField: known, text: { HeadsetTextValue($0) }, setFocus: {
                   guard AXUIElementSetMessagingTimeout($0, 0.04) == .success else { return false }
                   return AXUIElementSetAttributeValue($0, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
               }, mouse: { CGEvent(source: nil)?.location }, clickPoint: { clickPoint($0, window: $1, pid: $2) },
               click: pointer.map { executor in { point, authorized, done in
                   executor.click(at: point, authorized: authorized, marker: HeadsetMarker, completion: done)
               } }, warmAccessibility: { pid, authorized, deadline in
                   InputFocus.prepareVoiceAccessibility(pid: pid, authorized: authorized, deadline: deadline)
               }, targetedLocator: { pid, window, authorized, deadline in
                   guard known(pid) else { return TargetedResult(candidates: [], complete: true, reason: "unknown-app") }
                   return targetedEditors(pid: pid, window: window, authorized: authorized, deadline: deadline)
               })
    }
    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        guard AXUIElementSetMessagingTimeout(element, 0.04) == .success else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private static func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        guard let window = axElement(attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)), owner(window) == pid else { return nil }
        return window
    }
    private static func systemFocusedPID() -> pid_t? {
        axElement(attribute(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute)).flatMap(owner)
    }
    private static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        guard let element = axElement(attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)), owner(element) == pid else { return nil }
        return element
    }
    private static func owner(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
    private static func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    private static func belongs(_ element: AXUIElement, to window: AXUIElement, pid: pid_t) -> Bool {
        guard owner(element) == pid else { return false }
        if let ownWindow = axElement(attribute(element, kAXWindowAttribute)) { return CFEqual(ownWindow, window) }
        var current = element
        for _ in 0..<64 {
            if CFEqual(current, window) { return true }
            guard let parent = axElement(attribute(current, kAXParentAttribute)), owner(parent) == pid else { return false }
            current = parent
        }
        return false
    }
    private static func describe(_ element: AXUIElement, window: AXUIElement) -> Node? {
        guard AXUIElementSetMessagingTimeout(element, 0.04) == .success else { return nil }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute, "AXHidden", "AXEditable", "AXReadOnly", kAXPositionAttribute, kAXSizeAttribute]
        var copied: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &copied)
        let values: [Any]
        if status == .success, let batch = copied as? [Any], batch.count == names.count { values = batch }
        else if status == .notImplemented { values = names.map { attribute(element, $0) ?? NSNull() } }
        else { return nil }
        guard let role = values[0] as? String else { return nil }
        let subrole = values[1] as? String ?? ""
        var info = Node(role: role, subrole: subrole)
        if (values[3] as? NSNumber)?.boolValue == true { info.visible = false }
        if (values[2] as? NSNumber)?.boolValue == false { info.enabled = false }
        info.readOnly = (values[5] as? NSNumber)?.boolValue == true
        guard ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"].contains(role) || info.excluded else { return info }
        guard !info.excluded else { return info }
        info.enabled = (values[2] as? NSNumber)?.boolValue == true
        if let bounds = frame(position: values[6] as CFTypeRef, size: values[7] as CFTypeRef), let windowBounds = frame(window) {
            info.visible = info.visible && !bounds.intersection(windowBounds).isNull &&
                PointerGeometry.activeDisplayRects().contains { !$0.intersection(bounds).isNull }
        } else { info.visible = false }
        let declaredEditable = (values[4] as? NSNumber)?.boolValue
        let readOnly = (values[5] as? NSNumber)?.boolValue
        info.readOnly = declaredEditable == false || readOnly == true
        info.editable = ordinaryEditor(role: role, declaredEditable: declaredEditable, readOnly: readOnly)
        return info
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        return frame(position: position, size: size)
    }
    private static func frame(position: CFTypeRef, size: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width >= 8, dimensions.height >= 8 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    private static func clickPoint(_ element: AXUIElement, window: AXUIElement, pid: pid_t) -> CGPoint? {
        guard belongs(element, to: window, pid: pid), let bounds = frame(element), let windowBounds = frame(window),
              let resolution = TargetWindowLocator.resolve(pid: pid),
              abs(resolution.rect.minX - windowBounds.minX) <= 2, abs(resolution.rect.minY - windowBounds.minY) <= 2,
              abs(resolution.rect.width - windowBounds.width) <= 4, abs(resolution.rect.height - windowBounds.height) <= 4 else { return nil }
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        guard PointerGeometry.isCursorSettled(at: point, window: resolution.rect, screens: PointerGeometry.activeDisplayRects(), occluders: resolution.occluders),
              let hit = hitElement(point), belongs(hit, to: window, pid: pid), descends(hit, from: element, pid: pid) else { return nil }
        return point
    }
    private static func descends(_ element: AXUIElement, from target: AXUIElement, pid: pid_t) -> Bool {
        var current = element
        for _ in 0..<32 {
            guard owner(current) == pid else { return false }
            if CFEqual(current, target) { return true }
            guard let parent = axElement(attribute(current, kAXParentAttribute)) else { return false }
            current = parent
        }
        return false
    }
    private static func hitElement(_ point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementSetMessagingTimeout(system, 0.04) == .success else { return nil }
        var hit: AXUIElement?
        return AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success ? hit : nil
    }
    /// The supported Agent's visible main-input region, not a claim of whole-window uniqueness.
    /// Every sample is read-only; focusing/clicking is deferred until the ordinary editor is independently verified.
    private static func targetedEditors(pid: pid_t, window: AXUIElement, authorized: @escaping () -> Bool, deadline: TimeInterval) -> TargetedResult {
        guard authorized(), let bounds = frame(window) else { return TargetedResult(candidates: [], complete: false, reason: "targeted-window-unavailable") }
        var points: [CGPoint] = []
        // Cover compact one-line composers as well as expanded input areas.
        // Sparse vertical samples can fall on the toolbar above/below the editor.
        for y in [bounds.maxY - 50, bounds.maxY - 70, bounds.maxY - 90,
                  bounds.maxY - 115, bounds.maxY - 135, bounds.minY + bounds.height * 0.58] {
            for x in [0.4, 0.64, 0.86] {
                let point = CGPoint(x: bounds.minX + bounds.width * x, y: min(bounds.maxY - 8, max(bounds.minY + 8, y)))
                if !points.contains(point) { points.append(point) }
            }
        }
        var result = TargetedResult(candidates: [], complete: true)
        var metadata: [CFHashCode: (AXUIElement, Node?)] = [:]
        var parents: [CFHashCode: (AXUIElement, AXUIElement?)] = [:]
        for (index, point) in points.enumerated() {
            result.pending = points.count - index
            guard ProcessInfo.processInfo.systemUptime < deadline, index % 3 != 0 || authorized() else {
                result.complete = false; result.reason = "targeted-time-or-state"; return result
            }
            guard PointerGeometry.activeDisplayRects().contains(where: { $0.contains(point) }), let hit = hitElement(point), owner(hit) == pid else { continue }
            var current = hit
            var candidate: AXUIElement?
            var path: [Node] = []
            var reachedWindow = false
            for depth in 0..<64 {
                result.depth = max(result.depth, depth)
                guard ProcessInfo.processInfo.systemUptime < deadline else { result.complete = false; result.reason = "targeted-time-limit"; return result }
                guard owner(current) == pid else { break }
                let hash = CFHash(current)
                let info: Node?
                if let cached = metadata[hash], CFEqual(cached.0, current) { info = cached.1 }
                else { info = describe(current, window: window); metadata[hash] = (current, info); result.count += 1 }
                guard let info else {
                    if candidate != nil { result.complete = false; result.reason = "targeted-ancestor-unverified"; return result }
                    break
                }
                path.append(info)
                if !regionPathAllowed(path) { candidate = nil; break }
                if candidate == nil, info.role == "AXTextArea", info.ordinary { candidate = current }
                if CFEqual(current, window) { reachedWindow = true; break }
                let parent: AXUIElement?
                if let cached = parents[hash], CFEqual(cached.0, current) { parent = cached.1 }
                else { parent = axElement(attribute(current, kAXParentAttribute)); parents[hash] = (current, parent) }
                guard let parent else {
                    if candidate != nil { result.complete = false; result.reason = "targeted-ancestor-unverified"; return result }
                    break
                }
                current = parent
            }
            if let candidate {
                guard reachedWindow else { result.complete = false; result.reason = "targeted-depth-limit"; return result }
                if !result.candidates.contains(where: { CFEqual($0, candidate) }) { result.candidates.append(candidate) }
                if result.candidates.count > 1 { result.pending = 0; result.reason = "targeted-ambiguous"; return result }
            }
        }
        result.pending = 0
        if !authorized() { result.complete = false; result.reason = "targeted-state-changed" }
        return result
    }
    static func regionPathAllowed(_ path: [Node]) -> Bool {
        path.allSatisfy { !$0.excluded && !$0.readOnly && $0.enabled && $0.visible }
    }
}
