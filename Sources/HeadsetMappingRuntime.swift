/** [INPUT]: IOHID 原始事件、音量桥和规则存储。[OUTPUT]: 检测反馈、规则派发、短租约和取消。[POS]: 单一自定义映射入口；检测不执行动作。[PROTOCOL]: 同步 Sources/CLAUDE.md。 */
import AppKit
import IOKit.hid
import ApplicationServices

final class HeadsetMappingRuntime: NSObject {
    static let shared = HeadsetMappingRuntime()
    private var manager: IOHIDManager?
    private var timer: Timer?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var machines: [String: HeadsetGesture] = [:]
    private var signals: [String: HeadsetSignal] = [:]
    private var boundRules: [String: HeadsetRule] = [:]
    private var pulses: [String: HeadsetPulse] = [:]
    private var pulseSignals: [String: HeadsetSignal] = [:]
    private var downTimes: [String: Double] = [:]
    private var learningUntil: Date?
    private var selected: HeadsetSignal?
    private var wanted: HeadsetRule.Gesture?
    private var learner = HeadsetOperationLearning()
    var learnedOperation: ((HeadsetLearnedOperation) -> Void)?
    private var candidate: HeadsetSignal?
    private var repeats = 0
    private var lastTap: Double?
    private var volumeBaseline: Float?
    private var volumeUID: String?
    var feedback: ((String, HeadsetSignal?) -> Void)?
    var statusChanged: ((String) -> Void)?
    private(set) var status = "就绪"
    private let lease = HeadsetSupport.appendingPathComponent("operation-lease.json")
    private let health = HeadsetSupport.appendingPathComponent("operation-health.json")
    var learning: Bool { learningUntil != nil }
    private var frontBundle: String? {
        guard let pid = InputFocus.focusedApplicationPID() else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }?.bundleIdentifier
    }
    func report(_ value: String) { status = value; statusChanged?(value) }
    func start() {
        guard timer == nil else { return }
        HeadsetRuleStore.shared.changed = { [weak self] in self?.cancel(); self?.publishLease() }
        HeadsetMappingActions.shared.message = { [weak self] in self?.report($0) }
        timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        NotificationCenter.default.addObserver(self, selector: #selector(stop), name: NSApplication.willTerminateNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(interrupted), name: .init("com.apple.screenIsLocked"), object: nil)
    }
    private func startHID() {
        guard manager == nil, Date() >= retryHIDAt, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else { return }
        retryHIDAt = Date().addingTimeInterval(3)
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey:12] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, { ref, _, _, value in
            guard let ref else { return }
            let owner = Unmanaged<HeadsetMappingRuntime>.fromOpaque(ref).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == 12 else { return }
            let d = IOHIDElementGetDevice(element)
            guard var signal = owner.describe(d) else { return }
            signal.usage = Int(IOHIDElementGetUsage(element))
            owner.receive(signal, down: IOHIDValueGetIntegerValue(value) != 0)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ref, _, _, device in
            guard let ref else { return }
            let owner = Unmanaged<HeadsetMappingRuntime>.fromOpaque(ref).takeUnretainedValue()
            if let removed = owner.describe(device), owner.signals.values.contains(where: { $0.device == removed.device }) || owner.selected?.device == removed.device { owner.cancel(); owner.stopLearning(); owner.report("设备断开，本次操作已取消") }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if IOHIDManagerOpen(m, 0) == kIOReturnSuccess { manager = m }
        else { IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) }
    }
    private func describe(_ d: IOHIDDevice) -> HeadsetSignal? {
        let v = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
        let p = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
        guard v > 0, p > 0 else { return nil }
        let serial = IOHIDDeviceGetProperty(d, kIOHIDSerialNumberKey as CFString) as? String ?? "model"
        let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "按键设备"
        return .init(kind: .hid, device: "\(v):\(p):\(serial)", name: name, vendor: v, product: p, usage: 0)
    }
    func devices() -> [HeadsetSignal] {
        startHID()
        var list = [HeadsetSignal]()
        if let manager, let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            list = devices.compactMap(describe).sorted { $0.name < $1.name }
        }
        if let audio = HeadsetAudio.current(), audio.volume != nil { list.insert(.init(kind: .volume, device: audio.uid, name: audio.name, usage: 1), at: 0) }
        return list.reduce(into: []) { result, item in if !result.contains(where: { $0.device == item.device && $0.kind == item.kind }) { result.append(item) } }
    }
    func beginLearning(device: HeadsetSignal, gesture: HeadsetRule.Gesture? = nil) {
        stopLearning(); cancel(); HeadsetClickControl.shared.cancelCurrent(); HeadsetController.shared.cancelSession("operation learning")
        if let gesture, !HeadsetOperationLearning.supports(gesture, device: device) {
            feedback?("这个信号不支持所选操作，请选择直接录制或单击。", nil); return
        }
        selected = device; wanted = gesture; learner = HeadsetOperationLearning(expected: gesture)
        volumeBaseline = HeadsetAudio.current()?.volume; volumeUID = HeadsetAudio.current()?.uid
        learningUntil = Date().addingTimeInterval(30)
        feedback?(gesture.map { "请操作一次\($0.label)，等待识别结果。" } ?? "请操作耳机，系统会识别收到的信号。", nil)
    }
    func stopLearning() { learningUntil = nil; downTimes = [:]; selected = nil; lastTap = nil; pulses = [:]; pulseSignals = [:]; learner = HeadsetOperationLearning() }
    private func learningFeedback(_ update: HeadsetOperationLearning.Update) {
        switch update {
        case .pressed: feedback?("已收到按下，等待松开…", nil)
        case .holding: feedback?("检测到长按，松开后完成识别。", nil)
        case .mismatch(let actual): feedback?("收到的是\(actual.label)，与所选操作不同。请重新操作，或选择直接录制。", nil)
        case .recognized(let operation):
            stopLearning(); feedback?("已识别：\(operation.title)。请选择要执行的动作。", operation.signal)
            learnedOperation?(operation)
        }
    }
    private func receive(_ signal: HeadsetSignal, down: Bool) {
        if signal.vendor == 31 && signal.product == 2849 && signal.usage == 0xEA {
            pulseSignals[signal.identity] = signal
            var pulse = pulses[signal.identity] ?? HeadsetPulse()
            let edges = pulse.edge(down:down,now:ProcessInfo.processInfo.systemUptime)
            pulses[signal.identity] = pulse
            for edge in edges { process(signal,down:edge) }
        } else { process(signal,down:down) }
    }
    private func process(_ signal: HeadsetSignal, down: Bool) {
        guard !LockScreenInput.locked else { cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if learning {
            guard signal.device == selected?.device, selected?.kind == .hid else { return }
            let updates = learner.edge(signal, down: down, now: now)
            if !down && updates.isEmpty { feedback?("已收到松开，正在识别单击或双击…", nil) }
            for update in updates {
                guard learning else { break }; learningFeedback(update)
            }
            return
        }
        guard HeadsetRuleStore.shared.controls(signal), ready(signal), AXIsProcessTrusted(), !HeadsetPairing.shared.isActive, !HeadsetTouchDiagnostic.shared.isActive else { return }
        signals[signal.identity] = signal
        var machine = machines[signal.identity] ?? HeadsetGesture()
        let options = optionsFor(signal)
        let events = machine.edge(down: down, now: now, doubleEnabled: options.0, holdEnabled: options.1)
        machines[signal.identity] = machine
        for event in events { dispatch(event, signal: signal) }
    }
    private func optionsFor(_ signal: HeadsetSignal) -> (Bool, Bool) {
        let legacy = signal.kind == .hid ? HeadsetProfiles.shared.profile(vendor: signal.vendor, product: signal.product) : nil
        return (HeadsetRuleStore.shared.matching(signal, gesture: .doubleClick, app: frontBundle) != nil || legacy != nil && signal.usage == 0xCD,
                HeadsetRuleStore.shared.matching(signal, gesture: .hold, app: frontBundle) != nil || legacy?.supportsHold == true && signal.usage == 0xEA)
    }
    private func dispatch(_ event: HeadsetGesture.Event, signal: HeadsetSignal) {
        if event == .holdEnd {
            if let rule = boundRules.removeValue(forKey: signal.identity), HeadsetMappingActions.shared.currentRuleID == rule.id { HeadsetMappingActions.shared.finish() }
            return
        }
        let gesture: HeadsetRule.Gesture = event == .click ? .click : event == .doubleClick ? .doubleClick : .hold
        guard let rule = HeadsetRuleStore.shared.matching(signal, gesture: gesture, app: frontBundle) else {
            if event == .click { replay(signal) }
            else if event == .doubleClick, signal.usage == 0xCD, HeadsetProfiles.shared.profile(vendor: signal.vendor, product: signal.product) != nil { HeadsetController.shared.doubleClick() }
            else if event == .holdBegin, signal.usage == 0xEA, HeadsetProfiles.shared.profile(vendor: signal.vendor, product: signal.product)?.supportsHold == true {
                var fallback = HeadsetRule(signal:signal,gesture:.hold,action:.spriteVoice,key:HeadsetKey.parse("LeftOption"))
                fallback.id = "legacy:\(signal.identity)"; boundRules[signal.identity] = fallback; HeadsetMappingActions.shared.begin(fallback)
            }
            return
        }
        if event == .holdBegin { boundRules[signal.identity] = rule }
        HeadsetMappingActions.shared.begin(rule)
    }
    private func replay(_ signal: HeadsetSignal) {
        if signal.usage == 0xCD, HeadsetProfiles.shared.profile(vendor:signal.vendor,product:signal.product) != nil {
            HeadsetController.shared.firstNativePress()
            _ = HeadsetKeyEmitter().tap(HeadsetKey.parse("LeftOption")!); return
        }
        let codes = [0xCD:16, 0xE9:0, 0xEA:1, 0xB5:17, 0xB6:18, 0xE2:7]
        guard signal.kind == .hid, let code = codes[signal.usage] else { report("当前应用没有匹配规则，未执行"); return }
        for state in [0xA,0xB] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: .init(rawValue: UInt(state << 8)), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1)?.cgEvent
            event?.setIntegerValueField(.eventSourceUserData, value: HeadsetMarker); event?.post(tap: .cghidEventTap)
        }
    }
    func volumeStep(uid: String) -> Float? { HeadsetRuleStore.shared.rules.first { $0.enabled && $0.signal.kind == .volume && $0.signal.device == uid }?.signal.step }
    func hasVolumeRule(_ current: HeadsetAudioDevice, side: HeadsetClickGate.Side, step: Float) -> Bool {
        let signal = HeadsetSignal(kind: .volume, device: current.uid, name: current.name, usage: side == .right ? 1 : -1, step: step)
        guard HeadsetRuleStore.shared.controls(signal) else { return false }
        return HeadsetRuleStore.shared.matching(signal, gesture: .click, app: frontBundle) != nil
    }
    func handleVolume(_ current: HeadsetAudioDevice, side: HeadsetClickGate.Side, step: Float) -> Bool {
        let signal = HeadsetSignal(kind: .volume, device: current.uid, name: current.name, usage: side == .right ? 1 : -1, step: step)
        guard HeadsetRuleStore.shared.controls(signal) else { return false }
        guard let rule = HeadsetRuleStore.shared.matching(signal, gesture: .click, app: frontBundle) else { return false }
        HeadsetMappingActions.shared.begin(rule); return true
    }
    func cancel() { machines = [:]; signals = [:]; boundRules = [:]; pulses = [:]; pulseSignals = [:]; HeadsetMappingActions.shared.cancel() }
    private func ready(_ signal: HeadsetSignal) -> Bool {
        guard let data = try? Data(contentsOf: health), let value = try? JSONSerialization.jsonObject(with: data) as? [String:Any], let time = value["time"] as? Double, Date().timeIntervalSince1970 - time < 3,
              let sources = value["sources"] as? [String] else { report("等待耳机原生映射就绪…"); return false }
        return sources.contains(signal.identity)
    }
    private var publishedAt = Date.distantPast
    private var retryHIDAt = Date.distantPast
    private var retryTapAt = Date.distantPast
    private func publishLease() {
        guard AXIsProcessTrusted(), manager != nil, let tap, CGEvent.tapIsEnabled(tap:tap), !LockScreenInput.locked else { try? FileManager.default.removeItem(at: lease); return }
        let sources = HeadsetRuleStore.shared.rules.filter { $0.enabled && $0.signal.kind == .hid }.map(\.signal)
        if sources.isEmpty { try? FileManager.default.removeItem(at:lease); publishedAt = Date(); return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["pid":getpid(),"time":Date().timeIntervalSince1970,"sources":sources.compactMap { try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]) else { return }
        try? FileManager.default.createDirectory(at: HeadsetSupport, withIntermediateDirectories: true)
        try? data.write(to: lease, options: .atomic); publishedAt = Date()
    }
    private func tick() {
        startHID(); installCancellation()
        if LockScreenInput.locked || !AXIsProcessTrusted() { interrupted(); return }
        if Date().timeIntervalSince(publishedAt) > 0.5 { publishLease() }
        HeadsetMappingActions.shared.tick()
        for (id, var pulse) in pulses {
            guard let signal = pulseSignals[id] else { continue }
            let edges = pulse.tick(now:ProcessInfo.processInfo.systemUptime); pulses[id] = pulse
            for edge in edges { process(signal,down:edge) }
        }
        if let until = learningUntil {
            if Date() > until { stopLearning(); feedback?("检测超时，未保存。请检查设备与输入监控权限。", nil) }
            else if selected?.kind == .volume, let audio = HeadsetAudio.current(), let v = audio.volume {
                guard audio.uid == selected?.device, audio.uid == volumeUID else { stopLearning(); feedback?("声音输出已改变，请重新检测。", nil); return }
                if let old = volumeBaseline { let delta = v - old; if abs(delta) >= 0.015 && abs(delta) <= 0.2 {
                    let signal = HeadsetSignal(kind: .volume, device: audio.uid, name: audio.name, usage: delta > 0 ? 1 : -1, step: abs(delta))
                    if let update = learner.volume(signal) { learningFeedback(update) }
                } }
                volumeBaseline = v
            }
            if learning { for update in learner.tick(now: ProcessInfo.processInfo.systemUptime) { guard learning else { break }; learningFeedback(update) } }
            return
        }
        for (id, var machine) in machines {
            guard let signal = signals[id] else { continue }
            let options = optionsFor(signal)
            let events = machine.tick(now: ProcessInfo.processInfo.systemUptime, doubleEnabled: options.0, holdEnabled: options.1)
            machines[id] = machine
            for event in events { dispatch(event, signal: signal) }
        }
    }
    private func installCancellation() {
        guard tap == nil, Date() >= retryTapAt, AXIsProcessTrusted() else { return }
        retryTapAt = Date().addingTimeInterval(3)
        let types: [CGEventType] = [.keyDown,.flagsChanged,.leftMouseDown,.rightMouseDown]
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: types.reduce(0) { $0 | (1 << $1.rawValue) }, callback: { _, type, event, ref in
            guard let ref, event.getIntegerValueField(.eventSourceUserData) != HeadsetMarker else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<HeadsetMappingRuntime>.fromOpaque(ref).takeUnretainedValue()
            if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 { HeadsetMappingWindow.shared.cancelFromEscape() }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.interrupted(); if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if HeadsetMappingActions.shared.busy && (type == .leftMouseDown || type == .rightMouseDown || event.getIntegerValueField(.eventSourceUnixProcessID) <= 0) { owner.cancel(); owner.report("手动操作已取消当前映射") }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap { tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes) }
    }
    @objc private func interrupted() { cancel(); stopLearning(); try? FileManager.default.removeItem(at: lease) }
    @objc private func stop() { interrupted(); timer?.invalidate(); if let manager { IOHIDManagerClose(manager, 0) } }
}
