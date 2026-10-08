/**
 * [INPUT]: 只读 Codex 本机项目配置与 state_N.sqlite 元数据；SQLite 以 READONLY 打开，不读登录凭证或聊天正文。
 * [OUTPUT]: 项目/任务候选、项目归属与可判定的未读索引；项目动作不依赖任务数据库，字段未知或跨身份有歧义时停止。
 * [POS]: Codex 专属适配的发现层；这些本机持久化字段不是公共 API，升级后需重新核验。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import SQLite3

enum CodexCatalog {
    struct Project {
        let id: String
        let name: String
        let paths: [String]
        var dictionary: [String: Any] { ["id": id, "name": name, "paths": paths] }
    }
    struct Chat {
        let id: String
        let title: String
        let cwd: String
        let projectId: String?
        let unread: Bool?
        var dictionary: [String: Any] {
            var value: [String: Any] = ["id": id, "title": String(title.prefix(200)), "cwd": cwd,
                                      "unread": unread.map { $0 ? "yes" : "no" } ?? "unknown"]
            if let projectId { value["projectId"] = projectId }
            return value
        }
    }
    struct Snapshot {
        let projects: [Project]
        let chats: [Chat]
        let truncated: Bool
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static var directory: URL {
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], configured.hasPrefix("/") {
            return URL(fileURLWithPath: configured)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static func state(in directory: URL = directory) throws -> [String: Any] {
        let url = directory.appendingPathComponent(".codex-global-state.json")
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
              let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure(message: "Codex 本机项目配置不可读或格式已变化。")
        }
        return value
    }
    static func projects(from state: [String: Any]) throws -> [Project] {
        guard let entries = state["local-projects"] as? [String: [String: Any]] else {
            throw Failure(message: "当前 Codex 项目格式不受支持，请核对版本。")
        }
        let order = state["project-order"] as? [String] ?? []
        return try entries.map { id, entry in
            guard entry["id"] as? String == id, let name = entry["name"] as? String, !name.isEmpty,
                  let paths = entry["rootPaths"] as? [String], !paths.isEmpty,
                  paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
                throw Failure(message: "Codex 项目字段已变化，未猜测项目目录。")
            }
            return Project(id: id, name: name, paths: paths)
        }.sorted {
            let a = order.firstIndex(of: $0.id) ?? Int.max, b = order.firstIndex(of: $1.id) ?? Int.max
            return a == b ? $0.name < $1.name : a < b
        }
    }
    /// 不合并不同登录身份的蓝点。旧迁移身份不代表当前身份，不能借它猜当前账号。
    static func unreadIDs(from state: [String: Any]) -> Set<String>? {
        guard let index = state["electron-thread-read-state-v1"] as? [String: Any],
              index["version"] as? Int == 1,
              let identities = index["unreadByIdentity"] as? [String: [String: Any]], identities.count == 1,
              let hosts = identities.values.first else { return nil }
        let local = hosts.filter { $0.key.hasPrefix("local:") }
        guard local.count == 1, let ids = local.values.first as? [String] else { return nil }
        return Set(ids)
    }
    static func load(in directory: URL = directory, includeChats: Bool = true) throws -> Snapshot {
        let saved = try state(in: directory), projects = try projects(from: saved)
        // 项目定向只需要本机项目配置，任务索引升级/缺失不能阻断新建。
        guard includeChats else { return Snapshot(projects: projects, chats: [], truncated: false) }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let databases = files.compactMap { file -> (Int, String)? in
            guard file.hasPrefix("state_"), file.hasSuffix(".sqlite"),
                  let number = Int(file.dropFirst(6).dropLast(7)) else { return nil }
            return (number, file)
        }.sorted { $0.0 > $1.0 }
        guard let file = databases.first?.1 else { throw Failure(message: "没有找到 Codex 本机任务索引。") }
        var database: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent(file).path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw Failure(message: "Codex 本机任务索引无法只读打开。")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        // 只列用户主聊天；无正文、preview、rollout 路径或登录字段。
        let sql = "SELECT id, COALESCE(NULLIF(name,''), title), cwd, project_id FROM threads WHERE archived=0 AND source NOT LIKE '{%' ORDER BY updated_at DESC LIMIT 5001"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(message: "Codex 任务索引字段不受支持，未猜测旧任务。")
        }
        defer { sqlite3_finalize(statement) }
        let assignments = saved["thread-project-assignments"] as? [String: [String: Any]] ?? [:]
        // 当前 Codex 正处于项目 ID 迁移期；原生索引 ID 必须映射回当前侧边栏项目，不能静默丢归属。
        let aliasesByHost = saved["app-server-project-id-by-legacy-project-id-by-host"] as? [String: [String: String]] ?? [:]
        let aliases = aliasesByHost["local:" + directory.path] ?? [:]
        let projectless = Set(saved["projectless-thread-ids"] as? [String] ?? [])
        let hosts = saved["thread-project-membership-host-ids"] as? [String: String] ?? [:]
        let ids = unreadIDs(from: saved)
        var chats: [Chat] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw Failure(message: "Codex 任务索引读取中断。") }
            func column(_ n: Int32) -> String? {
                sqlite3_column_text(statement, n).map { String(cString: $0) }
            }
            guard let id = column(0), UUID(uuidString: id) != nil, let title = column(1), let cwd = column(2) else { continue }
            if let host = hosts[id], host != "local" { continue }
            var projectId = column(3)
            if let nativeId = projectId, !projects.contains(where: { $0.id == nativeId }) {
                let mapped = aliases.filter { $0.value == nativeId }.map(\.key)
                if mapped.count == 1 { projectId = mapped[0] }
                else if mapped.count > 1 { throw Failure(message: "Codex 项目 ID 迁移存在歧义，未猜测任务归属。") }
            }
            if projectId == nil, let assignment = assignments[id] {
                // 显式非本机归属绝不按同名目录误归到本机项目。
                guard assignment["projectKind"] as? String == "local" else { continue }
                projectId = assignment["projectId"] as? String
            }
            if projectId == nil, !projectless.contains(id), assignments[id] == nil {
                let matches = projects.filter { $0.paths.contains(cwd) }
                if matches.count == 1 { projectId = matches[0].id }
            }
            chats.append(Chat(id: id, title: title, cwd: cwd, projectId: projectId, unread: ids.map { $0.contains(id) }))
        }
        return Snapshot(projects: projects, chats: Array(chats.prefix(5000)), truncated: chats.count > 5000)
    }
    static func key(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    static func matchProjects(_ query: String, in projects: [Project]) -> [Project] {
        let query = key(query)
        let exact = projects.filter { project in
            [project.id, project.name].contains { key($0) == query }
                || project.paths.contains { key($0) == query || key(URL(fileURLWithPath: $0).lastPathComponent) == query }
        }
        return exact.isEmpty ? projects.filter { key($0.name).contains(query) } : exact
    }
    static func matchChats(_ query: String?, projectId: String?, unreadOnly: Bool, in chats: [Chat]) throws -> [Chat] {
        var candidates = chats.filter { projectId == nil || $0.projectId == projectId }
        if let query {
            let key = key(query)
            let exact = candidates.filter { self.key($0.id) == key || self.key($0.title) == key }
            candidates = exact.isEmpty ? candidates.filter { self.key($0.title).contains(key) } : exact
        }
        if unreadOnly, candidates.contains(where: { $0.unread == nil }) {
            throw Failure(message: "当前 Codex 蓝点索引无法确定登录身份。请按任务名称选择；不会把未知状态当作已读。")
        }
        return candidates.filter { !unreadOnly || $0.unread == true }
    }
}
