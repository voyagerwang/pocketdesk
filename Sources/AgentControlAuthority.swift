/**
 * [INPUT]: TaskStore当前任务事实、原生桌面/自动语音私有身份与既有WS控制租约查询。
 * [OUTPUT]: 锁屏语音可跑完整任务，工具范围按“需不需要解锁屏幕”收紧；能零模型办定的设备开关先走确定性快路；仅运行中任务可取得其实际来源的控制权限；未知会话或已退休的语音许可拒绝。
 * [POS]: AgentRunner控制授权的统一投影；语音来源不冒用手机会话，锁屏语音另受工具白名单与临时许可双重限制。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum AgentControlAuthority {
    /// 锁屏语音的确定性快路：一句话能零模型办定的设备开关，不白调一次模型。
    /// 没命中就返回 false，交给正常执行循环——锁屏也要能查日程、记待办、正常回话。
    static func runLockedVoice(_ task: AgentTask, completion: @escaping (AgentRunner.Outcome) -> Void) -> Bool {
        guard DesktopVoice.lockedTask(task) else { return false }
        guard DesktopVoice.authorizes(task) else {
            completion(.init(content: "这次指令的控制许可已经失效，请再喊一次。", usage: .zero,
                error: nil, pages: [], rounds: 0, drifted: false, needsInput: true)); return true
        }
        return AgentRunner.tryQuickControl(task: task, completion: completion)
    }
    /// 锁屏时做不成的工具：屏幕锁着，界面既看不见也无法点，驱动别人界面的派单同样无从核验。
    /// 这类提前拒掉并告知能怎么办，其余能力（设备、日程、待办、消息、提醒、检索）照常可用。
    static let lockedBlockedTools: Set<String> = ["open_app", "open_target", "open_page", "open_bookmark",
                                                  "desktop_action", "dispatch_to_app", "agent_workspace",
                                                  "codex_action", "close_duplicate_chrome_tabs"]
    static func lockedToolRefusal(taskId: String, tool: String) -> String? {
        guard let task = TaskStore.task(id: taskId), DesktopVoice.lockedTask(task),
              lockedBlockedTools.contains(tool) else { return nil }
        return "未执行：电脑锁屏时不能打开应用、网页或操作桌面。请改用不受锁屏影响的能力，并如实告诉用户解锁后再做这一步。"
    }
    static func allows(task: AgentTask?, remote: (String) -> Bool) -> Bool {
        guard let task, task.status == .running, let session = task.controlSession else { return false }
        if DesktopVoice.lockedTask(task) { return DesktopVoice.authorizes(task) }
        if SpriteDesktopInput.authorizes(task) { return true }
        return remote(session)
    }
}
