/** [INPUT]: 单设备按下/松开与单调时钟。[OUTPUT]: 互斥的单击、双击和长按开始/结束。[POS]: 纯手势状态机。[PROTOCOL]: 同步 Sources/CLAUDE.md。 */
import Foundation

struct HeadsetGesture {
    static let doubleInterval = 0.38
    enum Event: Equatable { case click, doubleClick, holdBegin, holdEnd }
    private var downAt: Double?
    private var releasedAt: Double?
    private var holding = false
    private var second = false
    mutating func edge(down: Bool, now: Double, doubleEnabled: Bool, holdEnabled: Bool) -> [Event] {
        var result = tick(now: now, doubleEnabled: doubleEnabled, holdEnabled: holdEnabled)
        if down {
            guard downAt == nil else { return result }
            second = releasedAt.map { now - $0 <= Self.doubleInterval } ?? false
            if second { releasedAt = nil }
            downAt = now
        } else {
            guard let start = downAt else { return result }
            downAt = nil
            if holding { holding = false; second = false; result.append(.holdEnd) }
            else if second { second = false; result.append(.doubleClick) }
            else if now - start < 0.7 || !holdEnabled {
                if doubleEnabled { releasedAt = now } else { result.append(.click) }
            }
        }
        return result
    }
    mutating func tick(now: Double, doubleEnabled: Bool, holdEnabled: Bool) -> [Event] {
        if let downAt, holdEnabled, !holding, now - downAt >= 0.7 { holding = true; releasedAt = nil; return [.holdBegin] }
        if let releasedAt, downAt == nil, now - releasedAt > Self.doubleInterval { self.releasedAt = nil; return [.click] }
        return []
    }
    mutating func cancel() { self = HeadsetGesture() }
}

/// Volume notifications have discrete steps but no release edge. Only pair two
/// observed steps; never infer a held key from repeated volume changes.
struct HeadsetTapGesture {
    private var pendingAt: Double?
    var hasPending: Bool { pendingAt != nil }
    mutating func tap(now: Double, doubleEnabled: Bool) -> [HeadsetGesture.Event] {
        guard now.isFinite else { return [] }
        var result = tick(now: now)
        if !doubleEnabled { result += finishPending(); result.append(.click); return result }
        if let pendingAt, now >= pendingAt, now - pendingAt <= HeadsetGesture.doubleInterval {
            self.pendingAt = nil; result.append(.doubleClick)
        } else { pendingAt = now }
        return result
    }
    mutating func tick(now: Double) -> [HeadsetGesture.Event] {
        guard let pendingAt, now.isFinite, now - pendingAt > HeadsetGesture.doubleInterval else { return [] }
        return finishPending()
    }
    mutating func finishPending() -> [HeadsetGesture.Event] {
        guard pendingAt != nil else { return [] }
        pendingAt = nil; return [.click]
    }
    mutating func cancel() { pendingAt = nil }
}

/// The known AB13X reports a held key as repeated down/up pulses. Collapse only
/// this verified device path; arbitrary headsets retain genuine edge semantics.
struct HeadsetPulse {
    private var pressed = false
    private var releaseAt: Double?
    mutating func edge(down: Bool, now: Double) -> [Bool] {
        if down { releaseAt = nil; if !pressed { pressed = true; return [true] } }
        else if pressed { releaseAt = now + 0.3 }
        return []
    }
    mutating func tick(now: Double) -> [Bool] {
        if let releaseAt, now >= releaseAt { self.releaseAt = nil; pressed = false; return [false] }
        return []
    }
}
