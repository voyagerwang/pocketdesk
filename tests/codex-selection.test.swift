/**
 * [INPUT]: CodexCatalog 的分层项目匹配、CodexSelection 的纯目标解析与 AgentTaskComposer.NavigationFocus 的注入焦点/时钟观察；可选 --live 只读本机项目名称/目录。
 * [OUTPUT]: 验证准确名称优先于共用旧目录、语音空格兼容、真正同名/同目录澄清及显式旧项目保留；验证导航初期未知焦点只在期限内等待，明确切应用、失权、锁屏或已确认后失焦均停止。
 * [POS]: Codex 项目发现、选择与导航门禁的隔离回归；焦点序列使用值替身，不读取真实桌面、不修改配置、不打开应用或派单。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct CodexSelectionTests {
    static func main() throws {
        navigationFocusSequences()
        let path = "/Users/test/Documents/PocketDesk"
        let pocket = CodexCatalog.Project(id: "current", name: "PocketDesk", paths: [path])
        let legacy = CodexCatalog.Project(id: "legacy", name: "voice-deck-mvp", paths: ["/Users/test/archive/voice-deck-mvp", path])
        let projects = [legacy, pocket]
        func ids(_ query: String, in candidates: [CodexCatalog.Project] = projects) -> [String] {
            CodexCatalog.matchProjects(query, in: candidates).map(\.id)
        }
        assert(ids("PocketDesk") == [pocket.id], "准确项目名优先于旧项目的附带目录")
        assert(ids(" Pocket Desk ") == [pocket.id], "语音转写的空格不制造伪歧义")
        assert(ids("POCKET\tDESK") == [pocket.id])
        assert(ids("voice-deck-mvp") == [legacy.id], "明确旧项目名称仍可选择")
        assert(ids("legacy") == [legacy.id], "准确 ID 仍保留身份选择")
        assert(ids(path) == projects.map(\.id), "共用完整路径没有唯一身份，仍需澄清")
        assert(ids(path.lowercased()).isEmpty, "完整目录严格区分大小写，不误开其他目录")
        assert(ids("Pocket") == [pocket.id], "准确匹配未命中时允许名称片段")
        assert(ids(" ").isEmpty)
        let duplicate = CodexCatalog.Project(id: "duplicate", name: "pocketdesk", paths: ["/Users/test/other"])
        assert(ids("PocketDesk", in: projects + [duplicate]) == [pocket.id, duplicate.id], "真正同名不猜测")
        let spaced = CodexCatalog.Project(id: "spaced", name: "Pocket Desk", paths: ["/Users/test/spaced"])
        assert(ids("Pocket Desk", in: projects + [spaced]) == [spaced.id], "完整准确名称先于去空格别名")
        assert(ids("PocketDesk", in: [legacy]) == [legacy.id], "没有准确名称时保留目录末级回退")
        let accented = CodexCatalog.Project(id: "accented", name: "Café", paths: ["/Users/test/cafe"])
        assert(ids("cafe\u{301}", in: [accented]) == [accented.id])

        let snapshot = CodexCatalog.Snapshot(projects: projects, chats: [], truncated: false)
        let openPocket = CodexActionRequest(action: .openProject, project: "Pocket Desk")
        guard case .destination(.project(let selected, let selectedPath, _)) = try CodexSelection.resolve(openPocket, snapshot: snapshot) else {
            fatalError("Pocket Desk 应唯一解析到当前项目")
        }
        assert(selected.id == pocket.id && selectedPath == path)
        let openLegacy = CodexActionRequest(action: .openProject, project: "voice-deck-mvp")
        guard case .question(let directoryQuestion) = try CodexSelection.resolve(openLegacy, snapshot: snapshot) else {
            fatalError("显式旧项目有多个目录时仍要求选择目录，不得打开当前项目")
        }
        assert(directoryQuestion.contains("多个目录"))
        let openSharedPath = CodexActionRequest(action: .openProject, project: path)
        guard case .question = try CodexSelection.resolve(openSharedPath, snapshot: snapshot) else {
            fatalError("共用完整路径不能自动选项目")
        }
        func question(_ request: CodexActionRequest, snapshot: CodexCatalog.Snapshot) throws -> String {
            guard case .question(let text) = try CodexSelection.resolve(request, snapshot: snapshot) else {
                fatalError("应返回可读选择问题")
            }
            assert(!text.contains("{\"") && !text.contains("\"id\"") && !text.contains("\"paths\""), "选择问题不输出 JSON")
            assert(!text.contains("11111111-1111-1111-1111-111111111111"), "选择问题不展示内部 UUID")
            return text
        }
        let sharedQuestion = try question(openSharedPath, snapshot: snapshot)
        assert(sharedQuestion.contains("1. voice-deck-mvp") && sharedQuestion.contains("2. PocketDesk"))
        let namedQuestion = try question(openPocket, snapshot: .init(projects: projects + [duplicate], chats: [], truncated: false))
        assert(namedQuestion.contains(path) && namedQuestion.contains("/Users/test/other"), "同名项目用目录区分")
        let sameDirectory = CodexCatalog.Project(id: "same-dir", name: "PocketDesk", paths: [path])
        let indistinguishable = try question(openPocket, snapshot: .init(projects: [pocket, sameDirectory], chats: [], truncated: false))
        assert(indistinguishable.contains("同名且目录相同") && indistinguishable.contains("修改名称"))
        let candidates = (1...7).map { CodexCatalog.Project(id: "candidate-\($0)", name: "Project \($0)", paths: ["/test/\($0)"]) }
        let limitedQuestion = try question(.init(action: .openProject, project: "Project"),
            snapshot: .init(projects: candidates, chats: [], truncated: false))
        assert(limitedQuestion.contains("5. Project 5") && !limitedQuestion.contains("Project 6") && limitedQuestion.contains("还有 2 项"))
        let chatID = "11111111-1111-1111-1111-111111111111"
        let chats = [CodexCatalog.Chat(id: chatID, title: "查看更新", cwd: path, projectId: pocket.id, unread: false),
            CodexCatalog.Chat(id: "another-chat", title: "查看更新", cwd: "/Users/test/archive/voice-deck-mvp", projectId: legacy.id, unread: false)]
        let taskQuestion = try question(.init(action: .openTask, task: "查看更新"),
            snapshot: .init(projects: projects, chats: chats, truncated: false))
        assert(taskQuestion.contains("查看更新（PocketDesk）") && taskQuestion.contains("查看更新（voice-deck-mvp）"))
        let sameProjectChat = CodexCatalog.Chat(id: "same-project", title: "查看更新", cwd: path, projectId: pocket.id, unread: false)
        let duplicateTaskQuestion = try question(.init(action: .openTask, task: "查看更新"),
            snapshot: .init(projects: projects, chats: [chats[0], sameProjectChat], truncated: false))
        assert(duplicateTaskQuestion.contains("请在 Codex 中直接打开"))
        let truncatedQuestion = try question(.init(action: .openTask, task: "查看更新"),
            snapshot: .init(projects: projects, chats: chats, truncated: true))
        assert(!truncatedQuestion.contains("ID"))
        let homePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("PocketDesk-test").path
        let homeProject = CodexCatalog.Project(id: "home", name: "Home", paths: [homePath, "/test/another"])
        let tildeRequest = CodexActionRequest(action: .openProject, project: " ~/PocketDesk-test ")
        guard case .destination(.project(let tildeSelected, let tildePath, _)) = try CodexSelection.resolve(tildeRequest,
            snapshot: .init(projects: [homeProject], chats: [], truncated: false)) else {
            fatalError("展示的 ~ 目录可再次准确选择，不改路径大小写")
        }
        assert(tildeSelected.id == homeProject.id && tildePath == homePath)

        if CommandLine.arguments.contains("--live") {
            let live = try CodexCatalog.load(includeChats: false)
            let matches = CodexCatalog.matchProjects("Pocket Desk", in: live.projects)
            assert(matches.count == 1 && matches[0].name == "PocketDesk", "本机 Pocket Desk 只命中当前 PocketDesk")
            let old = CodexCatalog.matchProjects("voice-deck-mvp", in: live.projects)
            assert(old.count == 1 && old[0].name == "voice-deck-mvp", "本机旧项目按明确名称仍可找")
            guard case .destination(.project(let selected, _, _)) = try CodexSelection.resolve(openPocket, snapshot: live) else {
                fatalError("本机 Pocket Desk 不再因旧目录而询问")
            }
            assert(selected.name == "PocketDesk")
            print("PASS live Codex projects: Pocket Desk → PocketDesk; explicit voice-deck-mvp retained")
        }
        print("PASS Codex project matching, selection and navigation focus sequences")
    }

    private static func navigationFocusSequences() {
        let target: pid_t = 4101, other: pid_t = 4102
        func observe(_ focus: inout AgentTaskComposer.NavigationFocus, _ pid: pid_t?, at now: TimeInterval,
                     authorized: Bool = true, environmentAllowed: Bool = true) -> AgentTaskComposer.NavigationFocus.State {
            focus.observe(expectedPID: target, focusedPID: pid, authorized: authorized,
                          environmentAllowed: environmentAllowed, now: now)
        }

        // --- 首次焦点未知：等待期间不能认作已准备，真实目标出现才放行 ---
        var settling = AgentTaskComposer.NavigationFocus(deadline: 101)
        assert(observe(&settling, nil, at: 100) == .waiting)
        assert(!settling.confirmed, "未知焦点不能形成目标证据")
        assert(observe(&settling, nil, at: 100.95) == .waiting)
        assert(observe(&settling, target, at: 100.99) == .ready)
        assert(settling.confirmed)
        assert(observe(&settling, target, at: 102) == .ready, "期限只约束首次未知焦点，不使已确认目标过期")

        // --- 未知超时与用户切应用：均停止，不能靠等待弱化明确的焦点证据 ---
        var timedOut = AgentTaskComposer.NavigationFocus(deadline: 101)
        assert(observe(&timedOut, nil, at: 100.9) == .waiting)
        assert(observe(&timedOut, nil, at: 101) == .stopped, "边界时刻不再等待")
        assert(!timedOut.confirmed)
        var switched = AgentTaskComposer.NavigationFocus(deadline: 101)
        assert(observe(&switched, nil, at: 100) == .waiting)
        assert(observe(&switched, other, at: 100.05) == .stopped, "明确其他应用立即停止，不能等它回来再发送")
        assert(!switched.confirmed)

        // --- 硬门禁：授权或环境失效时，目标焦点也不能越过门禁 ---
        var revoked = AgentTaskComposer.NavigationFocus(deadline: 101)
        assert(observe(&revoked, nil, at: 100) == .waiting)
        assert(observe(&revoked, target, at: 100.05, authorized: false) == .stopped)
        assert(!revoked.confirmed, "失权后的焦点不建立可发送证据")
        var locked = AgentTaskComposer.NavigationFocus(deadline: 101)
        assert(observe(&locked, nil, at: 100) == .waiting)
        assert(observe(&locked, target, at: 100.05, environmentAllowed: false) == .stopped)
        assert(!locked.confirmed, "锁屏后的焦点不建立可发送证据")

        // --- 已确认后的失焦：未知也必须停止，初次等待窗口不能复活 ---
        var lostFocus = AgentTaskComposer.NavigationFocus(deadline: 101)
        assert(observe(&lostFocus, target, at: 100) == .ready)
        assert(observe(&lostFocus, nil, at: 100.05) == .stopped)
        assert(lostFocus.confirmed)
        var changedFocus = AgentTaskComposer.NavigationFocus(deadline: 101)
        assert(observe(&changedFocus, target, at: 100) == .ready)
        assert(observe(&changedFocus, other, at: 100.05) == .stopped)
    }
}
