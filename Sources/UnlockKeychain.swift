/**
 * [INPUT]: 依赖 Security 的 SecItem（经典文件钥匙串）、CryptoKit 的 P256、Foundation；secret 后端协议化以便测试注入。
 * [OUTPUT]: 对外提供 UnlockSecretStore 协议、FileKeychainStore、MemorySecretStore、UnlockCredentialStore（系统密码、设备密钥、凭据清单的门面）。
 * [POS]: Sources 的快捷解锁机密层；密码只进本机钥匙串（G0 实测经典钥匙串可用、数据保护钥匙串无 entitlement 不可用），设备密钥为 CryptoKit P256 原始字节。
 * [REVIEW]: 经典钥匙串进程交互开关串行设置并恢复；后台禁止弹窗且忙时立即失败；只有本机显式授权允许系统提示，随后检查非交互读取，不变更ACL、不重建不可读身份。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CryptoKit
import Foundation
import Security

protocol UnlockSecretStore {
    func save(_ data: Data, service: String) throws
    func load(service: String) -> Data?
    func authorize(service: String) -> Bool
    func contains(service: String) -> Bool
    func delete(service: String)
}
extension UnlockSecretStore {
    func authorize(service: String) -> Bool { load(service: service) != nil }
}

/// 经典文件钥匙串实现。TN3137：macOS 上未签名/开发者签名的本地应用使用 login keychain；
/// 数据保护钥匙串需要 entitlement（G0 实测 -34018），不采用。
final class FileKeychainStore: UnlockSecretStore {
    // 经典钥匙串的交互开关是进程级，所有本模块操作串行保护并恢复原值。
    // 前台授权弹窗期间后台读取立即失败，不排队等用户解锁电脑。
    private static let accessLock = NSLock()
    private func access<T>(interactive: Bool = false, unavailable: T, _ body: () -> T) -> T {
        guard Self.accessLock.try() else { return unavailable }
        defer { Self.accessLock.unlock() }
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(interactive) == errSecSuccess else { return unavailable }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return body()
    }
    private let account: String
    init(account: String = "PocketDesk") { self.account = account }

    func save(_ data: Data, service: String) throws {
        let result: Result<Void, Error> = access(unavailable: .failure(UnlockStoreError.keychainWrite(errSecInteractionNotAllowed))) {
            Result { try self.saveItem(data, service: service) }
        }
        try result.get()
    }
    private func saveItem(_ data: Data, service: String) throws {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let updated = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw UnlockStoreError.keychainWrite(updated) }
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw UnlockStoreError.keychainWrite(status) }
    }

    func load(service: String) -> Data? {
        access(unavailable: nil) { read(service: service, interactive: false) }
    }
    func authorize(service: String) -> Bool {
        access(interactive: true, unavailable: false) { read(service: service, interactive: true) != nil }
    }
    private func read(service: String, interactive: Bool) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecUseAuthenticationUI as String: interactive ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    func contains(service: String) -> Bool {
        access(unavailable: true) { containsItem(service: service) }
    }
    private func containsItem(service: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        // 锁定/权限失败绝不解释为不存在，以免重建设备身份。
        return SecItemCopyMatching(query as CFDictionary, nil) != errSecItemNotFound
    }

    func delete(service: String) {
        access(unavailable: ()) { deleteItem(service: service) }
    }
    private func deleteItem(service: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// 测试/隔离环境的内存后端。
final class MemorySecretStore: UnlockSecretStore {
    private var items: [String: Data] = [:]
    private let mutex = NSLock()
    func save(_ data: Data, service: String) throws { mutex.lock(); items[service] = data; mutex.unlock() }
    func load(service: String) -> Data? { mutex.lock(); defer { mutex.unlock() }; return items[service] }
    func contains(service: String) -> Bool { load(service: service) != nil }
    func delete(service: String) { mutex.lock(); items[service] = nil; mutex.unlock() }
}

enum UnlockStoreError: Error, Equatable {
    case keychainWrite(OSStatus)
    case notConfigured
}

/// 快捷解锁机密门面：系统密码（Keychain，仅本机）、设备身份密钥（Keychain）、凭据清单（状态文件，公钥数据）。
/// String 不保证零化：减少副本与存活时间，只在提交瞬间解出，不做无限期内存缓存。
final class UnlockCredentialStore {
    static let passwordService = "dev.voicedeck.quickunlock.password"
    static let deviceKeyService = "dev.voicedeck.quickunlock.devicekey"
    let secrets: UnlockSecretStore
    let state: UnlockStateFile
    private let keyMutex = NSLock()

    init(secrets: UnlockSecretStore = FileKeychainStore(), state: UnlockStateFile = UnlockStateFile()) {
        self.secrets = secrets
        self.state = state
    }

    // MARK: - 系统密码

    var hasPassword: Bool { secrets.contains(service: Self.passwordService) }
    /// 仅本机已解锁网页的明确点击调用；系统弹窗由用户处理，不扩大条目访问名单。
    func authorizeKeychain() -> Bool {
        guard secrets.authorize(service: Self.passwordService),
              secrets.authorize(service: Self.deviceKeyService) else { return false }
        // 一次允许不足以保证锁屏读取；必须再次以禁止弹窗方式验证。
        return secrets.load(service: Self.passwordService) != nil && secrets.load(service: Self.deviceKeyService) != nil
    }

    func savePassword(_ password: String) throws {
        guard !password.isEmpty, password.utf16.count <= 256 else { throw UnlockStoreError.notConfigured }
        try secrets.save(Data(password.utf8), service: Self.passwordService)
    }

    func deletePassword() { secrets.delete(service: Self.passwordService) }

    /// 密码只在提交前取出；调用方必须在闭包内用完即弃，不得持有或记录。
    func withPassword<T>(_ body: (String) -> T) -> T? {
        guard let data = secrets.load(service: Self.passwordService), !data.isEmpty else { return nil }
        return body(String(decoding: data, as: UTF8.self))
    }

    // MARK: - 设备身份密钥

    /// 惰性生成 P256 设备密钥并落钥匙串；拿到公钥的未压缩点用于配对展示与注册。
    func deviceKey() -> P256.Signing.PrivateKey? {
        keyMutex.lock(); defer { keyMutex.unlock() }
        if let data = secrets.load(service: Self.deviceKeyService),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        guard !secrets.contains(service: Self.deviceKeyService) else { return nil }
        let key = P256.Signing.PrivateKey()
        do { try secrets.save(key.rawRepresentation, service: Self.deviceKeyService) } catch { return nil }
        return key
    }

    var devicePublicKeyPoint: Data? {
        deviceKey().map { Data([0x04]) + $0.publicKey.rawRepresentation } // rawRepresentation 即 x||y
    }

    // MARK: - 凭据清单

    var credentials: [UnlockCredentialRecord] { state.load().credentials }

    func credential(id: String) -> UnlockCredentialRecord? {
        credentials.first { $0.credentialId == id }
    }

    func upsertCredential(_ record: UnlockCredentialRecord) {
        state.mutate { s in
            s.credentials.removeAll { $0.credentialId == record.credentialId }
            s.credentials.append(record)
        }
    }

    func confirmCredential(id: String) -> Bool {
        var found = false
        state.mutate { s in
            guard let i = s.credentials.firstIndex(where: { $0.credentialId == id }) else { return }
            s.credentials[i].confirmed = true
            found = true
        }
        return found
    }

    /// 撤销单个凭据：记录即删（撤销的语义是清除，不是标记——标记会给"半撤销"状态留门）。
    func revokeCredential(id: String) {
        state.mutate { s in s.credentials.removeAll { $0.credentialId == id } }
    }

    func revokeAllCredentials() {
        state.mutate { s in s.credentials.removeAll() }
    }

    var enabled: Bool {
        get { state.load().enabled }
        set { state.mutate { $0.enabled = newValue } }
    }
}
