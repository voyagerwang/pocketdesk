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
}

/// CoreAudio reports the output volume, not the input that changed it. Delay
/// attribution briefly so a keyboard or slider exclusion can veto the change.
struct HeadsetVolumeSourceGate {
    static let confirmationDelay = 0.08
    private static let exclusionInterval = 0.8
    struct Ticket: Equatable {
        let revision: Int
        let observedAt: Double
    }
    private var blockedUntil = 0.0
    private var revision = 0

    mutating func exclude(now: Double) {
        guard Self.validTime(now) else { return }
        revision &+= 1
        blockedUntil = max(blockedUntil, now + Self.exclusionInterval)
    }
    func ticket(now: Double) -> Ticket? {
        guard Self.validTime(now), now >= blockedUntil else { return nil }
        return Ticket(revision: revision, observedAt: now)
    }
    func allows(_ ticket: Ticket, now: Double) -> Bool {
        guard Self.validTime(now), Self.validTime(ticket.observedAt),
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
    private let lock = NSLock()
    private var gate = HeadsetVolumeSourceGate()

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
