/**
 * [INPUT]: 依赖 Foundation 与 Models 的 TargetConfig；读写 Application Support/VoiceDeck/recipients.json。
 * [OUTPUT]: 对外提供小精灵与普通应用的统一接收者顺序：load/save/normalized/view。
 * [POS]: Sources 的接收者顺序层。小精灵是内置接收者，**不写进 TargetStore 的普通应用列表**
 *        （方案 §3）：它不是有 bundleID/appURL 的 macOS 应用，混进去会让它被 /api/activate、
 *        AppDiscovery 和 AX 输入绑定当成真应用处理。顺序单独存，手机与控制台共用同一份事实。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum RecipientOrderError: LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let reason): return "接收者顺序保存失败：\(reason)"
        }
    }
}

enum RecipientOrder {
    /// 小精灵的内置接收者 id。以双下划线开头，不会与真实应用 id 撞车。
    static let sprite = "__sprite__"
    static let file = TargetStore.supportDirectory.appendingPathComponent("recipients.json")

    /// 归一化：清理未知/重复引用，补齐新增应用；小精灵缺失时只在首位插一次。
    ///
    /// 「只插一次」是迁移语义：一旦顺序里有了小精灵，用户把它移到哪就保持在哪，
    /// 不得每次读取都重新置顶（方案 §3：不得每次读取重新把小精灵置顶）。
    static func normalized(_ order: [String], targets: [TargetConfig]) -> [String] {
        let valid = Set(targets.map { $0.id })
        var seen = Set<String>()
        var result: [String] = []
        for id in order where id == sprite || valid.contains(id) {
            if seen.contains(id) { continue }
            seen.insert(id)
            result.append(id)
        }
        if !result.contains(sprite) { result.insert(sprite, at: 0) }
        // 新增应用沿现有规则追加在末尾，不动用户已排好的相对顺序。
        for target in targets where !seen.contains(target.id) { result.append(target.id) }
        return result
    }

    static func load(targets: [TargetConfig]) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode(Order.self, from: data),
              saved.schemaVersion == schemaVersion else {
            return normalized([], targets: targets)
        }
        return normalized(saved.order, targets: targets)
    }

    static func save(_ order: [String], targets: [TargetConfig]) throws {
        let clean = normalized(order, targets: targets)
        let payload = Order(schemaVersion: schemaVersion, order: clean)
        guard let data = try? JSONEncoder().encode(payload) else {
            throw RecipientOrderError.writeFailed("序列化失败。")
        }
        do {
            try FileManager.default.createDirectory(at: TargetStore.supportDirectory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            throw RecipientOrderError.writeFailed(error.localizedDescription)
        }
    }

    static func view(targets: [TargetConfig]) -> [String: Any] {
        ["order": load(targets: targets), "sprite": sprite]
    }

    private static let schemaVersion = 1

    private struct Order: Codable {
        var schemaVersion: Int
        var order: [String]
    }
}
