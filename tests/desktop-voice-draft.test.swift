/**
 * [INPUT]: 真实DesktopVoice草稿提交/私有存储与任务/锁屏替身；临时只读目录制造清理失败。
 * [OUTPUT]: 锁屏短句无声纹依赖且单次提交；追问念出问题与候选、念完前的声音不当回答、8秒内免唤醒回答接回原任务且不另开、窗口过期不接；验证字幕修订不重唤醒、新呼叫保留旧半句而不提交、播报可打断、旧输入队列及故障去重；固定口令仍单次提交；豆包接管时正文不用、转交给它，它没接上就回落到本地并行听到的那份且剥掉唤醒名，它出字也剥。
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
struct AgentTask { var id: String; var requestId: String; var controlSession: String?; var status = TaskStatus.succeeded; var result: String? = nil; var recovery: Recovery? = nil; var text: String = ""; var error: String? = nil; var spoken: String? = nil }
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
/// 等待主线程任务回执。
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

        // 锁屏短句直接派单，不要求一秒声纹样本，也不依赖任何声纹桥。
        try DesktopVoiceSettings.saveDraft("")
        let direct=DesktopVoice();direct.submitUnlocked=submit
        let lockedCountBefore=TaskService.lockedSubmissions.count
        direct.testReceive("小E，开灯",at:30)
        direct.testAdvance(to:32.1);direct.testAdvance(to:35)
        precondition(TaskService.lockedSubmissions.count==lockedCountBefore+1 && accept("开灯"),"锁屏无声纹音频也只提交一次")
        precondition(direct.draft.isEmpty,"锁屏短句已接收后清理草稿")
        // 锁屏唤醒只给提示音：念一句“在呢”会把紧接着说的正文当自己的回声丢掉（mutedDrops 就是这么涨的）。
        try DesktopVoiceSettings.saveDraft("")
        LockScreenInput.locked = true
        let cue=DesktopVoice();cue.submitUnlocked=submit
        var cueSaid:[String]=[]
        cue.say={ phrase in cueSaid.append(phrase);return 0.3 }
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
        // 追问把问题本身念出来；念完几秒内不用再喊名字，直接回答就接回原任务，不另开新任务。
        LockScreenInput.locked=false
        let ask=DesktopVoice()
        var askIDs:[String]=[],heard:[String]=[],continued:[(String,String)]=[]
        ask.say={text in heard.append(text);return 0.5}
        ask.submitUnlocked={_,request in
            var t=AgentTask(id:UUID().uuidString,requestId:request,controlSession:"native")
            t.status = .running;TaskStore.tasks[t.id]=t;askIDs.append(t.id);return t
        }
        ask.continueTask={id,text in
            continued.append((id,text));var t=TaskStore.tasks[id]!;t.status = .running;TaskStore.tasks[id]=t;return t
        }
        ask.testReceive("小E，给张三发消息说我晚点到",at:800)
        ask.testAdvance(to:802.1);ask.testAdvance(to:804.7)
        precondition(askIDs.count==1,"第一句正常派单")
        TaskStore.tasks[askIDs[0]]!.status = .needsInput
        TaskStore.tasks[askIDs[0]]!.result = "要发给哪个张三？\n1. 产品部张三\n2. 研发部张三"
        ask.testAdvance(to:804.8)
        precondition(heard.last=="要发给哪个张三？产品部张三，还是研发部张三？","追问把问题和候选念出来，而不是“有个地方要你定一下”")
        ask.testSegment();ask.testReceive("研发部那个",at:806)
        precondition(continued.isEmpty && ((ask.snapshot()["voiceDebug"] as? [String: Any])?["replies"] as? Int ?? -1)==0,"问题还没念完时的声音不当回答")
        ask.testSegment();ask.testReceive("研发部那个",at:811)
        ask.testAdvance(to:813.1);ask.testAdvance(to:815.7)
        precondition(continued.count==1 && continued[0].0==askIDs[0] && continued[0].1=="研发部那个","不喊名字的回答接回原任务")
        precondition(askIDs.count==1,"回答不另开新任务")
        // 窗口过了再随口说话不算回答，也不派单。
        TaskStore.tasks[askIDs[0]]!.status = .needsInput
        TaskStore.tasks[askIDs[0]]!.result = "几点开始？"
        ask.testAdvance(to:817)
        precondition(heard.last=="几点开始？","单句追问原样念")
        ask.testSegment();ask.testReceive("今天天气不错",at:840)
        ask.testAdvance(to:843);ask.testAdvance(to:846)
        precondition(continued.count==1 && askIDs.count==1,"免唤醒窗口过期后旁人说话不接任务")
        // 模型写了口播总括：流式中途先念，收尾时同一句不再念；没提前念的，收尾念总括而不是截正文第一句。
        let brief=DesktopVoice()
        var briefIDs:[String]=[],briefHeard:[String]=[]
        brief.say={text in briefHeard.append(text);return 0.5}
        brief.submitUnlocked={_,request in
            var t=AgentTask(id:UUID().uuidString,requestId:request,controlSession:"native",text:"明天有什么日程")
            t.status = .running;TaskStore.tasks[t.id]=t;briefIDs.append(t.id);return t
        }
        brief.testReceive("小E，明天有什么日程",at:900)
        brief.testAdvance(to:902.1);brief.testAdvance(to:904.7)
        precondition(briefIDs.count==1,"日程问句正常派单")
        brief.speakEarly(taskId:"别的任务",line:"不该念")
        precondition(briefHeard.isEmpty,"不是语音自己提交的任务不旁听")
        brief.speakEarly(taskId:briefIDs[0],line:"明天两个日程，下午的撞了")
        precondition(briefHeard==["明天两个日程，下午的撞了"],"口播行写完就先念，不等整段回答")
        brief.speakEarly(taskId:briefIDs[0],line:"明天两个日程，下午的撞了")
        precondition(briefHeard.count==1,"同一任务只提前念一次")
        TaskStore.tasks[briefIDs[0]]!.status = .succeeded
        TaskStore.tasks[briefIDs[0]]!.result = "- 十点评审\n- 两点周会"
        TaskStore.tasks[briefIDs[0]]!.spoken = "明天两个日程，下午的撞了"
        brief.testAdvance(to:908)
        precondition(briefHeard.count==1,"收尾时同一句总括不再念第二遍")
        brief.testSegment();brief.testReceive("小E，这周有什么待办",at:920)
        brief.testAdvance(to:922.1);brief.testAdvance(to:924.7)
        precondition(briefIDs.count==2,"第二句正常派单")
        TaskStore.tasks[briefIDs[1]]!.status = .succeeded
        TaskStore.tasks[briefIDs[1]]!.result = "这周第一条是写周报，第二条是交报销，第三条是约体检。"
        TaskStore.tasks[briefIDs[1]]!.spoken = "这周三条待办，最急的是写周报"
        brief.testAdvance(to:925)
        precondition(briefHeard.last=="这周三条待办，最急的是写周报","没提前念的收尾时念总括，而不是正文第一句")
        // 连续对话：上一句刚派出去，紧接着说下一件不用重喊名字；像闲聊的话丢掉并立刻关窗；窗口过期、锁屏、关掉开关都不接。
        let chat=DesktopVoice()
        var chatIDs:[String]=[]
        chat.submitUnlocked={_,request in
            var t=AgentTask(id:UUID().uuidString,requestId:request,controlSession:"native")
            t.status = .running;TaskStore.tasks[t.id]=t;chatIDs.append(t.id);return t
        }
        chat.testReceive("小E，帮我记一个明天开会的待办",at:1000)
        chat.testAdvance(to:1002.1);chat.testAdvance(to:1004.7)
        precondition(chatIDs.count==1,"第一句照常派单")
        chat.testAdvance(to:1004.8)
        precondition(chat.status.contains("直接说"),"窗口开着时提示不用喊名字")
        chat.testSegment();chat.testReceive("再帮我查一下明天的天气",at:1005)
        chat.testAdvance(to:1007.1);chat.testAdvance(to:1009.7)
        precondition(chatIDs.count==2,"紧接着的下一句不喊名字也派单")
        chat.testSegment();chat.testReceive("哈哈哈哈太好笑了",at:1010)
        chat.testAdvance(to:1012.1);chat.testAdvance(to:1014.7)
        precondition(chatIDs.count==2 && ((chat.snapshot()["voiceDebug"] as! [String:Any])["followRejects"] as? Int)==1,"像闲聊的话不派单")
        chat.testSegment();chat.testReceive("打开微信",at:1015)
        chat.testAdvance(to:1017.1);chat.testAdvance(to:1019.7)
        precondition(chatIDs.count==2,"误接一次就关窗，后面的话不再接")
        chat.testSegment();chat.testReceive("小E，打开微信",at:1030)
        chat.testAdvance(to:1032.1);chat.testAdvance(to:1034.7)
        precondition(chatIDs.count==3,"重喊名字照常")
        chat.testSegment();chat.testReceive("那后天呢",at:1060)
        chat.testAdvance(to:1062.1);chat.testAdvance(to:1064.7)
        precondition(chatIDs.count==3,"窗口过期后不喊名字不接")
        chat.testSegment();chat.testReceive("小E，帮我记一条待办",at:1070)
        chat.testAdvance(to:1072.1);chat.testAdvance(to:1074.7)
        chat.testSegment();chat.testReceive("谢谢",at:1075)
        chat.testAdvance(to:1077.1);chat.testAdvance(to:1079.7)
        chat.testSegment();chat.testReceive("帮我把灯关了",at:1080)
        chat.testAdvance(to:1082.1);chat.testAdvance(to:1084.7)
        precondition(chatIDs.count==4,"说“谢谢”结束这轮，之后不再免唤醒")
        var noFollow=DesktopVoiceSettings();noFollow.dictationEnabled=false;noFollow.followUpEnabled=false;try noFollow.save()
        let off=DesktopVoice()
        var offIDs=0
        off.submitUnlocked={_,request in offIDs+=1;var t=AgentTask(id:UUID().uuidString,requestId:request,controlSession:"native");t.status = .running;TaskStore.tasks[t.id]=t;return t}
        off.testReceive("小E，帮我记一个待办",at:1100)
        off.testAdvance(to:1102.1);off.testAdvance(to:1104.7)
        off.testSegment();off.testReceive("再帮我查一下天气",at:1105)
        off.testAdvance(to:1107.1);off.testAdvance(to:1109.7)
        precondition(offIDs==1,"关掉连续对话就每次都要喊名字")
        try local.save()
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
        precondition(beginCalls == 0, "只喊名字先等一下，看名字后面是不是紧接着有话")
        handoff.testAdvance(to: 300.7)
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
        named.testAdvance(to: 600.7)
        named.testReceive("小E开灯", at: 601)
        named.finishDictation(nil)
        named.testAdvance(to: 610); named.testAdvance(to: 613)
        precondition(writes == before + 1 && submitted.last == "开灯", "本地兜底剥掉唤醒名后仍按原话派单")

        let dictatedAgain = DesktopVoice(); dictatedAgain.submitUnlocked = submit
        dictatedAgain.dictationAvailable = { true }
        dictatedAgain.dictationBegin = { true }
        before = writes
        dictatedAgain.testReceive("小E", at: 400)
        dictatedAgain.testAdvance(to: 400.7)
        dictatedAgain.testReceive("开个会", at: 401)
        dictatedAgain.finishDictation("把明天的周会推迟到下午三点")
        precondition(writes == before + 1, "豆包出字就按它派单")

        let unavailable = DesktopVoice(); unavailable.submitUnlocked = submit
        unavailable.dictationAvailable = { false }
        unavailable.dictationBegin = { beginCalls += 1; return true }
        before = writes
        unavailable.testReceive("小E", at: 500)
        unavailable.testAdvance(to: 500.7)
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
        silence.testAdvance(to: 600.7)
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
        idle.testAdvance(to: 700.7)
        idle.testAdvance(to: 707)
        precondition((idle.snapshot()["dictation"] as! [String: Any])["active"] as? Bool == true, "八秒内仍等人开口")
        idle.testAdvance(to: 709)
        precondition((idle.snapshot()["dictation"] as! [String: Any])["active"] as? Bool == false, "一直没人说话就交回待唤醒")

        // 一句话唤醒：识别先吐出“小E”、紧接着修订成“小E开灯”——不能在名字那一刻就把麦克风交给豆包，
        // 否则豆包只听到半句“灯”并以它为准；整句由本机听完，按“开灯”走固定短口令。
        var oneShotBegins = 0
        let oneShot = DesktopVoice(); oneShot.submitUnlocked = submit
        oneShot.dictationAvailable = { true }
        oneShot.dictationBegin = { oneShotBegins += 1; return true }
        before = writes
        oneShot.testReceive("小E", at: 800)
        oneShot.testReceive("小E开灯", at: 800.3)
        oneShot.testAdvance(to: 800.8)
        precondition(oneShotBegins == 0, "名字后面紧接着有话就不交给豆包")
        oneShot.testAdvance(to: 802.4)
        precondition(writes == before + 1 && submitted.last == "开灯", "小E开灯一句话执行")
        precondition((oneShot.snapshot()["voiceDebug"] as! [String: Any])["oneShots"] as? Int == 1, "一句话唤醒计数")

        print("Desktop voice draft: accepted receipt, cleanup failure, restart dedupe and locked preservation passed")
    }
}
