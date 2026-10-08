import Foundation

enum HeadsetVoiceTiming {
    static let maxRecordingSeconds: TimeInterval = 10 * 60
    // Keep the send session alive while final text arrives and the send delay runs.
    static let maxSendSessionSeconds: TimeInterval = maxRecordingSeconds + 30
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
