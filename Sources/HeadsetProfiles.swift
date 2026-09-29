import Foundation

struct HeadsetProfile: Codable, Equatable {
    let vendorID: Int
    let productID: Int
    let name: String
    let supportsHold: Bool
    static let quark = HeadsetProfile(vendorID: 13058, productID: 4827, name: "MOONDROP Quark2", supportsHold: true)
    var usesPulsedHold: Bool { vendorID == 31 && productID == 2849 }
    var valid: Bool { vendorID > 0 && vendorID <= 65535 && productID > 0 && productID <= 65535 && !name.isEmpty }
}

final class HeadsetProfiles {
    static let shared = HeadsetProfiles()
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoiceDeck/headset/profiles.json")
    private let lock = NSLock()
    private var profiles: [HeadsetProfile]
    init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([HeadsetProfile].self, from: data), saved.allSatisfy(\.valid) {
            profiles = saved
        } else { profiles = [.quark] }
    }
    var all: [HeadsetProfile] { lock.lock(); defer { lock.unlock() }; return profiles }
    func profile(vendor: Int, product: Int) -> HeadsetProfile? { all.first { $0.vendorID == vendor && $0.productID == product } }
    func save(_ profile: HeadsetProfile) throws {
        guard profile.valid else { throw NSError(domain: "PocketDesk.Headset", code: 1, userInfo: [NSLocalizedDescriptionKey: "耳机设备信息无效"]) }
        lock.lock(); defer { lock.unlock() }
        var next = profiles.filter { $0.vendorID != profile.vendorID || $0.productID != profile.productID }
        next.append(profile)
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: Self.file, options: .atomic)
        profiles = next
    }
}

/// Only paired down/up signals count; repeated down cannot advance the wizard.
struct HeadsetLearning {
    enum Stage: Int { case center, plus, minus, hold, complete }
    private(set) var stage = Stage.center
    private var began: Double?
    private var pulseStart: Double?
    private var lastPulse: Double?
    var acceptsPulsedHold = false
    var expectedUsage: UInt32 { stage == .center ? 0xCD : stage == .plus ? 0xE9 : 0xEA }
    mutating func receive(usage: UInt32, down: Bool, time: Double) -> Bool {
        guard stage != .complete, usage == expectedUsage else { return false }
        if stage == .hold && acceptsPulsedHold {
            if let lastPulse, time - lastPulse > 0.3 { pulseStart = nil }
            if down {
                if pulseStart == nil { pulseStart = time }
                lastPulse = time
            } else if let start = pulseStart {
                lastPulse = time
                if time - start >= 0.7 { stage = .complete; return true }
            }
        }
        if down { if began == nil { began = time }; return false }
        guard let start = began else { return false }
        began = nil
        guard time >= start, stage != .hold || time - start >= 0.7 else { return false }
        stage = Stage(rawValue: stage.rawValue + 1)!
        return true
    }
}
