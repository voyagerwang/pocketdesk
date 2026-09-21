/**
 * [INPUT]: 依赖 Sources/UnlockWebAuthn.swift、Sources/UnlockConfig.swift（记录类型）与 CryptoKit；无 IO、无钥匙串、无桌面副作用。
 * [OUTPUT]: 隔离测试可执行文件：CBOR 解码、clientData/authData 解析、注册与断言验签、篡改矩阵（挑战/origin/RP/UV/签名/counter）。
 * [POS]: tests 的快捷解锁验签回归；用最小 CBOR 编码器模拟认证器字节，全部纯函数路径。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CryptoKit
import Foundation

// MARK: - 最小 CBOR 编码器（仅测试用）

enum TestCBOR {
    /// 带类型的长度头：major<<5 | info，info 按值域选 8/16/32 位附加字节。
    static func typed(_ major: UInt8, _ count: Int) -> Data {
        if count < 24 { return Data([(major << 5) | UInt8(count)]) }
        if count <= Int(UInt8.max) { return Data([(major << 5) | 24, UInt8(count)]) }
        if count <= Int(UInt16.max) { return Data([(major << 5) | 25]) + withUnsafeBytes(of: UInt16(count).bigEndian) { Data($0) } }
        return Data([(major << 5) | 26]) + withUnsafeBytes(of: UInt32(count).bigEndian) { Data($0) }
    }
    static func uint(_ v: UInt64) -> Data {
        if v < 24 { return Data([UInt8(v)]) }
        if v <= UInt8.max { return Data([0x18, UInt8(v)]) }
        return Data([0x19]) + withUnsafeBytes(of: UInt16(v).bigEndian) { Data($0) }
    }
    static func negInt(_ v: Int) -> Data { typed(1, -1 - v) }
    static func text(_ s: String) -> Data { typed(3, s.utf8.count) + Data(s.utf8) }
    static func bytes(_ d: Data) -> Data { typed(2, d.count) + d }
    static func map(_ pairs: [(Data, Data)]) -> Data {
        typed(5, pairs.count) + pairs.reduce(Data()) { $0 + $1.0 + $1.1 }
    }
}

// MARK: - 假认证器（模拟平台通行密钥的字节行为）

final class FakeAuthenticator {
    let privateKey = P256.Signing.PrivateKey()
    let credentialId = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    var signCount: UInt32 = 0

    var publicKeyPoint: Data { Data([0x04]) + privateKey.publicKey.rawRepresentation }

    private func coseKey() -> Data {
        let x = privateKey.publicKey.rawRepresentation.prefix(32)
        let y = privateKey.publicKey.rawRepresentation.suffix(32)
        return TestCBOR.map([
            (TestCBOR.uint(1), TestCBOR.uint(2)),       // kty: EC2
            (TestCBOR.uint(3), TestCBOR.negInt(-7)),    // alg: ES256
            (TestCBOR.negInt(-1), TestCBOR.uint(1)),    // crv: P-256
            (TestCBOR.negInt(-2), TestCBOR.bytes(Data(x))),
            (TestCBOR.negInt(-3), TestCBOR.bytes(Data(y))),
        ])
    }

    func clientData(type: String, challenge: String, origin: String, crossOrigin: Bool = false) -> Data {
        let cross = crossOrigin ? ",\"crossOrigin\":true" : ""
        return Data("{\"type\":\"\(type)\",\"challenge\":\"\(challenge)\",\"origin\":\"\(origin)\"\(cross)}".utf8)
    }

    /// 注册：fmt=none + attestedCredentialData。
    func registration(challenge: String, origin: String, rpId: String,
                      type: String = "webauthn.create", crossOrigin: Bool = false,
                      flags: UInt8 = 0x45) -> (clientDataJSON: Data, attestationObject: Data) {
        let rpHash = Data(SHA256.hash(data: Data(rpId.utf8)))
        var authData = rpHash + Data([flags]) + withUnsafeBytes(of: UInt32(0).bigEndian) { Data($0) }
        if flags & 0x40 != 0 {
            authData += Data(repeating: 0, count: 16)   // aaguid
            authData += withUnsafeBytes(of: UInt16(credentialId.count).bigEndian) { Data($0) }
            authData += credentialId
            authData += coseKey()
        }
        let attestation = TestCBOR.map([
            (TestCBOR.text("fmt"), TestCBOR.text("none")),
            (TestCBOR.text("attStmt"), TestCBOR.map([])),
            (TestCBOR.text("authData"), TestCBOR.bytes(authData)),
        ])
        return (clientData(type: type, challenge: challenge, origin: origin, crossOrigin: crossOrigin), attestation)
    }

    /// 断言：签名覆盖 authData || SHA256(clientDataJSON)。
    func assertion(challenge: String, origin: String, rpId: String,
                   type: String = "webauthn.get", crossOrigin: Bool = false,
                   flags: UInt8 = 0x05, signOverride: P256.Signing.PrivateKey? = nil) -> (clientDataJSON: Data, authenticatorData: Data, signature: Data) {
        let client = clientData(type: type, challenge: challenge, origin: origin, crossOrigin: crossOrigin)
        signCount += 1
        let authData = Data(SHA256.hash(data: Data(rpId.utf8))) + Data([flags])
            + withUnsafeBytes(of: signCount.bigEndian) { Data($0) }
        let signer = signOverride ?? privateKey
        var material = authData
        material.append(contentsOf: SHA256.hash(data: client))
        let signature = try! signer.signature(for: material)
        return (client, authData, Data(signature.derRepresentation))
    }
}

// MARK: - 断言辅助

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}
func checkThrows<T>(_ expr: @autoclosure () throws -> T, _ name: String) {
    do { _ = try expr(); failures += 1; print("FAIL \(name)（未抛错）") }
    catch { print("PASS \(name) [\(error)]") }
}

let origin = "https://quickunlock.example.com"
let rpId = "quickunlock.example.com"

// MARK: - 测试主体

@main struct UnlockWebAuthnTest {
    static func main() throws {

    do {
        let data = TestCBOR.map([
            (TestCBOR.text("a"), TestCBOR.uint(5)),
            (TestCBOR.text("b"), TestCBOR.bytes(Data([1, 2, 3]))),
            (TestCBOR.text("c"), TestCBOR.negInt(-7)),
        ])
        let decoded = try CBOR.decode(data)
        check(decoded["a"]?.intValue == 5, "cbor uint")
        check(decoded["b"]?.dataValue == Data([1, 2, 3]), "cbor bytes")
        check(decoded["c"]?.intValue == -7, "cbor negint")
        check(decoded["z"] == nil, "cbor missing key")
        checkThrows(try CBOR.decode(Data([0x18])), "cbor truncated")
    } catch { failures += 1; print("FAIL cbor decode crashed: \(error)") }

    // MARK: - 注册验证

    let auth = FakeAuthenticator()
    let regChallenge = Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
    do {
        let reg = auth.registration(challenge: regChallenge, origin: origin, rpId: rpId)
        let result = try UnlockWebAuthn.verifyRegistration(clientDataJSON: reg.clientDataJSON,
                                                           attestationObject: reg.attestationObject,
                                                           challenge: regChallenge, origin: origin, rpId: rpId)
        check(result.credentialId == Base64URL.encode(auth.credentialId), "registration credentialId")
        check(result.publicKeyPoint == auth.publicKeyPoint, "registration public key point")
    } catch { failures += 1; print("FAIL registration valid: \(error)") }

    // 篡改矩阵（注册）
    do {
        func expectRegError(_ name: String, _ mutate: (FakeAuthenticator) -> (Data, Data)) throws {
            let reg = mutate(FakeAuthenticator())
            checkThrows(try UnlockWebAuthn.verifyRegistration(clientDataJSON: reg.0, attestationObject: reg.1,
                                                              challenge: regChallenge, origin: origin, rpId: rpId), name)
        }
        try expectRegError("registration wrong challenge") { $0.registration(challenge: Base64URL.encode(Data(repeating: 9, count: 32)), origin: origin, rpId: rpId) }
        try expectRegError("registration wrong origin") { $0.registration(challenge: regChallenge, origin: "https://evil.example", rpId: rpId) }
        try expectRegError("registration wrong type") { $0.registration(challenge: regChallenge, origin: origin, rpId: rpId, type: "webauthn.get") }
        try expectRegError("registration crossOrigin") { $0.registration(challenge: regChallenge, origin: origin, rpId: rpId, crossOrigin: true) }
        try expectRegError("registration rpId mismatch") { $0.registration(challenge: regChallenge, origin: origin, rpId: "evil.example") }
        try expectRegError("registration UP/UV missing") { $0.registration(challenge: regChallenge, origin: origin, rpId: rpId, flags: 0x40) }
        try expectRegError("registration no attested data") { $0.registration(challenge: regChallenge, origin: origin, rpId: rpId, flags: 0x05) }
    } catch { failures += 1; print("FAIL registration tamper crashed") }

    // MARK: - 断言验证

    let record = UnlockCredentialRecord(credentialId: Base64URL.encode(auth.credentialId),
                                        publicKey: Base64URL.encode(auth.publicKeyPoint),
                                        label: "手机", createdAt: 0, lastUsedAt: nil,
                                        signCount: 0, confirmed: true, transport: "synced")
    do {
        let assertionChallenge = Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let asr = auth.assertion(challenge: assertionChallenge, origin: origin, rpId: rpId)
        let count = try UnlockWebAuthn.verifyAssertion(clientDataJSON: asr.clientDataJSON,
                                                       authenticatorData: asr.authenticatorData,
                                                       signature: asr.signature,
                                                       challenge: assertionChallenge, origin: origin, rpId: rpId,
                                                       credential: record)
        check(count > 0, "assertion valid returns signCount")
    } catch { failures += 1; print("FAIL assertion valid: \(error)") }

    do {
        func expectAsrError(_ name: String, _ mutate: (FakeAuthenticator) -> (Data, Data, Data)) {
            let asr = mutate(FakeAuthenticator())
            checkThrows(try UnlockWebAuthn.verifyAssertion(clientDataJSON: asr.0, authenticatorData: asr.1,
                                                           signature: asr.2, challenge: assertionChallenge,
                                                           origin: origin, rpId: rpId, credential: record), name)
        }
        let assertionChallenge = Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        expectAsrError("assertion wrong challenge") { $0.assertion(challenge: Base64URL.encode(Data(repeating: 1, count: 32)), origin: origin, rpId: rpId) }
        expectAsrError("assertion wrong origin") { $0.assertion(challenge: assertionChallenge, origin: "https://evil.example", rpId: rpId) }
        expectAsrError("assertion wrong type") { $0.assertion(challenge: assertionChallenge, origin: origin, rpId: rpId, type: "webauthn.create") }
        expectAsrError("assertion crossOrigin") { $0.assertion(challenge: assertionChallenge, origin: origin, rpId: rpId, crossOrigin: true) }
        expectAsrError("assertion rpId mismatch") { $0.assertion(challenge: assertionChallenge, origin: origin, rpId: "evil.example") }
        expectAsrError("assertion UP missing") { $0.assertion(challenge: assertionChallenge, origin: origin, rpId: rpId, flags: 0x04) }
        expectAsrError("assertion UV missing") { $0.assertion(challenge: assertionChallenge, origin: origin, rpId: rpId, flags: 0x01) }
        // 换钥签名：内容合法但签名者不是登记公钥
        expectAsrError("assertion forged key") { fake in
            fake.assertion(challenge: assertionChallenge, origin: origin, rpId: rpId, signOverride: P256.Signing.PrivateKey())
        }
    } catch { failures += 1; print("FAIL assertion tamper crashed") }

    // counter 回退：旧值 > 0 且新值更小
    do {
        let rolledBack = UnlockCredentialRecord(credentialId: record.credentialId, publicKey: record.publicKey,
                                                label: record.label, createdAt: 0, lastUsedAt: nil,
                                                signCount: 100, confirmed: true, transport: "synced")
        let challenge = Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        var lowAuth = auth
        lowAuth.signCount = 50
        let asr = lowAuth.assertion(challenge: challenge, origin: origin, rpId: rpId)
        checkThrows(try UnlockWebAuthn.verifyAssertion(clientDataJSON: asr.clientDataJSON, authenticatorData: asr.authenticatorData,
                                                       signature: asr.signature, challenge: challenge, origin: origin,
                                                       rpId: rpId, credential: rolledBack), "counter rollback rejected")
        // 同步凭据 counter=0 恒定不算回退（0→0 合法）
        let asrZero = auth.assertion(challenge: Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) })),
                                     origin: origin, rpId: rpId)
        let zeroChallenge = (try! JSONSerialization.jsonObject(with: asrZero.clientDataJSON) as! [String: Any])["challenge"] as! String
        _ = try UnlockWebAuthn.verifyAssertion(clientDataJSON: asrZero.clientDataJSON,
                                               authenticatorData: asrZero.authenticatorData,
                                               signature: asrZero.signature,
                                               challenge: zeroChallenge,
                                               origin: origin, rpId: rpId, credential: record)
        print("PASS counter zero-sync accepted")
    } catch { failures += 1; print("FAIL counter test: \(error)") }

    if failures > 0 { print("unlock-webauthn: \(failures) FAILURES"); exit(1) }
    print("unlock-webauthn: passed")
    }
}
