/**
 * [INPUT]: 依赖 Foundation 的 FileManager/Codable；由 AgentHTTP 读写、ModelClient 消费。
 * [OUTPUT]: 对外提供 Codex/API 后端选择、多 API 服务商配置与显式活动 ID、兼容当前 API 的字段、持久化与脱敏视图；旧单条配置仅在解码时迁为 legacy-api，凭证同源比较限制旧 Key 的沿用。
 * [POS]: Sources 的模型服务配置层；只落在这台 Mac 的 Application Support 下，
 *        仅本机控制台（回环）可读写，**绝不下发到手机**，也不进 /api/status 与日志。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum ModelBackend: String, Codable {
    case api
    case codex
}

struct APIProviderConfig: Codable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var model: String
    var apiKey: String

    var isConfigured: Bool { (try? ModelConfigStore.validateProvider(self)) != nil }
}

struct ModelConfig: Codable, Equatable {
    static let codexModel = "gpt-6-luna"
    static let legacyProviderID = "legacy-api"
    var backend: ModelBackend = .api
    var providers: [APIProviderConfig] = []
    var activeProviderID: String?
    var updatedAt: TimeInterval = 0

    var activeProvider: APIProviderConfig? { providers.first { $0.id == activeProviderID } }
    // 兼容推理消费者；Codex 激活时仍保留最近选中的 API，绝不从其他条目猜一个默认值。
    var baseURL: String {
        get { activeProvider?.baseURL ?? "" }
        set { setActiveValue(newValue, at: \.baseURL) }
    }
    var model: String {
        get { activeProvider?.model ?? "" }
        set { setActiveValue(newValue, at: \.model) }
    }
    var apiKey: String {
        get { activeProvider?.apiKey ?? "" }
        set { setActiveValue(newValue, at: \.apiKey) }
    }
    var backupConfigured: Bool { activeProvider?.isConfigured == true }
    // 这里只表示后端已选择；Codex 的登录和模型访问以真实连通性测试为准。
    var isConfigured: Bool { backend == .codex || backupConfigured }
    var activeModel: String { backend == .codex ? Self.codexModel : model }
    var activeHost: String { backend == .codex ? "codex" : (ModelConfigStore.endpoint(for: baseURL)?.host ?? "") }

    init(baseURL: String = "", model: String = "", apiKey: String = "", updatedAt: TimeInterval = 0,
         backend: ModelBackend = .api) {
        self.backend = backend
        self.updatedAt = updatedAt
        if !baseURL.isEmpty || !model.isEmpty || !apiKey.isEmpty {
            providers = [.init(id: Self.legacyProviderID, name: ModelConfigStore.providerName(for: baseURL),
                               baseURL: baseURL, model: model, apiKey: apiKey)]
            activeProviderID = Self.legacyProviderID
        }
    }

    init(backend: ModelBackend = .api, providers: [APIProviderConfig], activeProviderID: String?, updatedAt: TimeInterval = 0) {
        self.backend = backend
        self.providers = providers
        self.activeProviderID = activeProviderID.flatMap { id in providers.contains { $0.id == id } ? id : nil }
        self.updatedAt = updatedAt
    }

    func provider(id: String) -> APIProviderConfig? { providers.first { $0.id == id } }

    mutating func replaceProvider(_ provider: APIProviderConfig) {
        if let index = providers.firstIndex(where: { $0.id == provider.id }) { providers[index] = provider }
        else { providers.append(provider) }
    }

    mutating func removeProvider(id: String) {
        providers.removeAll { $0.id == id }
        if activeProviderID == id { activeProviderID = nil }
    }

    private mutating func setActiveValue(_ value: String, at keyPath: WritableKeyPath<APIProviderConfig, String>) {
        var provider = activeProvider ?? APIProviderConfig(
            id: providers.contains(where: { $0.id == Self.legacyProviderID }) ? UUID().uuidString.lowercased() : Self.legacyProviderID,
            name: "API 服务", baseURL: "", model: "", apiKey: "")
        provider[keyPath: keyPath] = value
        replaceProvider(provider)
        activeProviderID = provider.id
    }

    private enum CodingKeys: String, CodingKey { case backend, providers, activeProviderID, baseURL, model, apiKey, updatedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        backend = try values.decodeIfPresent(ModelBackend.self, forKey: .backend) ?? .api
        updatedAt = try values.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
        if values.contains(.providers) {
            providers = try values.decodeIfPresent([APIProviderConfig].self, forKey: .providers) ?? []
            let id = try values.decodeIfPresent(String.self, forKey: .activeProviderID)
            activeProviderID = id.flatMap { value in providers.contains { $0.id == value } ? value : nil }
        } else {
            let baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
            let model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
            let apiKey = try values.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
            if !baseURL.isEmpty || !model.isEmpty || !apiKey.isEmpty {
                providers = [.init(id: Self.legacyProviderID, name: ModelConfigStore.providerName(for: baseURL),
                                   baseURL: baseURL, model: model, apiKey: apiKey)]
                activeProviderID = Self.legacyProviderID
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(backend, forKey: .backend)
        try values.encode(providers, forKey: .providers)
        try values.encode(activeProviderID ?? "", forKey: .activeProviderID)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

enum ModelConfigError: Error, LocalizedError {
    case invalidBackend
    case badScheme(String)
    case missingHost
    case emptyModel
    case emptyKey
    case newOriginNeedsKey
    case invalidProviderAction
    case invalidProvider
    case emptyProviderName
    case providerNotFound

    var errorDescription: String? {
        switch self {
        case .invalidBackend: return "模型后端必须是 codex 或 api。"
        case .badScheme(let value): return "Base URL 必须是 http:// 或 https:// 开头（当前：\(value)）"
        case .missingHost: return "Base URL 缺少主机名。"
        case .emptyModel: return "请填写模型名。"
        case .emptyKey: return "请填写 API Key。"
        case .newOriginNeedsKey: return "服务地址已更换，请填写该服务的 API Key；原 Key 只会用于原服务。"
        case .invalidProviderAction: return "不支持的服务商操作。"
        case .invalidProvider: return "服务商配置格式不正确。"
        case .emptyProviderName: return "请填写服务商名称。"
        case .providerNotFound: return "找不到这个 API 服务商，请刷新后重试。"
        }
    }
}

enum ModelConfigStore {
    // 与 targets.json 同一支持目录，独立文件。API Key 落盘是权衡结果：
    // 本项目是 ad-hoc 签名的本地构建，每次重编译 CDHash 都会变，钥匙串项会跟着失效
    // （与辅助功能授权同理），因此首版用 0600 的受保护文件，后续换正式签名再迁钥匙串。
    static var file = TargetStore.supportDirectory.appendingPathComponent("model.json")

    static func load() -> ModelConfig {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(ModelConfig.self, from: data) else { return ModelConfig() }
        return decoded
    }

    /// 保存完整配置并收紧权限；Key 的沿用与清空由 HTTP 草稿事务判定。
    static func save(_ config: ModelConfig) throws {
        var next = config
        next.updatedAt = Date().timeIntervalSince1970
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func providerName(for baseURL: String) -> String {
        if credentialOriginMatches(baseURL, "https://api.deepseek.com") { return "DeepSeek" }
        if credentialOriginMatches(baseURL, "https://api.openai.com") { return "OpenAI" }
        return endpoint(for: baseURL)?.host ?? "API 服务"
    }

    static func validateProvider(_ provider: APIProviderConfig) throws {
        if provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ModelConfigError.emptyProviderName }
        if endpoint(for: provider.baseURL) == nil { throw ModelConfigError.badScheme(provider.baseURL) }
        if provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ModelConfigError.emptyModel }
        if provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ModelConfigError.emptyKey }
    }

    /// 归一化出真实的 /chat/completions 地址：允许填到根路径（自动补 /v1 之外的完整尾缀）。
    /// 只接受 http/https —— 其他协议（file/ftp/自研 scheme）一律拒绝，不为 SSRF 留口子。
    static func endpoint(for baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.hasSuffix("/chat/completions") ? trimmed : trimmed + "/chat/completions"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// 凭证只允许在同源地址沿用；路径不改变服务身份，显式默认端口与省略端口等价。
    static func credentialOriginMatches(_ first: String, _ second: String) -> Bool {
        guard let firstURL = endpoint(for: first), let secondURL = endpoint(for: second),
              let firstScheme = firstURL.scheme?.lowercased(), let secondScheme = secondURL.scheme?.lowercased(),
              let firstHost = firstURL.host?.lowercased(), let secondHost = secondURL.host?.lowercased() else { return false }
        let firstPort = firstURL.port ?? (firstScheme == "https" ? 443 : 80)
        let secondPort = secondURL.port ?? (secondScheme == "https" ? 443 : 80)
        return firstScheme == secondScheme && firstHost == secondHost && firstPort == secondPort
    }

    private static func keyHint(_ key: String) -> String {
        key.count > 8 ? "\(key.prefix(3))…\(key.suffix(4))" : (key.isEmpty ? "" : "已保存")
    }

    static func providerView(_ provider: APIProviderConfig) -> [String: Any] {
        ["id": provider.id, "name": provider.name, "baseURL": provider.baseURL, "model": provider.model,
         "hasKey": !provider.apiKey.isEmpty, "keyHint": keyHint(provider.apiKey), "configured": provider.isConfigured]
    }

    /// 只返回脱敏条目；顶层字段保留旧客户端契约，不从其他服务商借凭证或猜默认选择。
    static func view(_ config: ModelConfig) -> [String: Any] {
        return [
            "backend": config.backend.rawValue,
            "activeModel": config.activeModel,
            "authMode": config.backend == .codex ? "chatgpt" : "api-key",
            "backupConfigured": config.backupConfigured,
            "providers": config.providers.map(providerView),
            "activeProviderID": config.activeProviderID ?? "",
            "baseURL": config.baseURL,
            "model": config.model,
            "hasKey": !config.apiKey.isEmpty,
            "keyHint": keyHint(config.apiKey),
            "updatedAt": config.updatedAt,
            "configured": config.isConfigured,
        ]
    }
}
