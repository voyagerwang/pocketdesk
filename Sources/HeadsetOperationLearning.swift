import Foundation

/// Detection has no execution or persistence side effects. A result describes the
/// signal the computer actually received, rather than a physical left/right ear.
struct HeadsetLearnedOperation: Equatable {
    let signal: HeadsetSignal
    let gesture: HeadsetRule.Gesture
    var title: String { signal.kind == .volume ? signal.label : signal.label + " · " + gesture.label }
}

struct HeadsetOperationLearning {
    enum Update: Equatable {
        case pressed
        case holding
        case mismatch(HeadsetRule.Gesture)
        case recognized(HeadsetLearnedOperation)
    }
    let expected: HeadsetRule.Gesture?
    private var machines: [String: HeadsetGesture] = [:]
    private var signals: [String: HeadsetSignal] = [:]
    private var holds: Set<String> = []
    init(expected: HeadsetRule.Gesture? = nil) { self.expected = expected }
    static func supports(_ gesture: HeadsetRule.Gesture, device: HeadsetSignal) -> Bool {
        if device.kind == .volume { return gesture == .click }
        return gesture != .doubleClick || device.vendor != 31 || device.product != 2849
    }
    mutating func edge(_ signal: HeadsetSignal, down: Bool, now: Double) -> [Update] {
        guard signal.valid, signal.kind == .hid else { return [] }
        signals[signal.identity] = signal
        var machine = machines[signal.identity] ?? HeadsetGesture()
        let events = machine.edge(down: down, now: now, doubleEnabled: Self.supports(.doubleClick, device: signal), holdEnabled: true)
        machines[signal.identity] = machine
        var updates = translate(events, signal: signal)
        if down && updates.isEmpty { updates.append(.pressed) }
        return updates
    }
    mutating func tick(now: Double) -> [Update] {
        var updates: [Update] = []
        for id in machines.keys.sorted() {
            guard let signal = signals[id], var machine = machines[id] else { continue }
            let events = machine.tick(now: now, doubleEnabled: Self.supports(.doubleClick, device: signal), holdEnabled: true)
            machines[id] = machine; updates += translate(events, signal: signal)
        }
        return updates
    }
    func volume(_ signal: HeadsetSignal) -> Update? {
        guard signal.valid, signal.kind == .volume else { return nil }
        return result(signal, gesture: .click)
    }
    private func result(_ signal: HeadsetSignal, gesture: HeadsetRule.Gesture) -> Update {
        if let expected, expected != gesture { return .mismatch(gesture) }
        return .recognized(.init(signal: signal, gesture: gesture))
    }
    private mutating func translate(_ events: [HeadsetGesture.Event], signal: HeadsetSignal) -> [Update] {
        events.compactMap { event in
            switch event {
            case .click: return result(signal, gesture: .click)
            case .doubleClick: return result(signal, gesture: .doubleClick)
            case .holdBegin: holds.insert(signal.identity); return .holding
            case .holdEnd:
                guard holds.remove(signal.identity) != nil else { return nil }
                return result(signal, gesture: .hold)
            }
        }
    }
}
