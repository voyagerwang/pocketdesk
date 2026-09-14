/**
 * [INPUT]: 已鉴权的浏览器心跳；调用者在 Server 串行队列使用。
 * [OUTPUT]: 有界、持久化的连接记录；设备描述不是身份认证依据。
 * [POS]: 连接可见性，独立于配对凭证与控制租约。
 */
import Foundation

final class DeviceConnections {
    struct Visit: Codable {
        var id: String
        var name: String
        var model: String
        var platform: String
        var browser: String
        var started: Double
        var lastSeen: Double
        var ended: Double?
    }
    private var visits: [Visit] = []
    private var sessions: [String: String] = [:]
    private let file: URL
    private let namesFile: URL
    private var names: [String: String] = [:]
    private var lastSave: Double = 0
    init(directory: URL) {
        file = directory.appendingPathComponent("device-connections.json")
        namesFile = directory.appendingPathComponent("device-names.json")
        if let data = try? Data(contentsOf: namesFile), let saved = try? JSONDecoder().decode([String: String].self, from: data) { names = saved }
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Visit].self, from: data) {
            visits = saved
            // 服务重启不恢复在线身份。
            for i in visits.indices where visits[i].ended == nil { visits[i].ended = visits[i].lastSeen }
        }
    }
    private func expire(_ now: Double) {
        for i in visits.indices where visits[i].ended == nil && now - visits[i].lastSeen > 45 {
            visits[i].ended = visits[i].lastSeen + 45
            sessions.removeValue(forKey: visits[i].id)
        }
        visits.removeAll { ($0.ended ?? now) < now - 30 * 86400 }
        if visits.count > 500 { visits = Array(visits.suffix(500)) }
    }
    private func save(_ now: Double) {
        guard let data = try? JSONEncoder().encode(visits) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            lastSave = now
        } catch { /* 记录写入失败不阻断现有输入通道。 */ }
    }
    @discardableResult func heartbeat(_ body: [String: Any], now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let id = body["deviceId"] as? String, UUID(uuidString: id) != nil else { return false }
        func field(_ key: String) -> String { String((body[key] as? String ?? "").filter { !$0.isNewline && !$0.isASCIIControl }.prefix(80)) }
        expire(now)
        let index = visits.lastIndex { $0.id == id && $0.ended == nil }
        let visit = Visit(id: id, name: field("name"), model: field("model"), platform: field("platform"), browser: field("browser"), started: index.map { visits[$0].started } ?? now, lastSeen: now)
        let changed = index.map { visits[$0].name != visit.name || visits[$0].model != visit.model } ?? true
        if let index { visits[index] = visit } else { visits.append(visit) }
        sessions[id] = field("session")
        expire(now)
        if changed || now - lastSave >= 15 { save(now) }
        return true
    }
    func rename(id: String, name: String) -> Bool {
        guard visits.contains(where: { $0.id == id }), name.count <= 60 else { return false }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).filter { !$0.isASCIIControl }
        var updated = names
        if value.isEmpty { updated.removeValue(forKey: id) } else { updated[id] = value }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: namesFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: namesFile.path)
            names = updated
            return true
        } catch { return false }
    }
    func snapshot(now: Double = Date().timeIntervalSince1970, controls: (String) -> Bool) -> [[String: Any]] {
        expire(now)
        return visits.reversed().map { visit in
            var row: [String: Any] = ["id": visit.id, "name": names[visit.id] ?? visit.name, "model": visit.model, "platform": visit.platform, "browser": visit.browser, "started": visit.started, "lastSeen": visit.lastSeen, "online": visit.ended == nil, "controlling": visit.ended == nil && controls(sessions[visit.id] ?? "")]
            if let ended = visit.ended { row["ended"] = ended }
            return row
        }
    }
}
private extension Character {
    var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}
