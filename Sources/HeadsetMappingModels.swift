/** [INPUT]: Foundation/CoreGraphics 与既有 ShortcutKeys。[OUTPUT]: 耳机信号、规则、快捷键及原子保存。[POS]: 无系统副作用的配置层。[PROTOCOL]: 同步 Sources/CLAUDE.md。 */
import Foundation
import CoreGraphics

struct HeadsetSignal: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case hid, volume }
    var kind: Kind
    var device: String
    var name: String
    var vendor: Int = 0
    var product: Int = 0
    var page: Int = 12
    var usage: Int
    var step: Float? = nil
    var identity: String { "\(kind.rawValue):\(device):\(page):\(usage)" }
    var usesPulsedHold: Bool { kind == .hid && vendor == 31 && product == 2849 && usage == 0xEA }
    var valid: Bool {
        guard !device.isEmpty, !name.isEmpty else { return false }
        if kind == .hid { return vendor > 0 && vendor <= 65535 && product > 0 && product <= 65535 && page == 12 && usage > 0 && usage <= 65535 }
        return [-1, 1].contains(usage) && step.map { $0.isFinite && $0 >= 0.015 && $0 <= 0.2 } == true
    }
    var label: String {
        if kind == .volume { return usage > 0 ? "音量增加" : "音量减少" }
        return [0xCD: "播放 / 暂停", 0xE9: "音量增加", 0xEA: "音量减少", 0xB5: "下一曲", 0xB6: "上一曲", 0xE2: "静音"][usage] ?? "按键 \(String(usage, radix: 16).uppercased())"
    }
}

struct HeadsetKey: Codable, Equatable {
    var code: UInt16
    var flags: UInt64
    var modifier: Bool
    var label: String
    var valid: Bool { code <= 127 && !label.isEmpty && flags & ~Self.allowedFlags == 0 && modifier == Self.modifiers.contains(code) }
    static let modifiers: Set<UInt16> = [54,55,56,58,59,60,61,62]
    static let allowedFlags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue
    static func parse(_ value: String) -> HeadsetKey? {
        let single: [String: (UInt16, CGEventFlags)] = ["leftoption":(58,.maskAlternate),"option":(58,.maskAlternate),"opt":(58,.maskAlternate),"rightoption":(61,.maskAlternate),"leftcommand":(55,.maskCommand),"rightcommand":(54,.maskCommand),"leftshift":(56,.maskShift),"rightshift":(60,.maskShift),"leftcontrol":(59,.maskControl),"rightcontrol":(62,.maskControl)]
        if let (code, flags) = single[ShortcutKeys.normalize(value)] { return .init(code: code, flags: flags.rawValue, modifier: true, label: value) }
        guard let key = ShortcutKeys.resolve(value) else { return nil }
        return .init(code: key.keycode, flags: key.flags.rawValue, modifier: false, label: ShortcutKeys.canonicalize(value))
    }
}

struct HeadsetRule: Codable, Equatable {
    enum Gesture: String, Codable, CaseIterable { case click, doubleClick, hold
        var label: String { self == .click ? "单击" : self == .doubleClick ? "双击" : "长按" }
    }
    enum Action: String, Codable, CaseIterable { case hotkey, openApp, spriteWake, spriteVoice, voice, spriteEnd, cancel, disabled
        var label: String {
            switch self { case .hotkey:return "按键 / 快捷键"; case .openApp:return "打开本机应用"; case .spriteWake:return "唤醒小精灵"; case .spriteVoice:return "小精灵并开始语音"; case .voice:return "当前输入框语音"; case .spriteEnd:return "结束小精灵语音并提交"; case .cancel:return "取消当前操作"; case .disabled:return "禁用此操作" }
        }
    }
    var id: String = UUID().uuidString
    var signal: HeadsetSignal
    var gesture: Gesture
    var action: Action
    var key: HeadsetKey? = nil
    var appPath: String? = nil
    var scope: String? = nil
    var enabled: Bool = true
    var holdsKey: Bool = false
    var voiceToggle: Bool = false
    var valid: Bool {
        guard !id.isEmpty, signal.valid, HeadsetOperationLearning.supports(gesture, device: signal) else { return false }
        guard scope == nil || scope?.isEmpty == false else { return false }
        if [.hotkey,.spriteVoice,.voice].contains(action), key?.valid != true { return false }
        if action == .openApp, appPath.map({ $0.hasPrefix("/") && $0.hasSuffix(".app") }) != true { return false }
        return !holdsKey || action == .hotkey && gesture == .hold
    }
}

