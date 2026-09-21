/**
 * [INPUT]: 依赖 Foundation 的 JSON/FileManager 与 TargetStore.supportDirectory 的目录约定。
 * [OUTPUT]: 对外提供 UnlockConfig（origin/rpId/relayWSS 部署配置的加载与校验）、UnlockStateFile（enabled 与凭据登记的持久化）、UnlockCredentialRecord。
 * [POS]: Sources 的快捷解锁配置层；UnlockCoordinator/UnlockRelayClient/UnlockPanel 消费。生产配置缺失时显式"未配置"，绝不回退自签或明文地址。
 * [REVIEW]: 配置与状态共用 VoiceDeck 目录；精确解析 origin/relay 主机，拒绝伪 localhost 与不匹配 RP。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// 部署配置：操作者从 relay/config.example.json 落地为 quick-unlock.config.json。
/// 三项缺一不可：可信 origin（浏览器网页地址）、RP ID（WebAuthn 域）、出站 WSS 地址。
struct UnlockConfig: Codable, Equatable {
    var origin: String
    var rpId: String
    var relayWSS: String
    /// 设备在配对页显示的名字（可选，缺省用主机名）。
    var deviceName: String?

    /// 校验并归一化：origin 必须 https（localhost 明确标注为测试例外）、rpId 不得为空、
    /// relayWSS 必须 wss。不接受运行期由网络消息改动这些值。
    var validated: UnlockConfig? {
        var origin = self.origin.trimmingCharacters(in: .whitespacesAndNewlines)
        var rpId = self.rpId.trimmingCharacters(in: .whitespacesAndNewlines)
        let relay = self.relayWSS.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rpId.isEmpty, !relay.isEmpty else { return nil }
        guard let originURL = URLComponents(string: origin), let host = originURL.host,
              originURL.user == nil, originURL.password == nil, originURL.query == nil,
              originURL.fragment == nil, ["", "/"].contains(originURL.path),
              host == rpId || host.hasSuffix("." + rpId),
              let relayURL = URLComponents(string: relay), let relayHost = relayURL.host,
              relayURL.user == nil, relayURL.password == nil, relayURL.fragment == nil else { return nil }
        let isLocalTest = originURL.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)
        guard origin.hasPrefix("https://") || isLocalTest else { return nil }
        guard relayURL.scheme == "wss" || (isLocalTest && relayURL.scheme == "ws" && ["localhost", "127.0.0.1"].contains(relayHost)) else { return nil }
        origin = String(origin.dropLast(origin.hasSuffix("/") ? 1 : 0))
        if rpId == "localhost" { rpId = "localhost" }
        return UnlockConfig(origin: origin, rpId: rpId, relayWSS: relay, deviceName: deviceName)
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VoiceDeck", isDirectory: true)
    }

    static func load(directory: URL = UnlockConfig.defaultDirectory) -> UnlockConfig? {
        let url = directory.appendingPathComponent("quick-unlock.config.json")
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(UnlockConfig.self, from: data) else { return nil }
        return raw.validated
    }
}

/// 一条已登记的解锁凭据（公钥数据，不含任何机密）。
struct UnlockCredentialRecord: Codable, Equatable {
    var credentialId: String        // base64url
    var publicKey: String           // P-256 未压缩点（0x04||x||y）的 base64url
    var label: String
    var createdAt: Double
    var lastUsedAt: Double?
    var signCount: UInt32
    var confirmed: Bool             // 配对核对后为 true；未确认凭据不得用于解锁
    var transport: String           // "synced"（平台同步通行密钥）等，仅展示
}

/// 用户态持久化（enabled、凭据清单）。与部署配置分开：配置是运维的，状态是用户的。
final class UnlockStateFile {
    let directory: URL
    private let mutex = NSLock()
    private var cache: State?
    struct State: Codable {
        var enabled: Bool = false
        var credentials: [UnlockCredentialRecord] = []
        var lastSeq: UInt64 = 0
    }

    init(directory: URL = UnlockConfig.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("quick-unlock-state.json") }

    func load() -> State {
        mutex.lock(); defer { mutex.unlock() }
        return unlockedLoad()
    }

    private func unlockedLoad() -> State {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            let fresh = State()
            cache = fresh
            return fresh
        }
        cache = state
        return state
    }

    func mutate(_ change: (inout State) -> Void) {
        mutex.lock(); defer { mutex.unlock() }
        var state = unlockedLoad()
        change(&state)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL, options: .atomic)
        }
        cache = state
    }
}
