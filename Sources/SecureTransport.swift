/**
 * [INPUT]: 依赖 Security 的 PKCS12 身份与 Network TLS；读取本机私有 TLS 目录。
 * [OUTPUT]: 提供独立 HTTPS/WSS 监听参数；证书缺失时不开启安全通道，绝不降级密码请求。
 * [POS]: Sources 的 TLS 装配边界；三条服务共享同一证书，客户端必须正常验证信任链。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Security
import Network

final class SecureTransport {
    static let port: UInt16 = 46487
    static let directory = TargetStore.supportDirectory.appendingPathComponent("tls")
    private let identity: sec_identity_t

    // 承载证书私钥的一次性钥匙串：只在 App 私有目录内，不进登录钥匙串，也绝不向用户索要密码。
    //
    // 但它**会自己上锁**：`security show-keychain-info` 显示新建钥匙串默认 `lock-on-sleep
    // timeout=300s`（闲置 5 分钟即锁；`SecKeychainSetSettings` 实测改不动，登录钥匙串才是
    // no-timeout）。而 TLS 握手取私钥**没有任何超时**——一旦上锁，签名会永久停在 securityd 的
    // 等待里，把唯一的网络工作线程占死：HTTPS 页面、心跳、/api 一起静默超时（而不是某次请求失败），
    // 同时弹出一个「钥匙串密码」框，而那个密码是随机生成、用户不可能知道的。
    // 实测（锁上后从外部观察）：签名卡死 → 重新解锁 → 签名立刻恢复正常。
    // 所以密码留一份在 App 私有文件里（0600，只保护这张自签证书的私钥），并由主线程每 3 秒补一次
    // 解锁，把任何一次上锁都在下一次握手前抹平；万一还是被卡住，由 ServerWatchdog 兜底重启。
    private static let passwordFileName = "keychain-password"
    private static let keepUnlockedInterval: TimeInterval = 3
    private static var liveKeychain: SecKeychain?
    private static var liveKeychainPath = ""
    private static var livePassword = ""
    private static var keepUnlockedTimer: Timer?

    init() throws {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent("server.p12"))
        let password = try String(contentsOf: Self.directory.appendingPathComponent("password"), encoding: .utf8).trimmingCharacters(in: .newlines)

        // 清理上一轮遗留的临时钥匙串（都在 App 私有目录内，绝不触碰登录钥匙串）。
        Self.cleanupStaleTempKeychains()

        var items: CFArray?
        var temp: SecKeychain?

        // 仅在 App 私有目录内建一次性临时钥匙串承载证书私钥：随机密码、代码内解锁、
        // promptUser=false 保证绝不弹出任何密码/授权框，且私钥永不进入登录钥匙串。
        // 注：此处**绝不**回退到默认/登录钥匙串——那会触发系统密码弹窗，损害用户信任。
        if let kc = Self.createUnlockedTempKeychain() {
            var options: [String: Any] = [
                kSecImportExportPassphrase as String: password,
                kSecImportExportKeychain as String: kc,
            ]
            // 把本 App 写进私钥的访问控制表：不写的话每次取用都可能转成一次系统授权询问。
            if let access = Self.appOnlyAccess() { options[kSecImportExportAccess as String] = access }
            let s = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
            if s == errSecSuccess { temp = kc }
        }

        // 导入失败则直接抛错（main.swift 用 try? 捕获 → HTTPS 不启动），但绝不会向用户索要密码。
        guard let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String], CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID(),
              let identity = sec_identity_create(raw as! SecIdentity) else {
            throw NSError(domain: "PocketDeskTLS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "无法在私有临时钥匙串中装配 TLS 身份，已放弃安全通道（不影响 HTTP）。"])
        }
        self.identity = identity
        if let keychain = temp { Self.startKeepingUnlocked(keychain) }
    }

    /// 在 App 私有目录内建一个带随机密码、已解锁、不加入用户列表的一次性钥匙串。
    private static func createUnlockedTempKeychain() -> SecKeychain? {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let path = Self.directory.appendingPathComponent("pocketdesk-tls-\(UUID().uuidString).keychain").path
        let kcPassword = UUID().uuidString + UUID().uuidString
        var ref: SecKeychain?
        let created = path.withCString { p in
            // promptUser=false：绝不以任何形式向用户索要密码。
            SecKeychainCreate(p, UInt32(kcPassword.utf8.count), kcPassword, false, nil, &ref)
        }
        guard created == errSecSuccess, let keychain = ref else { return nil }
        let unlocked = kcPassword.withCString { p in
            SecKeychainUnlock(keychain, UInt32(kcPassword.utf8.count), p, true)
        }
        guard unlocked == errSecSuccess else { return nil }
        Self.livePassword = kcPassword
        Self.liveKeychainPath = path
        Self.persistPassword(kcPassword)
        return keychain
    }

    /// 只把本 App 本身列入私钥的访问控制表，避免取用时弹出系统授权询问。
    private static func appOnlyAccess() -> SecAccess? {
        var trusted: SecTrustedApplication?
        // path = nil 表示"创建这个对象的进程本身"，即本 App。
        guard SecTrustedApplicationCreateFromPath(nil, &trusted) == errSecSuccess, let app = trusted else { return nil }
        var access: SecAccess?
        guard SecAccessCreate("PocketDesk 本机 TLS 私钥" as CFString, [app] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    /// 密码只落在本机 App 私有目录：它是随机串，只保护这张自签证书的私钥，与用户账号无关。
    private static func persistPassword(_ value: String) {
        let url = Self.directory.appendingPathComponent(passwordFileName)
        guard (try? Data(value.utf8).write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 主线程周期性补解锁。计时器**不能**挂在网络工作线程上——那正是被 securityd 占死的那条。
    private static func startKeepingUnlocked(_ keychain: SecKeychain) {
        Self.liveKeychain = keychain
        Self.keepUnlockedTimer?.invalidate()
        Self.keepUnlockedTimer = Timer.scheduledTimer(withTimeInterval: keepUnlockedInterval, repeats: true) { _ in
            let secret = Self.livePassword
            guard !secret.isEmpty else { return }
            _ = secret.withCString { p in
                SecKeychainUnlock(keychain, UInt32(secret.utf8.count), p, true)
            }
        }
    }

    /// 只清理明显过期的遗留钥匙串：1 小时内的文件可能属于仍在运行的实例，绝不能删。
    private static func cleanupStaleTempKeychains() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Self.directory.path) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for name in entries where name.hasPrefix("pocketdesk-tls-") && name.hasSuffix(".keychain") {
            // 必须 appendingPathComponent：NSString.appending 只做字符串拼接，会拼出 "tlspocketdesk-…"。
            let url = Self.directory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// 正常退出时带走自己的钥匙串与密码文件；被强杀时留给下次启动的过期清理。
    static func teardown() {
        keepUnlockedTimer?.invalidate()
        keepUnlockedTimer = nil
        livePassword = ""
        let fm = FileManager.default
        if !liveKeychainPath.isEmpty { try? fm.removeItem(atPath: liveKeychainPath) }
        liveKeychainPath = ""
        liveKeychain = nil
        try? fm.removeItem(at: Self.directory.appendingPathComponent(passwordFileName))
    }

    func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}