final class HeadsetRuleStore {
    static let shared = HeadsetRuleStore(file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VoiceDeck/headset/operation-rules.json"))
    let file: URL
    private let lock = NSLock()
    private var savedRules: [HeadsetRule] = []
    private(set) var loadIssue: String?
    var rules: [HeadsetRule] { lock.lock(); defer { lock.unlock() }; return savedRules }
    var changed: (() -> Void)?
    init(file: URL) {
        self.file = file
        if FileManager.default.fileExists(atPath:file.path) {
            do {
                let saved = try JSONDecoder().decode([HeadsetRule].self,from:Data(contentsOf:file))
                guard saved.allSatisfy(\.valid), Set(saved.map(\.id)).count == saved.count else { throw NSError(domain:"HeadsetMapping",code:4) }
                savedRules = saved
            } catch { loadIssue = "操作配置无法读取，原文件已保留。请恢复有效配置后重新打开应用。" }
        }
    }
    func save(_ rule: HeadsetRule) throws {
        guard rule.valid else { throw NSError(domain: "HeadsetMapping", code: 1, userInfo: [NSLocalizedDescriptionKey:"操作配置无效，请先完成检测和功能设置。"]) }
        guard !rules.contains(where: { $0.id != rule.id && $0.enabled && rule.enabled && $0.signal.identity == rule.signal.identity && $0.gesture == rule.gesture && $0.scope == rule.scope }) else { throw NSError(domain: "HeadsetMapping", code: 2, userInfo: [NSLocalizedDescriptionKey:"同一操作已配置，请编辑已有规则或选择另一作用应用。 "]) }
        if rule.signal.kind == .volume, rule.enabled, rules.contains(where: { $0.id != rule.id && $0.enabled && $0.signal.kind == .volume && $0.signal.device == rule.signal.device && abs(($0.signal.step ?? 0) - (rule.signal.step ?? 0)) >= 0.008 }) {
            throw NSError(domain:"HeadsetMapping",code:3,userInfo:[NSLocalizedDescriptionKey:"同一设备的音量步长不一致，请重新检测已有操作。"])
        }
        try persist(rules.filter { $0.id != rule.id } + [rule])
    }
    func remove(_ id: String) throws { try persist(rules.filter { $0.id != id }) }
    func matching(_ signal: HeadsetSignal, gesture: HeadsetRule.Gesture, app: String?) -> HeadsetRule? {
        let list = rules.filter { $0.enabled && $0.signal.identity == signal.identity && $0.gesture == gesture && ($0.scope == nil || $0.scope == app) }
        return list.first { $0.scope != nil } ?? list.first
    }
    func controls(_ signal: HeadsetSignal) -> Bool { rules.contains { $0.enabled && $0.signal.identity == signal.identity } }
    func controlsHID(vendor: Int, product: Int, usage: Int, serial: String? = nil) -> Bool { rules.contains { $0.enabled && $0.signal.kind == .hid && $0.signal.device == "\(vendor):\(product):\(serial ?? "model")" && $0.signal.usage == usage } }
    private func persist(_ next: [HeadsetRule]) throws {
        if let loadIssue { throw NSError(domain:"HeadsetMapping",code:4,userInfo:[NSLocalizedDescriptionKey:loadIssue]) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        lock.lock(); savedRules = next; lock.unlock(); changed?()
    }
}
