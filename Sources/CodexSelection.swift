/**
 * [INPUT]: Codex 专属动作与只读项目/任务快照。
 * [OUTPUT]: 唯一目标、模型读取的结构化列表或简短中文选择问题；候选只呈现名称与必要目录，不泄漏内部 ID；项目新页核验限定撰写区关联，不将侧栏名称当作当前项目。
 * [POS]: 与桌面动作无关的目标选择/证据策略，支持无副作用回归。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreGraphics

enum CodexSelection {
    enum Resolution {
        case list(String), destination(CodexDestination), question(String)
    }
    static func json(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "读取失败：Codex 列表无法编码。" }
        return text
    }
    static func resolve(_ request: CodexActionRequest, snapshot: CodexCatalog.Snapshot) throws -> Resolution {
        if request.action == .listProjects {
            return .list(json(["projects": snapshot.projects.map(\.dictionary)]))
        }
        var project: CodexCatalog.Project?
        if let query = request.project {
            let matches = CodexCatalog.matchProjects(query, in: snapshot.projects)
            guard matches.count == 1 else {
                return .question(matches.isEmpty ? "没找到“" + choiceName(query) + "”项目，请说一下准确项目名。"
                    : projectQuestion(matches))
            }
            project = matches[0]
        }
        if [.openProject, .sendProject].contains(request.action), let project {
            let requestedPath = request.project.flatMap(CodexCatalog.projectPath)
                .flatMap { project.paths.contains($0) ? $0 : nil }
            guard let path = requestedPath ?? (project.paths.count == 1 ? project.paths[0] : nil) else {
                return .question(choices("“" + choiceName(project.name) + "”有多个目录，请选一个：",
                    values: project.paths.map(displayPath), guidance: "直接说完整目录即可。"))
            }
            return .destination(.project(project, path, nameUnique: snapshot.projects.filter { CodexCatalog.key($0.name) == CodexCatalog.key(project.name) }.count == 1))
        }
        let scoped = snapshot.chats.filter { project == nil || $0.projectId == project?.id }
        if request.action == .listTasks {
            let matches = try CodexCatalog.matchChats(request.task, projectId: project?.id, unreadOnly: false, in: scoped)
            let displayed = request.unreadOnly == true ? matches.filter { $0.unread == true } : matches
            return .list(json(["tasks": displayed.prefix(40).map(\.dictionary), "hasMore": displayed.count > 40 || snapshot.truncated,
                               "unreadStateKnown": !matches.contains { $0.unread == nil },
                               "note": request.unreadOnly == true && matches.contains { $0.unread == nil }
                                ? "只列出已确认未读项；其他状态未知，不等于没有蓝点。可展开项目侧边栏或按任务标题选择。" : "本机任务元数据，不含正文。"] ))
        }
        if snapshot.truncated, request.task.flatMap({ UUID(uuidString: $0) }) == nil {
            return .question("任务太多，暂时无法准确定位。请在 Codex 中打开要继续的任务。")
        }
        let matches = try CodexCatalog.matchChats(request.task, projectId: project?.id, unreadOnly: request.unreadOnly == true, in: scoped)
        guard matches.count == 1 else {
            if matches.isEmpty && snapshot.truncated { throw CodexCatalog.Failure(message: "任务索引范围不完整，请使用更准确的任务名称。") }
            return .question(matches.isEmpty ? "没找到这个 Codex 任务，请说一下准确任务名。"
                : taskQuestion(matches, projects: snapshot.projects))
        }
        let chat = matches[0]
        return .destination(.task(chat, titleUnique: !snapshot.truncated && snapshot.chats.filter { $0.title == chat.title }.count == 1))
    }
    private static func choiceName(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    private static func choices(_ heading: String, values: [String], guidance: String) -> String {
        let lines = values.prefix(5).enumerated().map { "\($0.offset + 1). \($0.element)" }
        let overflow = values.count > 5 ? "\n还有 \(values.count - 5) 项未显示。" : ""
        return heading + "\n" + lines.joined(separator: "\n") + overflow + "\n" + guidance
    }
    private static func projectQuestion(_ projects: [CodexCatalog.Project]) -> String {
        var indistinguishable = false
        let values = projects.map { project in
            let sameName = projects.filter { CodexCatalog.key($0.name) == CodexCatalog.key(project.name) }
            guard sameName.count > 1 else { return choiceName(project.name) }
            let otherPaths = sameName.filter { $0.id != project.id }.flatMap(\.paths)
            guard let path = project.paths.first(where: { !otherPaths.contains($0) }) else {
                indistinguishable = true
                return choiceName(project.name) + "（同名且目录相同）"
            }
            return choiceName(project.name) + "（" + displayPath(path) + "）"
        }
        let guidance = indistinguishable ? "同名且目录相同的项目，请先在 Codex 中修改名称，再告诉我。"
            : "直接说项目名；同名项目请说完整目录。"
        return choices("有多个项目符合，请选一个：", values: values, guidance: guidance)
    }
    private static func taskQuestion(_ chats: [CodexCatalog.Chat], projects: [CodexCatalog.Project]) -> String {
        var indistinguishable = false
        let values = chats.map { chat in
            let sameTitle = chats.filter { CodexCatalog.key($0.title) == CodexCatalog.key(chat.title) }
            guard sameTitle.count > 1 else { return choiceName(chat.title) }
            if sameTitle.contains(where: { $0.id != chat.id && $0.projectId == chat.projectId }) {
                indistinguishable = true
            }
            let project = projects.first { $0.id == chat.projectId }
            return choiceName(chat.title) + "（" + (project.map { choiceName($0.name) } ?? displayPath(chat.cwd)) + "）"
        }
        let guidance = indistinguishable ? "同一项目里的同名任务，请在 Codex 中直接打开。"
            : "直接说任务名；同名任务请一起说项目名。"
        return choices("有多个任务符合，请选一个：", values: values, guidance: guidance)
    }
    static func isUnreadLabel(_ label: String, title: String) -> Bool {
        [title + ", Unread", title + ", unread", title + "，未读", title + " 未读",
         "Unread, " + title, "未读，" + title].contains(label)
    }
    /// home 页有完整可访问性标签；default/hero 的按钮只显示名称。
    /// 裸名称必须来自已确认与撰写框关联的控件，不能接受侧栏、正文或整窗同名项目。
    /// 同名项目或多根目录仍要求准确路径，路径不做大小写归一。
    static func isProjectSelector(_ destination: CodexDestination, role: String, label: String,
                                  composerScoped: Bool = false) -> Bool {
        guard case .project(let project, let path, let nameUnique) = destination,
              ["AXButton", "AXPopUpButton"].contains(role) else { return false }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityMatches: (String) -> Bool = { identity in
            identity == path || (nameUnique && project.paths.count == 1
                && CodexCatalog.key(identity) == CodexCatalog.key(project.name))
        }
        for prefix in ["Change project: ", "切换项目：", "更改項目：", "變更專案："] where label.hasPrefix(prefix) {
            return identityMatches(String(label.dropFirst(prefix.count)))
        }
        return composerScoped && identityMatches(label)
    }

    /// 不让普通 AXTitle 遮住 AXDescription/AXHelp 中真正的项目标签。
    static func projectSelectorLabel(_ destination: CodexDestination, role: String, labels: [String],
                                     composerScoped: Bool = false) -> String? {
        if let explicit = labels.first(where: { isProjectSelector(destination, role: role, label: $0) }) { return explicit }
        return composerScoped ? labels.first { isProjectSelector(destination, role: role, label: $0, composerScoped: true) } : nil
    }

    /// 撰写区控件还必须有真实几何关联；相同名称在侧栏或页面远处不能通过。
    /// 这是读取控件的范围约束，不是用于盲点的坐标。
    static func isComposerControl(frame: CGRect?, editorFrame: CGRect?) -> Bool {
        guard let frame, let editorFrame,
              [frame, editorFrame].allSatisfy({ rect in
                  !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
                      && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
              }), frame.height <= 96, frame.width <= editorFrame.width + 48 else { return false }
        return frame.midX >= editorFrame.minX - 24 && frame.midX <= editorFrame.maxX + 24
            && frame.midY >= editorFrame.minY - 96 && frame.midY <= editorFrame.maxY + 96
    }

    /// 共有父节点不能是覆盖正文和侧栏的整页分区，必须实际包住同一个撰写区。
    static func isComposerContainer(frame: CGRect?, editorFrame: CGRect?, controlFrame: CGRect?) -> Bool {
        guard let frame, let editorFrame, let controlFrame,
              isComposerControl(frame: controlFrame, editorFrame: editorFrame),
              !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0 else { return false }
        let bounds = editorFrame.insetBy(dx: -48, dy: -120)
        let container = frame.insetBy(dx: -2, dy: -2)
        return bounds.contains(frame) && container.contains(editorFrame) && container.contains(controlFrame)
    }
    static func identityMatches(_ destination: CodexDestination, labels: Set<String>, selected: Set<String>) -> Bool {
        switch destination {
        case .dot: return !selected.intersection(["Your dot", "Your.dot", "Your Dot", "你的 dot", "你的 Dot"]).isEmpty
        case .task(let chat, let titleUnique):
            return (titleUnique && selected.contains { $0 == chat.title || isUnreadLabel($0, title: chat.title) }) || selected.contains(chat.id)
        case .project(let project, let path, let nameUnique):
            return (nameUnique && selected.contains(project.name)) || selected.contains(path)
        }
    }
}
