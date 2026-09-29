import Foundation
import IOKit.hid
import IOKit.hidsystem

final class HeadsetCenterObserver {
    private let condition = NSCondition()
    private var classifier = HeadsetButtonClassifier()
    private var deviceIdentity: String?
    private var edges: [HeadsetButtonEdge] = []
    private var timebase = mach_timebase_info_data_t()
    var started = false
    var onReady: ((Bool) -> Void)?
    var onFirstPress: (() -> Void)?
    var onDoubleRelease: (() -> Void)?
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
                guard HeadsetProfiles.shared.profile(vendor: vendor, product: product) != nil else { return }
                guard IOHIDElementGetUsagePage(element) == 12, IOHIDElementGetUsage(element) == 0xCD else { return }
                let ticks = IOHIDValueGetTimeStamp(value)
                let ns = HeadsetNanoseconds(ticks,numer:observer.timebase.numer,denom:observer.timebase.denom)
                observer.condition.lock()
                let identity = "\(vendor):\(product):\(IOHIDDeviceGetService(device))"
                if observer.deviceIdentity != identity {
                    observer.deviceIdentity = identity
                    observer.classifier = HeadsetButtonClassifier()
                    observer.edges.removeAll()
                }
                observer.condition.unlock()
                observer.receive(down:IOHIDValueGetIntegerValue(value) != 0, time:ns)
            }, Unmanaged.passUnretained(self).toOpaque())
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
                let observer = Unmanaged<HeadsetCenterObserver>.fromOpaque(context!).takeUnretainedValue()
                observer.condition.lock()
                observer.classifier = HeadsetButtonClassifier()
                observer.edges.removeAll()
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
    private func receive(down: Bool, time: UInt64) {
        condition.lock()
        let edge = classifier.edge(down:down,time:time)
        if let edge {
            edges.append(edge); if edges.count > 32 { edges.removeFirst(edges.count - 32) }
            condition.broadcast()
        }
        condition.unlock()
        if let edge, edge.down && !edge.second { DispatchQueue.main.async { self.onFirstPress?() } }
        if let edge, !edge.down && edge.second { DispatchQueue.main.asyncAfter(deadline:.now()+0.04) { self.onDoubleRelease?() } }
        if let edge { HeadsetLog("HID edge down=\(down) second=\(edge.second) sequence=\(edge.sequence) t=\(time)") }
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
