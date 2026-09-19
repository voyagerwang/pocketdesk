/**
 * [INPUT]: CapabilityModels 与冻结 A 协议包。
 * [OUTPUT]: 共享 fixture 文件读取与预期判定。
 * [POS]: tests 的只读协议验证设施，不编入产品。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CryptoKit

// MARK: - 冻结包路径与共享 fixtures 运行器

enum CapabilityProtocolPaths {
    static let environmentOverrideKey = "PD_UNIFIED_ASSISTANT_PROTOCOL_DIR"
    /// 本工单指定冻结包（SHA256SUMS.json 已核验）；只读，不写冻结包。
    static let frozenPackageProtocolDirectory =
        "/Users/yz/.codex/zcode-night-20260919/frozen/A-protocol-v1-r2/protocols/unified-assistant/v1"

    static func defaultProtocolDirectory() -> URL {
        if let raw = ProcessInfo.processInfo.environment[environmentOverrideKey], !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return URL(fileURLWithPath: frozenPackageProtocolDirectory)
    }
    static func schemaURL(in dir: URL) -> URL { dir.appendingPathComponent("unified-assistant-v1.schema.json") }
    static func manifestURL(in dir: URL) -> URL {
        dir.appendingPathComponent("fixtures").appendingPathComponent("manifest.json")
    }
    static func fixtureURL(in dir: URL, relativeToFixtures rel: String) -> URL {
        dir.appendingPathComponent("fixtures").appendingPathComponent(rel)
    }
}

struct FixtureCase: Codable, Equatable {
    let file: String
    let defs: String
    let expect: String
    let errorContains: String?
    let note: String?
}

struct FixtureManifest: Codable {
    let cases: [FixtureCase]
}

struct FixtureOutcome: Equatable {
    let file: String
    let defs: String
    let expect: String
    let matched: Bool
    let detail: String?
}

enum FixtureRunner {
    static func loadManifest(protocolDir: URL) throws -> FixtureManifest {
        try JSONDecoder().decode(FixtureManifest.self, from:
            Data(contentsOf: CapabilityProtocolPaths.manifestURL(in: protocolDir)))
    }

    /// 逐 case 用与 TS 同一组 fixtures 判定：pass 必须 ok，reject 必须失败且错误命中 errorContains。
    static func runAll(protocolDir: URL) throws -> [FixtureOutcome] {
        try loadManifest(protocolDir: protocolDir).cases.map { run(case: $0, protocolDir: protocolDir) }
    }

    static func run(case fixture: FixtureCase, protocolDir: URL) -> FixtureOutcome {
        func outcome(_ matched: Bool, _ detail: String?) -> FixtureOutcome {
            FixtureOutcome(file: fixture.file, defs: fixture.defs, expect: fixture.expect,
                           matched: matched, detail: detail)
        }
        guard let kind = CapabilityObjectKind(rawValue: fixture.defs) else {
            return outcome(false, "manifest 引用了未知的 defs：\(fixture.defs)")
        }
        let url = CapabilityProtocolPaths.fixtureURL(in: protocolDir, relativeToFixtures: fixture.file)
        guard let data = try? Data(contentsOf: url), let value = try? JSONValue.parse(data) else {
            return outcome(false, "fixture 文件缺失或无法解析：\(url.path)")
        }
        let result = CapabilityProtocol.validate(kind: kind, value: value)
        switch fixture.expect {
        case "pass":
            return result.ok
                ? outcome(true, nil)
                : outcome(false, "本应通过却被拒绝：" + result.errors.map(\.matchText).joined(separator: "; "))
        case "reject":
            guard let needle = fixture.errorContains, !needle.isEmpty else {
                return outcome(false, "reject case 缺少 errorContains")
            }
            if result.ok { return outcome(false, "本应被拒绝却通过了") }
            let hit = result.errors.contains { $0.matchText.contains(needle) }
            return hit
                ? outcome(true, nil)
                : outcome(false, "拒绝原因未命中 errorContains「\(needle)」：" +
                    result.errors.map(\.matchText).joined(separator: "; "))
        default:
            return outcome(false, "未知 expect：\(fixture.expect)")
        }
    }
}

// 冻结文件逐个核对，字段表守卫只作额外诊断，不声称覆盖 schema 的全部语义。
extension FixtureRunner {
    static func verifyFrozenFiles(protocolDir: URL) throws -> [String] {
        let root = URL(fileURLWithPath: "/Users/yz/.codex/zcode-night-20260919/frozen/A-protocol-v1-r2")
        let hashes = try JSONDecoder().decode([String: String].self,
            from: Data(contentsOf: root.appendingPathComponent("SHA256SUMS.json")))
        let prefix = "protocols/unified-assistant/v1/"
        return hashes.keys.sorted().filter { $0.hasPrefix(prefix) }.compactMap { key in
            let relative = String(key.dropFirst(prefix.count))
            guard let data = try? Data(contentsOf: protocolDir.appendingPathComponent(relative)) else { return key }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return digest == hashes[key] ? nil : key
        }
    }
}
