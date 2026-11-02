/**
 * [INPUT]: 控制台的音色/语速设置、本机神经音色桥（DesktopVoiceTTS）与系统已安装的中文音色（AVSpeechSynthesisVoice）。
 * [OUTPUT]: 异步神经音色与有界逐项淘汰缓存；新唤醒取消后迟到音频不播，失败才用系统音色，不阻塞主线程等待云端。
 * [POS]: 小E唯一发声出口；不朗读任务原文；DesktopVoice播报期间仅接受新唤醒，打断与声学回采隔离由协调器负责。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AVFoundation
import Foundation

final class DesktopVoiceSpeech {
    struct Voice { let identifier: String; let name: String; let quality: Int }

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private var generation = 0
    private var preparing = false
    private static let cacheLimit = 64
    private var rendering = Set<String>()
    private let renderQueue = DispatchQueue(label: "pocketdesk.voice.speech")
    /// 取音频单独走并发队列：renderQueue 是串行的，若再往它身上派活并同步等待，会把自己锁死。
    private let networkQueue = DispatchQueue(label: "pocketdesk.voice.speech.net", attributes: .concurrent)
    private(set) var lastError = ""
    private var settingsCache: DesktopVoiceSettings?
    #if DESKTOP_VOICE_TEST
    var testReady: Bool?
    var testAudio: ((String, String, String, String) -> Data?)?
    var testPlay: ((Data) -> TimeInterval)?
    #endif
    private var ready: Bool {
        #if DESKTOP_VOICE_TEST
        if let testReady { return testReady }
        #endif
        return DesktopVoiceTTS.ready
    }
    private func requestAudio(_ text: String, voice: String, rate: String, pitch: String) -> Data? {
        #if DESKTOP_VOICE_TEST
        if let testAudio { return testAudio(text, voice, rate, pitch) }
        #endif
        return DesktopVoiceTTS.audio(text, voice: voice, rate: rate, pitch: pitch)
    }

    private func config() -> DesktopVoiceSettings {
        if let settingsCache { return settingsCache }
        let loaded = DesktopVoiceSettings.load()
        settingsCache = loaded
        return loaded
    }

    /// 配置改了之后重新取一次；内存里已渲染的句子按「音色+语速+文本」作键，不需要清空。
    func reload() {
        settingsCache = nil
        cachedVoice = nil
    }

    // MARK: - 音色清单

    /// 系统已安装的中文音色，质量优先、同名时女声优先；同名不同地区只保留一份（zh-CN 优先）。不会安装或下载任何音色。
    static func installed() -> [Voice] {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        let ordered = all.sorted { a, b in
            if a.language == b.language {
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
            return a.language < b.language
        }
        var seen = Set<String>()
        return ordered.compactMap { voice in
            // 同名音色在 zh-CN / zh-TW 各有一份，只保留中文大陆那一份，下拉里不出现两条一样的名字。
            guard seen.insert(voice.name).inserted else { return nil }
            return Voice(identifier: voice.identifier, name: voice.name, quality: voice.quality.rawValue)
        }
        .sorted { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            return a.name < b.name
        }
    }

    /// 控制台下拉：神经音色排在前面，系统音色跟在后面兜底。
    static func allVoices() -> [[String: Any]] {
        let neural = DesktopVoiceTTS.voices().compactMap { entry -> [String: Any]? in
            guard let id = entry["id"] as? String else { return nil }
            return ["id": id, "name": entry["name"] as? String ?? id,
                    "hint": entry["hint"] as? String ?? "", "quality": 3, "kind": "neural"]
        }
        let system = installed().map { voice in
            ["id": voice.identifier, "name": voice.name, "hint": voice.quality > 1 ? "高级" : "紧凑",
             "quality": voice.quality, "kind": "system"] as [String: Any]
        }
        return neural + system
    }

    static func resolve(_ preferred: String?) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        if let preferred, let picked = all.first(where: { $0.identifier == preferred }) { return picked }
        let mainland = all.filter { $0.language == "zh-CN" }
        return (mainland.isEmpty ? all : mainland).max { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue < b.quality.rawValue }
            return preference(a) < preference(b)
        }
    }
    private static func preference(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = voice.gender == .female ? 2 : 1
        if voice.name.localizedCaseInsensitiveContains("Tingting") || voice.name.contains("婷婷") { score += 10 }
        return score
    }

    private var cachedVoice: (identifier: String?, voice: AVSpeechSynthesisVoice?)?

    /// 系统音色在播报路径上只解析一次；音色改了自然失效，不在每次应答时碰磁盘。
    private func currentVoice() -> AVSpeechSynthesisVoice? {
        let identifier = config().voiceIdentifier
        if let cachedVoice, cachedVoice.identifier == identifier { return cachedVoice.voice }
        let voice = Self.resolve(identifier)
        cachedVoice = (identifier, voice)
        return voice
    }

    var isSpeaking: Bool { preparing || (player?.isPlaying ?? false) || synthesizer.isSpeaking }

    /// 只读诊断：不包含正文，只有计数与错误。
    var diagnostics: [String: Any] {
        ["cached": cache.count, "pending": rendering.count, "ready": DesktopVoiceTTS.ready,
         "lastError": lastError, "engine": config().ttsEngine, "voice": config().ttsVoice ?? "",
         "script": DesktopVoiceTTS.scriptPath ?? "", "bridge": DesktopVoiceTTS.lastError]
    }

    /// 已渲染短句的音频数据；本地核对音色时读取缓存，不影响生产播报。
    func rendered(_ text: String) -> Data? { cache[Self.key(text, config: config())] }

    // MARK: - 播报

    /// 预渲染：把固定短句先合成进内存缓存，唤醒应答因此没有合成等待。
    func prewarm(_ text: String) { render(text) }

    /// 播报一句；返回预计时长供调用方静默麦克风。命中缓存时立即出声。
    @discardableResult
    func say(_ text: String) -> TimeInterval {
        let trimmed = Self.text(text)
        guard !trimmed.isEmpty else { return 0 }
        let settings = config()
        let key = Self.key(trimmed, config: settings)
        stop()
        if let data = cache[key] { touch(key); return play(data) }
        if settings.usesNeural && ready {
            preparing = true
            let expected = generation
            networkQueue.async { [weak self] in
                guard let self else { return }
                let prosody = Self.prosody(trimmed, settings: settings)
                let data = self.requestAudio(trimmed, voice: settings.ttsVoice ?? "zh-CN-XiaoxiaoNeural", rate: prosody.rate, pitch: prosody.pitch)
                DispatchQueue.main.async {
                    if let data { self.store(data, key: key) }
                    guard self.generation == expected else { return }
                    self.preparing = false
                    if let data { self.lastError = ""; _ = self.play(data) }
                    else { self.lastError = "神经音色暂不可用，已使用本机音色"; _ = self.speak(trimmed, settings: settings) }
                }
            }
            return Self.estimate(trimmed)
        }
        // 神经音色没就绪：先让系统音色顶上，同时后台把那句合成好，下次就是她的声音。
        render(trimmed)
        return speak(trimmed, settings: settings)
    }

    func stop() {
        generation += 1; preparing = false
        player?.stop(); player = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private static func text(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    }
    private func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
    }
    private func store(_ data: Data, key: String) {
        cache[key] = data; touch(key)
        while cacheOrder.count > Self.cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    /// 缓存键包含音色与韵律档位：换了音色不会播到别的嗓音。
    private static func key(_ text: String, config: DesktopVoiceSettings) -> String {
        let voice = config.usesNeural ? (config.ttsVoice ?? "zh-CN-XiaoxiaoNeural") : (config.voiceIdentifier ?? "system")
        return "\(voice)|\(config.ttsRate)|\(text)"
    }

    // MARK: - 韵律：同一句话每次不完全一样，才不像播报

    /// 每句话固定微调一点，重启后依然一致；短句快一点，长句慢一点。
    /// 语速在基准上下浮动 2%，音高浮动 3Hz——同一句话不会每次一模一样，但也不会飘。
    private static func prosody(_ text: String, settings: DesktopVoiceSettings) -> (rate: String, pitch: String) {
        let seed = text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        var rate = settings.ttsRate + (seed % 5) - 2
        if text.count <= 6 { rate += 2 }
        rate = min(25, max(-25, rate))
        let pitch = (seed / 5 % 7) - 3
        return (rate >= 0 ? "+\(rate)%" : "\(rate)%", pitch >= 0 ? "+\(pitch)Hz" : "\(pitch)Hz")
    }

    private func synthesize(_ text: String, settings: DesktopVoiceSettings, wait: TimeInterval) -> Data? {
        guard ready else { return nil }
        let (rate, pitch) = Self.prosody(text, settings: settings)
        let voice = settings.ttsVoice ?? "zh-CN-XiaoxiaoNeural"
        let done = DispatchSemaphore(value: 0)
        var audio: Data?
        networkQueue.async {
            audio = self.requestAudio(text, voice: voice, rate: rate, pitch: pitch)
            done.signal()
        }
        if wait <= 0 { return nil }
        if done.wait(timeout: .now() + wait) == .timedOut { return nil }
        return audio
    }

    private func utterance(_ text: String, settings: DesktopVoiceSettings) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = currentVoice()
        // 默认语速偏慢，0.95 更接近说话人的自然节奏，同时不牺牲短句的即时感。
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        return utterance
    }

    private func play(_ data: Data) -> TimeInterval {
        #if DESKTOP_VOICE_TEST
        if let testPlay { return testPlay(data) }
        #endif
        do {
            let audio = try AVAudioPlayer(data: data)
            guard audio.prepareToPlay() else { lastError = "音色数据无法播放"; return 0.6 }
            audio.play(); player = audio
            return audio.duration
        } catch {
            lastError = error.localizedDescription
            return 0
        }
    }

    private func speak(_ text: String, settings: DesktopVoiceSettings) -> TimeInterval {
        synthesizer.speak(utterance(text, settings: settings))
        return Self.estimate(text)
    }

    /// 没有缓存时的保守时长估计：中文约每秒 4.6 字，加起播与余音。
    static func estimate(_ text: String) -> TimeInterval {
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard count > 0 else { return 0 }
        return Double(count) / 4.6 + 0.45
    }

    /// 渲染一句进内存缓存：神经音色优先；失败时下次播报自然退回系统音色，不留空白。
    private func render(_ text: String) {
        let trimmed = Self.text(text)
        guard !trimmed.isEmpty else { return }
        let settings = config()
        let key = Self.key(trimmed, config: settings)
        guard cache[key] == nil, !rendering.contains(key) else { return }
        rendering.insert(key)
        renderQueue.async { [weak self] in
            guard let self else { return }
            let data = self.synthesize(trimmed, settings: settings, wait: 12)
            DispatchQueue.main.async {
                self.rendering.remove(key)
                if let data {
                    self.store(data, key: key)
                    self.lastError = ""
                } else if settings.usesNeural {
                    self.lastError = "音色服务不可用，已退回系统音色"
                }
            }
        }
    }
}
