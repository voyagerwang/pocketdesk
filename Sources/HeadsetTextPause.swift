import Foundation

/// A user-selected text inactivity heuristic, never a claim of acoustic silence
/// or a final recognition result. Ending recording still uses the normal finalization gate.
struct HeadsetTextPause {
    private let original: String
    private let delay: Double
    private var latest: String
    private var changedAt: Double?
    init(original: String, delay: Double = 3) {
        precondition(delay.isFinite && delay > 0)
        self.original = original; self.delay = delay; latest = original
    }
    mutating func remaining(text: String, now: Double) -> Double? {
        if text != latest { latest = text; changedAt = now }
        guard let changedAt, text != original, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return max(0, delay - max(0, now - changedAt))
    }
}
