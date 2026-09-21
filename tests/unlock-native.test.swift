/**
 * [INPUT]: UnlockCoordinator、CryptoKit 和隔离的锁屏/输入/凭据替身。
 * [OUTPUT]: 原生注册、确认、签名域、一次性消费、撤销/断线/锁屏变化拒绝与互操作向量。
 * [POS]: 原生协议回归；不接触真实密码、不注入系统输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CryptoKit

final class NativeLock: LockStateProviding {
    var state = "locked"
    var epoch: UInt64 = 1
    var sessionUserID: Int64? = 501
}
final class NativeInput: UnlockInputExecuting {
    let lock: NativeLock
    var count = 0
    var beforeKey: (() -> Void)?
    init(_ lock: NativeLock) { self.lock = lock }
    func prepare(session: String) -> [String: Any] { ["challenge": "test"] }
    func submit(password: String, id: String, session: String, authorized: @escaping () -> Bool,
                completion: @escaping ([String: Any]) -> Void) {
        beforeKey?()
        guard authorized() else { completion(["sent": false]); return }
        count += 1; lock.state = "unlocked"; completion(["sent": true])
    }
}
@main enum TestNative {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ name: String) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UnlockCredentialStore(secrets: MemorySecretStore(), state: UnlockStateFile(directory: directory))
        store.enabled = true; try store.savePassword("mock-only")
        let lock = NativeLock(), input = NativeInput(lock)
        let coordinator = UnlockCoordinator(credentials: store, configProvider: { nil }, lockState: lock, executor: input)
        var wakeCount = 0
        var beforeInputCount = 0
        coordinator.onBeforeInput = { beforeInputCount += 1 }
        coordinator.onUnlocked = { wakeCount += 1 }
        let phone = P256.Signing.PrivateKey()
        let point = phone.publicKey.x963Representation
        let offer = coordinator.beginPairing(native: true)
        let pairId = offer["pairId"] as! String, challenge = offer["challenge"] as! String
        let proof = try phone.signature(for: UnlockCoordinator.nativeMessage(action: "pair", request: pairId,
            challenge: challenge, credential: Base64URL.encode(point))).derRepresentation
        check(coordinator.registerNative(pairId: "wrong", publicKey: point, signature: proof, label: "test")["error"] != nil, "reject wrong pairing token")
        let registration = coordinator.registerNative(pairId: pairId, publicKey: point, signature: proof, label: "Android")
        let credential = registration["credentialId"] as! String
        check(store.credential(id: credential)?.confirmed == false, "registration is not confirmation")
        check(!coordinator.confirmPairing(pairId: "wrong"), "wrong confirmation refused")
        check(coordinator.confirmPairing(pairId: pairId), "local confirmation")
        check(coordinator.readiness(native: true) == nil && coordinator.readiness() == .unconfigured, "native needs no relay config")
        func attempt(_ name: String, action: String = "unlock", mutate: () -> Void = {}, connected: @escaping () -> Bool = { true }) throws -> [String: Any] {
            lock.state = "locked"
            let response = coordinator.handleUnlockRequest(requestId: name, nativeCredential: credential)
            let sig = try phone.signature(for: UnlockCoordinator.nativeMessage(action: action, request: name,
                challenge: response["challenge"] as! String, credential: credential)).derRepresentation
            mutate()
            var result: [String: Any] = [:]
            coordinator.handleNativeAssertion(requestId: name, credentialId: credential, signature: sig, connected: connected) { result = $0 }
            return result
        }
        check(try attempt("wrong-domain", action: "pair")["error"] != nil, "cross-protocol signature rejected")
        check(try attempt("disconnect", connected: { false })["error"] != nil, "disconnect before input")
        check(try attempt("epoch", mutate: { lock.epoch += 1 })["error"] != nil, "lock epoch change rejected")
        check(try attempt("session", mutate: { lock.sessionUserID = nil })["error"] != nil, "unknown session rejected")
        lock.sessionUserID = 501
        check(input.count == 0, "invalid requests injected zero keys")
        check(beforeInputCount == 0, "invalid requests never wake display")
        input.beforeKey = { coordinator.cancelAuthorization() }
        let canceled = try attempt("cancel-during-input")
        check(canceled["outcome"] as? String == "failed" && input.count == 0, "revocation checked before key")
        input.beforeKey = nil
        let success = try attempt("success")
        check(success["outcome"] as? String == "unlocked" && input.count == 1, "valid signature unlocks mock session")
        check(beforeInputCount == 2, "verified attempts wake before input even if later canceled")
        check(wakeCount == 1, "wake once only after confirmed unlock; rejected attempts never wake")
        var replay: [String: Any] = [:]
        coordinator.handleNativeAssertion(requestId: "success", credentialId: credential, signature: Data()) { replay = $0 }
        check(replay["error"] != nil && input.count == 1, "replay never injects again")
        lock.state = "locked"
        check(try attempt("revoke", mutate: { coordinator.revokeCredential(id: credential) })["error"] != nil, "revoked device rejected")
        check(beforeInputCount == 2, "replay and revocation never wake display")
        // 固定向量供 Java 单测独立重建核对码与签名消息，不共享实现。
        let fixed = Data([4]) + Data(repeating: 1, count: 64)
        print("VECTOR pairingCode=" + UnlockCoordinator.pairingCode(devicePoint: fixed, credentialPoint: fixed, challenge: Data(repeating: 2, count: 32)))
        exit(failures == 0 ? 0 : 1)
    }
}
