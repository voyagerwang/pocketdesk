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
    // 承载证书私钥的一次性临时钥匙串；故意不碰登录钥匙串，避免每次启动弹“使用登录钥匙串”。
    private let tempKeychain: SecKeychain?

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
            let s = SecPKCS12Import(data as CFData, [
                kSecImportExportPassphrase as String: password,
                kSecImportExportKeychain as String: kc,
            ] as CFDictionary, &items)
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
        self.tempKeychain = temp
    }

    /// 在 App 私有目录内建一个带随机密码、已解锁、不加入用户列表的一次性钥匙串。
    private static func createUnlockedTempKeychain() -> SecKeychain? {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let path = Self.directory.appendingPathComponent("pocketdesk-tls-\(UUID().uuidString).keychain").path
        let kcPassword = UUID().uuidString
        var ref: SecKeychain?
        let created = path.withCString { p in
            // promptUser=false：绝不以任何形式向用户索要密码。
            SecKeychainCreate(p, UInt32(kcPassword.utf8.count), kcPassword, false, nil, &ref)
        }
        guard created == errSecSuccess, let keychain = ref else { return nil }
        let unlocked = kcPassword.withCString { p in
            SecKeychainUnlock(keychain, UInt32(kcPassword.utf8.count), p, true)
        }
        return unlocked == errSecSuccess ? keychain : nil
    }

    /// 删除本 App 私有目录内上一轮遗留的临时钥匙串文件，避免长期残留。
    private static func cleanupStaleTempKeychains() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Self.directory.path) else { return }
        for name in entries where name.hasPrefix("pocketdesk-tls-") && name.hasSuffix(".keychain") {
            try? fm.removeItem(atPath: (Self.directory.path as NSString).appending(name))
        }
    }

    func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}
