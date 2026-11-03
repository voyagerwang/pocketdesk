/**
 * [INPUT]: 真实DesktopVoice草稿提交/私有存储与任务/锁屏替身；临时只读目录制造清理失败。
 * [OUTPUT]: 验证字幕修订不重唤醒、新呼叫保留旧半句而不提交、播报可打断、旧输入队列及故障去重；固定口令仍单次提交；豆包接管时正文不用、转交给它，它没接上就回落到本地并行听到的那份且剥掉唤醒名，它出字也剥。
 * [POS]: 自动语音接收与草稿持久化故障回归；不启动蓝牙、识别或实际用户任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import AppKit

enum TaskStatus { case accepted, running, verifying, needsInput, submitted, succeeded, failed, abandoned
    var acceptsFollowUp: Bool {
        switch self {
        case .succeeded, .submitted, .needsInput, .failed, .abandoned: return true
        case .accepted, .running, .verifying: return false
        }
    }
}
struct AgentTask { var id: String; var requestId: String; var controlSession: String?; var status = TaskStatus.succeeded; var result: String? = nil; var recovery: Recovery? = nil; var text: String = "" }
struct Recovery { var kind: String; var nextStep: String? = nil }
enum LockScreenInput { static var locked = false }
enum TaskStore { static var tasks: [String:AgentTask] = [:]; static func task(id: String) -> AgentTask? { tasks[id] } }
enum Auth { static let token = "fixture" }
enum TaskService {
    /// 锁屏语音现在会真的走这个入口；记下来供断言，仍不触达任何真实任务服务。
    static var lockedSubmissions:[String]=[]
    static var lockedSessions:[String?]=[]
    static func submit(subject:String,requestId:String,text:String,context:Int?,controlSession:String?) throws -> AgentTask {
        lockedSubmissions.append(text);lockedSessions.append(controlSession)
        return AgentTask(id:UUID().uuidString,requestId:requestId,controlSession:controlSession)
    }
}
enum MijiaQuickControl { static func resolve(_ text:String)->Bool? { ["关灯","开灯"].contains(text) ? true : nil } }
/// 声纹桥替身：真实模型不参与回归，只控制“像不像”的结论。
enum DesktopVoiceVoiceprint {
    static var match = true
    static var broken = false
    static var verifications = 0
    static var enrollments: [String] = []
    static var ready = true
    static var hasProfile = false
    static var diagnostics: [String: Any] { ["ready": ready] }
    static func health() -> [String: Any]? { ["ok": true, "enrolled": false, "samples": 0, "threshold": 0.72] }
    static func verify(_ samples: [Float]) -> [String: Any]? {
        verifications += 1
        if broken { return nil }
        return ["ok": true, "score": match ? 0.86 : 0.31, "match": match, "threshold": 0.72]
    }
    static func enroll(_ samples: [Float], label: String) -> [String: Any]? {
        enrollments.append(label)
        return ["ok": true, "samples": 1, "threshold": 0.72]
    }
    static func clear() -> Bool { true }
}
/// 声纹校验是异步的：等主线程把结果接回来再断言，不靠固定 sleep。
func pump(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    precondition(condition(), "异步结果应收敛")
}
func accept(_ text: String) -> Bool { TaskService.lockedSubmissions.contains(text) }
@main struct Tests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DesktopVoiceSettings.directory = dir
        defer {
            try? FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:dir.path)
            try? FileManager.default.removeItem(at:dir)
        }
        // 本组回归守的是纯本机模式：键盘麦克风 + 本地识别。
        var local = DesktopVoiceSettings(); local.dictationEnabled = false
        try local.save(); try DesktopVoiceSettings.saveDraft("帮我保留这条指令")
        var ledger:[String:AgentTask] = [:]; var writes = 0; var submitted:[String]=[]
        let submit:(String,String)throws->AgentTask = { text,id in
            submitted.append(text)
            if let known = ledger[id] { return known }
            writes += 1
            let task=AgentTask(id:UUID().uuidString,requestId:id,controlSession:"native")
            ledger[id]=task
            return task
        }
        let voice=DesktopVoice(); voice.submitUnlocked=submit
        precondition(writes==0,"恢复草稿不自动发送")
        try FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:dir.path)
        try voice.sendDraft()
        precondition(writes==1 && voice.status.contains("任务已接收"),"任务接受后清理失败不冒充未发送")
        precondition(!voice.draft.isEmpty && !DesktopVoiceSettings.draft().isEmpty,"内存与磁盘草稿保留")
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:dir.path)
        let restored=DesktopVoice();restored.submitUnlocked=submit
        precondition(writes==1,"新运行时不自动重派")
        try restored.sendDraft()
        precondition(writes==1 && restored.draft.isEmpty,"恢复重试查回原任务且清草稿")
        try DesktopVoiceSettings.saveDraft("锁屏不发送")
        let locked=DesktopVoice();locked.submitUnlocked=submit;LockScreenInput.locked=true
        do { try locked.sendDraft();fatalError("locked draft sent") } catch { }
        precondition(writes==1 && !locked.draft.isEmpty,"锁屏显式草稿按钮也不绕过")
        #if DESKTOP_VOICE_TEST
        LockScreenInput.locked=false;try DesktopVoiceSettings.saveDraft("")
        let quick=DesktopVoice();quick.submitUnlocked=submit
        quick.testReceive("小E，关灯",at:10)
        quick.testAdvance(to:11.99);precondition(writes==1,"未满足停顿不提交")
        quick.testAdvance(to:12.01);precondition(writes==2,"稳定短口令无需系统final即可交真实提交链")
        quick.testAdvance(to:13);quick.testAdvance(to:20)
        precondition(writes==2 && quick.draft.isEmpty,"同一轮多次tick只提交一次且任务接收后清草稿")
        // 锁屏问日程照样进任务：走锁定会话的临时许可，不再整句静默吞掉。
        LockScreenInput.locked=true
        let lockedQuery=DesktopVoice();lockedQuery.submitUnlocked=submit
        lockedQuery.testReceive("小E，明天我有几个日程",at:21)
        lockedQuery.testAdvance(to:23.1);lockedQuery.testAdvance(to:26)
        precondition(writes==2 && TaskService.lockedSubmissions==["明天我有几个日程"],"锁屏问句也进任务，只派一次")
        precondition(TaskService.lockedSessions == [DesktopVoice.testLockedSession],"锁屏任务走锁定会话")
        precondition(lockedQuery.draft.isEmpty,"任务已接收，草稿不残留")

        // 注册过声纹之后，锁屏这一句要先认人：不像就留稿、不派单；像才照常执行。
        try DesktopVoiceSettings.saveDraft("")
        let owner=DesktopVoice();owner.submitUnlocked=submit
        var ownerSaid:[String]=[]
        owner.say={ phrase in ownerSaid.append(phrase);return 0.3 }
        owner.testVoiceprintEnrolled(true)
        DesktopVoiceVoiceprint.match=false
        owner.testReceive("小E，开灯",at:30);owner.testAudio([Float](repeating:0.4,count:24000),at:30)
        owner.testAdvance(to:32.1);owner.testAdvance(to:35)
        pump { !owner.draft.isEmpty }
        precondition(DesktopVoiceVoiceprint.verifications==1 && owner.draft=="开灯","不像的声音不派单，原话留稿")
        precondition(ownerSaid.contains { $0.contains("只认你") },"认不上要说清原因")
        DesktopVoiceVoiceprint.match=true
        try DesktopVoiceSettings.saveDraft("")
        let ownerOk=DesktopVoice();ownerOk.submitUnlocked=submit
        ownerOk.testVoiceprintEnrolled(true)
        ownerOk.testReceive("小E，开灯",at:40);ownerOk.testAudio([Float](repeating:0.4,count:24000),at:40)
        ownerOk.testAdvance(to:42.1);ownerOk.testAdvance(to:45)
        pump { accept("开灯") }
        precondition(DesktopVoiceVoiceprint.verifications==2 && accept("开灯"),"本人声音照常执行")
        DesktopVoiceVoiceprint.broken=true
        try DesktopVoiceSettings.saveDraft("")
        let noVerify=DesktopVoice();noVerify.submitUnlocked=submit
        noVerify.testVoiceprintEnrolled(true)
        noVerify.testReceive("小E，开灯",at:50);noVerify.testAudio([Float](repeating:0.4,count:24000),at:50)
        noVerify.testAdvance(to:52.1);noVerify.testAdvance(to:55)
        pump { !noVerify.draft.isEmpty }
        precondition(noVerify.draft=="开灯","声纹验不了时不放行，原话留稿")
        DesktopVoiceVoiceprint.broken=false;DesktopVoiceVoiceprint.match=true
        // 锁屏唤醒只给提示音：念一句“在呢”会把紧接着说的正文当自己的回声丢掉（mutedDrops 就是这么涨的）。
        try DesktopVoiceSettings.saveDraft("")
        LockScreenInput.locked = true
        let cue=DesktopVoice();cue.submitUnlocked=submit
        var cueSaid:[String]=[]
        cue.say={ phrase in cueSaid.append(phrase);return 0.3 }
        cue.testVoiceprintEnrolled(true)
        precondition(cue.testASR=="-","未收音时不声称识别模式")
        cue.testReceive("小E",at:300, final:false)
        precondition(cue.testASR=="cloud","锁屏优先走云端识别，长句才听得准")
        cue.testAdvance(to:300.6)
        precondition(cueSaid.isEmpty && cue.testCapturing,"锁屏唤醒不出声应答，也不因此停听")
        cue.testReceive("小E，明天我有几个日程",at:301)
        cue.testAudio([Float](repeating:0.4,count:24000),at:301.2)
        cue.testAdvance(to:303.5);cue.testAdvance(to:306.2);cue.testAdvance(to:310)
        pump { accept("明天我有几个日程") }
        precondition(accept("明天我有几个日程") && cue.testMutedDrops==0,"锁屏接着说的话不被自己的应答吞掉")
        LockScreenInput.locked=false
        // 注册按 2 秒切段：一段音频只能算一个样本，锁屏上就会在阈值边上抖。
        try DesktopVoiceSettings.saveDraft("")
        DesktopVoiceVoiceprint.enrollments=[]
        let learn=DesktopVoice();learn.submitUnlocked=submit
        learn.say={ _ in 0.2 }
        learn.testReceive("小E，记住我的声音",at:400)
        learn.testAudio([Float](repeating:0.3,count:32000),at:400.6)
        learn.testAdvance(to:404);learn.testAdvance(to:407)
        let burst=[Float](repeating:0.3,count:24000),gap=[Float](repeating:0,count:9600)
        learn.testAudio(burst+gap+burst+gap+burst,at:408)
        learn.testAdvance(to:430)
        pump { DesktopVoiceVoiceprint.enrollments.count >= 3 }
        precondition(DesktopVoiceVoiceprint.enrollments.count==3,"念三句注册就得到三个样本，画像不再靠单一样本")
        LockScreenInput.locked=false
        let revised=DesktopVoice();revised.submitUnlocked=submit
        revised.testReceive("小E，关灯",at:30)
        revised.testReceive("小E，不要关灯",at:31)
        revised.testAdvance(to:33.1);precondition(writes==2,"修订为否定后不执行旧字幕")
        let free=DesktopVoice();free.submitUnlocked=submit
        free.testReceive("小E，帮我记录明天的待办",at:50)
        free.testAdvance(to:52.1);free.testAdvance(to:54.7)
        precondition(writes==3 && free.draft.isEmpty,"收尾超时不卡死：按已听内容提交一次")
        let stuck=DesktopVoice();stuck.submitUnlocked=submit
        stuck.testReceive("小E，帮我看看今天的天气怎么样",at:60)
        stuck.testAdvance(to:62.1)
        precondition(writes==3,"进入收尾但尚未超时不提前派单")
        stuck.testSegment();stuck.testReceive("小E，关灯",at:63)
        precondition(writes==3 && DesktopVoiceSettings.parked().contains("天气"),"重喊开启新轮，旧半句保留而不执行")
        stuck.testAdvance(to:65.1)
        precondition(writes==4 && stuck.draft.isEmpty,"重开的一轮照常提交且不留草稿")
        let parked=DesktopVoice()
        try parked.testPark("上一条没发出去的")
        precondition(parked.testParked == "上一条没发出去的" && DesktopVoiceSettings.parked() == "上一条没发出去的" && parked.draft.isEmpty,"旧草稿挪到较早未发送槽，不再阻挡新一轮收音")
        let resume=DesktopVoice();resume.submitUnlocked=submit
        resume.testReceive("小E，帮我看看今天的天气怎么样",at:70)
        resume.testAdvance(to:72.1)
        resume.testAudio([Float](repeating:0.5,count:160),at:73)
        resume.testAdvance(to:74)
        precondition(writes==4 && resume.draft.isEmpty,"收尾中重新说话撤销收尾，不提前派单")
        let cumulative=DesktopVoice();cumulative.submitUnlocked=submit
        cumulative.testReceive("小E，帮我",at:80)
        cumulative.testReceive("小E，帮我记一条明天",at:81)
        cumulative.testReceive("小E，帮我记一条明天整理资料的待办",at:82)
        precondition((cumulative.snapshot()["voiceDebug"] as! [String:Any])["rewakes"] as? Int == 0,"同段转写更新不反复重开")
        cumulative.testReceive("小E，帮我记一条明天整理资料的待办，小E，关灯",at:83)
        precondition(DesktopVoiceSettings.parked().contains("整理资料"),"同段第二次唤醒保留旧内容")
        cumulative.testAdvance(to:85.1);precondition(writes==5,"同段新口令只执行一次")
        let interrupt=DesktopVoice();interrupt.submitUnlocked=submit
        var playing=true, interrupted=false
        interrupt.speaking={playing};interrupt.stopSpeaking={playing=false;interrupted=true}
        interrupt.testReceive("嗯，办好了",at:90)
        precondition(!interrupted,"回采普通播报不触发唤醒")
        interrupt.testReceive("嗯，办好了，小E，关灯",at:91)
        precondition(interrupted && !playing,"播报期间新唤醒立即停止旧声音")
        interrupt.testAdvance(to:93.1);precondition(writes==6,"打断后新口令照常提交")
        let queue=try DesktopVoiceSettings.parkedRecords()
        precondition(queue.count>=3,"连续重开不覆盖较早草稿")
        let ids=queue.map(\.requestID)
        try DesktopVoiceSettings.saveParked(nil)
        let remaining=try DesktopVoiceSettings.parkedRecords().map(\.requestID)
        precondition(remaining==Array(ids.dropFirst()),"仅移除明确处理的一条")
        let history=try Data(contentsOf:DesktopVoiceSettings.historyFile)
        try DesktopVoiceSettings.saveDraft("不能被覆盖的原文")
        try Data("corrupt".utf8).write(to:DesktopVoiceSettings.historyFile)
        let blocked=DesktopVoice();blocked.submitUnlocked=submit
        blocked.testReceive("小E，关灯",at:100)
        precondition(writes==6 && blocked.draft=="不能被覆盖的原文" && DesktopVoiceSettings.draft()=="不能被覆盖的原文", "旧输入队列损坏时不丢当前正文、不执行新任务")
        try history.write(to:DesktopVoiceSettings.historyFile)
        let acknowledgment=DesktopVoice();var replies=0
        acknowledgment.say={_ in replies += 1;return 0.3}
        acknowledgment.testReceive("小E",at:110)
        acknowledgment.testAudio([Float](repeating:0.5,count:160),at:110.3)
        acknowledgment.testAdvance(to:110.4)
        precondition(replies==0,"用户还在说话时不抢着应答")
        acknowledgment.testAdvance(to:110.7)
        precondition(replies==1,"只喊名字且停顿后应答一次")
        let concurrent=DesktopVoice()
        var taskIDs:[String]=[],finished=Set<String>(),speechCount=0
        concurrent.say={_ in speechCount+=1;return 0.1}
        concurrent.submitUnlocked={_,request in
            var t=AgentTask(id:UUID().uuidString,requestId:request,controlSession:"native")
            t.status = .running;TaskStore.tasks[t.id]=t;taskIDs.append(t.id);return t
        }
        concurrent.presentTask={t in if t.status == .succeeded { finished.insert(t.id) } }
        concurrent.testReceive("小E，开灯",at:200);concurrent.testAdvance(to:202.1)
        precondition(taskIDs.count==1)
        concurrent.testSegment();concurrent.testReceive("小E，关灯",at:203)
        TaskStore.tasks[taskIDs[0]]!.status = .succeeded
        concurrent.testAdvance(to:203.2)
        precondition(speechCount==0 && finished.isEmpty,"旧任务完成不抢新一轮收音")
        concurrent.testAdvance(to:205.1);concurrent.testAdvance(to:205.2)
        precondition(taskIDs.count==2 && finished.contains(taskIDs[0]),"新任务不覆盖旧任务的完成回执")
        TaskStore.tasks[taskIDs[1]]!.status = .succeeded
        concurrent.testAdvance(to:205.4)
        precondition(finished==Set(taskIDs) && speechCount==2,"后台任务各自播报一次结果")
        print("Desktop voice lifecycle: short command submitted once without native final; negation, rewake recovery and finalize timeout handled")
        #endif
        // ---------- 唤醒后的正文交给豆包：本地只做并行兜底 ----------
        var handed = DesktopVoiceSettings(); handed.dictationEnabled = true; try handed.save()
        var beginCalls = 0, cancelCalls = 0
        let handoff = DesktopVoice(); handoff.submitUnlocked = submit
        handoff.dictationAvailable = { true }
        handoff.dictationBegin = { beginCalls += 1; return true }
        handoff.dictationCancel = { cancelCalls += 1 }
        var before = writes
        handoff.testReceive("小E", at: 300)
        let handedState = handoff.snapshot()["dictation"] as? [String: Any]
        precondition(beginCalls == 1 && handedState?["active"] as? Bool == true, "只喊名字就交给豆包接管")
        handoff.testReceive("帮我记一条明天整理资料的待办", at: 301)
        handoff.testAdvance(to: 304)
        precondition(writes == before, "豆包收音时本地那段不抢先派单")
        handoff.finishDictation(nil)
        precondition(cancelCalls == 1, "接管结束一律叫停，不留豆包继续往接收框里打字")
        handoff.testAdvance(to: 310)
        handoff.testAdvance(to: 313)
        precondition(writes == before + 1, "豆包没接上就用本地并行听到的那份派单")

        // 名字那一声先唤醒，同一段的最终修订又把名字带了回来：进正文前得剥掉，
        // 否则“小E开灯”认不出是固定设备短口令，开灯只能退回模型跑四轮（实测 16 秒）。
        let named = DesktopVoice(); named.submitUnlocked = submit
        named.dictationAvailable = { true }
        named.dictationBegin = { true }
        before = writes
        named.testReceive("小E", at: 600)
        named.testReceive("小E开灯", at: 601)
        named.finishDictation(nil)
        named.testAdvance(to: 610); named.testAdvance(to: 613)
        precondition(writes == before + 1 && submitted.last == "开灯", "本地兜底剥掉唤醒名后仍按原话派单")

        let dictatedAgain = DesktopVoice(); dictatedAgain.submitUnlocked = submit
        dictatedAgain.dictationAvailable = { true }
        dictatedAgain.dictationBegin = { true }
        before = writes
        dictatedAgain.testReceive("小E", at: 400)
        dictatedAgain.testReceive("开个会", at: 401)
        dictatedAgain.finishDictation("把明天的周会推迟到下午三点")
        precondition(writes == before + 1, "豆包出字就按它派单")

        let unavailable = DesktopVoice(); unavailable.submitUnlocked = submit
        unavailable.dictationAvailable = { false }
        unavailable.dictationBegin = { beginCalls += 1; return true }
        before = writes
        unavailable.testReceive("小E", at: 500)
        let unavailableState = unavailable.snapshot()["dictation"] as? [String: Any]
        precondition(unavailableState?["active"] as? Bool == false, "豆包没就绪不接管")
        unavailable.testReceive("帮我记一条待办", at: 501)
        unavailable.testAdvance(to: 510)
        unavailable.testAdvance(to: 513)
        precondition(writes == before + 1, "豆包不可用时本地照常派单")

        // 豆包是按住说话：本地听出说完了就让它松手，而不是等它自己停。
        var finishCalls = 0
        let silence = DesktopVoice(); silence.submitUnlocked = submit
        silence.dictationAvailable = { true }
        silence.dictationBegin = { true }
        silence.dictationCharacters = { 0 }
        silence.dictationFinishTurn = { finishCalls += 1 }
        silence.testReceive("小E", at: 600)
        silence.testDictationAudio([Float](repeating: 0.5, count: 160), at: 601)
        silence.testReceive("帮我记一条明天整理资料的待办", at: 601)
        silence.testAdvance(to: 602.5)
        precondition(finishCalls == 0, "停顿不够长不松手")
        silence.testAdvance(to: 604.5)
        precondition(finishCalls == 1, "本地听出说完了就让它松手收尾")

        // 播报还没停就喊名字：按字数估的静音额度不能把声学时钟冻住。本地这一路听不到声、
        // 豆包面板却还在出字，就仍然是“人还在说”，不能在两秒时松手把后半句吃掉。
        var mutedFinish = 0
        var panel = 0
        let muted = DesktopVoice(); muted.submitUnlocked = submit
        muted.speaking = { true }
        muted.dictationAvailable = { true }
        muted.dictationBegin = { true }
        muted.dictationCharacters = { panel }
        muted.dictationFinishTurn = { mutedFinish += 1 }
        muted.testReceive("小E", at: 800)
        panel = 4; muted.testAdvance(to: 801)
        muted.testAdvance(to: 803)
        precondition(mutedFinish == 0, "播报静音期内不听声音，豆包还在出字就是还在说")
        panel = 9; muted.testAdvance(to: 805)
        precondition(mutedFinish == 0, "豆包继续出字就不松手")
        muted.testAdvance(to: 806.5)
        precondition(mutedFinish == 0, "面板刚停一秒多，再等他一句")
        muted.testAdvance(to: 808.5)
        precondition(mutedFinish == 1, "面板也不出字了才替它松手")

        // 唤醒后一直没人说话：不抱着麦克风干等，直接回到待唤醒。
        let idle = DesktopVoice(); idle.submitUnlocked = submit
        idle.dictationAvailable = { true }
        idle.dictationBegin = { true }
        idle.testReceive("小E", at: 700)
        idle.testAdvance(to: 707)
        precondition((idle.snapshot()["dictation"] as! [String: Any])["active"] as? Bool == true, "八秒内仍等人开口")
        idle.testAdvance(to: 709)
        precondition((idle.snapshot()["dictation"] as! [String: Any])["active"] as? Bool == false, "一直没人说话就交回待唤醒")

        print("Desktop voice draft: accepted receipt, cleanup failure, restart dedupe and locked preservation passed")
    }
}
