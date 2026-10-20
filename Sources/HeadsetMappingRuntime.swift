/**
 * [INPUT]: 依赖 IOHID 原始边沿/连接 registry、设备档案、规则存储、helper 操作租约/健康回执、共享动作拥有者与已准备接收框回执、音量桥。
 * [OUTPUT]: 发布绑定唯一当前 IOHIDDevice registry 的来源短租约，helper 沿服务父链核验并按 registry 回读健康；未知/歧义/旧连接回执拒绝接管，不依赖服务暴露序列号。新连接核验后路由共享准备链路，按压绑定 PID/代际、双击绑定同接收框；未接管保持直通，检测不执行动作。
 * [POS]: Sources 的耳机语义输入路由；helper 只按设备抑制来源，运行时决定手势与拥有者，不拦截键盘 Option；默认中键不经过单击/长按延时分类。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import IOKit.hid
import ApplicationServices

final class HeadsetMappingRuntime: NSObject {
    struct SourceAttachments {
        private(set) var registries: [UInt64: Double] = [:]
        mutating func attach(registry: UInt64, at time: Double) {
            guard registry > 0, time.isFinite, registries[registry] == nil else { return }
            registries[registry] = time
        }
        mutating func detach(registry: UInt64) { registries.removeValue(forKey: registry) }
        func covers(healthTimestamp: Double, registry: UInt64) -> Bool {
            guard registry > 0, registries.count == 1, let connection = registries.first, connection.key == registry else { return false }
            return healthTimestamp.isFinite && healthTimestamp >= connection.value
        }
    }
    private static let attachmentLock = NSLock()
    private static var attachments: [String: SourceAttachments] = [:]
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
    private let learningVolumeObserver = HeadsetVolumeObserver()
    private var learningVolumeCandidates: [(signal: HeadsetSignal, ticket: HeadsetVolumeSourceGate.Ticket)] = []
    private var volumeMachines: [String: HeadsetTapGesture] = [:]
    private var volumeSignals: [String: HeadsetSignal] = [:]
    private struct VolumeContext {
        let outputID: UInt32
        let pid: pid_t?
        let fallback: () -> Void
    }
    private var volumeContexts: [String: VolumeContext] = [:]
    private let volumeRules: HeadsetRuleStore
    private let performVolumeRule: (HeadsetRule) -> Void
    private let actions: HeadsetMappingActions
    private struct NativeCenterContext {
        let signal: HeadsetSignal
        let rule: HeadsetRule
        let pid: pid_t?
        let registry: UInt64?
        let generation: Int
    }
    private var nativeCenters: [String: NativeCenterContext] = [:]
    private struct NativeClassifierContext { var classifier: HeadsetButtonClassifier; let pid: pid_t?; var receiver: HeadsetVoiceReceiver? }
    private var nativeClassifiers: [String: NativeClassifierContext] = [:]
    private var nativeUnownedDowns: [String: HeadsetSignal] = [:]
    private var signalRegistries: [String: UInt64] = [:]
    var nativeRouteAllows: (() -> Bool)?
    var nativeSourceReady: ((HeadsetSignal) -> Bool)?
    var nativePaired: (HeadsetSignal) -> Bool = { HeadsetProfiles.shared.profile(vendor: $0.vendor, product: $0.product) != nil }
    var nativeForeground: () -> pid_t? = { HeadsetVoiceFocus.currentApplicationPID() }
    var nativeApplicationBundle: () -> String? = {
        guard let pid = HeadsetVoiceFocus.currentApplicationPID() else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }?.bundleIdentifier
    }
    var nativePreparedReceiver: () -> HeadsetVoiceReceiver? = { HeadsetController.shared.preparedClickReceiver }
    var nativeDoubleRelease: (HeadsetVoiceReceiver) -> Void = { HeadsetController.shared.doubleClick(expectedPID: $0.pid, expectedElement: $0.element) }
    var volumeOutput: () -> HeadsetAudioDevice? = { HeadsetAudio.current() }
    var volumeFocus: () -> pid_t? = { HeadsetVoiceFocus.currentApplicationPID() }
    var volumeSourcePending: () -> Bool = { HeadsetClickControl.shared.hasPendingVolumeSource }
    var volumeEnvironmentAllows: () -> Bool = {
        !LockScreenInput.locked && AXIsProcessTrusted() && !HeadsetPairing.shared.isActive && !HeadsetTouchDiagnostic.shared.isActive
    }
    init(volumeRules: HeadsetRuleStore = .shared, actions: HeadsetMappingActions = .shared,
         performVolumeRule: @escaping (HeadsetRule) -> Void = { HeadsetMappingActions.shared.begin($0) }) {
        self.volumeRules = volumeRules; self.actions = actions; self.performVolumeRule = performVolumeRule
        super.init()
    }
    var feedback: ((String, HeadsetSignal?) -> Void)?
    var statusChanged: ((String) -> Void)?
    private(set) var status = "就绪"
    private let lease = HeadsetSupport.appendingPathComponent("operation-lease.json")
    var learning: Bool { learningUntil != nil }
    private var frontBundle: String? {
        nativeApplicationBundle()
    }
    func report(_ value: String) { status = value; statusChanged?(value) }
    func start() {
        guard timer == nil else { return }
        volumeRules.changed = { [weak self] in self?.cancel(); self?.publishLease() }
        actions.message = { [weak self] in self?.report($0) }
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
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ref, _, _, device in
            guard let ref else { return }
            Unmanaged<HeadsetMappingRuntime>.fromOpaque(ref).takeUnretainedValue().noteAttachment(device)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterInputValueCallback(m, { ref, _, _, value in
            guard let ref else { return }
            let owner = Unmanaged<HeadsetMappingRuntime>.fromOpaque(ref).takeUnretainedValue()
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == 12 else { return }
            let d = IOHIDElementGetDevice(element)
            let vendor = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let product = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
            if HeadsetVolumeSourceEvent.isKeyboardVolume(page: Int(IOHIDElementGetUsagePage(element)), usage: Int(IOHIDElementGetUsage(element)), keyboardCollection: IOHIDDeviceConformsTo(d, 1, 6), pairedHeadset: HeadsetProfiles.shared.profile(vendor: vendor, product: product) != nil) {
                HeadsetVolumeSourceGuard.shared.exclude()
                HeadsetClickControl.shared.manualVolumeChange(source: "keyboard-HID")
            }
            guard var signal = owner.describe(d) else { return }
            guard HeadsetMappingRuntime.sourceAttachmentMatches(signal, registry: HeadsetMappingRuntime.registryID(d)) != false else { return }
            signal.usage = Int(IOHIDElementGetUsage(element))
            owner.signalRegistries[signal.identity] = HeadsetMappingRuntime.registryID(d)
            owner.receive(signal, down: IOHIDValueGetIntegerValue(value) != 0)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ref, _, _, device in
            guard let ref else { return }
            let owner = Unmanaged<HeadsetMappingRuntime>.fromOpaque(ref).takeUnretainedValue()
            if let removed = owner.describe(device) {
                HeadsetMappingRuntime.detachSource(removed.device, registry: HeadsetMappingRuntime.registryID(device))
                let registry = HeadsetMappingRuntime.registryID(device)
                owner.disconnectNativeDevice(removed.device, registry: registry)
                if owner.signals.values.contains(where: { $0.device == removed.device && owner.signalRegistries[$0.identity] == registry }) || owner.selected?.device == removed.device { owner.cancel(); owner.stopLearning(); owner.report("设备断开，本次操作已取消") }
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        if IOHIDManagerOpen(m, 0) == kIOReturnSuccess {
            manager = m
            if let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> { devices.forEach(noteAttachment) }
        }
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
    static func registryID(_ device: IOHIDDevice) -> UInt64 {
        var registry: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registry)
        return registry
    }
    private func noteAttachment(_ device: IOHIDDevice) {
        guard let signal = describe(device) else { return }
        let registry = Self.registryID(device)
        guard registry > 0 else { return }
        Self.attachmentLock.lock()
        var state = Self.attachments[signal.device] ?? SourceAttachments()
        let newAttachment = state.registries[registry] == nil
        state.attach(registry: registry, at: Date().timeIntervalSince1970)
        Self.attachments[signal.device] = state
        Self.attachmentLock.unlock()
        if newAttachment { disconnectNativeDevice(signal.device) }
    }
    private static func detachSource(_ device: String, registry: UInt64) {
        attachmentLock.lock(); defer { attachmentLock.unlock() }
        var state = attachments[device] ?? SourceAttachments()
        state.detach(registry: registry); attachments[device] = state
    }
    static func sourceAttachmentMatches(_ signal: HeadsetSignal, registry: UInt64) -> Bool? {
        attachmentLock.lock(); defer { attachmentLock.unlock() }
        return attachments[signal.device].map { $0.registries[registry] != nil }
    }
    private static func attachmentCovers(_ signal: HeadsetSignal, timestamp: Double, registry: UInt64) -> Bool {
        attachmentLock.lock(); defer { attachmentLock.unlock() }
        return attachments[signal.device]?.covers(healthTimestamp: timestamp, registry: registry) == true
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
        if device.kind == .volume, let audio = HeadsetAudio.current(), audio.uid == device.device {
            learningVolumeObserver.start(device: audio.id) { [weak self] receivedAt in self?.observeLearningVolume(notifiedAt: receivedAt) }
        }
        feedback?(gesture.map { "请操作一次\($0.label)，等待识别结果。" } ?? "请操作耳机，系统会识别收到的信号。", nil)
    }
    func stopLearning() {
        learningVolumeObserver.stop()
        learningVolumeCandidates = []
        learningUntil = nil; downTimes = [:]; selected = nil; lastTap = nil; pulses = [:]; pulseSignals = [:]; learner = HeadsetOperationLearning()
    }
    private func observeLearningVolume(notifiedAt: Double? = nil) {
        guard learning, selected?.kind == .volume, let audio = HeadsetAudio.current(), let volume = audio.volume else { return }
        guard audio.uid == selected?.device, audio.uid == volumeUID else { stopLearning(); feedback?("声音输出已改变，请重新检测。", nil); return }
        let old = volumeBaseline
        volumeBaseline = volume
        guard let old else { return }
        let delta = volume - old
        guard abs(delta) >= 0.015 && abs(delta) <= 0.2 else { return }
        let observedAt = HeadsetVolumeSourceEvent.observationTime(notifiedAt: notifiedAt, now: ProcessInfo.processInfo.systemUptime)
        guard let ticket = HeadsetVolumeSourceGuard.shared.ticket(now: observedAt) else { discardLearningVolume(); return }
        let signal = HeadsetSignal(kind: .volume, device: audio.uid, name: audio.name, usage: delta > 0 ? 1 : -1, step: abs(delta))
        learningVolumeCandidates.append((signal, ticket))
        DispatchQueue.main.asyncAfter(deadline: .now() + HeadsetVolumeSourceGuard.confirmationDelay) { [weak self] in self?.confirmLearningVolume() }
    }
    func discardLearningVolume() {
        learner.cancelVolume(); learningVolumeCandidates = []
        if learning, selected?.kind == .volume {
            volumeBaseline = HeadsetAudio.current()?.volume
            feedback?("已忽略键盘或系统调音量，请操作耳机继续录制。", nil)
        }
    }
    private func confirmLearningVolume() {
        guard learning, selected?.kind == .volume else { return }
        guard !HeadsetVolumeSourceGuard.shared.checkingPointer else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let due = learningVolumeCandidates.filter { now - $0.ticket.observedAt >= HeadsetVolumeSourceGuard.confirmationDelay }
        learningVolumeCandidates.removeAll { now - $0.ticket.observedAt >= HeadsetVolumeSourceGuard.confirmationDelay }
        for candidate in due {
            guard learning, candidate.signal.device == selected?.device, HeadsetAudio.current()?.uid == selected?.device else { break }
            guard HeadsetVolumeSourceGuard.shared.allows(candidate.ticket, now: now) else { discardLearningVolume(); break }
            let updates = learner.volume(candidate.signal, now: candidate.ticket.observedAt)
            if updates.isEmpty { feedback?("收到一次\(candidate.signal.label)，等待确认单击或双击…", nil) }
            for update in updates { guard learning else { break }; learningFeedback(update) }
        }
    }
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
        if signal.usesPulsedHold {
            pulseSignals[signal.identity] = signal
            var pulse = pulses[signal.identity] ?? HeadsetPulse()
            let edges = pulse.edge(down:down,now:ProcessInfo.processInfo.systemUptime)
            pulses[signal.identity] = pulse
            for edge in edges { process(signal,down:edge) }
        } else { process(signal,down:down) }
    }
    private func process(_ signal: HeadsetSignal, down: Bool) {
        if !down, nativeUnownedDowns.removeValue(forKey: signal.identity) != nil {
            if timer != nil { publishLease() }
            return
        }
        guard !LockScreenInput.locked else { cancel(); return }
        let now = ProcessInfo.processInfo.systemUptime
        if learning {
            guard signal.device == selected?.device, selected?.kind == .hid else { return }
            if let wanted, !HeadsetOperationLearning.supports(wanted, device: signal) {
                feedback?("这个减音量键的连续点击与长按重复信号会混在一起，暂不录制它的双击。可改用中键或加键。", nil)
                return
            }
            let updates = learner.edge(signal, down: down, now: now)
            if !down && updates.isEmpty { feedback?("已收到松开，正在识别单击或双击…", nil) }
            for update in updates {
                guard learning else { break }; learningFeedback(update)
            }
            return
        }
        if handleNativeCenter(signal, down: down, now: now, registry: signalRegistries[signal.identity]) { return }
        guard volumeRules.controls(signal), ready(signal), AXIsProcessTrusted(), !HeadsetPairing.shared.isActive, !HeadsetTouchDiagnostic.shared.isActive else { return }
        signals[signal.identity] = signal
        var machine = machines[signal.identity] ?? HeadsetGesture()
        let options = optionsFor(signal)
        let events = machine.edge(down: down, now: now, doubleEnabled: options.0, holdEnabled: options.1)
        machines[signal.identity] = machine
        for event in events { dispatch(event, signal: signal) }
    }
    private func optionsFor(_ signal: HeadsetSignal) -> (Bool, Bool) {
        let legacy = signal.kind == .hid ? HeadsetProfiles.shared.profile(vendor: signal.vendor, product: signal.product) : nil
        return (volumeRules.matching(signal, gesture: .doubleClick, app: frontBundle) != nil || legacy != nil && signal.usage == 0xCD,
                volumeRules.matching(signal, gesture: .hold, app: frontBundle) != nil || legacy?.supportsHold == true && signal.usage == 0xEA)
    }
    private func dispatch(_ event: HeadsetGesture.Event, signal: HeadsetSignal) {
        if event == .holdEnd {
            if let rule = boundRules.removeValue(forKey: signal.identity), actions.currentRuleID == rule.id { actions.finish() }
            return
        }
        let gesture: HeadsetRule.Gesture = event == .click ? .click : event == .doubleClick ? .doubleClick : .hold
        guard let rule = volumeRules.matching(signal, gesture: gesture, app: frontBundle) else {
            if event == .click { replay(signal) }
            else if event == .doubleClick, signal.usage == 0xCD, HeadsetProfiles.shared.profile(vendor: signal.vendor, product: signal.product) != nil {
                if let receiver = nativePreparedReceiver() { nativeDoubleRelease(receiver) }
            }
            else if event == .holdBegin, signal.usage == 0xEA, HeadsetProfiles.shared.profile(vendor: signal.vendor, product: signal.product)?.supportsHold == true {
                var fallback = HeadsetRule(signal:signal,gesture:.hold,action:.spriteVoice,key:HeadsetKey.parse("LeftOption"))
                fallback.id = "legacy:\(signal.identity)"; boundRules[signal.identity] = fallback; actions.begin(fallback)
            }
            return
        }
        if event == .holdBegin { boundRules[signal.identity] = rule }
        actions.begin(rule)
    }
    private func replay(_ signal: HeadsetSignal) {
        if signal.usage == 0xCD, HeadsetProfiles.shared.profile(vendor:signal.vendor,product:signal.product) != nil {
            actions.begin(Self.nativeCenterRule(signal), releaseAfterPreparation: true); return
        }
        let codes = [0xCD:16, 0xE9:0, 0xEA:1, 0xB5:17, 0xB6:18, 0xE2:7]
        guard signal.kind == .hid, let code = codes[signal.usage] else { report("当前应用没有匹配规则，未执行"); return }
        for state in [0xA,0xB] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: .init(rawValue: UInt(state << 8)), timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: (code << 16) | (state << 8), data2: -1)?.cgEvent
            event?.setIntegerValueField(.eventSourceUserData, value: HeadsetMarker); event?.post(tap: .cghidEventTap)
        }
    }
    // ---------- 默认有线中键：保留按住说、松开结束 ----------
    static func nativeCenterRule(_ signal: HeadsetSignal) -> HeadsetRule {
        var rule = HeadsetRule(signal: signal, gesture: .hold, action: .voice, key: HeadsetKey.parse("LeftOption"))
        rule.id = "native-center:\(signal.identity)"
        return rule
    }
    static func canLeaseHID(listening: Bool, cancellation: Bool, trusted: Bool, inputGranted: Bool,
                            locked: Bool, detecting: Bool) -> Bool {
        listening && cancellation && trusted && inputGranted && !locked && !detecting
    }
    private func nativeEnvironmentAllows() -> Bool {
        if let nativeRouteAllows { return nativeRouteAllows() && !learning }
        return Self.canLeaseHID(listening: manager != nil, cancellation: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
                                trusted: AXIsProcessTrusted(), inputGranted: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted,
                                locked: LockScreenInput.locked,
                                detecting: learning || HeadsetPairing.shared.isActive || HeadsetTouchDiagnostic.shared.isActive)
    }
    private func defaultNativeCenter(_ signal: HeadsetSignal) -> Bool {
        let app = nativeApplicationBundle()
        let overridden = volumeRules.rules.contains { $0.enabled && $0.signal.identity == signal.identity && ($0.scope == nil || $0.scope == app) }
        return signal.kind == .hid && signal.page == 12 && signal.usage == 0xCD && signal.valid && nativePaired(signal) && !overridden
    }
    func effectiveHIDSources(devices: [HeadsetSignal]) -> [HeadsetSignal] {
        var sources = volumeRules.rules.filter { $0.enabled && $0.signal.kind == .hid }.map(\.signal)
        for device in devices {
            var center = device; center.usage = 0xCD
            if defaultNativeCenter(center) { sources.append(center) }
        }
        var included = Set<String>()
        return sources.filter { nativeUnownedDowns[$0.identity] == nil && included.insert($0.identity).inserted }
    }
    @discardableResult func handleNativeCenter(_ signal: HeadsetSignal, down: Bool,
                                               now: Double = ProcessInfo.processInfo.systemUptime, registry: UInt64? = nil) -> Bool {
        if !down, let context = nativeCenters[signal.identity] {
            if let registry, let expected = context.registry, registry != expected { return true }
            nativeCenters.removeValue(forKey: signal.identity)
            let current = actions.currentRuleID == context.rule.id && actions.recordingGeneration == context.generation
            let valid = nativeEnvironmentAllows() && ready(signal) && nativeForeground() == context.pid
            let receiver = current ? nativePreparedReceiver() : nil
            if current { if valid { actions.finish() } else { actions.cancel() } }
            if valid && current {
                let previous = nativeClassifiers[signal.identity]
                var classifier = nativeClassifiers[signal.identity]?.classifier ?? HeadsetButtonClassifier()
                let edge = classifier.edge(down: false, time: UInt64(now * 1_000_000_000))
                nativeClassifiers[signal.identity] = NativeClassifierContext(classifier: classifier, pid: context.pid,
                    receiver: edge?.second == true ? nil : receiver)
                if edge?.second == true, !actions.busy, let first = previous?.receiver, let receiver,
                   first.pid == context.pid, first.pid == receiver.pid, CFEqual(first.element, receiver.element) { nativeDoubleRelease(first) }
            } else { nativeClassifiers.removeValue(forKey: signal.identity) }
            return true
        }
        guard signal.kind == .hid, signal.page == 12, signal.usage == 0xCD, signal.valid, nativePaired(signal) else { return false }
        if nativeUnownedDowns[signal.identity] != nil {
            if !down {
                nativeUnownedDowns.removeValue(forKey: signal.identity)
                if timer != nil { publishLease() }
            }
            return true
        }
        guard nativeEnvironmentAllows(), ready(signal) else {
            if down {
                nativeUnownedDowns[signal.identity] = signal
                // 未确认接管的整轮保持直通；立即撤掉来源，不能等续租周期再切映射。
                if timer != nil { publishLease() }
            }
            cancelNativeCenter(signal.identity); return true
        }
        guard defaultNativeCenter(signal) else { return false }
        guard down, nativeCenters[signal.identity] == nil else { return true }
        let pid = nativeForeground()
        let previous = nativeClassifiers[signal.identity]
        var classifier = HeadsetButtonClassifier()
        if let previous, previous.pid == pid { classifier = previous.classifier }
        _ = classifier.edge(down: true, time: UInt64(now * 1_000_000_000))
        nativeClassifiers[signal.identity] = NativeClassifierContext(classifier: classifier, pid: pid, receiver: previous?.pid == pid ? previous?.receiver : nil)
        let rule = Self.nativeCenterRule(signal)
        actions.begin(rule)
        nativeCenters[signal.identity] = NativeCenterContext(signal: signal, rule: rule, pid: pid, registry: registry, generation: actions.recordingGeneration)
        return true
    }
    private func cancelNativeCenter(_ identity: String) {
        if let context = nativeCenters.removeValue(forKey: identity), actions.currentRuleID == context.rule.id,
           actions.recordingGeneration == context.generation { actions.cancel() }
        nativeClassifiers.removeValue(forKey: identity)
    }
    func cancelNativeTapSequence() { nativeClassifiers.removeAll() }
    func disconnectNativeDevice(_ device: String, registry: UInt64? = nil) {
        for (identity, context) in nativeCenters where context.signal.device == device && (registry == nil || context.registry == registry) { cancelNativeCenter(identity) }
        nativeUnownedDowns = nativeUnownedDowns.filter { $0.value.device != device || registry != nil && signalRegistries[$0.key] != registry }
        if registry == nil { nativeClassifiers = nativeClassifiers.filter { !$0.key.hasPrefix("hid:\(device):") } }
    }
    func tickNativeCenters() {
        for (identity, context) in nativeCenters {
            if !nativeEnvironmentAllows() || !ready(context.signal) || nativeForeground() != context.pid || !defaultNativeCenter(context.signal) {
                cancelNativeCenter(identity)
            }
        }
    }
    static func operationMappingActive(_ signal: HeadsetSignal, now: Double = Date().timeIntervalSince1970) -> Bool {
        let path = HeadsetSupport.appendingPathComponent("operation-health.json")
        guard let data = try? Data(contentsOf: path), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let receipt = operationHealthReceipt(value, for: signal, now: now) else { return false }
        return attachmentCovers(signal, timestamp: receipt.timestamp, registry: receipt.registry)
    }
    static func operationHealthReceipt(_ value: [String: Any], for signal: HeadsetSignal, now: Double) -> (timestamp: Double, registry: UInt64)? {
        guard let timestamp = value["time"] as? Double, healthIsFresh(timestamp: timestamp, now: now),
              let sources = value["sources"] as? [String], sources.contains(signal.identity),
              let registries = value["registries"] as? [String: NSNumber], let registry = registries[signal.identity],
              registry.uint64Value > 0 else { return nil }
        return (timestamp, registry.uint64Value)
    }
    func volumeStep(uid: String) -> Float? { volumeRules.rules.first { $0.enabled && $0.signal.kind == .volume && $0.signal.device == uid }?.signal.step }
    func volumeDoubleClickEnabled(uid: String) -> Bool {
        volumeRules.rules.contains { $0.enabled && $0.signal.kind == .volume && $0.signal.device == uid && $0.gesture == .doubleClick && ($0.scope == nil || $0.scope == frontBundle) }
    }
    func hasVolumeRule(_ current: HeadsetAudioDevice, side: HeadsetClickGate.Side, step: Float) -> Bool {
        let signal = HeadsetSignal(kind: .volume, device: current.uid, name: current.name, usage: side == .right ? 1 : -1, step: step)
        return volumeRules.matching(signal, gesture: .click, app: frontBundle) != nil || volumeRules.matching(signal, gesture: .doubleClick, app: frontBundle) != nil
    }
    func handleVolume(_ current: HeadsetAudioDevice, side: HeadsetClickGate.Side, step: Float, now: Double = ProcessInfo.processInfo.systemUptime, fallback: @escaping () -> Void = {}) -> Bool {
        let signal = HeadsetSignal(kind: .volume, device: current.uid, name: current.name, usage: side == .right ? 1 : -1, step: step)
        guard hasVolumeRule(current, side: side, step: step) else { return false }
        guard !learning, volumeEnvironmentAllows(), let output = volumeOutput(), output.uid == current.uid, output.id == current.id, output.volume != nil else { cancelVolumeGestures(); return true }
        let pid = volumeFocus()
        if let previous = volumeContexts[signal.identity], previous.pid != pid || previous.outputID != current.id {
            volumeMachines.removeValue(forKey: signal.identity)
        }
        var machine = volumeMachines[signal.identity] ?? HeadsetTapGesture()
        let previousContext = volumeContexts[signal.identity]
        let doubleEnabled = volumeRules.matching(signal, gesture: .doubleClick, app: frontBundle) != nil
        let context = VolumeContext(outputID: current.id, pid: pid, fallback: fallback)
        volumeContexts[signal.identity] = context; volumeSignals[signal.identity] = signal
        let events = machine.tap(now: now, doubleEnabled: doubleEnabled)
        volumeMachines[signal.identity] = machine
        if !machine.hasPending { removeVolumeGesture(signal.identity) }
        for event in events {
            dispatchVolume(event, signal: signal, fallback: event == .click ? previousContext?.fallback ?? context.fallback : context.fallback)
        }
        return true
    }
    private func dispatchVolume(_ event: HeadsetGesture.Event, signal: HeadsetSignal, fallback: () -> Void) {
        let gesture: HeadsetRule.Gesture = event == .doubleClick ? .doubleClick : .click
        if let rule = volumeRules.matching(signal, gesture: gesture, app: frontBundle) { performVolumeRule(rule) }
        else if event == .click { fallback() }
    }
    private func removeVolumeGesture(_ identity: String) {
        volumeMachines.removeValue(forKey: identity); volumeSignals.removeValue(forKey: identity); volumeContexts.removeValue(forKey: identity)
    }
    func tickVolume(now: Double) {
        guard !volumeMachines.isEmpty else { return }
        guard HeadsetVolumeSourceGuard.shared.ticket(now: now) != nil else { cancelVolumeGestures(); return }
        guard !volumeSourcePending() else { return }
        guard !learning, volumeEnvironmentAllows(), let output = volumeOutput(), output.volume != nil else { cancelVolumeGestures(); return }
        for id in Array(volumeMachines.keys) {
            guard let context = volumeContexts[id], let signal = volumeSignals[id], var machine = volumeMachines[id] else { continue }
            guard output.uid == signal.device, output.id == context.outputID, volumeFocus() == context.pid else { removeVolumeGesture(id); continue }
            let events = machine.tick(now: now)
            volumeMachines[id] = machine
            if !machine.hasPending { removeVolumeGesture(id) }
            for event in events { dispatchVolume(event, signal: signal, fallback: context.fallback) }
        }
    }
    func cancelVolumeGestures() { volumeMachines = [:]; volumeSignals = [:]; volumeContexts = [:] }
    func cancel() { machines = [:]; signals = [:]; boundRules = [:]; pulses = [:]; pulseSignals = [:]; nativeCenters = [:]; nativeClassifiers = [:]; cancelVolumeGestures(); actions.cancel() }
    static func healthIsFresh(timestamp: Double, now: Double) -> Bool {
        let age = now - timestamp
        return age.isFinite && age >= 0 && age < 3
    }
    private func ready(_ signal: HeadsetSignal) -> Bool {
        if let nativeSourceReady { return nativeSourceReady(signal) }
        guard Self.operationMappingActive(signal) else { report("等待耳机原生映射就绪…"); return false }
        return true
    }
    private var publishedAt = Date.distantPast
    private var retryHIDAt = Date.distantPast
    private var retryTapAt = Date.distantPast
    static func operationLeaseSource(_ signal: HeadsetSignal, attachments: [(signal: HeadsetSignal, registry: UInt64)]) -> [String: Any]? {
        guard signal.kind == .hid, signal.valid else { return nil }
        let registries = Set(attachments.filter {
            $0.signal.kind == .hid && $0.signal.device == signal.device && $0.signal.vendor == signal.vendor &&
                $0.signal.product == signal.product
        }.map(\.registry))
        // ---------- 规则身份与本轮连接绑定 ----------
        // 同名/无序列号设备同时出现时，不能猜测哪个连接拥有已保存规则。
        guard registries.count == 1, let registry = registries.first, registry > 0,
              let data = try? JSONEncoder().encode(signal),
              var source = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        source["registryID"] = registry
        return source
    }
    private func publishLease() {
        guard nativeEnvironmentAllows() else { try? FileManager.default.removeItem(at: lease); return }
        let attachments = manager.flatMap { IOHIDManagerCopyDevices($0) as? Set<IOHIDDevice> }?.compactMap { device -> (signal: HeadsetSignal, registry: UInt64)? in
            guard let signal = describe(device) else { return nil }
            return (signal, Self.registryID(device))
        } ?? []
        let sources = effectiveHIDSources(devices: attachments.map(\.signal)).compactMap { Self.operationLeaseSource($0, attachments: attachments) }
        if sources.isEmpty { try? FileManager.default.removeItem(at:lease); publishedAt = Date(); return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["pid":getpid(),"time":Date().timeIntervalSince1970,"sources":sources]) else { return }
        try? FileManager.default.createDirectory(at: HeadsetSupport, withIntermediateDirectories: true)
        try? data.write(to: lease, options: .atomic); publishedAt = Date()
    }
    private func tick() {
        startHID(); installCancellation()
        if LockScreenInput.locked || !AXIsProcessTrusted() { interrupted(); return }
        if Date().timeIntervalSince(publishedAt) > 0.5 { publishLease() }
        actions.tick(); tickNativeCenters()
        for (id, var pulse) in pulses {
            guard let signal = pulseSignals[id] else { continue }
            let edges = pulse.tick(now:ProcessInfo.processInfo.systemUptime); pulses[id] = pulse
            for edge in edges { process(signal,down:edge) }
        }
        if let until = learningUntil {
            if Date() > until { stopLearning(); feedback?("检测超时，未保存。请检查设备与输入监控权限。", nil) }
            else { observeLearningVolume() }
            confirmLearningVolume()
            if learning && learningVolumeCandidates.isEmpty { for update in learner.tick(now: ProcessInfo.processInfo.systemUptime) { guard learning else { break }; learningFeedback(update) } }
            return
        }
        tickVolume(now: ProcessInfo.processInfo.systemUptime)
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
        let types: [CGEventType] = [.keyDown,.flagsChanged,.leftMouseDown,.rightMouseDown,CGEventType(rawValue: 14)!]
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: types.reduce(0) { $0 | (1 << $1.rawValue) }, callback: { _, type, event, ref in
            guard let ref, event.getIntegerValueField(.eventSourceUserData) != HeadsetMarker else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<HeadsetMappingRuntime>.fromOpaque(ref).takeUnretainedValue()
            if type.rawValue == 14, let native = NSEvent(cgEvent: event), HeadsetVolumeSourceEvent.isSystemVolume(type: type.rawValue, subtype: native.subtype.rawValue, data1: native.data1, marker: event.getIntegerValueField(.eventSourceUserData)) {
                HeadsetVolumeSourceGuard.shared.exclude()
                HeadsetClickControl.shared.manualVolumeChange(source: "system-media")
                return Unmanaged.passUnretained(event)
            }
            if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 { HeadsetMappingWindow.shared.cancelFromEscape() }
            if type == .leftMouseDown || type == .rightMouseDown || event.getIntegerValueField(.eventSourceUnixProcessID) <= 0 {
                owner.cancelNativeTapSequence()
            }
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.interrupted(); if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if owner.actions.busy && (type == .leftMouseDown || type == .rightMouseDown || event.getIntegerValueField(.eventSourceUnixProcessID) <= 0) { owner.cancel(); owner.report("手动操作已取消当前映射") }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap { tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0); CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes) }
    }
    @objc private func interrupted() { cancel(); stopLearning(); try? FileManager.default.removeItem(at: lease) }
    @objc private func stop() { interrupted(); timer?.invalidate(); if let manager { IOHIDManagerClose(manager, 0) } }
}
