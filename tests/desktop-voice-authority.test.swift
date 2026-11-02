/**
 * [INPUT]: 真实AgentControlAuthority与纯任务/桌面来源/快捷控制替身。
 * [OUTPUT]: 验证锁屏语音可跑完整任务（快路口令零模型、其余交回正常执行循环）、无许可时零执行、需解锁屏幕的工具被逐条拒绝，其他来源仍遵循原租约。
 * [POS]: 自动语音锁屏边界回归；不录音、不锁屏、不执行设备写入或模型调用。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
struct AgentTask { enum Status { case running, succeeded }; var id = "t1"; var status = Status.running; var controlSession: String?; var text = "开灯" }
enum SpriteDesktopInput { static var allowed = false; static func authorizes(_ t: AgentTask) -> Bool { allowed } }
enum TaskStore { static var tasks: [String: AgentTask] = [:]; static func task(id: String) -> AgentTask? { tasks[id] } }
enum DesktopVoice {
    static var permitted = false
    static func authorizes(_ t: AgentTask) -> Bool { permitted && lockedTask(t) }
    static func lockedTask(_ t: AgentTask) -> Bool { t.controlSession == "voice-private" }
}
enum AgentRunner {
    enum Usage { case zero }
    struct Outcome { var content: String?; var usage: Usage; var error: String?; var pages: [String]; var rounds: Int; var drifted: Bool; var needsInput = false }
    static var calls = 0
    static func tryQuickControl(task: AgentTask, completion: @escaping (Outcome) -> Void) -> Bool {
        calls += 1
        if task.text != "开灯" { return false }
        completion(.init(content:"直接读回",usage:.zero,error:nil,pages:[],rounds:0,drifted:false));return true
    }
}
@main struct Tests {
    static var count = 0
    static func check(_ value: Bool, _ label: String) { count += 1; if !value { fatalError(label) } }
    static func main() {
        var remoteCalls = 0
        let remote: (String)->Bool = { _ in remoteCalls += 1; return true }
        var task = AgentTask(controlSession:"voice-private")
        TaskStore.tasks["t1"] = task
        check(!AgentControlAuthority.allows(task:nil,remote:remote),"无任务拒绝")
        check(!AgentControlAuthority.allows(task:task,remote:remote) && remoteCalls == 0,"退休语音不能借远程租约")
        var outcome: AgentRunner.Outcome?
        check(AgentControlAuthority.runLockedVoice(task){outcome=$0},"锁屏来源被独立入口接管")
        check(AgentRunner.calls == 0 && outcome?.needsInput == true,"无私有许可时零执行")

        DesktopVoice.permitted = true
        check(AgentControlAuthority.allows(task:task,remote:remote),"私有许可生效")
        check(AgentControlAuthority.runLockedVoice(task){outcome=$0} && outcome?.content == "直接读回","确定性快路零模型")

        // 锁屏也要能正常回话：非快路口令（问日程这类）交回正常执行循环，由模型作答。
        task.text = "明天我有几个日程"
        TaskStore.tasks["t1"] = task
        check(!AgentControlAuthority.runLockedVoice(task){_ in} && AgentRunner.calls == 2,"非快路口令不再被锁屏拦死，交回执行循环")

        // 需要解锁屏幕的工具在工具层拒绝；设备、日程、待办、消息、检索照常放行。
        for blocked in AgentControlAuthority.lockedBlockedTools.sorted() {
            check(AgentControlAuthority.lockedToolRefusal(taskId:"t1",tool:blocked) != nil,"锁屏拒绝桌面工具：\(blocked)")
        }
        for allowed in ["mijia","feishu_execute","feishu_message","read_workbench_event","create_workbench_task",
                        "search_web","wake_alarm","search_computer_files"] {
            check(AgentControlAuthority.lockedToolRefusal(taskId:"t1",tool:allowed) == nil,"锁屏放行：\(allowed)")
        }
        check(AgentControlAuthority.lockedToolRefusal(taskId:"missing",tool:"open_app") == nil,"未知任务不冒充锁屏拒绝")

        // 非锁屏来源不受这套限制，也不留桌面工具的拒绝。
        var unlocked = AgentTask(controlSession:"ws-active")
        unlocked.id = "t2"; TaskStore.tasks["t2"] = unlocked
        check(AgentControlAuthority.lockedToolRefusal(taskId:"t2",tool:"open_app") == nil,"非锁屏任务不适用桌面工具拒绝")
        check(!AgentControlAuthority.runLockedVoice(unlocked){_ in},"非语音保持原执行循环")
        check(AgentControlAuthority.allows(task:unlocked,remote:remote) && remoteCalls == 1,"原WS租约仍可用")

        task.status = .succeeded
        check(!AgentControlAuthority.allows(task:task,remote:remote),"终态失权")
        unlocked.controlSession = nil
        check(!AgentControlAuthority.allows(task:unlocked,remote:remote),"无会话拒绝")
        print("Desktop voice authority: \(count) checks passed")
    }
}
