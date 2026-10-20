/**
 * [INPUT]: 依赖已配对设备的原始中键 HID、按键分类器与 helper 新鲜操作健康回执。
 * [OUTPUT]: 仅未被语义路由接管的来源通知原生直通首按/双击；交付再核连接、PID 和首按代际，旧回调不借新会话；已接管设备不重复装配，真实键盘 Option 不参与匹配。
 * [POS]: Sources 的原生直通兼容观察者；自动聚焦由 HeadsetMappingRuntime 和共享动作层负责，本监听器不发快捷键、不移动焦点。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import IOKit.hid
import IOKit.hidsystem

final class HeadsetCenterObserver {
    private let condition = NSCondition()
    private var classifier = HeadsetButtonClassifier()
    private var deviceIdentity: String?
    private var classifierPID: pid_t?
    private var callbackEpoch = 0
    private var edges: [HeadsetButtonEdge] = []
    private var timebase = mach_timebase_info_data_t()
    var started = false
    var onReady: ((Bool) -> Void)?
    var onFirstPress: ((pid_t) -> Void)?
    var onDoubleRelease: ((pid_t) -> Void)?
    var semanticSourceActive: (HeadsetSignal) -> Bool = { HeadsetMappingRuntime.operationMappingActive($0) }
    static func shouldObserve(_ signal: HeadsetSignal, paired: Bool, semanticActive: Bool) -> Bool {
        signal.kind == .hid && signal.page == 12 && signal.usage == 0xCD && paired && !semanticActive
    }
    static func shouldDeliver(observedPID: pid_t?, currentPID: pid_t?, semanticActive: Bool, sameAttachment: Bool, sameSequence: Bool = true) -> Bool {
        observedPID != nil && observedPID == currentPID && !semanticActive && sameAttachment && sameSequence
    }
    init() { mach_timebase_info(&timebase) }
    func start() {
        guard !started else { return }; started = true
        Thread.detachNewThread { [self] in
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey:12] as CFDictionary)
            IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
                let observer = Unmanaged<HeadsetCenterObserver>.fromOpaque(context!).takeUnretainedValue()
                let element = IOHIDValueGetElement(value)
                let device = IOHIDElementGetDevice(element)
                let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
                let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
                guard IOHIDElementGetUsagePage(element) == 12, IOHIDElementGetUsage(element) == 0xCD else { return }
                let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? "model"
                let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "耳机"
                let signal = HeadsetSignal(kind: .hid, device: "\(vendor):\(product):\(serial)", name: name, vendor: vendor, product: product, usage: 0xCD)
                let registry = HeadsetMappingRuntime.registryID(device)
                guard HeadsetCenterObserver.shouldObserve(signal, paired: HeadsetProfiles.shared.profile(vendor: vendor, product: product) != nil,
                                         semanticActive: observer.semanticSourceActive(signal)),
                      HeadsetMappingRuntime.sourceAttachmentMatches(signal, registry: registry) != false else {
                    observer.condition.lock(); observer.classifier = HeadsetButtonClassifier(); observer.edges.removeAll(); observer.callbackEpoch += 1; observer.condition.unlock()
                    return
                }
                let ticks = IOHIDValueGetTimeStamp(value)
                let ns = HeadsetNanoseconds(ticks,numer:observer.timebase.numer,denom:observer.timebase.denom)
                let focusedPID = HeadsetVoiceFocus.currentApplicationPID()
                observer.condition.lock()
                let identity = "\(vendor):\(product):\(IOHIDDeviceGetService(device))"
                if observer.deviceIdentity != identity || observer.classifierPID != focusedPID {
                    observer.deviceIdentity = identity
                    observer.classifierPID = focusedPID
                    observer.callbackEpoch += 1
                    observer.classifier = HeadsetButtonClassifier()
                    observer.edges.removeAll()
                }
                observer.condition.unlock()
                observer.receive(down:IOHIDValueGetIntegerValue(value) != 0, time:ns, signal:signal, registry:registry, focusedPID:focusedPID)
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
                let observer = Unmanaged<HeadsetCenterObserver>.fromOpaque(context!).takeUnretainedValue()
                observer.condition.lock()
                observer.classifier = HeadsetButtonClassifier()
                observer.edges.removeAll()
                observer.callbackEpoch += 1
                observer.condition.unlock()
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) // Never seize the device.
            DispatchQueue.main.async { self.onReady?(result == kIOReturnSuccess) }
            HeadsetLog("HID passive open result=\(result)")
            if result == kIOReturnSuccess { CFRunLoopRun() }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
    private func receive(down: Bool, time: UInt64, signal: HeadsetSignal, registry: UInt64, focusedPID: pid_t?) {
        condition.lock()
        let edge = classifier.edge(down:down,time:time)
        if let edge, edge.down && !edge.second { callbackEpoch += 1 }
        let epoch = callbackEpoch
        if let edge {
            edges.append(edge); if edges.count > 32 { edges.removeFirst(edges.count - 32) }
            condition.broadcast()
        }
        condition.unlock()
        if let edge, edge.down && !edge.second {
            DispatchQueue.main.async {
                guard let focusedPID, Self.shouldDeliver(observedPID: focusedPID, currentPID: HeadsetVoiceFocus.currentApplicationPID(),
                    semanticActive: self.semanticSourceActive(signal), sameAttachment: HeadsetMappingRuntime.sourceAttachmentMatches(signal, registry: registry) != false,
                    sameSequence: self.callbackIsCurrent(epoch)) else { return }
                self.onFirstPress?(focusedPID)
            }
        }
        if let edge, !edge.down && edge.second {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.04) {
                guard let focusedPID, Self.shouldDeliver(observedPID: focusedPID, currentPID: HeadsetVoiceFocus.currentApplicationPID(),
                    semanticActive: self.semanticSourceActive(signal), sameAttachment: HeadsetMappingRuntime.sourceAttachmentMatches(signal, registry: registry) != false,
                    sameSequence: self.callbackIsCurrent(epoch)) else { return }
                self.onDoubleRelease?(focusedPID)
            }
        }
        if let edge { HeadsetLog("HID edge down=\(down) second=\(edge.second) sequence=\(edge.sequence) t=\(time)") }
    }
    private func callbackIsCurrent(_ epoch: Int) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return callbackEpoch == epoch
    }
    func match(time ticks: UInt64, down: Bool) -> HeadsetButtonEdge? {
        let time = HeadsetNanoseconds(ticks,numer:timebase.numer,denom:timebase.denom)
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(0.008)
        while true {
            if let i = edges.firstIndex(where: { e in
                let distance = e.time > time ? e.time-time : time-e.time
                return e.down == down && distance <= 1_000_000
            }) { return edges.remove(at:i) }
            if !condition.wait(until:deadline) { return nil }
        }
    }
}
