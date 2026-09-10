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

    init() throws {
        let data = try Data(contentsOf: Self.directory.appendingPathComponent("server.p12"))
        let password = try String(contentsOf: Self.directory.appendingPathComponent("password"), encoding: .utf8).trimmingCharacters(in: .newlines)
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: password] as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let raw = first[kSecImportItemIdentity as String], CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID(),
              let identity = sec_identity_create(raw as! SecIdentity) else {
            throw NSError(domain: "PocketDeskTLS", code: Int(status))
        }
        self.identity = identity
    }

    func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}
