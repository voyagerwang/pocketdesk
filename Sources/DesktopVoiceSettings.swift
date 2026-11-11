/**
 * [INPUT]: 本机控制台显式配置及私有 Application Support 文件；不读取第三方账号或Wi-Fi凭据。
 * [OUTPUT]: 当前草稿及旧输入队列各携稳定票据；旧单槽兼容迁移且不覆盖更早内容；小E、应答、音色、锁屏、连续对话和设备绑定的私有原子存储。
 * [POS]: 自动语音的配置边界；旧声纹字段解码时忽略；损坏文件不自动启用，设备缺失不替换为系统麦克风。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

struct DesktopVoiceSettings: Codable {
    var enabled = false
    var wakeWord = "小E"
    var allowLocked = true
    var peripheralID: String? = nil
    /// 唤醒应答：听到唤醒词后先回一句再收音；多句用「|」分隔，每句短一点，会轮换着说。
    var ackEnabled = true
    var ackPhrase = "嗯，我在|在呢|哎，听着呢|嗯？你说"
    /// 控制台选定的系统音色标识；为空时自动选本机质量最高的中文音色。
    var voiceIdentifier: String? = nil
    /// 正文转写交给豆包输入法的系统 ASR：它只能听系统默认输入设备，所以这条模式下不再用蓝牙键盘取音，
    /// 本地识别并行听作为兜底。关掉则整轮完全用本机识别（可继续用 EasyInput 键盘麦克风）。
    var dictationEnabled = true
    /// 音色来源：neural 走本机神经音色桥（真人感），system 只用 macOS 自带音色。
    var ttsEngine = "neural"
    /// 神经音色代号，例如 zh-CN-XiaoxiaoNeural。
    var ttsVoice: String? = "zh-CN-XiaoxiaoNeural"
    /// 基准语速（百分比，正数更快）；实际播报会在它上下浮动 2%。
    var ttsRate = 4
    /// 连续对话：办完一件事后麦克风再留几秒，接着说下一件不用重喊名字；锁屏时始终不开。
    var followUpEnabled = true
    var usesNeural: Bool { ttsEngine == "neural" }
    static var directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/VoiceDeck/voice")
    static var file: URL { directory.appendingPathComponent("settings.json") }
    static var draftFile: URL { directory.appendingPathComponent("draft.json") }
    static var parkedFile: URL { directory.appendingPathComponent("parked.json") }
    static var historyFile: URL { directory.appendingPathComponent("parked-history.json") }
    static func load() -> DesktopVoiceSettings {
        guard let settings = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: file)),
              valid(wake: settings.wakeWord), valid(ack: settings.ackPhrase), valid(tts: settings),
              settings.peripheralID == nil || UUID(uuidString: settings.peripheralID!) != nil else { return Self() }
        return settings
    }
    static func valid(wake: String) -> Bool {
        !wake.isEmpty && wake.count <= 8 && wake.unicodeScalars.allSatisfy { CharacterSet.letters.union(.decimalDigits).contains($0) }
    }
    /// 应答池：单句 16 字以内，整体 120 字以内，不许换行；「|」分段，空段当作没写。
    static func valid(ack: String) -> Bool {
        ack.count <= 120 && !ack.contains(where: { $0 == "\n" || $0 == "\r" })
            && pool(ack).allSatisfy { !$0.isEmpty && $0.count <= 16 }
    }
    static func pool(_ ack: String) -> [String] {
        ack.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func valid(voice identifier: String) -> Bool {
        identifier.isEmpty || (identifier.count <= 128 && identifier.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0)
        })
    }
    static func valid(tts settings: DesktopVoiceSettings) -> Bool {
        guard ["neural", "system"].contains(settings.ttsEngine), (-25...25).contains(settings.ttsRate) else { return false }
        return valid(voice: settings.ttsVoice ?? "")
    }
    func save() throws {
        guard Self.valid(wake: wakeWord), Self.valid(ack: ackPhrase), Self.valid(tts: self),
              Self.valid(voice: voiceIdentifier ?? ""),
              peripheralID == nil || UUID(uuidString: peripheralID!) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        try Self.write(JSONEncoder().encode(self), to: Self.file)
    }
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    struct Draft: Codable { let requestID: String; let text: String }
    static func draftRecord() -> Draft? { try? JSONDecoder().decode(Draft.self, from: Data(contentsOf: draftFile)) }
    static var draftIsCorrupt: Bool { FileManager.default.fileExists(atPath: draftFile.path) && draftRecord() == nil }
    static func draft() -> String { draftRecord()?.text ?? "" }
    static func draftRequestID() -> String? { draftRecord()?.requestID }
    static func saveDraft(_ text: String) throws {
        let old = draftRecord()
        let record = Draft(requestID: old?.text == text ? old!.requestID : UUID().uuidString, text: text)
        try write(JSONEncoder().encode(record), to: draftFile)
    }
    /// 较早未发送的一条输入：新一轮收音不再被它堵死，但原文与票据都保留，仍可幂等发送。
    static func parkedRecords() throws -> [Draft] {
        if FileManager.default.fileExists(atPath: historyFile.path) {
            let data = try Data(contentsOf: historyFile)
            guard data.count <= 2_097_152 else { throw CocoaError(.fileReadTooLarge) }
            let records = try JSONDecoder().decode([Draft].self, from: data)
            guard Set(records.map(\.requestID)).count == records.count else { throw CocoaError(.fileReadCorruptFile) }
            return records
        }
        if FileManager.default.fileExists(atPath: parkedFile.path) {
            return [try JSONDecoder().decode(Draft.self, from: Data(contentsOf: parkedFile))]
        }
        return []
    }
    static func parkedRecord() -> Draft? { try? parkedRecords().first }
    static var parkedIsCorrupt: Bool { (try? parkedRecords()) == nil }
    static func parked() -> String { parkedRecord()?.text ?? "" }
    static func saveParked(_ record: Draft?) throws {
        var records = try parkedRecords()
        if let record {
            if let old = records.first(where: { $0.requestID == record.requestID }) {
                guard old.text == record.text else { throw CocoaError(.fileWriteInvalidFileName) }
            } else { records.insert(record, at: 0) }
        } else if !records.isEmpty { records.removeFirst() }
        let encoded = try JSONEncoder().encode(records)
        guard encoded.count <= 2_097_152 else { throw CocoaError(.fileWriteOutOfSpace) }
        // 先原子发布队列；旧文件即使清理失败也只是备份，读取只认已发布队列。
        try write(encoded, to: historyFile)
        if FileManager.default.fileExists(atPath: parkedFile.path) {
            try? FileManager.default.removeItem(at: parkedFile)
        }
    }
}

extension DesktopVoiceSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, wakeWord, allowLocked, peripheralID, ackEnabled, ackPhrase, voiceIdentifier, ttsEngine, ttsVoice, ttsRate, dictationEnabled, followUpEnabled
    }
    // 旧配置文件缺字段时按默认值补齐，不能因为新增设置就整份回落到默认并静默关掉监听。
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        enabled = try box.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        wakeWord = try box.decodeIfPresent(String.self, forKey: .wakeWord) ?? wakeWord
        allowLocked = try box.decodeIfPresent(Bool.self, forKey: .allowLocked) ?? allowLocked
        peripheralID = try box.decodeIfPresent(String.self, forKey: .peripheralID)
        ackEnabled = try box.decodeIfPresent(Bool.self, forKey: .ackEnabled) ?? ackEnabled
        ackPhrase = try box.decodeIfPresent(String.self, forKey: .ackPhrase) ?? ackPhrase
        voiceIdentifier = try box.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        ttsEngine = try box.decodeIfPresent(String.self, forKey: .ttsEngine) ?? ttsEngine
        ttsVoice = try box.decodeIfPresent(String.self, forKey: .ttsVoice) ?? ttsVoice
        ttsRate = try box.decodeIfPresent(Int.self, forKey: .ttsRate) ?? ttsRate
        dictationEnabled = try box.decodeIfPresent(Bool.self, forKey: .dictationEnabled) ?? dictationEnabled
        followUpEnabled = try box.decodeIfPresent(Bool.self, forKey: .followUpEnabled) ?? followUpEnabled
    }
}
