/**
 * [INPUT]: 依赖 Foundation 的 FileManager/Data；首次启动用 SecRandomCopyBytes 生成 32 字节随机 token。
 * [OUTPUT]: 对外提供 Auth（token 的首次生成、持久化到 Application Support/VoiceDeck/token，以及写请求的 Bearer 校验）。
 * [POS]: Sources 的鉴权层；Server 的写端点调用 verify，/api/qr 读取 token 拼进二维码 URL 完成单向分发。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Security

enum Auth {
    static let tokenFile = TargetStore.supportDirectory.appendingPathComponent("token")

    // 进程首次需要时懒加载；文件不存在则生成并落盘，之后稳定不变（重装/换机才换 token）。
    static let token: String = {
        if let saved = try? String(contentsOf: tokenFile, encoding: .utf8),
           !saved.trimmingCharacters(in: .whitespaces).isEmpty {
            return saved.trimmingCharacters(in: .whitespaces)
        }
        try? FileManager.default.createDirectory(at: TargetStore.supportDirectory, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let raw = status == errSecSuccess ? Data(bytes) : Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let value = raw.base64URLEncodedString()
        try? value.write(to: tokenFile, atomically: true, encoding: .utf8)
        return value
    }()

    // 写端点校验：Authorization: Bearer <token>。token 为空（理论上不会发生）时一律拒绝。
    static func verify(authorizationHeader: String?) -> Bool {
        guard let header = authorizationHeader?.trimmingCharacters(in: .whitespaces) else { return false }
        guard header.lowercased().hasPrefix("bearer ") else { return false }
        let provided = String(header.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        // 恒定时间比较，避免计时侧信道泄露 token。
        return constantTimeEquals(provided, token)
    }

    // WS 首帧握手校验：直接比对裸 token 字符串。
    static func verify(token provided: String) -> Bool {
        constantTimeEquals(provided, token)
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8), bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
        return diff == 0
    }
}

private extension Data {
    // base64url：URL 安全的 base64，去掉 +/ 与填充，适合放进二维码 URL。
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
