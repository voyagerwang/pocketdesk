import Foundation

enum HeadsetFinishMode: String, Codable {
    case manual
    case textPause
}

struct HeadsetClickPreference: Codable, Equatable {
    let uid: String
    var name: String
    var enabled: Bool
    var step: Float?
    var finishMode: HeadsetFinishMode? = nil
    var textPauseSeconds: Double? = nil
    var effectiveFinishMode: HeadsetFinishMode { finishMode ?? .manual }
    var effectiveTextPauseSeconds: Double { textPauseSeconds ?? 3 }
    var textPauseLabel: String { String(format: "%g", effectiveTextPauseSeconds) }
    static func validPauseSeconds(_ seconds: Double) -> Bool {
        seconds.isFinite && (0.5...30).contains(seconds) && seconds * 2 == (seconds * 2).rounded()
    }
    var valid: Bool { !uid.isEmpty && !name.isEmpty && Self.validPauseSeconds(effectiveTextPauseSeconds) && (step == nil || (step!.isFinite && step! >= 0.015 && step! <= 0.2)) }
}

final class HeadsetClickPreferences {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoiceDeck/headset/click-controls.json")
    static let shared = HeadsetClickPreferences(file: file)
    private let file: URL
    private(set) var all: [HeadsetClickPreference]
    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([HeadsetClickPreference].self, from: data), saved.allSatisfy(\.valid) { all = saved }
        else { all = [] }
    }
    func preference(for uid: String) -> HeadsetClickPreference? { all.first { $0.uid == uid } }
    func save(_ preference: HeadsetClickPreference) throws {
        guard preference.valid else { throw NSError(domain: "PocketDesk.Headset", code: 1, userInfo: [NSLocalizedDescriptionKey: "耳机配置无效"]) }
        var next = all.filter { $0.uid != preference.uid }; next.append(preference)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        all = next
    }
}

struct HeadsetClickCalibration {
    private var previous: Float
    private var firstDelta: Float?
    init(volume: Float) { previous = volume }
    mutating func observe(_ volume: Float) -> Float? {
        let delta = volume - previous; previous = volume
        guard abs(delta) >= 0.015, abs(delta) <= 0.2 else { return nil }
        if let first = firstDelta, first * delta < 0, abs(abs(first) - abs(delta)) < 0.008 {
            return (abs(first) + abs(delta)) / 2
        }
        firstDelta = delta; return nil
    }
}
