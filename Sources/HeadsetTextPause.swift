/**
 * [INPUT]: 依赖录音前原文、实时转写、单调时钟与用户选择的等待秒数。
 * [OUTPUT]: 提供非空新增转写的停顿剩余时间；文字变化或可观察性中断后重算，原文/空文不触发。
 * [POS]: Sources 的纯语音结束策略；默认与自定义操作共用，不负责最终转写或发送。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
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
        if text != latest || changedAt == nil { latest = text; changedAt = now }
        guard let changedAt, text != original, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return max(0, delay - max(0, now - changedAt))
    }
    mutating func suspend() { changedAt = nil }
}
