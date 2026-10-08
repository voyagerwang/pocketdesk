/** Quark2 minus: delay short-press volume until release; hold exclusively starts sprite. */
import AppKit
import IOKit.hid
import ApplicationServices

struct HeadsetHold {
    private(set) var pressed = false
    private(set) var active = false
    mutating func press() -> Bool {
        guard !pressed else { return false }
        pressed = true; return true
    }
    mutating func threshold() -> Bool {
        guard pressed, !active else { return false }
        active = true; return true
    }
    mutating func release() -> Bool {
        let wasActive = active
        pressed = false; active = false
        return wasActive
    }
}
final class HeadsetLongPress {
    private var hold = HeadsetHold()
    private var pending: DispatchWorkItem?
    private var pendingRelease: DispatchWorkItem?
    private var pulseMode = false
    private var manager: IOHIDManager?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var heartbeat: Timer?
    private let lease = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoiceDeck/headset/hold-lease.json")
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    var onCancel: (() -> Void)?
    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey:12] as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(m, { context, _, _, value in
            guard let context else { return }
            let owner = Unmanaged<HeadsetLongPress>.fromOpaque(context).takeUnretainedValue()
            let e = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(e) == 12, IOHIDElementGetUsage(e) == 0xEA else { return }
            let d = IOHIDElementGetDevice(e)
            let vendor = (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? 0
            let product = (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? 0
            guard let profile = HeadsetProfiles.shared.profile(vendor: vendor, product: product) else { return }
            guard profile.supportsHold, !HeadsetRuleStore.shared.controlsHID(vendor: vendor, product: product, usage: 0xEA, serial: IOHIDDeviceGetProperty(d, kIOHIDSerialNumberKey as CFString) as? String) else { return }
            owner.pulseMode = profile.usesPulsedHold
            owner.receive(down: IOHIDValueGetIntegerValue(value) != 0)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterDeviceRemovalCallback(m, { context, _, _, _ in
            guard let context else { return }
            Unmanaged<HeadsetLongPress>.fromOpaque(context).takeUnretainedValue().cancel()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if let connected = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> {
            pulseMode = connected.contains { d in
                (IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue == 31 &&
                (IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue == 2849
            }
        }
        NSLog("PocketDesk volume-down listener: %d; pulse mode: %@", result, pulseMode.description)
        heartbeat = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.maintain() }
        RunLoop.main.add(heartbeat!, forMode: .common)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.cancel(); self?.removeLease()
        }
        maintain()
    }
    private func removeLease() { try? FileManager.default.removeItem(at: lease) }
    private func maintain() {
        guard AXIsProcessTrusted(), !LockScreenInput.locked, !HeadsetPairing.shared.isActive, !HeadsetMappingRuntime.shared.learning else { cancel(); removeLease(); return }
        if tap == nil {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: { _, type, event, context in
                    let owner = Unmanaged<HeadsetLongPress>.fromOpaque(context!).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.cancel(); owner.removeLease()
                        if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    // F20 is reserved for this device's mapped minus key while the lease is live.
                    guard event.getIntegerValueField(.keyboardEventKeycode) == 90 else { return Unmanaged.passUnretained(event) }
                    // Only swallow legacy F20 during migration; raw device HID drives the gesture.
                    return nil
                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            if let tap {
                tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                NSLog("PocketDesk exclusive minus tap ready")
            }
        }
        guard let tap, CGEvent.tapIsEnabled(tap: tap) else { removeLease(); return }
        try? FileManager.default.createDirectory(at: lease.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try? JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier, "time": Date().timeIntervalSince1970])
        try? data?.write(to: lease, options: .atomic)
    }
    private func cancel() {
        pendingRelease?.cancel(); pendingRelease = nil
        pending?.cancel(); pending = nil
        if hold.pressed { _ = hold.release(); onCancel?() }
    }
    private func lowerVolumeOnce() {
        // Replay one ordinary media-key click, not a held/repeating volume event.
        for state in [0xA, 0xB] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: (1 << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        NSLog("PocketDesk minus short press: volume down once")
    }
    private func receive(down: Bool) {
        guard !LockScreenInput.locked, !HeadsetPairing.shared.isActive, !HeadsetMappingRuntime.shared.learning else { cancel(); return }
        if down {
            pendingRelease?.cancel(); pendingRelease = nil
            guard hold.press() else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hold.threshold() else { return }
                NSLog("PocketDesk minus hold: sprite only")
                self.onBegin?()
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        } else {
            guard hold.pressed else { return }
            if pulseMode {
                pendingRelease?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.finishRelease() }
                pendingRelease = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            } else { finishRelease() }
        }
    }
    private func finishRelease() {
        pendingRelease = nil
        guard hold.pressed else { return }
        pending?.cancel(); pending = nil
        if hold.release() { onEnd?() } else { lowerVolumeOnce() }
    }
}
