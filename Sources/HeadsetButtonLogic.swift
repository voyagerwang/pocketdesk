/**
 * [INPUT]: 依赖耳机按键边沿、录音结束/面板/焦点/文字观测与发送偏好。
 * [OUTPUT]: 提供按键分类、接收框焦点准备与录音/启动期限、取消探测/重试/确认时序、小精灵接续动作结果、最终转写稳定窗口和发送门禁。
 * [POS]: Sources 的纯耳机判定层；结束拥有者与输入执行者共用时序边界，不注入输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum HeadsetVoiceTiming {
    // 应用激活、原焦点保存和系统 AX 读回共用有界准备期；焦点确认后立即启动。
    static let focusPreparationSeconds: TimeInterval = 3
    static let startupObservationSeconds: TimeInterval = 3
    static let cancellationProbeSeconds: TimeInterval = 0.15
    static let cancellationRetrySeconds: TimeInterval = 0.3
    static let cancellationConfirmationSeconds: TimeInterval = 1
    static let maxRecordingSeconds: TimeInterval = 10 * 60
    // Keep the send session alive while final text arrives and the send delay runs.
    static let maxSendSessionSeconds: TimeInterval = maxRecordingSeconds + 30
    static let finalTextStabilitySeconds: TimeInterval = 0.6
    static func sendWait(delay: Double, immediate: Bool) -> Double {
        immediate ? 0.4 : max(finalTextStabilitySeconds, delay)
    }
}

/// 接收层决定是否开始或结束；耳机拥有者只按结果接管录音，不自行猜测焦点与豆包状态。
enum HeadsetSpriteVoiceAction {
    case unavailable, started, waiting, ended
}

struct HeadsetButtonEdge {
    let time: UInt64
    let down: Bool
    let second: Bool
    let sequence: Int
}
struct HeadsetButtonClassifier {
    var pressed = false
    var pressTime: UInt64 = 0
    var releaseTime: UInt64?
    var second = false
    var sequence = 0
    mutating func edge(down: Bool, time: UInt64) -> HeadsetButtonEdge? {
        guard down != pressed else { return nil }
        pressed = down
        if down {
            second = releaseTime.map { time >= $0 && time - $0 <= 380_000_000 } ?? false
            if !second { sequence += 1 }
            pressTime = time
        } else {
            releaseTime = !second && time >= pressTime && time - pressTime <= 500_000_000 ? time : nil
        }
        return HeadsetButtonEdge(time: time,down:down,second:second,sequence:sequence)
    }
}
struct HeadsetSendGate {
    static func ready(sameFocus: Bool, panelObserved: Bool, panelVisible: Bool, textChanged: Bool,
                      nonempty: Bool, recordingEnded: Bool = true, stableFor: Double, closedFor: Double, delay: Double) -> Bool {
        recordingEnded && sameFocus && panelObserved && !panelVisible && textChanged && nonempty && stableFor >= delay && closedFor >= delay
    }
}

func HeadsetNanoseconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
    let n = UInt64(numer), d = UInt64(denom)
    return (ticks / d) * n + (ticks % d) * n / d
}
