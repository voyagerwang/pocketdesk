/**
 * [INPUT]: 依赖 AgentHTTP/Auth/TaskStore（装配期只读）与 SpriteSession/SpriteFeedback/SpriteFeedbackPanel。
 * [OUTPUT]: 强持有面板与协调层直至进程退出；提供 SpriteDesk.install(webRoot:)——桌面反馈的唯一装配入口：展示会话、任务只读投影与原生面板及离线球体资源。
 * [POS]: Sources 的桌面反馈装配层；独立成文件让 main.swift 只留一行接缝，也便于测试排除。
 *        不执行工具、不修改任务状态机、不注入任何应用的输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// main.swift 只调 `SpriteDesk.install(webRoot:)` 一行。重复调用无害。
enum SpriteDesk {
    private static var installed = false
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
    }
}
