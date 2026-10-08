import Foundation

/// Recognizes a calibrated volume step and suppresses our own restoration echo.
struct HeadsetClickGate {
    enum Side { case left, right }
    let baseline: Float
    let step: Float
    private(set) var restoring = false
    private var restoreDeadline = 0.0
    private var eligibleAt = 0.0
    private(set) var failed = false
    init(baseline: Float, step: Float) { self.baseline = baseline; self.step = step }
    mutating func observe(_ volume: Float, now: Double) -> Side? {
        guard !failed, volume.isFinite else { return nil }
        if restoring {
            if abs(volume - baseline) < 0.004 { restoring = false }
            else if now >= restoreDeadline { failed = true }
            return nil
        }
        guard now >= eligibleAt else { return nil }
        let delta = volume - baseline
        guard abs(delta) >= 0.004 else { return nil }
        // Arbitrary slider jumps are not interpreted as clicks.
        guard abs(abs(delta) - step) < 0.008 else { failed = true; return nil }
        restoring = true; restoreDeadline = now + 1.5; eligibleAt = now + 0.6
        return delta > 0 ? .right : .left
    }
}
