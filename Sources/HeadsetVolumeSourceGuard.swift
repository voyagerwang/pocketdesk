/**
 * [INPUT]: 依赖媒体键/HID 来源分类、单调时钟与鼠标命中的 Slider 角色及只读音量语义。
 * [OUTPUT]: 提供线程安全来源票据与待核验状态；真实媒体键或音量滑块使候选失效，普通点击及其他滑块保留原票据，音量拖动期间持续禁用语音路由。
 * [POS]: Sources 的耳机音量来源边界；CoreAudio 只提供音量结果，本层将可证实的手动来源与耳机动作隔离，不读取正文或执行动作。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum HeadsetVolumeSourceEvent {
    static func observationTime(notifiedAt: Double?, now: Double) -> Double {
        guard let notifiedAt, notifiedAt.isFinite, notifiedAt >= 0, notifiedAt <= now else { return now }
        return notifiedAt
    }
    static func isSystemVolume(type: UInt32, subtype: Int16, data1: Int, marker: Int64) -> Bool {
        type == 14 && subtype == 8 && [0, 1].contains((data1 >> 16) & 0xffff) && marker != HeadsetMarker
    }
    static func isKeyboardVolume(page: Int, usage: Int, keyboardCollection: Bool, pairedHeadset: Bool) -> Bool {
        page == 12 && [0xE9, 0xEA].contains(usage) && keyboardCollection && !pairedHeadset
    }
    static func isVolumeSlider(role: String, labels: [String]) -> Bool {
        guard role == "AXSlider" else { return false }
        return labels.contains { label in
            let lowered = label.lowercased()
            return lowered.contains("音量") || lowered.split(whereSeparator: { !$0.isLetter }).contains("volume")
        }
    }
}

/// CoreAudio reports the output volume, not the input that changed it. Delay
/// attribution briefly so a keyboard or slider exclusion can veto the change.
struct HeadsetVolumeSourceGate {
    static let confirmationDelay = 0.08
    static let pointerVerificationBudget = 0.2
    static let maximumPointerWait = 0.4
    private static let exclusionInterval = 0.8
    struct Ticket: Equatable {
        let revision: Int
        let observedAt: Double
    }
    struct PointerTicket: Equatable { let revision: Int }
    private var blockedUntil = 0.0
    private var revision = 0
    private var pointerRevision = 0
    private var pendingPointer: PointerTicket?
    private var pointerDown = false
    private var draggingSlider = false
    private var pointerVolumeUntil = 0.0
    var checkingPointer: Bool { pendingPointer != nil }
    func pointerVolumeActive(now: Double) -> Bool {
        Self.validTime(now) && (draggingSlider || now < pointerVolumeUntil)
    }

    mutating func beginPointer(now: Double) -> PointerTicket? {
        guard Self.validTime(now) else { return nil }
        pointerRevision &+= 1
        let ticket = PointerTicket(revision: pointerRevision)
        pendingPointer = ticket; pointerDown = true; draggingSlider = false
        return ticket
    }
    @discardableResult mutating func resolvePointer(_ ticket: PointerTicket, slider: Bool, now: Double) -> Bool {
        guard Self.validTime(now), pendingPointer == ticket else { return false }
        pendingPointer = nil
        if slider {
            draggingSlider = pointerDown; pointerVolumeUntil = now + Self.exclusionInterval
            exclude(now: now)
        }
        return slider
    }
    mutating func endPointer(now: Double) {
        guard Self.validTime(now) else { return }
        pointerDown = false
        if draggingSlider {
            draggingSlider = false; pointerVolumeUntil = now + Self.exclusionInterval
            exclude(now: now)
        }
    }

    mutating func exclude(now: Double) {
        guard Self.validTime(now) else { return }
        revision &+= 1
        blockedUntil = max(blockedUntil, now + Self.exclusionInterval)
    }
    func ticket(now: Double) -> Ticket? {
        guard Self.validTime(now), !draggingSlider, now >= blockedUntil else { return nil }
        return Ticket(revision: revision, observedAt: now)
    }
    func allows(_ ticket: Ticket, now: Double) -> Bool {
        guard Self.validTime(now), Self.validTime(ticket.observedAt),
              pendingPointer == nil, !draggingSlider,
              ticket.revision == revision, now >= blockedUntil else { return false }
        let elapsed = now - ticket.observedAt
        return elapsed.isFinite && elapsed >= Self.confirmationDelay
    }
    private static func validTime(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }
}

/// The native event callback only records provenance here. UI cancellation and
/// audio writes remain with the existing controllers on their own execution path.
final class HeadsetVolumeSourceGuard {
    static let shared = HeadsetVolumeSourceGuard()
    static let confirmationDelay = HeadsetVolumeSourceGate.confirmationDelay
    static let pointerVerificationBudget = HeadsetVolumeSourceGate.pointerVerificationBudget
    static let maximumPointerWait = HeadsetVolumeSourceGate.maximumPointerWait
    private let lock = NSLock()
    private var gate = HeadsetVolumeSourceGate()
    var checkingPointer: Bool {
        lock.lock(); defer { lock.unlock() }
        return gate.checkingPointer
    }
    func pointerVolumeActive(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gate.pointerVolumeActive(now: now)
    }

    func beginPointer(now: Double = ProcessInfo.processInfo.systemUptime) -> HeadsetVolumeSourceGate.PointerTicket? {
        lock.lock(); defer { lock.unlock() }
        return gate.beginPointer(now: now)
    }
    @discardableResult func resolvePointer(_ ticket: HeadsetVolumeSourceGate.PointerTicket, slider: Bool,
                                          now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gate.resolvePointer(ticket, slider: slider, now: now)
    }
    func endPointer(now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        gate.endPointer(now: now)
    }

    func exclude(now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        gate.exclude(now: now)
    }
    func ticket(now: Double = ProcessInfo.processInfo.systemUptime) -> HeadsetVolumeSourceGate.Ticket? {
        lock.lock(); defer { lock.unlock() }
        return gate.ticket(now: now)
    }
    func allows(_ ticket: HeadsetVolumeSourceGate.Ticket, now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gate.allows(ticket, now: now)
    }
}
