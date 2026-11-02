/**
 * [INPUT]: 装配DesktopVoice、EasyInput独立收音及锁屏确定性任务边界，依赖 AgentHTTP/Auth/TaskStore（装配期只读）与 SpriteSession/SpriteFeedback/SpriteFeedbackPanel。
 * [OUTPUT]: 强持有面板与协调层直至进程退出；提供 SpriteDesk.install(webRoot:)——桌面反馈的唯一装配入口：展示会话、任务只读投影与原生面板及离线球体资源；并把唤醒后的正文交给豆包（就绪态门禁 + 接收框入口 + 取消回执）。
 * [POS]: Sources 的桌面反馈装配层；独立成文件让 main.swift 只留一行接缝，也便于测试排除。
 *        复用TaskService执行，锁屏语音只调用已绑定设备快路径；不注入任何应用的输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// main.swift 只调 `SpriteDesk.install(webRoot:)` 一行。重复调用无害。
enum SpriteDesk {
    private static var installed = false
    private static let headsetControls = HeadsetController.shared
    private static var desktopInput: SpriteDesktopInput?
    private static var retainedSpeech: DesktopVoiceSpeech?
    private static var retainedPanel: SpriteFeedbackPanel?
    private static var retainedFeedback: SpriteFeedback?
    private static let lock = NSLock()

    static func install(webRoot: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        let session = SpriteSession()
        AgentHTTP.spriteSession = session
        let subject = String(Auth.token.prefix(8))
        let feedback = SpriteFeedback(session: session, subject: subject)
        let provider: () -> AgentTask? = { [subject] in
            let mine = TaskStore.all().filter { $0.subject == subject }
            return mine.max { $0.createdAt < $1.createdAt }
        }
        feedback.taskProvider = provider
        let panel = SpriteFeedbackPanel(webRoot: webRoot)
        retainedPanel = panel
        retainedFeedback = feedback
        feedback.panel = panel
        feedback.start()
        let input = SpriteDesktopInput(panel: panel)
        desktopInput = input
        headsetControls.start()
        let voice = DesktopVoice.shared
        let speech = DesktopVoiceSpeech()
        retainedSpeech = speech
        voice.say = { [weak speech] in speech?.say($0) ?? 0 }
        voice.speaking = { [weak speech] in speech?.isSpeaking ?? false }
        voice.stopSpeaking = { [weak speech] in speech?.stop() }
        voice.warm = { [weak speech] in speech?.prewarm($0) }
        voice.speechReload = { [weak speech] in speech?.reload() }
        voice.speechDebug = { [weak speech] in speech?.diagnostics ?? [:] }
        voice.voices = { DesktopVoiceSpeech.allVoices() }
        // 有任务在跑也允许重喊唤醒词：卡住的不是任务，是上一轮收音；抢输入焦点由输入归属自己把关。
        voice.canWake = { [weak panel] in
            guard panel != nil else { return false }
            return desktopInput?.hasInputInProgress != true
        }
        voice.present = { [weak panel] status, text in panel?.externalVoice(status: status, text: text) }
        voice.presentTask = { [weak panel] task in
            guard !LockScreenInput.locked else { return }
            if panel?.desktopMode != true { panel?.externalVoice(status: "执行中", text: task.text) }
            panel?.desktopTask(task)
        }
        voice.submitUnlocked = SpriteDesktopInput.submitAutomaticVoice
        // 唤醒后的正文默认交给豆包输入法的系统 ASR：它只听系统默认输入设备，
        // 本机识别并行听同一段音频，它没接上就用本机那份，不用重说。
        voice.dictationAvailable = { VoiceInputGuide.snapshot().stage == .ready }
        voice.dictationBegin = { [weak input] in
            guard let input else { return false }
            return input.beginWakeDictation { [weak voice] text in voice?.finishDictation(text) }
        }
        voice.dictationCancel = { [weak input] in input?.dismissWakeDictation() }
        voice.dictationFinishTurn = { [weak input] in _ = input?.endWakeDictation() }
        voice.dictationCharacters = { [weak input] in input?.desktopCharacters ?? 0 }
        // 接着上一句说的话接到原任务上，模型才看得到“是多少”指的是什么。
        voice.continueTask = { taskID, text in
            try TaskService.supplement(taskId: taskID, text: text, expectedRevision: nil)
        }
        let previousRunner = TaskService.runAgent
        TaskService.runAgent = { config, task, done in
            if !AgentControlAuthority.runLockedVoice(task, completion: done) { previousRunner(config, task, done) }
        }
        // 锁屏语音照常调模型，但需解锁屏幕的工具逐条拒绝——两道门都挂在 AgentRunner 上，
        // 不让执行循环自己认识桌面语音身份。
        AgentRunner.lockedVoice = { DesktopVoice.lockedTask($0) }
        AgentRunner.lockedToolRefusal = { taskId, tool in AgentControlAuthority.lockedToolRefusal(taskId: taskId, tool: tool) }
        voice.install()
    }
}
