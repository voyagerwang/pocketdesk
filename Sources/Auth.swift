/**
 * [INPUT]: 依赖 Foundation、Darwin 的无链接文件描述符与 Security 随机源；存储目录来自 TargetStore。
 * [OUTPUT]: 配对 token 私有持久化与恒定时间校验；原值不轮换，拒绝异常文件，存储失败时关闭 token 鉴权。
 * [POS]: Sources 的鉴权层；Server 的写端点调用 verify，/api/qr 读取 token 拼进二维码 URL 完成单向分发。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Security
import Darwin

enum Auth {
    static let tokenFile = TargetStore.supportDirectory.appendingPathComponent("token")
    private static let storageLock = NSLock()

    // ---- 私有存储：只修复权限，不轮换已配对手机持有的原值 ----
    static let token = loadToken(directory: TargetStore.supportDirectory)

    static func loadToken(directory: URL) -> String {
        storageLock.lock(); defer { storageLock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        } catch { return "" }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return "" }
        defer { Darwin.close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == geteuid(),
              fchmod(parent, 0o700) == 0 else { return "" }
        if let value = readToken(parent) { return value }
        // 只有明确不存在才创建；损坏、无权或链接均不能悄悄替换成新凭据。
        guard errno == ENOENT else { return "" }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        let data = Data(Data(bytes).base64URLEncodedString().utf8)
        let temporary = ".token-" + UUID().uuidString
        let file = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { return "" }
        defer { Darwin.close(file); unlinkat(parent, temporary, 0) }
        let written = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(file) == 0 else { return "" }
        // 完整落盘后独占发布；另一进程先发布时只读取它，不覆盖已分发凭据。
        guard renameatx_np(parent, temporary, parent, "token", UInt32(RENAME_EXCL)) == 0 || errno == EEXIST else { return "" }
        return readToken(parent) ?? ""
    }

    private static func readToken(_ parent: Int32) -> String? {
        let file = openat(parent, "token", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size > 0, info.st_size <= 4096,
              fchmod(file, 0o600) == 0 else { errno = EINVAL; return nil }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        guard Darwin.read(file, &bytes, bytes.count) == bytes.count,
              let saved = String(bytes: bytes, encoding: .utf8) else { errno = EINVAL; return nil }
        let value = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count == 43, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { errno = EINVAL; return nil }
        return value
    }

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
        guard !bBytes.isEmpty, aBytes.count == bBytes.count else { return false }
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
