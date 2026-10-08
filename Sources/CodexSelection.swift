/**
 * [INPUT]: Codex 专属动作与只读项目/任务快照。
 * [OUTPUT]: 唯一目标、分页候选或待选择问题；项目新页支持明确选择器标签及撰写区内唯一项目名称，限定局部关联，不将侧栏名称当作当前项目。
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
                return .question(matches.isEmpty ? "没有找到这个 Codex 本机项目：" + query
                    : "有多个匹配项目，请选一个：\n" + json(["projects": matches.map(\.dictionary)]))
            }
            project = matches[0]
        }
        if [.openProject, .sendProject].contains(request.action), let project {
            let requestedPath = request.project.flatMap { project.paths.contains($0) ? $0 : nil }
            guard let path = requestedPath ?? (project.paths.count == 1 ? project.paths[0] : nil) else {
                return .question("这个项目有多个目录，请选择要使用的目录：\n" + json(project.dictionary))
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
            return .question("本机任务索引范围不完整，请用列表返回的准确任务 ID 选择。")
        }
        let matches = try CodexCatalog.matchChats(request.task, projectId: project?.id, unreadOnly: request.unreadOnly == true, in: scoped)
        guard matches.count == 1 else {
            if matches.isEmpty && snapshot.truncated { throw CodexCatalog.Failure(message: "任务索引范围不完整，请使用更准确的任务名称。") }
            return .question(matches.isEmpty ? "没有找到符合条件的 Codex 任务。"
                : "有多个匹配任务，请选一个：\n" + json(["tasks": matches.prefix(40).map(\.dictionary), "hasMore": matches.count > 40]))
        }
        let chat = matches[0]
        return .destination(.task(chat, titleUnique: !snapshot.truncated && snapshot.chats.filter { $0.title == chat.title }.count == 1))
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
