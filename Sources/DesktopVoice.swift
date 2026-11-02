/**
 * [INPUT]: EasyInputAudio绑定PCM与SystemMicrophoneAudio兜底PCM、本地Speech识别、DesktopVoiceTurn纯规则、唤醒应答发声、豆包接管正文的注入入口与既有任务入口。
 * [OUTPUT]: 唤醒回应与同段转写去重；锁屏也能跑完整任务、需解锁屏幕的工具在工具层拒；只喊名字时把正文交给豆包（只能用系统默认输入设备，本地识别并行听同一段、失败/无字/超时回落本地那份），一口气说完仍走本地；锁屏没有豆包也没有屏幕：识别改用系统云端（失败一次退回本机）、应答只给短提示音不吞后续正文；重喊保留旧输入并重开，播报期间仍可唤醒打断；纯本机模式下键盘优先、断开自动换电脑麦克风、键盘回来自动切回；长停顿自愈、后台任务分别收尾。
 * [POS]: 自动语音生命周期协调器；不注入按键、不解锁电脑、不保存原始音频、不上传待唤醒转写。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import AVFoundation
import Speech

final class DesktopVoice: NSObject {
    static let shared = DesktopVoice()
    private static let lockedSession = UUID().uuidString
    private static let permissionLock = NSLock()
    private static var lockedPermits = Set<String>()
    static func authorizes(_ task: AgentTask) -> Bool {
        permissionLock.lock(); defer { permissionLock.unlock() }
        return task.controlSession == lockedSession && lockedPermits.contains(task.requestId)
    }
    static func lockedTask(_ task: AgentTask) -> Bool { task.controlSession == lockedSession }
    var canWake: () -> Bool = { true }
    var present: (String, String) -> Void = { _, _ in }
    /// 裸的也当补充：接着上一句说的短追问不新开任务，否则“是多少”这种句子模型看不到前文。
    var continueTask: (String, String) throws -> AgentTask = { _, _ in throw CocoaError(.featureUnsupported) }
    /// 收尾时的一句话反馈由装层注入，便于按当前任务结果选词。
    var presentTask: (AgentTask) -> Void = { _ in }
    var submitUnlocked: (String, String) throws -> AgentTask = { _, _ in throw CocoaError(.featureUnsupported) }
    /// 发声出口由装配层注入：返回预计时长，播报期间丢弃麦克风回采。
    var say: (String) -> TimeInterval = { _ in 0 }
    var speaking: () -> Bool = { false }
    var stopSpeaking: () -> Void = {}
    var warm: (String) -> Void = { _ in }
    var voices: () -> [[String: Any]] = { [] }
    /// 发声层的只读诊断：音色服务是否就绪、已经缓存了几句、最后的错误。
    var speechDebug: () -> [String: Any] = { [:] }
    /// 音色或语速改了之后清掉发声层的配置缓存，让下一句立刻用新声音。
    var speechReload: (() -> Void)?
    /// 豆包输入法现在能不能接下正文：装配层接本机安装/启用/选中状态，缺省当作不可用。
    var dictationAvailable: () -> Bool = { false }
    /// 预置接收框并发豆包语音快捷键；返回 false 表示这轮没接上，仍用本地识别。
    var dictationBegin: (() -> Bool)?
    /// 放弃豆包这轮收下的文字；豆包在收音期间被打断时调用。
    var dictationCancel: () -> Void = {}
    /// 豆包是按住说话：本地听出这句说完了就松手收尾，否则它一直收下去。
    var dictationFinishTurn: () -> Void = {}
    /// 接收框里现在有多少字：豆包自己出的字本地不一定听得全，停顿容忍要按两边取大。
    var dictationCharacters: () -> Int = { 0 }
    /// 豆包接管期间本地识别并行的兜底文字，只留不合并进正文。
    private var fallbackText = "", fallbackPrefix = ""
    private(set) var dictationActive = false
    private var dictationAt: TimeInterval = 0
    /// 豆包本该接下这轮但没接时的原因；只在状态行上说一句，不拦本地识别。
    private var dictationHint: String?
    private(set) var settings = DesktopVoiceSettings.load()
    private(set) var status = "未启用"
    private(set) var draft = DesktopVoiceSettings.draft()
    private(set) var parked = DesktopVoiceSettings.parked()
    private let audio = EasyInputAudio()
    /// 键盘未连接时的兜底收音源；两者不同时收音。
    private let systemMic = SystemMicrophoneAudio()
    private enum InputSource { case none, keyboard, system }
    private var source: InputSource = .none
    private var keyboardLinked = false
    private var keyboardLostAt: TimeInterval = 0
    /// 键盘回来了但正在说话：这一句说完再切，不把人半句掐掉。
    private var handbackPending = false
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognitionGeneration = 0
    private var segmentWakeCount = 0
    private var playbackListening = false
    private var lifecycle = 0
    private var running = false
    private var capturing = false
    private var finishing = false
    private var bodyAt: TimeInterval = 0
    private var quickCount = 0
    private var body = "", prefix = "", partial = ""
    private var segmentSpoke = false
    private var lastVoice: TimeInterval = 0
    private var turnAt: TimeInterval = 0
    private var finishAt: TimeInterval = 0
    private var lastAck: String?
    private var lastOutcome: String?
    /// 只喊了名字时推迟的那一声应答；期间用户接着说，就不应了。
    private var ackPending = false
    private var ackAt: TimeInterval = 0
    /// 任务没这么快结束时补一句“这就去办”。
    private var receiptPending = false
    private var receiptAt: TimeInterval = 0
    private var idleAt: TimeInterval = 0
    private var muteUntil: TimeInterval = 0
    private var lastBegin: TimeInterval = 0
    private var receivedAudio = false
    private var failures = 0
    private var wakeCount = 0, finalCount = 0, emptyFinalCount = 0, submittedCount = 0, rewakeCount = 0, recoverCount = 0
    /// 播报静音窗口里被丢掉的最终转写：锁屏感觉“喊了没反应”时，先看这个数是不是在涨。
    private var mutedDrops = 0
    private var verifyPass = 0, verifyRefuse = 0, verifyShort = 0, verifyFail = 0
    /// 高置信通过后慢慢把新样本并进画像的次数计数（不是每次都学）。
    private var adaptCount = 0
    /// 锁屏优先走云端识别；这条路过一次失败就退回本机，解锁后再恢复重试。
    private var cloudBroken = false
    /// 声纹：本轮音频累计（认人）、注册采集窗口与已注册状态。
    private var turnAudio: [Float] = []
    private var enrollAudio: [Float] = []
    /// 大于 0 表示正在采集注册样本，到这个时刻收工。
    private var enrollUntil: TimeInterval = 0
    private var voiceprintEnrolled = false
    private var voiceprintScore: Double?
    private var voiceprintThreshold: Double?
    private var lastTaskID = ""
    private var lastTaskAt: TimeInterval = 0
    private var taskID: String?
    private var pendingTasks = Set<String>()
    private var deferredTasks: [AgentTask] = []
    private var timer: Timer?
    private var waiting: String {
        source == .system ? "等待“\(settings.wakeWord)” · 电脑麦克风" : "等待“\(settings.wakeWord)”"
    }
    /// 电脑麦克风直接收扬声器回音，比键盘多留一段余音，不把自己的播报听成用户说话。
    private var echoTail: TimeInterval { source == .system ? 0.5 : 0.12 }
    private var sourceLabel: String {
        source == .system ? "电脑内置麦克风 · 键盘未连接" : "EasyInput AI · 蓝牙麦克风"
    }
    #if DESKTOP_VOICE_TEST
    private var testTime: TimeInterval?
    func testReceive(_ text: String, at time: TimeInterval, final: Bool = false) {
        running = true; testTime = time; recognized(text, final: final)
    }
    func testAdvance(to time: TimeInterval) { testTime = time; tick() }
    func testAudio(_ samples: [Float], at time: TimeInterval) { running = true; testTime = time; self.samples(samples, fromKeyboard: true) }
    func testSystemAudio(_ samples: [Float], at time: TimeInterval) { running = true; testTime = time; self.samples(samples, fromKeyboard: false) }
    /// 豆包接管正文时取音固定为系统默认输入；测试里没人调 start()，用这个入口把源对齐生产。
    func testDictationAudio(_ samples: [Float], at time: TimeInterval) {
        running = true; testTime = time; if source == .none { source = .system }
        self.samples(samples, fromKeyboard: false)
    }
    func testLink(_ linked: Bool, at time: TimeInterval) { running = true; testTime = time; link(linked) }
    var testSource: String { sourceLabel }
    var testMicStarts = 0
    var testMicStops = 0
    func testPark(_ text: String) throws { try keep(text); park() }
    static var testLockedSession: String { lockedSession }
    func testVoiceprintEnrolled(_ enrolled: Bool) { voiceprintEnrolled = enrolled }
    var testVoiceprintScore: Double? { voiceprintScore }
    var testCapturing: Bool { capturing }
    var testMutedDrops: Int { mutedDrops }
    var testASR: String { asrMode }
    func testSegment() { segmentWakeCount = 0 }
    var testParked: String { parked }
    #endif
    private var now: TimeInterval {
        #if DESKTOP_VOICE_TEST
        if let testTime { return testTime }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }
    override init() {
        super.init()
        audio.onSamples = { [weak self] in self?.samples($0, fromKeyboard: true) }
        audio.onStatus = { [weak self] message in guard let self, !self.capturing else { return }; self.status = message }
        audio.onFailure = { [weak self] in self?.fail($0) }
        audio.onLink = { [weak self] in self?.link($0) }
        systemMic.onSamples = { [weak self] in self?.samples($0, fromKeyboard: false) }
        systemMic.onFailure = { [weak self] message in guard let self, !self.capturing else { return }; self.status = message }
        audio.onBinding = { [weak self] id in
            guard let self else { return }; var next = self.settings
            next.peripheralID = id.uuidString; try next.save(); self.settings = next
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(locked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
    }
    func install() {
        // 启动先把固定短句预渲染好：喊醒时第一句不用等合成。
        warmAll()
        if settings.enabled { start(requestPermission: false) }
    }
    func configure(enabled: Bool, wake: String, allowLocked: Bool, ack: String, ackEnabled: Bool, voice: String?,
                   engine: String? = nil, ttsVoice: String? = nil, rate: Int? = nil, dictation: Bool? = nil) throws {
        guard DesktopVoiceSettings.valid(wake: wake), DesktopVoiceSettings.valid(ack: ack),
              DesktopVoiceSettings.valid(voice: voice ?? "") else { throw CocoaError(.fileWriteInvalidFileName) }
        var next = settings
        next.enabled = enabled; next.wakeWord = wake; next.allowLocked = allowLocked
        next.ackPhrase = ack; next.ackEnabled = ackEnabled
        next.voiceIdentifier = (voice?.isEmpty ?? true) ? nil : voice
        if let engine, ["neural", "system"].contains(engine) { next.ttsEngine = engine }
        if let ttsVoice { next.ttsVoice = ttsVoice.isEmpty ? nil : ttsVoice }
        if let rate, (-25...25).contains(rate) { next.ttsRate = rate }
        if let dictation { next.dictationEnabled = dictation }
        guard DesktopVoiceSettings.valid(tts: next) else { throw CocoaError(.fileWriteInvalidFileName) }
        try next.save()
        let wasCapturing = capturing
        stop(preserve: true); settings = next
        reloadSpeech()
        if wasCapturing { present("输入已保留", draft) }
        if enabled { start(requestPermission: true) } else { status = "未启用" }
    }
    func retry() { stop(preserve: true); if settings.enabled { start(requestPermission: true) } }
    /// 试听：给一句能听出语气的日常句子，不只是一声应答。
    func preview() {
        stopSpeaking()
        _ = say(DesktopVoiceTurn.pick(Self.previewLines, avoiding: nil, roll: 0))
    }
    static let previewLines = ["我在呢，你说吧。今天下午三点提醒你开会。"]
    /// 把固定短句全部预渲染好：唤醒应答、收尾反馈都在里面，现场不用等合成。
    private func reloadSpeech() {
        speechReload?()
        warmAll()
    }
    private func warmAll() {
        for phrase in DesktopVoiceSettings.pool(settings.ackPhrase) { warm(String(phrase.prefix(16))) }
        for pool in DesktopVoiceTurn.outcomes.values { for phrase in pool { warm(phrase) } }
        for pool in DesktopVoiceTurn.replies.values { for phrase in pool { warm(phrase) } }
        for phrase in Self.previewLines { warm(phrase) }
        // 开关答案带设备名，值也简单，先合成好，别让"开灯"等一句合成。
        for phrase in ["灯开了", "灯关了", "开好了", "关好了", "插座开了", "插座关了"] { warm(phrase) }
    }
    func snapshot() -> [String: Any] {
        ["enabled": settings.enabled, "wakeWord": settings.wakeWord, "allowLocked": settings.allowLocked,
         "ackEnabled": settings.ackEnabled, "ackPhrase": settings.ackPhrase,
         "voice": settings.voiceIdentifier ?? "", "voices": voices(),
         "ttsEngine": settings.ttsEngine, "ttsVoice": settings.ttsVoice ?? "", "ttsRate": settings.ttsRate,
         "speech": speechDebug(),
         "source": sourceLabel, "bound": settings.peripheralID != nil,
         "keyboardLinked": keyboardLinked, "fallback": source == .system,
         "dictation": ["enabled": settings.dictationEnabled, "active": dictationActive,
                       "fallbackCharacters": fallbackText.count],
         "deviceCapabilities": audio.deviceCapabilities, "deviceFirmware": audio.deviceFirmware,
         "status": status, "audioDebug": audio.diagnostics, "micDebug": systemMic.diagnostics,
         "voiceDebug": ["running": running, "capturing": capturing, "finishing": finishing,
             "bodyCharacters": body.count, "committedCharacters": prefix.count, "partialCharacters": partial.count,
             "quickSubmissions": quickCount, "rewakes": rewakeCount, "recoveries": recoverCount,
             "wakes": wakeCount, "finals": finalCount, "emptyFinals": emptyFinalCount, "submitted": submittedCount, "lastTaskId": lastTaskID,
             "mutedDrops": mutedDrops, "asr": asrMode, "adapted": adaptCount,
             "verify": ["pass": verifyPass, "refuse": verifyRefuse, "short": verifyShort, "fail": verifyFail]], "receivingAudio": receivedAudio && running, "draft": draft, "parked": parked,
            "parkedCount": (try? DesktopVoiceSettings.parkedRecords().count) ?? 0,
            "speechPermission": SFSpeechRecognizer.authorizationStatus() == .authorized,
            "voiceprint": ["enabled": settings.voiceprintEnabled, "enrolled": voiceprintEnrolled,
                           "score": voiceprintScore ?? -1, "threshold": voiceprintThreshold ?? -1,
                           "debug": DesktopVoiceVoiceprint.diagnostics] as [String: Any]]
    }
    private func start(requestPermission: Bool) {
        guard settings.enabled else { return }
        if DesktopVoiceSettings.draftIsCorrupt || DesktopVoiceSettings.parkedIsCorrupt { status = "未发送输入文件无法读取，已暂停监听并保留原文件。"; return }
        if LockScreenInput.locked && !settings.allowLocked { status = "锁屏期间已暂停"; return }
        lifecycle += 1; let expected = lifecycle
        let permission = SFSpeechRecognizer.authorizationStatus()
        if permission == .notDetermined && requestPermission {
            status = "请允许 PocketDesk 使用语音识别。"
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in DispatchQueue.main.async {
                guard let self, self.lifecycle == expected else { return }; self.start(requestPermission: false)
            } }; return
        }
        guard permission == .authorized else { status = "请在系统设置中允许 PocketDesk 使用语音识别，然后重试。"; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.supportsOnDeviceRecognition else {
            status = "这台电脑的中文本地识别尚不可用，请先完成系统语音资源下载。"; return
        }
        self.recognizer = recognizer; running = true; failures = 0; receivedAudio = false
        muteUntil = 0; idleAt = now
        source = .none; keyboardLinked = false; keyboardLostAt = now; handbackPending = false
        warmAll()
        // 豆包接管正文时只能听系统默认输入设备：蓝牙键盘的 BLE 音频系统里不是一个音频设备，它听不到。
        if settings.dictationEnabled { useSystem() }
        else { audio.start(binding: settings.peripheralID.flatMap(UUID.init(uuidString:))) }
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }; RunLoop.main.add(timer!, forMode: .common)
        refreshVoiceprint()
    }
    private func stopRecognition() {
        recognitionGeneration += 1; recognition?.cancel(); recognition = nil; request = nil
    }
    private func stop(preserve: Bool) {
        lifecycle += 1
        if preserve { preserveDraft() }
        cancelDictation()
        stopRecognition(); stopSpeaking(); audio.stop(); stopMic(); running = false; receivedAudio = false
        timer?.invalidate(); timer = nil; capturing = false; finishing = false; body = ""; prefix = ""; partial = ""
        muteUntil = 0; playbackListening = false
        enrollAudio = []; enrollUntil = 0; turnAudio = []
        source = .none; keyboardLinked = false; handbackPending = false
        // 已接收任务的许可由该任务终态释放，暂停收音不应中断已经获准的动作。
    }
    private func preserveDraft() {
        guard capturing, !body.isEmpty else { return }
        draft = body
        do { try DesktopVoiceSettings.saveDraft(draft) }
        catch { status = "输入仅保留在内存，保存失败；请复制后再退出。" }
    }
    /// 设备级失败才回到“需要人处理”；识别与收尾异常一律自愈，不能让监听停在保留态。
    private func fail(_ message: String) { let wasCapturing = capturing; stop(preserve: true); status = message; if wasCapturing { present(message, draft) } }
    private func recover(_ message: String) {
        recoverCount += 1
        stopRecognition(); capturing = false; finishing = false
        body = ""; prefix = ""; partial = ""; status = message; present(message, "")
    }
    private func beginRecognition() {
        guard running, let recognizer else { return }
        stopRecognition(); idleAt = now; lastBegin = now; segmentSpoke = false; partial = ""; segmentWakeCount = 0
        let input = SFSpeechAudioBufferRecognitionRequest()
        // 锁屏时豆包输入法接管不了（输入法只能往前台焦点里打字），只能靠本机识别；本机小模型对长句
        // 明显吃亏，所以锁屏优先走系统云端识别，识别失败过就退回本机，解锁后重新试。
        input.requiresOnDeviceRecognition = !(LockScreenInput.locked && !cloudBroken)
        input.shouldReportPartialResults = true
        input.taskHint = .dictation; input.contextualStrings = [settings.wakeWord, "小精灵", "开灯", "关灯", "打开空调", "关闭空调"]
        request = input; let generation = recognitionGeneration
        recognition = recognizer.recognitionTask(with: input) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString, final = result?.isFinal ?? false
            DispatchQueue.main.async {
            guard let self, self.running, self.recognitionGeneration == generation else { return }
            if let text { self.recognized(text, final: final) }
            else if let error { self.recognitionError(error) }
        } }
    }
    /// 键盘连接/断开事实；断开后给短宽限再换电脑麦克风，否则每次重连都先在两边来回跳。
    private func link(_ linked: Bool) {
        guard running, !settings.dictationEnabled else { return }
        keyboardLinked = linked; keyboardLostAt = now
        guard !linked else {
            // 订阅一确认就切回，不等人开口；正在说的这一句仍说完再换。
            if source != .keyboard { if capturing || finishing { handbackPending = true } else { useKeyboard() } }
            return
        }
        if source == .keyboard { source = .none }
    }
    private func useSystem() {
        guard source != .system else { return }
        source = .system; handbackPending = false; status = waiting
        startMic()
    }
    private func useKeyboard() {
        guard source != .keyboard else { return }
        stopMic(); source = .keyboard; handbackPending = false; status = waiting
    }
    /// 回归测试不得真的打开电脑麦克风：真机才碰音频硬件。
    private func startMic() {
        #if DESKTOP_VOICE_TEST
        testMicStarts += 1
        #else
        systemMic.start()
        #endif
    }
    private func stopMic() {
        #if DESKTOP_VOICE_TEST
        testMicStops += 1
        #else
        systemMic.stop()
        #endif
    }
    /// 两句之间才换源；正在说的这一句仍用原麦克风说完。
    private func applyHandback() {
        if handbackPending { useKeyboard() }
    }
    private func samples(_ samples: [Float], fromKeyboard: Bool) {
        guard running else { return }
        // 两路同时在线时不能混：兜底要能接上同一句话，就只能用豆包也在听的那个设备。
        if settings.dictationEnabled && fromKeyboard { return }
        if fromKeyboard {
            keyboardLinked = true; keyboardLostAt = now
            if source == .system {
                if capturing || finishing { handbackPending = true } else { useKeyboard() }
            } else if source == .none { source = .keyboard }
        }
        // 只喂当前源：两路同时在线时，键盘优先，不同时收音。
        guard fromKeyboard ? source == .keyboard : source == .system else { return }
        capture(samples)
        if !receivedAudio, samples.contains(where: { abs($0) > 0.0001 }) {
            receivedAudio = true; status = waiting
        }
        guard receivedAudio else { return }
        // 识别任务没立起来时不要每个音频块都重建，给 0.3 秒退避。
        if request == nil && !finishing && now - lastBegin > 0.3 { beginRecognition() }
        // 播报时仍送本地识别，但只接收新唤醒；普通回采不成为正文或声学活动。
        let feedback = now < muteUntil || speaking()
        if playbackListening && !feedback {
            stopRecognition(); beginRecognition()
        }
        playbackListening = feedback
        let energy = samples.reduce(Float(0), { $0 + $1 * $1 }) / Float(samples.count)
        if finishing && !feedback {
            // 收尾等待中又说话了：刚才只是换气，不是说完。撤销收尾继续收音，不把后半句吃掉。
            guard now - finishAt > 0.25, energy > 0.000225 else { return }
            finishing = false; stopRecognition(); beginRecognition()
        }
        if !feedback && energy > 0.000225 {
            if capturing { lastVoice = now }; segmentSpoke = true
        }
        guard let request,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: EasyInputAudioWire.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        request.append(buffer)
    }
    private func recognized(_ text: String, final: Bool) {
        if final { finalCount += 1 }
        if dictationActive {
            // 豆包在收音：本地只留一份兜底，不并进正文、不重算唤醒（名字那句话豆包听不全）。
            absorbFallback(text, final: final); return
        }
        let parts = DesktopVoiceTurn.wakeParts(text, wake: settings.wakeWord)
        let newWake = parts.count > segmentWakeCount
        if (now < muteUntil || speaking()) && !newWake {
            if final { mutedDrops += 1; stopRecognition() }
            return
        }
        if final && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emptyFinal(); return }
        if newWake, let part = parts.last {
            guard canWake() else { if final { stopRecognition() }; return }
            guard !LockScreenInput.locked || settings.allowLocked else { return }
            segmentWakeCount = parts.count
            stopSpeaking(); muteUntil = 0; playbackListening = false
            if capturing { rewoke(part.body, previous: parts.count > 1 ? part.before : nil) }
            else { wake(part.body) }
            if final && capturing { append(part.body, final: true) }
        } else if capturing {
            append(parts.last?.body ?? text, final: final)
        } else if final { stopRecognition() }
    }
    private func feedback(_ phrase: String) -> TimeInterval {
        let text = DesktopVoiceTurn.feedback(phrase, wake: settings.wakeWord)
        return say(text)
    }
    private func retainTurn() -> Bool {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard park() else { return false }
        do { try keep(body) }
        catch { status = "输入无法保存，请先复制当前内容。"; present(status, body); return false }
        return park()
    }
    /// 唤醒：名字后面直接带了话就当场接着听，不再先回一句；只喊名字才应一声。
    private func wake(_ raw: String) {
        let candidate = DesktopVoiceTurn.normalize(raw, wake: settings.wakeWord)
        guard park() else { return }
        wakeCount += 1; failures = 0; capturing = true; finishing = false; turnAudio.removeAll()
        cloudBroken = false
        turnAt = now; lastVoice = now; bodyAt = now
        prefix = ""; partial = candidate; body = candidate
        if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ackPending = true; ackAt = now + DesktopVoiceTurn.ackDelay
        } else {
            ackPending = false
        }
        // 上一句反馈还在说就掐掉：用户已经开口了，不能让它接着念。
        stopSpeaking()
        if body.isEmpty { if beginDictation() { ackPending = false; ackAt = 0; return } } else { cancelDictation() }
        status = dictationHint ?? "正在听"
        present("正在听", body)
    }
    /// 只喊了名字那一声之后，正文交给豆包：它按下才开，名字那句话它听不全。
    /// 本地识别继续听同一段音频，豆包没接上就顶上。
    @discardableResult private func beginDictation() -> Bool {
        dictationHint = nil
        guard settings.dictationEnabled, !LockScreenInput.locked else { return false }
        guard dictationAvailable() else { dictationHint = "正在听 · 本机（豆包未就绪）"; return false }
        guard let dictationBegin, dictationBegin() else { dictationHint = "正在听 · 本机（接收框没起来）"; return false }
        dictationActive = true; dictationAt = now; fallbackText = ""; fallbackPrefix = ""
        ackPending = false; ackAt = 0
        status = "正在听 · 豆包"
        return true
    }
    private func cancelDictation() {
        guard dictationActive else { return }
        dictationActive = false; fallbackText = ""; fallbackPrefix = ""
        dictationCancel()
    }
    /// 豆包这轮的结果：有字就用它，没字就把本地并行听的那份顶上。
    func finishDictation(_ text: String?) {
        guard dictationActive else { return }
        dictationActive = false
        // 收尾成功时那边已经结束了；失败也一律叫停，不能让它继续往接收框里打字。
        dictationCancel()
        let dictated = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !dictated.isEmpty {
            body = dictated; prefix = dictated; partial = ""; bodyAt = now; lastVoice = now
            status = "正在听"
            commitFinal(); return
        }
        let fallback = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        fallbackText = ""; fallbackPrefix = ""
        guard capturing, !fallback.isEmpty else { returnToWake(); return }
        // 豆包没接上：换成本地这份，让既有的停顿规则收尾，不把人后半句裁掉。
        body = fallback; prefix = ""; partial = ""; bodyAt = now; lastVoice = now - 0.1
        status = "正在听 · 本机"
    }
    /// 豆包收音期间的本地转写只存不用，留给接管失败时一份完整的。
    private func absorbFallback(_ text: String, final: Bool) {
        let candidate = [fallbackPrefix, text].filter { !$0.isEmpty }.joined(separator: "，")
        if candidate != fallbackText { fallbackText = candidate }
        if final { fallbackPrefix = candidate; stopRecognition(); beginRecognition() }
    }
    /// 重新呼叫是开始新输入，不是执行旧半句；旧正文与票据先入队才可替换。
    private func rewoke(_ rest: String, previous: String?) {
        rewakeCount += 1
        if let previous { body = [prefix, previous].filter { !$0.isEmpty }.joined(separator: "，") }
        guard retainTurn() else { return }
        wake(rest)
    }
    private func append(_ raw: String, final: Bool) {
        let text = DesktopVoiceTurn.normalize(raw, wake: settings.wakeWord)
        partial = text
        let next = [prefix, text].filter { !$0.isEmpty }.joined(separator: "，")
        if next != body { body = next; bodyAt = now; lastVoice = now }
        // 名字后面接着说了话，那声应答就不必再出了。
        if !body.isEmpty { ackPending = false }
        status = "正在听"; present("正在听", body)
        if final {
            prefix = body; partial = ""
            if finishing { commitFinal(); return }
            stopRecognition()
            // 识别服务可能主动分段；最终段只累计，不把分段当作用户已说完。
            beginRecognition()
        }
    }
    private func acknowledge() {
        guard settings.ackEnabled, !dictationActive else { return }
        // 锁屏看不见屏幕，念一句应答反而把紧接着说的正文按回声丢掉（mutedDrops 就是这么涨的）。
        // 锁屏只给一声轻提示，马上继续收音，人不用等它念完再开口。
        if LockScreenInput.locked {
            playCue()
            muteUntil = max(muteUntil, now + 0.25)
            return
        }
        let phrase = DesktopVoiceTurn.ack(settings.ackPhrase, avoiding: lastAck, roll: Int.random(in: 0..<64))
        lastAck = phrase
        guard !phrase.isEmpty else { return }
        stopSpeaking()
        let duration = feedback(phrase)
        muteUntil = now + duration + echoTail
    }
    /// 锁屏应答用的极短提示音：不产生可被自己听成正文的语音。
    private func playCue() {
        guard let cue = NSSound(named: NSSound.Name("Tink")) ?? NSSound(named: NSSound.Name("Pop")) else { return }
        cue.stop(); cue.play()
    }
    private func emptyFinal() {
        emptyFinalCount += 1
        switch DesktopVoiceTurn.emptyFinal(body: body, finishing: finishing) {
        case .wake: returnToWake()
        case .commit: commitFinal()
        case .resume: stopRecognition(); beginRecognition()
        }
    }
    private func recognitionError(_ error: Error) {
        let noSpeech = (error as NSError).code == 1110
        // 云端这条路（断网、服务不可用）失败一次就退回本机，别让锁屏因为没有第二选择直接哑掉。
        if LockScreenInput.locked, !cloudBroken, !noSpeech { cloudBroken = true }
        if body.isEmpty {
            if noSpeech && !capturing { stopRecognition(); status = waiting; return }
            if capturing { returnToWake(); return }
            stopRecognition(); failures += 1
            status = failures >= 3 ? "本地语音识别暂不可用，正在重试。" : waiting
            return
        }
        if finishing { commitFinal(); return }
        if noSpeech { stopRecognition(); beginRecognition(); return }
        failures += 1
        if failures >= 3 { recover("本地语音识别暂不可用，正在重试。"); return }
        stopRecognition(); beginRecognition()
    }
    private func tick() {
        guard running else { return }
        if !LockScreenInput.locked { cloudBroken = false }
        // 云端识别要联网：一直在说话却迟迟不出字，就当这条路不可用，退回本机，不让锁屏干等。
        if LockScreenInput.locked, !cloudBroken, capturing, body.isEmpty, segmentSpoke,
           now - lastVoice < 0.6, now - turnAt > 3 {
            cloudBroken = true; stopRecognition(); beginRecognition()
        }
        if enrollUntil > 0 {
            if now > enrollUntil { finishEnrollment() }
            return
        }
        if DesktopVoiceTurn.wantsSystemFallback(linked: keyboardLinked, usingSystem: source == .system,
                                                silentFor: now - keyboardLostAt) { useSystem() }
        if ackPending {
            if !body.isEmpty { ackPending = false }
            else if now >= ackAt && now - lastVoice >= DesktopVoiceTurn.ackDelay {
                ackPending = false; acknowledge()
            }
        }
        if let id = taskID {
            if receiptPending && now >= receiptAt && !capturing && !speaking() {
                receiptPending = false
                speakReceipt()
            }
            pendingTasks.insert(id)
        }
        for id in pendingTasks {
            if let task = TaskStore.task(id: id) {
                if !capturing && id == taskID { presentTask(task) }
                if ![TaskStatus.accepted, .running, .verifying].contains(task.status) {
                    pendingTasks.remove(id)
                    if id == taskID { taskID = nil; receiptPending = false }
                    Self.permissionLock.lock(); Self.lockedPermits.remove(task.requestId); Self.permissionLock.unlock()
                    if capturing || speaking() { deferredTasks.append(task) }
                    else { presentTask(task); announce(task) }
                    if draft.isEmpty && !capturing { status = waiting }
                }
            }
        }
        if !capturing && !speaking() && !deferredTasks.isEmpty {
            let task = deferredTasks.removeFirst(); presentTask(task); announce(task)
        }
        guard capturing else {
            if request != nil && now - idleAt > 40 { stopRecognition() }
            return
        }
        if now - turnAt > 90 { if dictationActive { finishDictation(nil) } else { commitFinal() }; return }
        // 豆包在收正文：它自己不会因为停顿就停，本地声学停顿判“说完了”再让它松手。
        if dictationActive {
            if now - dictationAt > DesktopVoiceTurn.dictationBudget { finishDictation(nil); return }
            let heard = max(fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).count, dictationCharacters())
            // 一个字都没听到（可能还在想）就给足宽限；已经开口了就按同一套停顿规则。
            let tolerance = heard == 0 ? 6 : DesktopVoiceTurn.silence(String(repeating: "字", count: heard))
            // 唤醒后一直没人说话：不抱着麦克风干等，直接回到待唤醒。
            if heard == 0, now - dictationAt > 8 { finishDictation(nil); return }
            if heard > 0, now - lastVoice >= tolerance { dictationFinishTurn() }
            return
        }
        if finishing {
            // 识别服务不给最终结果时到点按已听内容收尾，不把整条监听卡在“保留”态。
            if now - finishAt > DesktopVoiceTurn.finalizeTimeout {
                if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { returnToWake() } else { commitFinal() }
            }
        } else if now - lastVoice >= (body.isEmpty ? 6 : DesktopVoiceTurn.silence(body)) {
            if body.isEmpty { returnToWake(); return }
            let text = DesktopVoiceTurn.command(body)
            if DesktopVoiceTurn.stableQuick(text, stableFor: now - bodyAt, quietFor: now - lastVoice,
                                           bound: MijiaQuickControl.resolve(text) != nil) {
                quickCount += 1; commitFinal(); return
            }
            finishing = true; finishAt = now; request?.endAudio()
        }
    }
    private func returnToWake() {
        cancelDictation()
        stopRecognition(); capturing = false; finishing = false; body = ""; prefix = ""; partial = ""; turnAudio.removeAll()
        ackPending = false
        status = waiting; present("", ""); applyHandback()
    }
    /// 刚才那件事还没说热、而这句话又明摆着在追问时，才接上去；否则仍当新任务。
    private func followUpTarget(_ text: String) -> String? {
        guard !LockScreenInput.locked, !lastTaskID.isEmpty,
              now - lastTaskAt <= DesktopVoiceTurn.followUpWindow,
              DesktopVoiceTurn.followUp(text),
              let task = TaskStore.task(id: lastTaskID), task.status.acceptsFollowUp else { return nil }
        return lastTaskID
    }
    private func commitFinal() {
        let text = DesktopVoiceTurn.command(body)
        let audio = turnAudio
        stopRecognition(); capturing = false; finishing = false; body = ""; prefix = ""; partial = ""; turnAudio = []
        guard !text.isEmpty else { returnToWake(); return }
        applyHandback()
        if let local = DesktopVoiceTurn.local(text) { answer(local); return }
        // 锁屏已经放开了全部能力，守住“只认机主”的就只剩这道声纹门。
        guard needsOwnerVoice else { submit(text); return }
        verifyOwner(text: text, audio: audio)
    }
    /// 对助手本人的话（退下、别说了、谢谢）：当场回一句，不派单、不报“搞定”。
    private func answer(_ kind: DesktopVoiceTurn.Local) {
        if kind == .remember { beginEnrollment(); return }
        if kind == .forget { forgetVoiceprint(); return }
        let phrase = DesktopVoiceTurn.reply(kind, avoiding: lastAck, roll: Int.random(in: 0..<64))
        if !phrase.isEmpty {
            lastAck = phrase
            stopSpeaking()
            let duration = feedback(phrase)
            muteUntil = now + duration + echoTail
        }
        if kind == .hush { stopSpeaking() }
        returnToWake()
    }
    private func submit(_ text: String) {
        do {
            try keep(text)
            guard let requestID = DesktopVoiceSettings.draftRequestID() else { throw CocoaError(.fileReadCorruptFile) }
            let task: AgentTask
            if let previous = followUpTarget(text) {
                // 接着上一句说的话：接到上一件任务上，模型看得到前文，不会把“是多少”当成新话题。
                task = try continueTask(previous, text)
            } else if LockScreenInput.locked {
                // 锁屏也要能正常回话：整句照旧进任务，仍用独立临时许可；真正做不了的桌面
                // 动作由 AgentControlAuthority 在工具层逐条拒，不在这里整句拦掉。
                Self.permissionLock.lock(); Self.lockedPermits.insert(requestID); Self.permissionLock.unlock()
                do {
                    task = try TaskService.submit(subject: String(Auth.token.prefix(8)), requestId: requestID,
                        text: text, context: nil, controlSession: Self.lockedSession)
                } catch {
                    Self.permissionLock.lock(); Self.lockedPermits.remove(requestID); Self.permissionLock.unlock(); throw error
                }
            } else { task = try submitUnlocked(text, requestID) }
            taskID = task.id; pendingTasks.insert(task.id); lastTaskID = task.id; lastTaskAt = now; submittedCount += 1
            // 多数任务不会一提交就完；一秒多还没结果就先说一声，不让人干等。
            receiptPending = settings.ackEnabled
            receiptAt = now + DesktopVoiceTurn.receiptDelay
            do { try keep(""); status = "执行中" }
            catch { draft = text; status = "任务已接收，草稿清理失败；请核对结果，不会重复发送。" }
            presentTask(task)
        } catch { draft = text; try? keep(text); status = "接收结果未确认，输入已保留；重试会核对原任务。" }
    }
    /// 任务还在跑：先把“这就去办”说出去，完成时再报结果。
    private func speakReceipt() {
        let phrase = DesktopVoiceTurn.outcome(.receipt, avoiding: lastOutcome, roll: Int.random(in: 0..<64))
        guard !phrase.isEmpty else { return }
        lastOutcome = phrase
        stopSpeaking()
        let duration = feedback(phrase)
        muteUntil = max(muteUntil, now + duration + echoTail)
    }
    /// 任务收尾时一句话反馈，像有人应了一声；失败与待确认只说结论，不复述内容。
    private func announce(_ task: AgentTask) {
        guard settings.ackEnabled else { return }
        receiptPending = false
        // “已请求但还没确认”不是失败：用户看到应用关了，我却在报“没办成”，比不说还糟。
        let awaiting = DesktopVoiceTurn.awaiting(task.result ?? "")
        let verdict: DesktopVoiceTurn.Verdict = task.status == .succeeded ? .succeeded
            : (task.status == .needsInput || (task.status == .failed && awaiting) ? .needsInput : .failed)
        let outcome = DesktopVoiceTurn.outcome(verdict, answered: DesktopVoiceTurn.answered(task.result),
                                               recovery: task.recovery.map { String(describing: $0.kind) })
        // 查到的东西就念查到的东西；“搞定了”只在没有可念结论时当兵底。
        // 查到的东西就念查到的东西；“搞定了”“还没确认上”只在没有可念结论时兜底。
        // 附带条件的结果（例如只有历史读数）也照念，念完那句就够，不必再报状态。
        var spoken = (outcome == .succeeded || outcome == .answered)
            ? DesktopVoiceTurn.speakable(task.result) : nil
        if spoken == nil, outcome != .succeeded, outcome != .answered,
           DesktopVoiceTurn.hasNumber(task.result ?? "") {
            spoken = DesktopVoiceTurn.speakable(task.result)
        }
        // 他能立刻看见的事，办成了就不吭声；只有失败或要他定夺时才说话。
        if DesktopVoiceTurn.perceivable(task.text), outcome == .succeeded || outcome == .unconfirmed { return }
        let phrase = spoken ?? DesktopVoiceTurn.outcome(outcome, avoiding: lastOutcome, roll: Int.random(in: 0..<64))
        lastOutcome = phrase
        stopSpeaking(); _ = feedback(phrase)
        // 没有精确时长时按中文每秒 4.6 字保守估计，宁可比实际多静默一会儿。
        muteUntil = now + Double(phrase.count) / 4.6 + 0.6 + (source == .system ? 0.4 : 0)
    }
    // MARK: - 声纹

    /// 本轮音频按源累计：认人要的是原声，不能用转写文本代替。
    private func capture(_ samples: [Float]) {
        turnAudio.append(contentsOf: samples)
        if turnAudio.count > 192_000 { turnAudio.removeFirst(turnAudio.count - 192_000) }
        // 注册时连着自己那句应答一起收会污染样本，播报期间的音频一律不算。
        guard enrollUntil > 0, now >= muteUntil else { return }
        enrollAudio.append(contentsOf: samples)
        if enrollAudio.count > DesktopVoiceTurn.enrollMaxSamples {
            enrollAudio.removeFirst(enrollAudio.count - DesktopVoiceTurn.enrollMaxSamples)
        }
    }
    /// 锁屏 + 声纹开关 + 已经注册过：这一句必须先认人。
    private var needsOwnerVoice: Bool {
        settings.voiceprintEnabled && LockScreenInput.locked && voiceprintEnrolled
    }
    /// 认人：像就照常执行；不像就把原话留在草稿里；验不了就明说，绝不静默放行。
    private func verifyOwner(text: String, audio: [Float]) {
        // 太短的一段算不出稳定画像：与其误判成“陌生人”，不如请他把话说完。
        guard audio.count >= 16000 else {
            verifyShort += 1
            try? self.keep(text)
            holdForOwner("这句太短，我没认出人；说长一点")
            return
        }
        status = "正在认声音"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = DesktopVoiceVoiceprint.verify(audio)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let result else {
                    self.verifyFail += 1
                    self.voiceprintScore = nil
                    try? self.keep(text)
                    self.holdForOwner("声纹这会儿验不了，锁屏先不执行；解锁就能办")
                    return
                }
                self.voiceprintScore = Self.number(result["score"])
                self.voiceprintThreshold = Self.number(result["threshold"])
                guard result["match"] as? Bool == true else {
                    self.verifyRefuse += 1
                    try? self.keep(text)
                    self.holdForOwner(Self.replyLocked)
                    return
                }
                self.verifyPass += 1
                self.submit(text)
                self.adaptVoiceprint(audio: audio, score: Self.number(result["score"]))
            }
        }
    }
    private static let replyLocked = "这个声音我不认识，锁屏时只认你"
    /// 一直说话时画像自己长：只在分数明显高于阈值时才学，且每十次才学一次。
    /// 不做“通过就学”——一次误收会被越学越像，等于自己把锁磨开。
    private func adaptVoiceprint(audio: [Float], score: Double?) {
        guard settings.voiceprintEnabled, let score, score >= DesktopVoiceTurn.adaptScoreFloor,
              audio.count >= DesktopVoiceTurn.enrollMinimumSampleCount else { return }
        adaptCount += 1
        guard adaptCount % DesktopVoiceTurn.adaptEvery == 0 else { return }
        DispatchQueue.global(qos: .utility).async { _ = DesktopVoiceVoiceprint.enroll(audio, label: "owner") }
    }
    private var asrMode: String {
        guard running else { return "-" }
        return (LockScreenInput.locked && !cloudBroken) ? "cloud" : "on-device"
    }
    /// 没放行的一句：说清楚为什么，原文留在草稿里等解锁后显式发送。
    private func holdForOwner(_ phrase: String) {
        stopSpeaking()
        let duration = feedback(phrase)
        muteUntil = max(muteUntil, now + duration + echoTail)
        returnToWake()
        // returnToWake 会把状态归回“等待小E”，这里再落一次保留态，解锁后屏幕上能看见原话。
        status = "输入已保留，解锁后可发送。"
        present(status, draft)
    }
    /// 喊「记住我的声音」之后：先让人多说几句，再拿这段音频注册。
    private func beginEnrollment() {
        // 注册只能在解锁时做：锁屏时谁都能喊一句“记住我的声音”，那就等于把锁交给屋里的人。
        guard !LockScreenInput.locked else {
            speakHeld("解锁之后我再记你的声音")
            status = waiting
            returnToWake()
            return
        }
        stopSpeaking()
        if !running { start(requestPermission: false) }
        enrollAudio = []
        // 让他多念几句、中间停顿：一句话一个样本，比随便说八秒更像他平时的声音。
        let phrase = voiceprintEnrolled ? "好，再慢慢念两三句，中间停一下" : "好，慢慢念两三句，中间停一下"
        let duration = feedback(phrase)
        muteUntil = max(muteUntil, now + duration + echoTail)
        // 采集窗口从应答念完才开始算，别把自己那句应答当成他的声音。
        enrollUntil = muteUntil + DesktopVoiceTurn.enrollSeconds
        returnToWake()
        status = "正在记你的声音"
    }
    private func finishEnrollment() {
        let audio = enrollAudio
        enrollAudio = []; enrollUntil = 0
        guard audio.count >= DesktopVoiceTurn.enrollMinimumSampleCount else {
            status = waiting
            let duration = feedback("没听够，再说一次“记住我的声音”")
            muteUntil = max(muteUntil, now + duration + echoTail)
            return
        }
        status = "正在记你的声音"
        // 整段只算一个样本，画像太窄：真到锁屏上分数就在阈值边上抖，稍微变个语气就被当成陌生人。
        // 按停顿切成一句一段，每段一个样本；一口气念完没有停顿就固定切。
        let segments = DesktopVoiceTurn.enrollmentSegments(audio)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: [String: Any]?
            for segment in segments {
                if let enrolled = DesktopVoiceVoiceprint.enroll(segment, label: "owner") { result = enrolled }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if result != nil {
                    self.voiceprintEnrolled = true
                    self.voiceprintThreshold = result.flatMap { Self.number($0["threshold"]) } ?? self.voiceprintThreshold
                    self.voiceprintScore = nil
                    self.speakHeld("记住了，锁屏时只认你")
                } else {
                    self.speakHeld("没记上，回头再试一次")
                }
                self.status = self.waiting
            }
        }
    }
    private func forgetVoiceprint() {
        // 忘掉声纹等于把锁打开：只能由解锁状态下的人来做。
        guard !LockScreenInput.locked else {
            speakHeld("解锁之后才能忘掉声纹")
            status = waiting
            returnToWake()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cleared = DesktopVoiceVoiceprint.clear()
            DispatchQueue.main.async {
                guard let self else { return }
                if cleared {
                    self.voiceprintEnrolled = false; self.voiceprintScore = nil
                    self.speakHeld("忘了，锁屏不再只认你")
                } else {
                    self.speakHeld("没清掉，稍后再试")
                }
                self.status = self.waiting
            }
        }
    }
    private func speakHeld(_ phrase: String) {
        stopSpeaking()
        let duration = feedback(phrase)
        muteUntil = max(muteUntil, now + duration + echoTail)
    }
    /// 启动时问一次“注册过没有”；桥没起也不影响别的功能。
    private func refreshVoiceprint() {
        guard settings.voiceprintEnabled else { voiceprintEnrolled = false; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let health = DesktopVoiceVoiceprint.health()
            DispatchQueue.main.async {
                guard let self else { return }
                // 桥没响应时按画像文件判：注册过就继续要求认人，绝不因为桥坏了就静默放行。
                self.voiceprintEnrolled = health.map { $0["enrolled"] as? Bool ?? false } ?? DesktopVoiceVoiceprint.hasProfile
                self.voiceprintThreshold = Self.number(health?["threshold"])
            }
        }
    }
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        return nil
    }

    private func keep(_ text: String) throws { try DesktopVoiceSettings.saveDraft(text); draft = text }
    /// 上一轮失败留下的草稿不再挡住新一轮收音；原文与票据挪到较早未发送槽，仍可幂等发送。
    @discardableResult private func park() -> Bool {
        guard !draft.isEmpty else { return true }
        guard let record = DesktopVoiceSettings.draftRecord() else {
            status = "上一条输入无法读取，请先核对。"; return false
        }
        do {
            try DesktopVoiceSettings.saveParked(record)
            try keep(""); parked = DesktopVoiceSettings.parked(); return true
        } catch {
            parked = DesktopVoiceSettings.parked(); status = "上一条输入未能保存，已保留原文。"
            present(status, draft); return false
        }
    }
    func sendDraft() throws {
        guard !LockScreenInput.locked, taskID == nil, !draft.isEmpty else { throw CocoaError(.userCancelled) }
        let text = draft
        // 明确点发送才清草稿；提交失败保留原文与本次意图。
        guard let requestID = DesktopVoiceSettings.draftRequestID() else { throw CocoaError(.fileReadCorruptFile) }
        let task = try submitUnlocked(text, requestID)
        taskID = task.id; pendingTasks.insert(task.id)
        do { try keep("") }
        catch { draft = text; status = "任务已接收，草稿清理失败；请核对结果，不会重复发送。" }
        presentTask(task)
        if settings.enabled && !running { start(requestPermission: false) }
    }
    func sendParked() throws {
        guard !LockScreenInput.locked, let record = DesktopVoiceSettings.parkedRecord() else { throw CocoaError(.userCancelled) }
        let task = try submitUnlocked(record.text, record.requestID)
        taskID = task.id; pendingTasks.insert(task.id); lastTaskID = task.id; submittedCount += 1
        try DesktopVoiceSettings.saveParked(nil); parked = DesktopVoiceSettings.parked()
        presentTask(task)
        if settings.enabled && !running { start(requestPermission: false) }
    }
    func discardParked() throws {
        try DesktopVoiceSettings.saveParked(nil); parked = DesktopVoiceSettings.parked()
    }
    func discardDraft() throws { guard taskID == nil else { throw CocoaError(.userCancelled) }; try keep(""); if settings.enabled { retry() } }
    @objc private func willSleep() { stop(preserve: true); status = "电脑睡眠期间已暂停" }
    @objc private func didWake() { if settings.enabled { start(requestPermission: false) } }
    @objc private func locked() { if !settings.allowLocked { stop(preserve: true); status = "锁屏期间已暂停" } }
    @objc private func unlocked() { if !running && settings.enabled { start(requestPermission: false) } }
    @objc private func willTerminate() { stop(preserve: true) }
}
