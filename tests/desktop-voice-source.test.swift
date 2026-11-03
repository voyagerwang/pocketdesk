/**
 * [INPUT]: 真实DesktopVoice协调器、真实EasyInput退避策略与任务/锁屏替身；不打开蓝牙、不打开麦克风。
 * [OUTPUT]: 验证断线退避序列、键盘中断超过宽限才换电脑麦克风、键盘回来自动切回、说话中不换源、播报回采余量按源放宽。
 * [POS]: 键盘→电脑麦克风兜底的回归；不启动识别、不派真实任务。
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
struct AgentTask { var id: String; var requestId: String; var controlSession: String?; var status = TaskStatus.succeeded; var text = ""; var result: String? = nil; var recovery: Recovery? = nil; var error: String? = nil; var spoken: String? = nil }
struct Recovery { var kind: String; var nextStep: String? = nil }
enum LockScreenInput { static var locked = false }
enum TaskStore { static var tasks: [String:AgentTask] = [:]; static func task(id: String) -> AgentTask? { tasks[id] } }
enum Auth { static let token = "fixture" }
enum TaskService {
    static func submit(subject:String,requestId:String,text:String,context:Int?,controlSession:String?) throws -> AgentTask { fatalError("no real task") }
    static func supplement(taskId:String,text:String,expectedRevision:Int?) throws -> AgentTask { fatalError("no real task") }
}
enum MijiaQuickControl { static func resolve(_ text:String)->Bool? { ["关灯","开灯"].contains(text) ? true : nil } }

@main struct Tests {
    static func main() throws {
        // 退避：1、2、4、8 秒之后固定 15 秒，插回键盘最多等一刻钟就接回来。
        precondition(EasyInputAudio.retryDelay(attempt: 0) == 0, "首次立即尝试")
        precondition(EasyInputAudio.retryDelay(attempt: 1) == 1, "第一次退避 1 秒")
        precondition(EasyInputAudio.retryDelay(attempt: 2) == 2, "第二次退避 2 秒")
        precondition(EasyInputAudio.retryDelay(attempt: 3) == 4, "第三次退避 4 秒")
        precondition(EasyInputAudio.retryDelay(attempt: 4) == 8, "第四次退避 8 秒")
        precondition(EasyInputAudio.retryDelay(attempt: 5) == 15 && EasyInputAudio.retryDelay(attempt: 9) == 15, "到顶后固定 15 秒，不用无限增长")

        // 兜底时机：断开后给 2 秒宽限，键盘在线就不换源。
        precondition(!DesktopVoiceTurn.wantsSystemFallback(linked: true, usingSystem: false, silentFor: 99), "键盘在线不换源")
        precondition(!DesktopVoiceTurn.wantsSystemFallback(linked: false, usingSystem: false, silentFor: 1.9), "宽限内不抢着换源")
        precondition(DesktopVoiceTurn.wantsSystemFallback(linked: false, usingSystem: false, silentFor: 2), "过了宽限换电脑麦克风")
        precondition(!DesktopVoiceTurn.wantsSystemFallback(linked: false, usingSystem: true, silentFor: 99), "已经在用电脑麦克风不重复换")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DesktopVoiceSettings.directory = dir
        defer {
            try? FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        // 本组守的是纯本机模式的输入源协调：蓝牙键盘优先、断开用电脑麦克风。
        var localOnly = DesktopVoiceSettings(); localOnly.dictationEnabled = false
        try localOnly.save(); try DesktopVoiceSettings.saveDraft("")
        var writes = 0
        let submit:(String,String)throws->AgentTask = { _, id in
            writes += 1
            return AgentTask(id: UUID().uuidString, requestId: id, controlSession: "native")
        }

        // 键盘在收音；断了之后不立刻换源，过了宽限才换，键盘回来立刻切回。
        let voice = DesktopVoice(); voice.submitUnlocked = submit
        voice.testAudio([Float](repeating: 0.5, count: 160), at: 1)
        precondition(voice.testSource.contains("蓝牙"), "默认键盘收音")
        voice.testLink(false, at: 2)
        voice.testAdvance(to: 3.9)
        precondition(voice.snapshot()["fallback"] as? Bool == false, "宽限内仍等键盘重连")
        voice.testAdvance(to: 4.1)
        precondition(voice.snapshot()["fallback"] as? Bool == true && voice.testMicStarts == 1, "过宽限用电脑麦克风顶上")
        precondition(voice.status.contains("电脑麦克风"), "状态说清楚现在靠电脑麦克风")
        voice.testSystemAudio([Float](repeating: 0.5, count: 160), at: 4.5)
        precondition(voice.snapshot()["receivingAudio"] as? Bool == true, "兜底源的声音照常进入识别链")
        voice.testLink(true, at: 5)
        precondition(voice.testSource.contains("蓝牙") && voice.testMicStops == 1, "键盘一确认连接就自动切回并关掉电脑麦克风")
        precondition(voice.status.contains("等待"), "切回后回到待唤醒")

        // 正在说话的半句不掐：键盘回来先记账，这一句说完才换源。
        let held = DesktopVoice(); held.submitUnlocked = submit
        held.testAudio([Float](repeating: 0.5, count: 160), at: 10)
        held.testReceive("小E，帮我记录明天的待办", at: 11)
        held.testLink(false, at: 11.2)
        held.testAdvance(to: 13.5)
        precondition(held.snapshot()["fallback"] as? Bool == true, "说话中断线也换源，别让人后面的话丢掉")
        held.testAudio([Float](repeating: 0.5, count: 160), at: 14)
        precondition(held.snapshot()["fallback"] as? Bool == true, "正在说话不切回，不掐半句")
        held.testAdvance(to: 22)
        precondition(writes == 1, "后半句照常收尾提交")
        precondition(held.snapshot()["fallback"] as? Bool == false, "这一句说完自动切回键盘")

        // 播报回采用电脑麦克风时要留更长的余音，否则会把自己的播报听成指令。
        let echo = DesktopVoice(); echo.submitUnlocked = submit
        echo.testLink(false, at: 30)
        echo.testAdvance(to: 32.5)
        precondition(echo.snapshot()["fallback"] as? Bool == true, "先进入兜底源")
        var spoken: Double = -1
        echo.say = { phrase in spoken = Double(phrase.count) / 4; return spoken }
        echo.testReceive("小E，关灯", at: 33)
        echo.testAdvance(to: 35.2)
        precondition(writes == 2, "兜底源下短口令照常单次提交")

        print("Desktop voice source: 断线退避、电脑麦克风兜底、自动切回与说话中不换源通过")
    }
}
