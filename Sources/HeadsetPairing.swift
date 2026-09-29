import AppKit
import IOKit.hid

final class HeadsetPairing: NSObject, NSWindowDelegate {
    static let shared = HeadsetPairing()
    private(set) var isActive = false
    private var panel: NSPanel?
    private var manager: IOHIDManager?
    private var devices: [HeadsetProfile] = []
    private var selected: HeadsetProfile?
    private var learning = HeadsetLearning()
    private var timer: Timer?
    private var lastProgress = Date()
    private let picker = NSPopUpButton(frame: NSRect(x: 24, y: 225, width: 472, height: 28))
    private let info = NSTextField(wrappingLabelWithString: "")
    private let action = NSButton(title: "开始检测", target: nil, action: nil)
    private let basic = NSButton(title: "跳过长按", target: nil, action: nil)
    private var holdPassed = false
    private var saved = false
    private let refresh = NSButton(title: "刷新设备", target: nil, action: nil)
    @objc func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.panel = panel; panel.title = "PocketDesk · 配置新耳机"; panel.delegate = self
        panel.isReleasedWhenClosed = false
        info.frame = NSRect(x: 24, y: 82, width: 472, height: 125)
        info.font = .systemFont(ofSize: 15)
        action.frame = NSRect(x: 345, y: 22, width: 150, height: 32)
        action.target = self; action.action = #selector(advance)
        basic.frame = NSRect(x: 150, y: 22, width: 180, height: 32)
        basic.target = self; basic.action = #selector(saveBasic); basic.isHidden = true
        refresh.target = self; refresh.action = #selector(scan)
        refresh.frame = NSRect(x: 24, y: 22, width: 110, height: 32)
        for view in [picker, info, action, basic, refresh] { panel.contentView?.addSubview(view) }
        scan(); panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func scan() {
        stop(); selected = nil; learning = HeadsetLearning(); holdPassed = false; saved = false
        refresh.isHidden = false; action.keyEquivalent = ""
        picker.isEnabled = true; action.title = "开始检测"; basic.isHidden = true
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone)); manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: 12] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HeadsetPairing>.fromOpaque(context).takeUnretainedValue().receive(value)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, device in
            guard let context else { return }
            let owner = Unmanaged<HeadsetPairing>.fromOpaque(context).takeUnretainedValue()
            if owner.matches(device) { owner.fail("耳机已断开，本次检测已取消。重新连接后点击刷新设备。") }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        devices = []; picker.removeAllItems()
        if let connected = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> {
            for d in connected {
                let vid = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
                let pid = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
                let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "未命名设备"
                let p = HeadsetProfile(vendorID: vid, productID: pid, name: name, supportsHold: false)
                if p.valid && !devices.contains(where: { $0.vendorID == vid && $0.productID == pid }) { devices.append(p) }
            }
        }
        devices.sort { $0.name < $1.name }
        for p in devices { picker.addItem(withTitle: "\(p.name)（\(p.vendorID):\(p.productID)）") }
        action.isEnabled = !devices.isEmpty && result == kIOReturnSuccess
        info.stringValue = result != kIOReturnSuccess ? "无法监听设备，请检查 PocketDesk 的输入监控权限，然后刷新。" : devices.isEmpty ? "没有检测到可读取按键的设备。请连接耳机后刷新；部分蓝牙或模拟耳机不会向电脑提供独立按键信号。" : "选择耳机后，依次检测中键、加号、减号及长按。列表也可能包含键盘，请确认设备名称。检测时原播放和音量动作可能发生；关闭窗口可取消，不保存配置。"
    }
    @objc private func advance() {
        if saved { panel?.close(); return }
        if learning.stage == .complete { save(hold: true); return }
        guard devices.indices.contains(picker.indexOfSelectedItem) else { return }
        selected = devices[picker.indexOfSelectedItem]; learning = HeadsetLearning(); holdPassed = false
        learning.acceptsPulsedHold = selected?.usesPulsedHold == true
        isActive = true; picker.isEnabled = false; action.isEnabled = false; basic.isHidden = true
        HeadsetController.shared.cancelSession("headset configuration")
        lastProgress = Date(); updatePrompt()
        timer?.invalidate()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.isActive, Date().timeIntervalSince(self.lastProgress) > 20 else { return }
            if self.learning.stage == .hold {
                self.info.stringValue = "还没有检测到完整长按。请再按住减号至少 1 秒，然后松开。\n\n也可以点击“跳过长按”保存：中键语音和发送仍可用，减号保持调音量，不启用长按小精灵。"
                self.basic.isHidden = false
            } else { self.fail("未收到这一按键的完整信号。此设备可能不提供标准媒体按键，或权限未生效。点击刷新可重试；原配置未改动。") }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    private func matches(_ d: IOHIDDevice) -> Bool {
        guard let p = selected else { return false }
        return (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue == p.vendorID && (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue == p.productID
    }
    private func receive(_ value: IOHIDValue) {
        guard isActive else { return }
        let e = IOHIDValueGetElement(value)
        guard matches(IOHIDElementGetDevice(e)), IOHIDElementGetUsagePage(e) == 12 else { return }
        let usage = IOHIDElementGetUsage(e)
        guard learning.receive(usage: usage, down: IOHIDValueGetIntegerValue(value) != 0, time: ProcessInfo.processInfo.systemUptime) else { return }
        lastProgress = Date(); updatePrompt()
    }
    private func updatePrompt() {
        switch learning.stage {
        case .center: info.stringValue = "1 / 4：请轻按一次耳机中键，然后松开。"
        case .plus: info.stringValue = "2 / 4：中键通过。请轻按一次加号，然后松开。"
        case .minus: info.stringValue = "3 / 4：加号通过。请轻按一次减号，然后松开。"
        case .hold: info.stringValue = "4 / 4：请按住减号至少 1 秒，然后松开。\n\n不需要长按小精灵？点击“跳过长按”保存，中键语音和发送仍可用。"; basic.isHidden = false
        case .complete:
            holdPassed = true; timer?.invalidate(); action.isEnabled = true; action.title = "保存并启用"; basic.isHidden = true
            info.stringValue = "检测完成。点击“保存并启用”，即可使用中键语音、双击发送和减号长按小精灵。"
        }
    }
    @objc private func saveBasic() { save(hold: false) }
    private func save(hold: Bool) {
        guard let p = selected, learning.stage == .hold || learning.stage == .complete, !hold || holdPassed else { return }
        do {
            try HeadsetProfiles.shared.save(HeadsetProfile(vendorID: p.vendorID, productID: p.productID, name: p.name, supportsHold: hold))
            stop(); saved = true; picker.isEnabled = false; basic.isHidden = true
            refresh.isHidden = true; action.isEnabled = true; action.title = "完成"; action.keyEquivalent = "\r"
            info.stringValue = "\(p.name) 已配置好。\n\n\(hold ? "中键开始语音，双击发送；长按减号唤起小精灵。" : "中键开始语音，双击发送。已跳过长按，减号保持调音量。")\n\n点击“完成”关闭窗口，稍等约 1 秒就可以试用了。下次连接自动生效。"
        } catch { info.stringValue = "保存失败：\(error.localizedDescription)。原配置保留，可重试。" }
    }
    private func fail(_ text: String) { stop(); info.stringValue = text; basic.isHidden = true; action.isEnabled = false }
    private func stop() {
        isActive = false; timer?.invalidate(); timer = nil
        if let manager { IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue); IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        manager = nil
    }
    func windowWillClose(_ notification: Notification) { stop(); panel = nil }
}
