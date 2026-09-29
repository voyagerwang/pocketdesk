import AppKit
import ApplicationServices
import IOKit.hid
import IOKit.hidsystem

let HeadsetSupport = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoiceDeck/headset")
let HeadsetMarker: Int64 = 0x48564331
let HeadsetLogLock = NSLock()
func HeadsetLog(_ message: String) {
    HeadsetLogLock.lock(); defer { HeadsetLogLock.unlock() }
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let path = HeadsetSupport.appendingPathComponent("status.log")
    if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
    if let h = try? FileHandle(forWritingTo: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
}
func HeadsetAttr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}
func HeadsetFocused() -> (pid_t, AXUIElement)? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let v = HeadsetAttr(root, kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (app.processIdentifier, unsafeBitCast(v, to: AXUIElement.self))
}
func HeadsetTextValue(_ element: AXUIElement) -> String? {
    guard let role = HeadsetAttr(element, kAXRoleAttribute) as? String,
          [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role),
          (HeadsetAttr(element, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else { return nil }
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
    init(pid: pid_t, element: AXUIElement, text: String) {
        self.pid = pid; self.element = element; original = text; latest = text
    }
}

final class HeadsetController: NSObject, NSMenuDelegate {
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
        HeadsetLog("PocketDesk headset started; native Option mapping is never modified; autoSend=\(autoSend) delay=\(delay)")
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
        let item = NSMenuItem(title: "耳机语音", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "耳机语音")
        menu.delegate = self
        menuNeedsUpdate(menu)
        item.submenu = menu
        return item
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let configure = NSMenuItem(title: "配置新耳机…", action: #selector(HeadsetPairing.show), keyEquivalent: "")
        configure.target = HeadsetPairing.shared; menu.addItem(configure)
        for profile in HeadsetProfiles.shared.all {
            menu.addItem(NSMenuItem(title: "已配置：\(profile.name) · \(profile.supportsHold ? "支持长按" : "基础按键")", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        let label = NSMenuItem(title: "耳机语音 · \(statusText)", action: nil, keyEquivalent: "")
        label.isEnabled = false; menu.addItem(label)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "单击：左 Option；双击：Enter", action: nil, keyEquivalent: ""))
        let auto = NSMenuItem(title: "语音结束后自动发送", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self; auto.state = autoSend ? .on : .off; menu.addItem(auto)
        let times = NSMenuItem(title: "自动发送等待：\(Int(delay)) 秒", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for n in [1,2,3,5,10] {
            let item = NSMenuItem(title: "\(n) 秒", action: #selector(setDelay(_:)), keyEquivalent: "")
            item.target = self; item.tag = n; item.state = Int(delay) == n ? .on : .off; sub.addItem(item)
        }
        times.submenu = sub; menu.addItem(times)
        let cancel = NSMenuItem(title: "取消本次待发送（也可按 Esc）", action: #selector(cancelAction), keyEquivalent: "")
        cancel.target = self; menu.addItem(cancel)
        menu.addItem(NSMenuItem.separator())
        let setup = NSMenuItem(title: "权限与使用说明…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self; menu.addItem(setup)
        
    }
    func setStatus(_ value: String) {
        guard value != statusText else { return }
        statusText = value
        if !value.contains("秒后发送") { HeadsetLog("state: \(value)") }
    }
    @objc func toggleAuto() { defaults.set(!autoSend, forKey: "autoSend"); cancelSession("auto setting changed") }
    @objc func setDelay(_ sender: NSMenuItem) { defaults.set(sender.tag, forKey: "delay"); cancelSession("delay changed") }
    @objc func cancelAction() { cancelSession("user cancelled") }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
    @objc func showSetup() {
        let alert = NSAlert()
        alert.messageText = "PocketDesk · 耳机语音"
        alert.informativeText = "单击耳机中键保留系统原生左 Option。快速轻点两次：在当前文字输入框按 Enter。\n\n自动发送默认等待 2 秒：仅在耳机开启语音后、豆包浮窗出现并关闭、原输入框文字已改变且稳定时触发。继续编辑、点击鼠标、切换窗口或按 Esc 会取消。界面无法识别时不会自动发送。\n\n请在系统设置 → 隐私与安全性 → 辅助功能中启用 PocketDesk。单击始终使用原来的系统映射。双击需要辅助功能和输入监控权限，以确认信号来自耳机。"
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
        if session != nil {
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
        guard !LockScreenInput.locked, !HeadsetPairing.shared.isActive else { cancelSession("locked"); return }
        cycleDraft = nil
        if let (pid,element) = HeadsetFocused(), let text = HeadsetTextValue(element) {
            cycleDraft = HeadsetVoiceSession(pid:pid,element:element,text:text)
            if session == nil { session = cycleDraft; HeadsetLog("native voice session armed") }
        }
        setStatus(session == nil ? "单击原样通过；此输入框无法自动发送" : "等待豆包语音完成")
    }
    func doubleClick() {
        guard !LockScreenInput.locked, !HeadsetPairing.shared.isActive else { cancelSession("locked"); return }
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
        if session != nil { HeadsetLog("cancelled: \(reason)") }
        session = nil; setStatus(active ? "就绪" : "等待辅助功能权限")
    }
    func tick() {
        guard !LockScreenInput.locked, !HeadsetPairing.shared.isActive else { cancelSession("locked"); return }
        guard AXIsProcessTrusted() else { session = nil; setStatus("等待辅助功能权限；单击仍可用"); return }
        if tap == nil { installTap() }
        guard active else { return }
        if !headset.started {
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted { headset.start() }
            else { setStatus("等待输入监控权限；单击仍可用"); return }
        }
        lastPanelVisible = panelVisible()
        guard let s = session else { return }
        if Date().timeIntervalSince(s.started) > 180 { cancelSession("session timeout"); return }
        guard sameTarget(s) else { cancelSession("focus changed"); return }
        let visible = lastPanelVisible
        if visible { s.sawPanel = true; s.panelGoneAt = nil }
        else if (s.sawPanel || s.manualSend) && s.panelGoneAt == nil { s.panelGoneAt = Date(); HeadsetLog("voice panel closed") }
        guard let value = HeadsetTextValue(s.element) else { cancelSession("text unreadable"); return }
        if value != s.latest { s.latest = value; s.stableSince = Date(); HeadsetLog("target text changed") }
        guard autoSend || s.immediate else { return }
        let wait = s.immediate ? 0.4 : delay
        let stableFor = Date().timeIntervalSince(s.stableSince)
        let closedFor = s.panelGoneAt.map { Date().timeIntervalSince($0) } ?? -1
        let changed = s.manualSend || value != s.original
        let ready = HeadsetSendGate.ready(sameFocus:true,panelObserved:s.sawPanel || s.manualSend,panelVisible:visible,
            textChanged:changed,nonempty:!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
            stableFor:stableFor,closedFor:closedFor,delay:wait)
        if !ready {
            if (s.sawPanel || s.manualSend) && !visible && changed { setStatus("\(String(format:"%.1f",max(0,wait-min(stableFor,closedFor)))) 秒后发送 · Esc 取消") }
            return
        }
        guard sameTarget(s), HeadsetTextValue(s.element) == value else { cancelSession("target changed before send"); return }
        session = nil; cycleDraft = nil; lastSent = Date()
        emit(36); setStatus("已按 Enter"); HeadsetLog("voice Enter sent")
    }

}
