/**
 * [INPUT]: 依赖 Security 的证书/私钥 DER 与 Network TLS；读取本机私有 TLS 目录。
 * [OUTPUT]: 提供独立 HTTPS/WSS 监听参数；证书缺失时不开启安全通道，绝不降级密码请求。
 * [POS]: Sources 的 TLS 装配边界；三条服务共享同一证书，客户端必须正常验证信任链。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Security
import Network

// SecIdentityCreate 是 Security 的 C 接口，Swift overlay 没有导出它；按符号名声明即可用。
@_silgen_name("SecIdentityCreate")
private func SecIdentityCreate(_ allocator: CFAllocator?, _ certificate: SecCertificate, _ privateKey: SecKey) -> SecIdentity?

final class SecureTransport {
    static let port: UInt16 = 46487
    static let directory = TargetStore.supportDirectory.appendingPathComponent("tls")

    // 证书与私钥直接以 DER 读进内存装配身份，**全程不进钥匙串**。
    //
    // 从前把私钥导入一次性临时钥匙串，代价是那个钥匙串会自己上锁：`security show-keychain-info`
    // 显示新建钥匙串默认 `lock-on-sleep timeout=300s`（闲置 5 分钟即锁，睡眠也锁），而
    // `SecKeychainSetSettings` 实测改不动（登录钥匙串才是 no-timeout）。TLS 握手取私钥又**没有
    // 任何超时**，一旦上锁，签名会永久停在 securityd 的等待里把唯一的网络工作线程占死：HTTPS 页面、
    // 心跳、/api 一起静默超时（不是某次请求失败），同时弹出一个「钥匙串密码」框——那是随机生成、
    // 用户不可能知道的密码。内存身份没有钥匙串、没有 ACL、没有上锁，这一类故障与弹窗从根上不存在。
    private let identity: sec_identity_t

    /// 手机安装信任用的 CA 证书（DER）。控制台与手机页据此提供可点击的下载入口。
    static var caCertificateURL: URL { directory.appendingPathComponent("PocketDesk-CA.cer") }

    init() throws {
        let certificateData = try Data(contentsOf: Self.directory.appendingPathComponent("server-cert.der"))
        let keyData = try Data(contentsOf: Self.directory.appendingPathComponent("server-key.der"))

        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw Self.failure("证书 server-cert.der 无法解析，")
        }
        // PKCS#1 DER 私钥：给对 keyType/keyClass，Security 直接在内存里建出 SecKey。
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            throw Self.failure("私钥 server-key.der 无法解析，")
        }
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw Self.failure("无法装配 TLS 身份，")
        }
        guard let secure = sec_identity_create(identity) else {
            throw Self.failure("TLS 身份无法交给 Network.framework，")
        }
        self.identity = secure
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PocketDeskTLS", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message + "已放弃安全通道（不影响 HTTP）。"])
    }

    func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}
