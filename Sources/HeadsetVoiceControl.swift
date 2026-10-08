import AppKit
import ApplicationServices
import IOKit.hid
import IOKit.hidsystem

let HeadsetSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoiceDeck/headset")
let HeadsetMarker: Int64 = 0x48564331
let HeadsetLogLock = NSLock()
private let HeadsetLogQueue = DispatchQueue(label: "dev.voicedeck.headset.log", qos: .utility)
func HeadsetLog(_ message: String) {
    let recordedAt = Date()
    // Logging must not hold up a hardware notification or the Option event.
    HeadsetLogQueue.async {
        HeadsetLogLock.lock(); defer { HeadsetLogLock.unlock() }
        let line = "\(ISO8601DateFormatter().string(from: recordedAt)) \(message)\n"
        let path = HeadsetSupport.appendingPathComponent("status.log")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    }
}
func HeadsetAttr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func HeadsetFocused() -> (pid_t, AXUIElement)? {
    guard let pid = InputFocus.focusedApplicationPID() else { return nil }
    let root = AXUIElementCreateApplication(pid)
    let value = HeadsetAttr(root, kAXFocusedUIElementAttribute)
        ?? HeadsetAttr(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let element = unsafeBitCast(value, to: AXUIElement.self)
    var owner: pid_t = 0
    guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { return nil }
    return (pid, element)
}
func HeadsetTextRoleAllowed(_ values: [Any]) -> Bool {
    guard values.count == 2, let role = values[0] as? String,
          [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) else { return false }
    // Missing/unsupported subrole keeps the existing ordinary-field behavior.
    return values[1] as? String != kAXSecureTextFieldSubrole
}
func HeadsetTextValue(_ element: AXUIElement) -> String? {
    var values: CFArray?
    let result = AXUIElementCopyMultipleAttributeValues(element,
        [kAXRoleAttribute, kAXSubroleAttribute] as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
    if result == .notImplemented {
        guard let role = HeadsetAttr(element, kAXRoleAttribute) as? String,
              [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role),
              (HeadsetAttr(element, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else { return nil }
    } else {
        guard result == .success, let values = values as? [Any], HeadsetTextRoleAllowed(values) else { return nil }
    }
    // Read the value only after confirming this is not a secure field.
    return HeadsetAttr(element, kAXValueAttribute) as? String
}

// Text is held only in memory. Logs contain state names, never dictated content.
final class HeadsetVoiceSession {
    let pid: pid_t
    let element: AXUIElement
    let original: String
    var latest: String
    let started = Date()
    var stableSince = Date()
    var sawPanel = false
    var panelGoneAt: Date?
    var immediate = false
    var manualSend = false
    var fromClickControl = false
    var awaitingClickEnd = false
    var optionPostedAt: Double?
    var firstTextObserved = false
    init(pid: pid_t, element: AXUIElement, text: String) {
        self.pid = pid; self.element = element; original = text; latest = text
    }
}

final class HeadsetController: NSObject {
    static let shared = HeadsetController()
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var timer: Timer?
    var session: HeadsetVoiceSession?
    let headset = HeadsetCenterObserver()
    
    var lastSent = Date.distantPast
    var active = false
    var hidReady = false
    var lastPanelVisible = false
    var cycleDraft: HeadsetVoiceSession?
    var voicePointer: PointerExecutor?
    private var voicePreparation: HeadsetVoiceFocusRequest?
    private var voicePreparationCompletion: ((Bool) -> Void)?
    var preparingClickVoice: Bool { voicePreparation != nil }
    let defaults = UserDefaults(suiteName: "dev.voicedeck.headset")!
    var autoSend: Bool { defaults.object(forKey: "autoSend") as? Bool ?? true }
    var delay: Double { let n = defaults.double(forKey: "delay"); return n >= 0.5 ? n : 2 }
    var statusText = "等待辅助功能权限"

    func start() {
        try? FileManager.default.createDirectory(at: HeadsetSupport, withIntermediateDirectories: true)
        if !defaults.bool(forKey: "migrated") {
            let old = UserDefaults(suiteName: "local.cm.HeadsetVoiceControl")
            defaults.set(old?.object(forKey: "autoSend") as? Bool ?? true, forKey: "autoSend")
            defaults.set(old?.object(forKey: "delay") as? Double ?? 2, forKey: "delay")
            defaults.set(true, forKey: "migrated")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        HeadsetLog("PocketDesk headset started; native Option mapping is never modified; autoSend=\(autoSend) delay=\(delay) maxRecording=\(Int(HeadsetVoiceTiming.maxRecordingSeconds)) sendSessionTimeout=\(Int(HeadsetVoiceTiming.maxSendSessionSeconds))")
        headset.onFirstPress = { [weak self] in self?.firstNativePress() }
        headset.onDoubleRelease = { [weak self] in self?.doubleClick() }
        headset.onReady = { [weak self] ready in
            self?.hidReady = ready
            self?.setStatus(ready ? "就绪 · 单击保持系统直连" : "耳机监听未就绪；单击保持原样")
        }
        // Existing PocketDesk grants are reused; no automatic permission prompts.
    }
    func applicationWillTerminate(_ notification: Notification) { HeadsetLog("v2 quit; native Option mapping unchanged") }
    func settingsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "耳机设置…", action: #selector(HeadsetSettings.show), keyEquivalent: "")
        item.target = HeadsetSettings.shared
        return item
    }

    func setStatus(_ value: String) {
        guard value != statusText else { return }
        statusText = value
        if !value.contains("秒后发送") { HeadsetLog("state: \(value)") }
    }
    @objc func toggleAuto() { defaults.set(!autoSend, forKey: "autoSend"); cancelSession("auto setting changed") }
    @objc func setDelay(_ sender: NSMenuItem) { defaults.set(sender.tag, forKey: "delay"); cancelSession("delay changed") }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
    @objc func showSetup() {
        let alert = NSAlert()
        alert.messageText = "PocketDesk · 耳机权限"
        alert.informativeText = "在系统设置 → 隐私与安全性中为 PocketDesk 开启辅助功能和输入监控。\n\n有线耳机沿用原有按键配置。启用单击控制的耳机通过音量增减切换语音：音量加用于普通输入，音量减用于小精灵。\n\n设置按设备保存；关闭设置窗口、Esc 取消本次语音均不会关闭功能。其他程序改变音量仍可能被误识别。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
    func installTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, ref in
                let c = Unmanaged<HeadsetController>.fromOpaque(ref!).takeUnretainedValue()
                return c.handle(type, event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            setStatus("无法监听按键，请检查辅助功能权限"); return
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        active = true; HeadsetLog("event tap ready")
    }
    func emit(_ key: CGKeyCode) {
        precondition(key == 36, "Only Enter can be synthesized; native Option is never altered")
        let src = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource:src,virtualKey:key,keyDown:true),
              let up = CGEvent(keyboardEventSource:src,virtualKey:key,keyDown:false) else { return }
        down.flags = []; up.flags = []
        down.setIntegerValueField(.eventSourceUserData,value:HeadsetMarker)
        up.setIntegerValueField(.eventSourceUserData,value:HeadsetMarker)
        down.post(tap:.cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.035) { up.post(tap:.cghidEventTap) }
    }
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap:tap,enable:true) }
            cancelSession("event tap interrupted"); return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == HeadsetMarker { return Unmanaged.passUnretained(event) }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if session != nil || voicePreparation != nil {
            let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
            if type == .leftMouseDown || type == .rightMouseDown ||
               (type == .keyDown && (key == 53 || key == 36 || pid <= 0)) ||
               (type == .flagsChanged && pid <= 0 && key != 58) { cancelSession("manual input") }
        }
        return Unmanaged.passUnretained(event)
    }
    func panelVisible() -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.bytedance.inputmethod.doubaoime").map { $0.processIdentifier })
        guard !pids.isEmpty,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] else { return false }
        return windows.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let layer = w[kCGWindowLayer as String] as? Int, layer >= 0, layer < 25,
                  let b = w[kCGWindowBounds as String] as? [String:Any],
                  let width = b["Width"] as? Double, let height = b["Height"] as? Double,
                  let alpha = w[kCGWindowAlpha as String] as? Double else { return false }
            return width >= 80 && height >= 25 && alpha > 0
        }
    }
    func sameTarget(_ s: HeadsetVoiceSession) -> Bool {
        guard let (pid,element) = HeadsetFocused() else { return false }
        return pid == s.pid && CFEqual(element,s.element)
    }
    func firstNativePress() {
        // Native Option has already passed through the system mapping. Never
        // move its receiver after recording has started.
        if voicePreparation != nil { cancelSession("native input during voice preparation") }
        guard !LockScreenInput.locked, !HeadsetPairing.shared.isActive, !HeadsetMappingRuntime.shared.learning else { cancelSession("locked or learning"); return }
        cycleDraft = nil
        if let (pid,element) = HeadsetFocused(), let text = HeadsetTextValue(element) {
            cycleDraft = HeadsetVoiceSession(pid:pid,element:element,text:text)
            if session == nil { session = cycleDraft; HeadsetLog("native voice session armed") }
        }
        setStatus(session == nil ? "单击原样通过；此输入框无法自动发送" : "等待豆包语音完成")
    }
    func prepareClickVoice(completion: @escaping (Bool) -> Void) {
        cancelSession("new click voice preparation")
        cycleDraft = nil
        guard !LockScreenInput.locked, AXIsProcessTrusted(), !HeadsetPairing.shared.isActive,
              !HeadsetMappingRuntime.shared.learning,
              let pid = InputFocus.focusedApplicationPID(), pid != getpid() else {
            setStatus("请先切到要输入的应用，再唤醒语音"); completion(false); return
        }
        let request = HeadsetVoiceFocusRequest(pid: pid)
        voicePreparation = request
        voicePreparationCompletion = completion
        let beganAt = ProcessInfo.processInfo.systemUptime
        setStatus("正在定位当前输入框…")
        HeadsetVoiceFocus.prepare(request: request, pointer: voicePointer) { [weak self] result in
            guard let self, self.voicePreparation === request else { return }
            self.voicePreparation = nil
            self.voicePreparationCompletion = nil
            switch result {
            case .success(let prepared):
                guard request.active, !LockScreenInput.locked, AXIsProcessTrusted(), !HeadsetPairing.shared.isActive,
                      !HeadsetMappingRuntime.shared.learning,
                      InputFocus.focusedApplicationPID() == prepared.pid,
                      let focused = InputFocus.focusedElement(pid: prepared.pid), CFEqual(focused, prepared.element),
                      HeadsetTextValue(focused) == prepared.original else {
                    request.cancel(); self.setStatus("输入位置已变化，请重新唤醒语音"); completion(false); return
                }
                let session = HeadsetVoiceSession(pid: prepared.pid, element: prepared.element, text: prepared.original)
                session.fromClickControl = true; session.awaitingClickEnd = true
                self.session = session
                HeadsetLog(String(format: "click startup: input focus prepared %.0f ms; pid=%d", (ProcessInfo.processInfo.systemUptime - beganAt) * 1000, prepared.pid))
                completion(true)
            case .failure(let error):
                self.setStatus(error.message)
                HeadsetLog("click startup: input focus unavailable; no voice shortcut sent")
                completion(false)
            }
        }
    }
    func clickVoiceOptionPosted(at time: Double) {
        guard let session, session.fromClickControl else { return }
        session.optionPostedAt = time
    }
    var clickVoiceText: String? {
        guard let session, session.fromClickControl, session.awaitingClickEnd else { return nil }
        return session.latest
    }
    func endClickVoice() {
        guard let session, session.fromClickControl else { return }
        session.awaitingClickEnd = false
        session.stableSince = Date()
        session.panelGoneAt = nil
        HeadsetLog("click voice ended; awaiting transcription and send delay")
    }
    func cancelClickVoice() {
        if voicePreparation != nil || session?.fromClickControl == true { cancelSession("click voice cancelled") }
    }
    func doubleClick() {
        guard !LockScreenInput.locked, !HeadsetPairing.shared.isActive, !HeadsetMappingRuntime.shared.learning else { cancelSession("locked or learning"); return }
        guard Date().timeIntervalSince(lastSent) > 1.5 else { HeadsetLog("duplicate send suppressed"); return }
        HeadsetLog("double click received directly from headset")
        guard let (pid,element) = HeadsetFocused(), let text = HeadsetTextValue(element) else {
            cancelSession("double click target unreadable"); return
        }
        let pending = HeadsetVoiceSession(pid:pid,element:element,text:text)
        pending.immediate = true; pending.manualSend = true
        pending.sawPanel = panelVisible()
        pending.panelGoneAt = pending.sawPanel ? nil : Date()
        session = pending
        setStatus(pending.sawPanel ? "双击：等待转写结束后发送" : "双击：准备发送")
    }
    func cancelSession(_ reason: String) {
        if session != nil || voicePreparation != nil { HeadsetLog("cancelled: \(reason)") }
        voicePreparation?.cancel(); voicePreparation = nil
        let pendingCompletion = voicePreparationCompletion
        voicePreparationCompletion = nil
        session = nil; setStatus(active ? "就绪" : "等待辅助功能权限")
        // Notify the owner after clearing the request. Its generation guard
        // rejects an obsolete callback without cancelling a newer recording.
        pendingCompletion?(false)
    }
    func tick() {
        guard !LockScreenInput.locked, !HeadsetPairing.shared.isActive, !HeadsetMappingRuntime.shared.learning else { cancelSession("locked or learning"); return }
        guard AXIsProcessTrusted() else { session = nil; setStatus("等待辅助功能权限；单击仍可用"); return }
        if tap == nil { installTap() }
        guard active else { return }
        if !headset.started {
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted { headset.start() }
            else { setStatus("等待输入监控权限；单击仍可用"); return }
        }
        guard let s = session else { return }
        if Date().timeIntervalSince(s.started) > HeadsetVoiceTiming.maxSendSessionSeconds {
            cancelSession("session timeout after \(Int(HeadsetVoiceTiming.maxSendSessionSeconds)) seconds"); return
        }
        guard sameTarget(s) else { cancelSession("focus changed"); return }
        lastPanelVisible = panelVisible()
        let visible = lastPanelVisible
        if visible {
            if !s.sawPanel, let postedAt = s.optionPostedAt {
                HeadsetLog(String(format: "click startup: dictation visible %.0f ms after Option; route=input", (ProcessInfo.processInfo.systemUptime - postedAt) * 1000))
            }
            s.sawPanel = true; s.panelGoneAt = nil
        }
        else if (s.sawPanel || s.manualSend) && s.panelGoneAt == nil { s.panelGoneAt = Date(); HeadsetLog("voice panel closed") }
        guard let value = HeadsetTextValue(s.element) else { cancelSession("text unreadable"); return }
        if value != s.latest {
            s.latest = value; s.stableSince = Date(); HeadsetLog("target text changed")
            if !s.firstTextObserved, let postedAt = s.optionPostedAt, value != s.original,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                s.firstTextObserved = true
                HeadsetLog(String(format: "click startup: first text observed %.0f ms after Option; route=input", (ProcessInfo.processInfo.systemUptime - postedAt) * 1000))
            }
        }
        guard autoSend || s.immediate else { return }
        let wait = s.immediate ? 0.4 : delay
        let stableFor = Date().timeIntervalSince(s.stableSince)
        let closedFor = s.panelGoneAt.map { Date().timeIntervalSince($0) } ?? -1
        let changed = s.manualSend || value != s.original
        let ready = HeadsetSendGate.ready(sameFocus:true,panelObserved:s.sawPanel || s.manualSend,panelVisible:visible,
            textChanged:changed,nonempty:!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, recordingEnded:!s.awaitingClickEnd,
            stableFor:stableFor,closedFor:closedFor,delay:wait)
        if !ready {
            if !s.awaitingClickEnd && (s.sawPanel || s.manualSend) && !visible && changed { setStatus("\(String(format:"%.1f",max(0,wait-min(stableFor,closedFor)))) 秒后发送 · Esc 取消") }
            return
        }
        guard sameTarget(s), HeadsetTextValue(s.element) == value else { cancelSession("target changed before send"); return }
        session = nil; cycleDraft = nil; lastSent = Date()
        emit(36); setStatus("已按 Enter"); HeadsetLog("voice Enter sent")
    }

}
