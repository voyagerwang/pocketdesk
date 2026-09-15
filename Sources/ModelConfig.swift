/**
 * [INPUT]: 依赖 Foundation 的 FileManager/Codable；由 AgentHTTP 读写、ModelClient 消费。
 * [OUTPUT]: 对外提供 ModelConfigStore（模型服务 Base URL / 模型名 / API Key 的持久化、
 *           脱敏视图、端点归一化与合法性校验）。
 * [POS]: Sources 的模型服务配置层；只落在这台 Mac 的 Application Support 下，
 *        仅本机控制台（回环）可读写，**绝不下发到手机**，也不进 /api/status 与日志。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

struct ModelConfig: Codable, Equatable {
    var baseURL: String = ""
    var model: String = ""
    var apiKey: String = ""
    var updatedAt: TimeInterval = 0

    var isConfigured: Bool { !baseURL.isEmpty && !model.isEmpty && !apiKey.isEmpty }
}

enum ModelConfigError: Error, LocalizedError {
    case badScheme(String)
    case missingHost
    case emptyModel
    case emptyKey

    var errorDescription: String? {
        switch self {
        case .badScheme(let value): return "Base URL 必须是 http:// 或 https:// 开头（当前：\(value)）"
        case .missingHost: return "Base URL 缺少主机名。"
        case .emptyModel: return "请填写模型名。"
        case .emptyKey: return "请填写 API Key。"
        }
    }
}

enum ModelConfigStore {
    // 与 targets.json 同一支持目录，独立文件。API Key 落盘是权衡结果：
    // 本项目是 ad-hoc 签名的本地构建，每次重编译 CDHash 都会变，钥匙串项会跟着失效
    // （与辅助功能授权同理），因此首版用 0600 的受保护文件，后续换正式签名再迁钥匙串。
    static let file = TargetStore.supportDirectory.appendingPathComponent("model.json")

    static func load() -> ModelConfig {
        guard let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode(ModelConfig.self, from: data) else { return ModelConfig() }
        return decoded
    }

    /// 保存并收紧权限；已有 Key 且本次留空表示沿用旧值，不覆盖成空。
    static func save(_ config: ModelConfig) throws {
        var next = config
        next.updatedAt = Date().timeIntervalSince1970
        try? FileManager.default.createDirectory(at: TargetStore.supportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(next)
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
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

    /// 脱敏视图：控制台只需要知道「配没配、配的是哪一段」，不需要拿回完整 Key。
    static func view(_ config: ModelConfig) -> [String: Any] {
        let key = config.apiKey
        let hint = key.count > 8 ? "\(key.prefix(3))…\(key.suffix(4))" : (key.isEmpty ? "" : "已保存")
        return [
            "baseURL": config.baseURL,
            "model": config.model,
            "hasKey": !key.isEmpty,
            "keyHint": hint,
            "updatedAt": config.updatedAt,
            "configured": config.isConfigured,
        ]
    }
}
