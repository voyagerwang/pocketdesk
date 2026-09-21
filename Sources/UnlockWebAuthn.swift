/**
 * [INPUT]: 依赖 CryptoKit 的 P256/SHA256、Foundation 的 JSON 解析；无任何 IO，全部纯函数。
 * [OUTPUT]: 对外提供 UnlockWebAuthn（注册/断言验证）、ParsedClientData、ParsedAuthenticatorData、UnlockAuthError、Base64URL 编解码、最小 CBOR 解码器 CBORElement。
 * [POS]: Sources 的快捷解锁验签核心；UnlockCoordinator 消费，测试直接构造字节驱动。验签用系统密码学（CryptoKit），CBOR 只做结构解析不做密码学。
 * [REVIEW]: 不可信 CBOR 长度及递归深度受限，防止输入造成整数溢出或无限递归。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CryptoKit
import Foundation

// MARK: - Base64URL

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

// MARK: - 最小 CBOR 解码（RFC 8949 子集：整数/字节串/文本串/数组/映射/简单值/标签穿透）

enum CBORError: Error { case truncated, unsupported, malformed }

indirect enum CBORElement {
    case uint(UInt64), negInt(UInt64), bytes(Data), text(String), array([CBORElement]), map([(CBORElement, CBORElement)]), simple(UInt8)
    var intValue: Int? {
        switch self {
        case .uint(let v): return Int(exactly: v)
        case .negInt(let v): return Int(exactly: v).map { -1 - $0 }
        default: return nil
        }
    }
    var dataValue: Data? { if case .bytes(let d) = self { return d }; return nil }
    var textValue: String? { if case .text(let s) = self { return s }; return nil }
    subscript(key: Int) -> CBORElement? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { $0.0.intValue == key }?.1
    }
    subscript(key: String) -> CBORElement? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { $0.0.textValue == key }?.1
    }
}

enum CBOR {
    static func decode(_ data: Data) throws -> CBORElement {
        var index = data.startIndex
        let element = try read(data, &index)
        return element
    }

    private static func read(_ data: Data, _ index: inout Data.Index, depth: Int = 0) throws -> CBORElement {
        guard depth < 32 else { throw CBORError.malformed }
        guard index < data.endIndex else { throw CBORError.truncated }
        let major = (data[index] & 0xE0) >> 5
        let info = data[index] & 0x1F
        index = data.index(after: index)
        func readLength() throws -> UInt64 {
            if info < 24 { return UInt64(info) }
            let width = 1 << (info - 24)
            guard info <= 27, index + width <= data.endIndex else { throw CBORError.truncated }
            var value: UInt64 = 0
            for _ in 0..<width { value = (value << 8) | UInt64(data[index]); index = data.index(after: index) }
            return value
        }
        switch major {
        case 0: return .uint(try readLength())
        case 1: return .negInt(try readLength())
        case 2:
            guard let count = Int(exactly: try readLength()), count <= data.count else { throw CBORError.malformed }
            guard count >= 0, index + count <= data.endIndex else { throw CBORError.truncated }
            let bytes = data.subdata(in: index..<data.index(index, offsetBy: count))
            index = data.index(index, offsetBy: count)
            return .bytes(bytes)
        case 3:
            guard let count = Int(exactly: try readLength()), count <= data.count else { throw CBORError.malformed }
            guard count >= 0, index + count <= data.endIndex else { throw CBORError.truncated }
            let bytes = data.subdata(in: index..<data.index(index, offsetBy: count))
            index = data.index(index, offsetBy: count)
            guard let text = String(data: bytes, encoding: .utf8) else { throw CBORError.malformed }
            return .text(text)
        case 4:
            guard let count = Int(exactly: try readLength()), count <= data.count else { throw CBORError.malformed }
            var items: [CBORElement] = []
            for _ in 0..<count { items.append(try read(data, &index, depth: depth + 1)) }
            return .array(items)
        case 5:
            guard let count = Int(exactly: try readLength()), count <= data.count else { throw CBORError.malformed }
            var entries: [(CBORElement, CBORElement)] = []
            for _ in 0..<count {
                let key = try read(data, &index, depth: depth + 1)
                let value = try read(data, &index, depth: depth + 1)
                entries.append((key, value))
            }
            return .map(entries)
        case 6:
            _ = try readLength() // 标签：穿透读内层
            return try read(data, &index, depth: depth + 1)
        default: return .simple(info)
        }
    }
}

// MARK: - WebAuthn 解析与验证

enum UnlockAuthError: Error, Equatable {
    case badEncoding, badJSON, badType, challengeMismatch, originMismatch, crossOrigin
    case badAuthData, rpIdMismatch, missingUP, missingUV, badCredential, badAlgorithm
    case badPublicKey, badSignature, counterRollback, unknownCredential, revoked
}

struct ParsedClientData {
    let type: String
    let challenge: String   // base64url 原文（按字节比较，不做大小写折叠）
    let origin: String
    let crossOrigin: Bool
}

struct ParsedAuthenticatorData {
    let rpIdHash: Data
    let flags: UInt8
    let signCount: UInt32
    let credentialId: Data?
    let credentialPublicKeyPoint: Data?  // P-256 未压缩点 0x04||x||y
    static let userPresent: UInt8 = 0x01
    static let userVerified: UInt8 = 0x04
}

enum UnlockWebAuthn {
    static func parseClientData(_ bytes: Data) throws -> ParsedClientData {
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let type = object["type"] as? String,
              let challenge = object["challenge"] as? String,
              let origin = object["origin"] as? String else { throw UnlockAuthError.badJSON }
        return ParsedClientData(type: type, challenge: challenge, origin: origin,
                                crossOrigin: object["crossOrigin"] as? Bool ?? false)
    }

    static func parseAuthenticatorData(_ data: Data) throws -> ParsedAuthenticatorData {
        guard data.count >= 37 else { throw UnlockAuthError.badAuthData }
        let rpIdHash = data.subdata(in: 0..<32)
        let flags = data[data.startIndex + 32]
        let countBytes = data.subdata(in: 33..<37)
        var signCount: UInt32 = 0
        for byte in countBytes { signCount = (signCount << 8) | UInt32(byte) }
        var credentialId: Data?
        var publicKeyPoint: Data?
        if flags & 0x40 != 0 { // attestedCredentialData（仅注册响应）
            guard data.count >= 37 + 18 else { throw UnlockAuthError.badAuthData }
            let offset = data.startIndex + 37
            let idLength = (Int(data[offset + 16]) << 8) | Int(data[offset + 17])
            let idStart = data.index(offset, offsetBy: 18)
            guard data.distance(from: idStart, to: data.endIndex) >= idLength else { throw UnlockAuthError.badAuthData }
            credentialId = data.subdata(in: idStart..<data.index(idStart, offsetBy: idLength))
            let cose = try CBOR.decode(data.subdata(in: data.index(idStart, offsetBy: idLength)..<data.endIndex))
            guard let point = cosePublicKeyPoint(cose) else { throw UnlockAuthError.badPublicKey }
            publicKeyPoint = point
        }
        return ParsedAuthenticatorData(rpIdHash: rpIdHash, flags: flags, signCount: signCount,
                                       credentialId: credentialId, credentialPublicKeyPoint: publicKeyPoint)
    }

    /// COSE Key（kty=2 EC2, alg=-7 ES256, crv=1 P-256）→ 未压缩点。
    static func cosePublicKeyPoint(_ cose: CBORElement) -> Data? {
        guard cose[1]?.intValue == 2, cose[3]?.intValue == -7, cose[-1]?.intValue == 1,
              let x = cose[-2]?.dataValue, let y = cose[-3]?.dataValue,
              x.count == 32, y.count == 32 else { return nil }
        return Data([0x04]) + x + y
    }

    private static func checkClientData(_ clientData: Data, expectedType: String, expectedChallenge: String,
                                        origin: String) throws -> ParsedClientData {
        let parsed = try parseClientData(clientData)
        guard parsed.type == expectedType else { throw UnlockAuthError.badType }
        // challenge 按原文比较：双方都使用 base64url 无填充编码，Mac 生成方即编码方。
        guard parsed.challenge == expectedChallenge, !parsed.challenge.isEmpty else { throw UnlockAuthError.challengeMismatch }
        guard parsed.origin == origin else { throw UnlockAuthError.originMismatch }
        guard !parsed.crossOrigin else { throw UnlockAuthError.crossOrigin }
        return parsed
    }

    private static func checkAuthData(_ authData: ParsedAuthenticatorData, rpId: String,
                                      requireCredential: Bool) throws {
        guard authData.rpIdHash == Data(SHA256.hash(data: Data(rpId.utf8))) else { throw UnlockAuthError.rpIdMismatch }
        guard authData.flags & ParsedAuthenticatorData.userPresent != 0 else { throw UnlockAuthError.missingUP }
        guard authData.flags & ParsedAuthenticatorData.userVerified != 0 else { throw UnlockAuthError.missingUV }
        if requireCredential {
            guard authData.credentialId != nil, authData.credentialPublicKeyPoint != nil else { throw UnlockAuthError.badCredential }
        }
    }

    /// 注册验证：clientDataJSON + attestationObject（fmt 不做信任锚校验，只要求 UP/UV 与密钥可解析；
    /// 平台同步通行密钥通常 fmt=none，工单允许）。返回 credentialId 与公钥点。
    static func verifyRegistration(clientDataJSON: Data, attestationObject: Data,
                                   challenge: String, origin: String, rpId: String) throws -> (credentialId: String, publicKeyPoint: Data, signCount: UInt32) {
        let client = try checkClientData(clientDataJSON, expectedType: "webauthn.create",
                                         expectedChallenge: challenge, origin: origin)
        _ = client
        guard let top = try? CBOR.decode(attestationObject),
              let authDataBytes = top["authData"]?.dataValue else { throw UnlockAuthError.badAuthData }
        let authData = try parseAuthenticatorData(authDataBytes)
        try checkAuthData(authData, rpId: rpId, requireCredential: true)
        return (Base64URL.encode(authData.credentialId!), authData.credentialPublicKeyPoint!, authData.signCount)
    }

    /// 断言验证：签名覆盖 authenticatorData || SHA256(clientDataJSON)，按记录归属与撤销态核验。
    /// counter 按同步凭据语义：仅拒绝明确回退（旧值 > 0 且新值更小），不以单调递增为唯一防重放。
    static func verifyAssertion(clientDataJSON: Data, authenticatorData: Data, signature: Data,
                                challenge: String, origin: String, rpId: String,
                                credential: UnlockCredentialRecord) throws -> UInt32 {
        try checkClientData(clientDataJSON, expectedType: "webauthn.get",
                            expectedChallenge: challenge, origin: origin)
        let authData = try parseAuthenticatorData(authenticatorData)
        try checkAuthData(authData, rpId: rpId, requireCredential: false)
        guard let pointBytes = Base64URL.decode(credential.publicKey),
              pointBytes.count == 65, pointBytes[pointBytes.startIndex] == 0x04,
              // CryptoKit rawRepresentation 是 x||y（64 字节）；存储格式是 0x04||x||y（65 字节）。
              let publicKey = try? P256.Signing.PublicKey(rawRepresentation: pointBytes.dropFirst()) else {
            throw UnlockAuthError.badPublicKey
        }
        var signed = authenticatorData
        signed.append(contentsOf: SHA256.hash(data: clientDataJSON))
        guard let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              publicKey.isValidSignature(ecdsa, for: signed) else { throw UnlockAuthError.badSignature }
        if credential.signCount > 0, authData.signCount < credential.signCount {
            throw UnlockAuthError.counterRollback
        }
        return authData.signCount
    }
}
