/**
 * [INPUT]: 依赖 Sources/UnlockCoordinator/UnlockWebAuthn/UnlockConfig/UnlockKeychain 与 CryptoKit；内存钥匙串、内存状态文件、mock 锁屏/执行器，无真实 IO 与桌面副作用。
 * [OUTPUT]: 隔离测试可执行文件：就绪检查、挑战生命周期、原子消费/重放/并发、代际与会话作废、撤销与关闭、配对核对码与确认、状态签名。
 * [POS]: tests 的快捷解锁状态机回归；恶意输入矩阵必须做到"输入执行次数为零"。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CryptoKit
import Foundation

// MARK: - Mock

final class MockLockState: LockStateProviding {
    var state: String
    private var _epoch: UInt64
    var sessionUserID: Int64?
    var epoch: UInt64 { _epoch }
    init(state: String = "locked", epoch: UInt64 = 7, sessionUserID: Int64? = 501) {
        self.state = state; self._epoch = epoch; self.sessionUserID = sessionUserID
    }
    func bump() { _epoch &+= 1 }
    func unlockNow() { state = "unlocked"; _epoch &+= 1 }
}

final class MockExecutor: UnlockInputExecuting {
    struct Record { let password: String; let authorizedResults: [Bool] }
    private(set) var records: [Record] = []
    var prepareResult: [String: Any] = [:]
    var submittedSemaphore = DispatchSemaphore(value: 0)
    var authorizedResults: [Bool] = []
    var onBeforeKey: ((Int) -> Void)?
    /// authorized() 任一为 false 时模拟执行器中止（与 LockScreenInput 一致：发出错误回执）。
    func prepare(session: String) -> [String: Any] { prepareResult }
    func submit(password: String, id: String, session: String, authorized: @escaping () -> Bool,
                completion: @escaping ([String: Any]) -> Void) {
        let gateResults = authorizedResults
        authorizedResults = []
        var gates: [Bool] = []
        // 逐键模拟：5 个事件各检查一次授权。
        for index in 0..<5 {
            onBeforeKey?(index)
            let ok = authorized()
            gates.append(ok)
            if !ok { break }
        }
        _ = gateResults
        records.append(Record(password: password, authorizedResults: gates))
        let allAllowed = gates.allSatisfy { $0 } && gates.count == 5
        completion(allAllowed ? ["sent": true] : ["error": "状态已变化，输入已停止；不会自动重试。"])
    }
    var submitCount: Int { records.count }
}

// MARK: - 测试辅助（复用 webauthn 测试的假认证器思想，独立最小实现）

final class TestAuthenticator {
    let privateKey = P256.Signing.PrivateKey()
    let credentialId = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    func clientData(type: String, challenge: String, origin: String) -> Data {
        Data("{\"type\":\"\(type)\",\"challenge\":\"\(challenge)\",\"origin\":\"\(origin)\"}".utf8)
    }
    func assertion(challenge: String, origin: String, rpId: String) -> (clientDataJSON: Data, authenticatorData: Data, signature: Data) {
        let client = clientData(type: "webauthn.get", challenge: challenge, origin: origin)
        let authData = Data(SHA256.hash(data: Data(rpId.utf8))) + Data([0x05]) + Data(repeating: 0, count: 4)
        var material = authData
        material.append(contentsOf: SHA256.hash(data: client))
        return (client, authData, Data(try! privateKey.signature(for: material).derRepresentation))
    }
}

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if condition { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
}

@main struct UnlockCoordinatorTest {
    static func main() throws {
        let origin = "https://quickunlock.example.com"
        let rpId = "quickunlock.example.com"
        let config = UnlockConfig(origin: origin, rpId: rpId, relayWSS: "wss://relay.example.com/ws", deviceName: "书房 Mac")

        func makeSystem() -> (UnlockCoordinator, UnlockCredentialStore, MockLockState, MockExecutor, TestAuthenticator) {
            let store = UnlockCredentialStore(secrets: MemorySecretStore(), state: UnlockStateFile(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
            let lock = MockLockState()
            let executor = MockExecutor()
            executor.prepareResult = ["challenge": "mock-challenge"]
            var cfg: UnlockConfig? = config
            let coordinator = UnlockCoordinator(credentials: store, configProvider: { cfg },
                                                lockState: lock, executor: executor,
                                                clock: { DispatchTime.now() })
            return (coordinator, store, lock, executor, TestAuthenticator())
        }

        // 就绪检查
        do {
            var cfg: UnlockConfig? = nil
            let store = UnlockCredentialStore(secrets: MemorySecretStore(), state: UnlockStateFile(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
            let lock = MockLockState()
            let coordinator = UnlockCoordinator(credentials: store, configProvider: { cfg }, lockState: lock, executor: MockExecutor())
            check(coordinator.readiness() == .unconfigured, "readiness: unconfigured")
            cfg = config
            check(coordinator.readiness() == .disabled, "readiness: disabled")
            store.enabled = true
            check(coordinator.readiness() == .noPassword, "readiness: no password")
            try store.savePassword("探针密码-非真实")
            check(coordinator.readiness() == .noCredential, "readiness: no credential")
            let auth = TestAuthenticator()
            store.upsertCredential(UnlockCredentialRecord(credentialId: Base64URL.encode(auth.credentialId),
                publicKey: Base64URL.encode(Data([0x04]) + auth.privateKey.publicKey.rawRepresentation),
                label: "手机", createdAt: 0, lastUsedAt: nil, signCount: 0, confirmed: false, transport: "synced"))
            check(coordinator.readiness() == .noCredential, "readiness: unconfirmed credential")
            store.confirmCredential(id: Base64URL.encode(auth.credentialId))
            check(coordinator.readiness() == nil, "readiness: ok")
        }

        // 正常路径 + 原子消费 + 重放
        do {
            let (coordinator, store, lock, executor, auth) = makeSystem()
            store.enabled = true
            try store.savePassword("探针密码-非真实")
            let credId = Base64URL.encode(auth.credentialId)
            store.upsertCredential(UnlockCredentialRecord(credentialId: credId,
                publicKey: Base64URL.encode(Data([0x04]) + auth.privateKey.publicKey.rawRepresentation),
                label: "手机", createdAt: 0, lastUsedAt: nil, signCount: 0, confirmed: true, transport: "synced"))
            let request = coordinator.handleUnlockRequest(requestId: "req-1")
            guard let challenge = request["challenge"] as? String else { throw NSError(domain: "no challenge", code: 1) }
            check(request["rpId"] as? String == rpId, "unlock challenge carries rpId")
            // 断言前模拟"提交后解锁"
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { lock.unlockNow() }
            let asr = auth.assertion(challenge: challenge, origin: origin, rpId: rpId)
            var result: [String: Any]?
            let done = DispatchSemaphore(value: 0)
            coordinator.handleUnlockAssertion(requestId: "req-1", credentialId: credId,
                                              clientDataJSON: asr.clientDataJSON,
                                              authenticatorData: asr.authenticatorData,
                                              signature: asr.signature) { r in result = r; done.signal() }
            done.wait()
            if result?["outcome"] as? String != "unlocked" { print("DEBUG happy result:", result ?? [:]) }
            check(result?["outcome"] as? String == "unlocked", "happy path unlocks")
            check(executor.submitCount == 1, "exactly one submit")
            check(executor.records.first?.password == "探针密码-非真实", "executor received credential once")
            // 重放：同一断言再来一次 → consumed，输入次数仍为 1
            var replay: [String: Any]?
            coordinator.handleUnlockAssertion(requestId: "req-1", credentialId: credId,
                                              clientDataJSON: asr.clientDataJSON,
                                              authenticatorData: asr.authenticatorData,
                                              signature: asr.signature) { r in replay = r }
            check(replay?["error"] as? String == UnlockVerificationFailure.consumed.rawValue, "replay rejected as consumed")
            check(executor.submitCount == 1, "replay performed zero input")
            // 结果带签名与设备公钥
            check(result?["sig"] != nil && result?["deviceKey"] != nil, "result signed with device key")
        }

        // 并发双断言：只有一个能执行
        do {
            let (coordinator, store, lock, executor, auth) = makeSystem()
            store.enabled = true
            try store.savePassword("探针密码-非真实")
            let credId = Base64URL.encode(auth.credentialId)
            store.upsertCredential(UnlockCredentialRecord(credentialId: credId,
                publicKey: Base64URL.encode(Data([0x04]) + auth.privateKey.publicKey.rawRepresentation),
                label: "手机", createdAt: 0, lastUsedAt: nil, signCount: 0, confirmed: true, transport: "synced"))
            let request = coordinator.handleUnlockRequest(requestId: "req-c")
            let challenge = request["challenge"] as! String
            lock.unlockNow(); lock.state = "locked" // 恢复 locked 但 epoch 推进——需要重新请求
            let request2 = coordinator.handleUnlockRequest(requestId: "req-c2")
            let challenge2 = request2["challenge"] as! String
            let asr = auth.assertion(challenge: challenge2, origin: origin, rpId: rpId)
            let group = DispatchGroup()
            let q = DispatchQueue(label: "test", attributes: .concurrent)
            var outcomes: [String] = []
            let outLock = NSLock()
            for _ in 0..<2 {
                group.enter()
                q.async {
                    coordinator.handleUnlockAssertion(requestId: "req-c2", credentialId: credId,
                                                      clientDataJSON: asr.clientDataJSON,
                                                      authenticatorData: asr.authenticatorData,
                                                      signature: asr.signature) { r in
                        outLock.lock(); outcomes.append(r["outcome"] as? String ?? r["error"] as? String ?? "?"); outLock.unlock()
                        group.leave()
                    }
                }
            }
            _ = challenge
            group.wait()
            check(executor.submitCount == 1, "concurrent double-assertion performs one input (\(outcomes))")
            check(outcomes.filter { $0 == "unlocked" || $0 == "unconfirmed" }.count == 1, "concurrent: one success path")
        }

        // 篡改/撤销/代际/会话/状态矩阵：输入执行次数必须为零
        do {
            func expectZeroInput(_ name: String, _ mutate: (UnlockCoordinator, UnlockCredentialStore, MockLockState) -> Void,
                                 prepareResult: [String: Any] = ["challenge": "c"]) {
                let (coordinator, store, lock, executor, auth) = makeSystem()
                store.enabled = true
                try? store.savePassword("探针密码-非真实")
                let credId = Base64URL.encode(auth.credentialId)
                store.upsertCredential(UnlockCredentialRecord(credentialId: credId,
                    publicKey: Base64URL.encode(Data([0x04]) + auth.privateKey.publicKey.rawRepresentation),
                    label: "手机", createdAt: 0, lastUsedAt: nil, signCount: 0, confirmed: true, transport: "synced"))
                executor.prepareResult = prepareResult
                let request = coordinator.handleUnlockRequest(requestId: "req-x")
                let challenge = request["challenge"] as? String ?? ""
                let asr = auth.assertion(challenge: challenge, origin: origin, rpId: rpId)
                mutate(coordinator, store, lock)
                var result: [String: Any]?
                coordinator.handleUnlockAssertion(requestId: "req-x", credentialId: credId,
                                                  clientDataJSON: asr.clientDataJSON,
                                                  authenticatorData: asr.authenticatorData,
                                                  signature: asr.signature) { r in result = r }
                check(executor.submitCount == 0, "\(name): zero input")
                check(result?["error"] != nil, "\(name): reported error (\(result?["error"] ?? result?["outcome"] ?? "nil"))")
            }
            expectZeroInput("lock released before assert") { _, _, lock in lock.unlockNow() }
            expectZeroInput("epoch bump") { _, _, lock in lock.bump() }
            expectZeroInput("session change") { _, _, lock in lock.sessionUserID = 999 }
            expectZeroInput("state unknown") { _, _, lock in lock.state = "unknown" }
            expectZeroInput("revoked credential") { coordinator, _, _ in coordinator.revokeCredential(id: Base64URL.encode(TestAuthenticator().credentialId)) }
            // 撤销后 pending 全清：直接用同 auth 的 credId
            do {
                let (coordinator, store, lock, executor, auth) = makeSystem()
                store.enabled = true
                try? store.savePassword("探针密码-非真实")
                let credId = Base64URL.encode(auth.credentialId)
                store.upsertCredential(UnlockCredentialRecord(credentialId: credId,
                    publicKey: Base64URL.encode(Data([0x04]) + auth.privateKey.publicKey.rawRepresentation),
                    label: "手机", createdAt: 0, lastUsedAt: nil, signCount: 0, confirmed: true, transport: "synced"))
                _ = coordinator.handleUnlockRequest(requestId: "req-r")
                coordinator.revokeCredential(id: credId)
                // 撤销后凭据不存在 → unknownCredential；pending 也已清
                let challenge = "stale"
                let asr = auth.assertion(challenge: challenge, origin: origin, rpId: rpId)
                var result: [String: Any]?
                coordinator.handleUnlockAssertion(requestId: "req-r", credentialId: credId,
                                                  clientDataJSON: asr.clientDataJSON,
                                                  authenticatorData: asr.authenticatorData,
                                                  signature: asr.signature) { r in result = r }
                check(executor.submitCount == 0, "revoked: zero input")
                check(result?["error"] as? String == UnlockVerificationFailure.unknownCredential.rawValue, "revoked: unknown credential")
            }
            // 未锁屏直接请求
            do {
                let (coordinator, store, _, _, auth) = makeSystem()
                store.enabled = true
                try? store.savePassword("探针密码-非真实")
                let credId = Base64URL.encode(auth.credentialId)
                store.upsertCredential(UnlockCredentialRecord(credentialId: credId,
                    publicKey: Base64URL.encode(Data([0x04]) + auth.privateKey.publicKey.rawRepresentation),
                    label: "手机", createdAt: 0, lastUsedAt: nil, signCount: 0, confirmed: true, transport: "synced"))
                var r: [String: Any]?
                r = coordinator.handleUnlockRequest(requestId: "req-u")
                check(r?["error"] != nil || r?["challenge"] != nil, "request in locked default state ok")
            }
            // prepare 门禁拒绝 → 零输入
            do {
                let (coordinator, store, lock, executor, auth) = makeSystem()
                store.enabled = true
                try? store.savePassword("探针密码-非真实")
                let credId = Base64URL.encode(auth.credentialId)
                store.upsertCredential(UnlockCredentialRecord(credentialId: credId,
                    publicKey: Base64URL.encode(Data([0x04]) + auth.privateKey.publicKey.rawRepresentation),
                    label: "手机", createdAt: 0, lastUsedAt: nil, signCount: 0, confirmed: true, transport: "synced"))
                executor.prepareResult = ["error": "锁屏输入暂不可用"]
                let request = coordinator.handleUnlockRequest(requestId: "req-p")
                let challenge = request["challenge"] as! String
                let asr = auth.assertion(challenge: challenge, origin: origin, rpId: rpId)
                var result: [String: Any]?
                coordinator.handleUnlockAssertion(requestId: "req-p", credentialId: credId,
                                                  clientDataJSON: asr.clientDataJSON,
                                                  authenticatorData: asr.authenticatorData,
                                                  signature: asr.signature) { r in result = r }
                check(result?["error"] as? String == UnlockVerificationFailure.prepareRejected.rawValue, "prepare rejected surfaced")
                check(executor.submitCount == 0, "prepare rejected: zero input")
            }
        }

        // 代际变化：授权闭包拒绝 → 执行器中止（sent=false）
        do {
            let (coordinator, store, lock, executor, auth) = makeSystem()
            store.enabled = true
            try store.savePassword("探针密码-非真实")
            let credId = Base64URL.encode(auth.credentialId)
            store.upsertCredential(UnlockCredentialRecord(credentialId: credId,
                publicKey: Base64URL.encode(Data([0x04]) + auth.privateKey.publicKey.rawRepresentation),
                label: "手机", createdAt: 0, lastUsedAt: nil, signCount: 0, confirmed: true, transport: "synced"))
            let request = coordinator.handleUnlockRequest(requestId: "req-g")
            let challenge = request["challenge"] as! String
            coordinator.setGeneration(999)   // 与请求时绑定的代际（0）不同 → 授权闭包全拒绝
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { lock.unlockNow() }
            let asr = auth.assertion(challenge: challenge, origin: origin, rpId: rpId)
            var result: [String: Any]?
            let done = DispatchSemaphore(value: 0)
            coordinator.handleUnlockAssertion(requestId: "req-g", credentialId: credId,
                                              clientDataJSON: asr.clientDataJSON,
                                              authenticatorData: asr.authenticatorData,
                                              signature: asr.signature) { r in result = r; done.signal() }
            done.wait()
            // prepare 允许，但按键中途授权闭包失败 → submit 返回错误 → outcome failed
            check(executor.submitCount == 0 && result?["error"] != nil, "generation change rejects before input")
        }

        // 配对：注册 → 核对码 → 确认/拒绝
        do {
            let (coordinator, store, _, _, _) = makeSystem()
            store.enabled = true
            try? store.savePassword("探针密码-非真实")
            let offer = coordinator.beginPairing()
            check(offer["pairId"] != nil && offer["challenge"] != nil, "pairing offer created")
            let pairId = offer["pairId"] as! String
            let challenge = offer["challenge"] as! String
            let phone = TestAuthenticator()
            // 用 TestAuthenticator 的 clientData + 手工 attestation（复用 webauthn 测试的编码思路）
            let reg = Self.registration(attestationChallenge: challenge, origin: origin, rpId: rpId, auth: phone)
            let result = coordinator.handlePairingRegister(pairId: pairId, clientDataJSON: reg.0, attestationObject: reg.1)
            check(result["code"] != nil, "pairing register returns code")
            check((result["code"] as? String)?.count == 7, "pairing code 7 digits")
            // 未确认凭据不能解锁
            check(store.credentials.first?.confirmed == false, "credential pending until confirm")
            let request = coordinator.handleUnlockRequest(requestId: "req-pair")
            check(request["error"] as? String == UnlockVerificationFailure.noCredential.rawValue, "unconfirmed credential blocks unlock")
            check(!coordinator.confirmPairing(pairId: "wrong-id"), "wrong pairing id rejected")
            check(coordinator.confirmPairing(pairId: pairId), "confirm pairing")
            check(store.credentials.first?.confirmed == true, "credential confirmed")
            // 拒绝路径：新配对注册后 deny → 凭据删除
            let offer2 = coordinator.beginPairing()
            let pairId2 = offer2["pairId"] as! String
            let challenge2 = offer2["challenge"] as! String
            let phone2 = TestAuthenticator()
            let reg2 = Self.registration(attestationChallenge: challenge2, origin: origin, rpId: rpId, auth: phone2)
            _ = coordinator.handlePairingRegister(pairId: pairId2, clientDataJSON: reg2.0, attestationObject: reg2.1)
            coordinator.denyPairing(pairId: pairId2)
            check(store.credentials.count == 1, "denied credential removed")
        }

        // 状态签名可被设备公钥验证
        do {
            let (coordinator, store, _, _, _) = makeSystem()
            store.enabled = true
            guard let (payload, sig) = coordinator.statusBroadcast() else { throw NSError(domain: "no state", code: 1) }
            let key = store.deviceKey()!
            let bytes = Base64URL.decode(payload["signedData"] as! String)!
            let ecdsa = try P256.Signing.ECDSASignature(derRepresentation: Base64URL.decode(sig) ?? Data())
            check(key.publicKey.isValidSignature(ecdsa, for: bytes), "status signature verifies with device key")
            // 篡改 payload → 验签失败
            var tampered = payload
            tampered["state"] = "unlocked"
            let tamperedBytes = try JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
            check(!key.publicKey.isValidSignature(ecdsa, for: tamperedBytes), "tampered state rejected")
        }

        // 在 submit 已进入后取消，下一键必须拒绝，而非仅清理 pending。
        for action in ["revoke", "disconnect", "delete", "session", "unknown-user"] {
            let (coordinator, store, lock, executor, auth) = makeSystem()
            store.enabled = true
            try store.savePassword("test-only")
            let id = Base64URL.encode(auth.credentialId)
            store.upsertCredential(UnlockCredentialRecord(credentialId: id,
                publicKey: Base64URL.encode(Data([0x04]) + auth.privateKey.publicKey.rawRepresentation),
                label: "test", createdAt: 0, signCount: 0, confirmed: true, transport: "synced"))
            let request = coordinator.handleUnlockRequest(requestId: action)
            let assertion = auth.assertion(challenge: request["challenge"] as! String, origin: origin, rpId: rpId)
            executor.onBeforeKey = { index in
                guard index == 1 else { return }
                switch action {
                case "revoke": coordinator.revokeCredential(id: id)
                case "disconnect": coordinator.setGeneration(20)
                case "delete": coordinator.cancelAuthorization(); store.deletePassword()
                case "session": lock.sessionUserID = 999
                default: lock.sessionUserID = nil
                }
            }
            coordinator.handleUnlockAssertion(requestId: action, credentialId: id,
                clientDataJSON: assertion.clientDataJSON, authenticatorData: assertion.authenticatorData,
                signature: assertion.signature) { _ in }
            check(executor.records.first?.authorizedResults == [true, false], "mid-submit \(action) stops next key")
        }
        check(UnlockConfig.defaultDirectory.lastPathComponent == "VoiceDeck", "configuration uses script directory")
        check(UnlockConfig(origin: "http://localhost.evil.com", rpId: "localhost.evil.com", relayWSS: "ws://localhost.evil.com").validated == nil, "localhost prefix attack rejected")
        // 配置校验
        do {
            check(UnlockConfig(origin: "https://a.com", rpId: "a.com", relayWSS: "wss://b/ws").validated != nil, "config https+wss valid")
            check(UnlockConfig(origin: "http://localhost:8443", rpId: "localhost", relayWSS: "ws://localhost:8788/ws").validated != nil, "config localhost test valid")
            check(UnlockConfig(origin: "http://evil.com", rpId: "evil.com", relayWSS: "wss://b/ws").validated == nil, "config plain http rejected")
            check(UnlockConfig(origin: "https://a.com", rpId: "a.com", relayWSS: "http://b/ws").validated == nil, "config non-wss relay rejected")
            check(UnlockConfig(origin: "https://a.com", rpId: "", relayWSS: "wss://b/ws").validated == nil, "config empty rpId rejected")
        }

        if failures > 0 { print("unlock-coordinator: \(failures) FAILURES"); exit(1) }
        print("unlock-coordinator: passed")
    }

    /// 构造 fmt=none 注册响应（与 unlock-webauthn 测试同一编码思路，独立实现避免测试间耦合）。
    static func registration(attestationChallenge: String, origin: String, rpId: String, auth: TestAuthenticator) -> (Data, Data) {
        func typed(_ major: UInt8, _ count: Int) -> Data {
            if count < 24 { return Data([(major << 5) | UInt8(count)]) }
            if count <= Int(UInt8.max) { return Data([(major << 5) | 24, UInt8(count)]) }
            if count <= Int(UInt16.max) { return Data([(major << 5) | 25]) + withUnsafeBytes(of: UInt16(count).bigEndian) { Data($0) } }
            return Data([(major << 5) | 26]) + withUnsafeBytes(of: UInt32(count).bigEndian) { Data($0) }
        }
        func text(_ s: String) -> Data { typed(3, s.utf8.count) + Data(s.utf8) }
        func bytes(_ d: Data) -> Data { typed(2, d.count) + d }
        func uint(_ v: UInt64) -> Data { v < 24 ? Data([UInt8(v)]) : Data([0x18, UInt8(v)]) }
        func negInt(_ v: Int) -> Data { typed(1, -1 - v) }
        func map(_ pairs: [(Data, Data)]) -> Data { typed(5, pairs.count) + pairs.reduce(Data()) { $0 + $1.0 + $1.1 } }
        let raw = auth.privateKey.publicKey.rawRepresentation
        let coseKey = map([
            (uint(1), uint(2)), (uint(3), negInt(-7)), (negInt(-1), uint(1)),
            (negInt(-2), bytes(raw.prefix(32))), (negInt(-3), bytes(raw.suffix(32))),
        ])
        var authData = Data(SHA256.hash(data: Data(rpId.utf8))) + Data([0x45]) + Data(repeating: 0, count: 4)
        authData += Data(repeating: 0, count: 16)
        authData += withUnsafeBytes(of: UInt16(auth.credentialId.count).bigEndian) { Data($0) }
        authData += auth.credentialId
        authData += coseKey
        let attestation = map([
            (text("fmt"), text("none")), (text("attStmt"), map([])), (text("authData"), bytes(authData)),
        ])
        let client = auth.clientData(type: "webauthn.create", challenge: attestationChallenge, origin: origin)
        return (client, attestation)
    }
}
