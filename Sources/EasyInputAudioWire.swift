/**
 * [INPUT]: EasyInput 0.1.33 的 EIBC 控制与 EIBA/IMA ADPCM 帧合同，固定会话及单调包序。
 * [OUTPUT]: 20字节会话控制包、严格验证后的160样本单声道PCM；错会话/截断/重复/倒序拒绝。
 * [POS]: EasyInput 蓝牙适配的纯协议层；不发现设备、不录音、不执行指令，独立于系统蓝牙与语音权限。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum EasyInputAudioWire {
    static let sampleRate = 16000.0
    static let steps = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    static let indexes = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8]
    static func number(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | (UInt64(bytes[offset + $1]) << ($1 * 8)) }
    }
    static func control(action: UInt8, session: UInt64, sequence: UInt32) -> Data? {
        guard (1...3).contains(action), session != 0 else { return nil }
        var bytes = Array("EIBC".utf8) + [1, action, 1, 0]
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: session >> ($0 * 8)) }
        bytes += (0..<4).map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) }
        return Data(bytes)
    }
    struct Frame { let sequence: UInt32; let samples: [Float] }
    static func decode(_ data: Data, session: UInt64) -> Frame? {
        let b = [UInt8](data)
        guard b.count == 112, Array(b[0..<4]) == Array("EIBA".utf8), b[4...7].elementsEqual([1,28,1,1]),
              session != 0, number(b,8,8) == session, number(b,24,2) == 160,
              number(b,26,2) == 84, b[30] <= 88, b[31] == 0 else { return nil }
        var predictor = Int(Int16(bitPattern: UInt16(number(b,28,2)))), index = Int(b[30])
        var pcm = [Float(predictor) / 32768]
        for n in 0..<159 {
            let byte = Int(b[32 + n / 2]), nibble = n % 2 == 0 ? byte & 15 : byte >> 4
            let step = steps[index]
            var diff = step >> 3
            if nibble & 1 != 0 { diff += step >> 2 }
            if nibble & 2 != 0 { diff += step >> 1 }
            if nibble & 4 != 0 { diff += step }
            predictor = min(32767, max(-32768, predictor + (nibble & 8 == 0 ? diff : -diff)))
            index = min(88, max(0, index + indexes[nibble])); pcm.append(Float(predictor) / 32768)
        }
        return Frame(sequence: UInt32(number(b,16,4)), samples: pcm)
    }
    struct SequenceGate {
        var last: UInt32?
        mutating func accept(_ next: UInt32) -> Bool {
            if let last { let delta = next &- last; guard delta > 0, delta < 0x80000000 else { return false } }
            last = next; return true
        }
    }
}
