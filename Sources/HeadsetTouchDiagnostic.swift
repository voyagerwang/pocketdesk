import AppKit
import ApplicationServices
import IOKit.hid
import CoreAudio
import AudioToolbox

/// User-started, bounded observation inside PocketDesk's existing permission identity.
/// No key injection, audio capture, remote command registration or text logging.
final class HeadsetTouchDiagnostic: NSObject, NSWindowDelegate {
    static let shared = HeadsetTouchDiagnostic()
    private var window: NSWindow?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let output = NSTextView()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var manager: IOHIDManager?
    private var timer: Timer?
    private var deadline: Date?
    var isActive: Bool { deadline != nil }
    private var side = ""
    private var count = 0
    private var lastAudio = ""
    private var lines: [String] = []
    private let logURL = HeadsetSupport.appendingPathComponent("touch-diagnostic.log")

    @objc func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 430),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window = w; w.title = "PocketDesk · 蓝牙耳机触控检测"; w.delegate = self; w.isReleasedWhenClosed = false
        status.frame = NSRect(x: 20, y: 332, width: 620, height: 76)
        status.stringValue = "选择一侧开始检测，再按住对应耳机约 3 秒后松开，重复两次。\n检测期间不要按电脑音量键。只观察信号，不录音、不模拟按键、不提交。"
        w.contentView?.addSubview(status)
        for (index, title) in ["检测右耳", "检测左耳", "停止检测"].enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(action(_:)))
            b.tag = index; b.frame = NSRect(x: 20 + index * 150, y: 285, width: 140, height: 32)
            w.contentView?.addSubview(b)
        }
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 620, height: 250))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        output.isEditable = false; output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.autoresizingMask = [.width]; output.isVerticallyResizable = true
        output.frame = NSRect(origin: .zero, size: scroll.contentSize)
        output.textContainer?.widthTracksTextView = true
        scroll.documentView = output; w.contentView?.addSubview(scroll)
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func action(_ button: NSButton) {
        if button.tag == 2 { stop(); status.stringValue = "检测已停止。"; return }
        start(side: button.tag == 0 ? "右耳" : "左耳")
    }
    private func record(_ message: String, event: Bool = false) {
        if event { count += 1 }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(side)] \(message)"
        lines.append(line); if lines.count > 250 { lines.removeFirst() }
        output.string = lines.joined(separator: "\n")
        output.scrollToEndOfDocument(nil)
        try? FileManager.default.createDirectory(at: HeadsetSupport, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: logURL) { file.seekToEndOfFile(); file.write(Data((line + "\n").utf8)); try? file.close() }
    }
    private func start(side: String) {
        HeadsetClickControl.shared.cancelCurrent()
        stop(); self.side = side; count = 0
        HeadsetController.shared.cancelSession("touch diagnostic")
        guard CGPreflightListenEventAccess() || AXIsProcessTrusted() else {
            status.stringValue = "PocketDesk 尚无可用的输入监听权限。请检查系统设置中的 PocketDesk；检测不会自动申请权限。"
            record("未启动：输入监听权限不可用"); return
        }
        record("开始；只记录 Consumer HID / 系统媒体按键 / 默认音频设备及音量")
        let ref = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                               eventsOfInterest: CGEventMask(1) << 14, callback: { _, type, event, ref in
            guard let ref else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<HeadsetTouchDiagnostic>.fromOpaque(ref).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.record("媒体监听中断，当前检测无效"); owner.stop()
            } else if type.rawValue == 14, let e = NSEvent(cgEvent: event), e.subtype.rawValue == 8 {
                owner.record("MEDIA subtype=\(e.subtype.rawValue) key=\((e.data1 >> 16) & 0xffff) state=\((e.data1 >> 8) & 0xff) repeat=\(e.data1 & 0xff)", event: true)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: ref)
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0); manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: 12] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, { ref, _, _, value in
            guard let ref else { return }
            let owner = Unmanaged<HeadsetTouchDiagnostic>.fromOpaque(ref).takeUnretainedValue()
            let e = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(e) == 12 else { return }
            let d = IOHIDElementGetDevice(e)
            let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "未知"
            let vid = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? NSNumber ?? 0
            let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? NSNumber ?? 0
            owner.record("HID \(name) \(vid):\(pid) usage=\(IOHIDElementGetUsage(e)) value=\(IOHIDValueGetIntegerValue(value))", event: true)
        }, ref)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, 0)
        record("监听状态 mediaTap=\(tap != nil) hidOpen=\(result)")
        lastAudio = audioState(); record(lastAudio)
        deadline = Date().addingTimeInterval(60)
        timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        tick()
    }
    private func tick() {
        guard let deadline else { return }
        if LockScreenInput.locked { stop(); status.stringValue = "电脑已锁定，检测停止。"; return }
        let audio = audioState()
        if audio != lastAudio { lastAudio = audio; record(audio) }
        let remaining = Int(ceil(deadline.timeIntervalSinceNow))
        if remaining <= 0 {
            record("结束：观察到 \(count) 条按键事件；事件数量不代表长按兼容性")
            stop(); status.stringValue = count == 0 ? "检测已结束：当前监听通道没有收到按键信号，尚不能建立长按映射。音频连接正常不代表触控信号会传给电脑。" : "本轮检测结束。需要核对事件是否来自耳机、是否包含对应按下和松开；此时尚未启用语音映射。"
        } else {
            status.stringValue = "正在检测\(side)（剩余 \(remaining) 秒）\n请按住\(side) 3 秒后松开，重复两次。\(count == 0 ? "尚未收到按键信号" : "收到 \(count) 条按键事件")。只检测，不触发语音。"
        }
    }
    private func audioState() -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0); var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return "AUDIO 不可用" }
        address.mSelector = kAudioObjectPropertyName
        var rawName: Unmanaged<CFString>?
        size = UInt32(MemoryLayout.size(ofValue: rawName))
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rawName)
        let name = rawName?.takeRetainedValue() as String? ?? "未知"
        address.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume; address.mScope = kAudioDevicePropertyScopeOutput
        var volume: Float32 = 0; size = UInt32(MemoryLayout<Float32>.size)
        let result = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return "AUDIO \(name) device=\(device) volume=\(result == noErr ? String(format: "%.3f", volume) : "不可读")"
    }
    private func stop() {
        timer?.invalidate(); timer = nil; deadline = nil
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, 0)
        }
        manager = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; source = nil
        if let tap { CFMachPortInvalidate(tap) }; tap = nil
    }
    func windowWillClose(_ notification: Notification) { stop(); window = nil }
}
