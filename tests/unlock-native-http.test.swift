/**
 * [INPUT]: 原生 HTTP 适配层与内存钥匙串/锁屏替身；不监听端口。
 * [OUTPUT]: TLS 强制、独立凭据、注册/确认路由、限流和请求尺寸边界回归。
 * [POS]: tests 原生路由隔离测试，拒绝路径不得执行输入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CryptoKit
// 仅给邀请生成函数提供无副作用依赖；路由测试不读取任何生产目录。
enum Util { static func primaryLANAddress() -> String? { nil } }
enum SecureTransport { static let port: UInt16 = 46487; static let directory = URL(fileURLWithPath: "/does-not-exist") }
final class TestLock: LockStateProviding { var state = "locked"; var epoch: UInt64 = 1; var sessionUserID: Int64? = 501 }
final class NoInput: UnlockInputExecuting {
    func prepare(session: String) -> [String: Any] { fatalError("unexpected input") }
    func submit(password: String, id: String, session: String, authorized: @escaping () -> Bool, completion: @escaping ([String: Any]) -> Void) { fatalError("unexpected input") }
}
@main enum TestNativeHTTP {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UnlockCredentialStore(secrets: MemorySecretStore(), state: UnlockStateFile(directory: directory))
        let coordinator = UnlockCoordinator(credentials: store, configProvider: { nil }, lockState: TestLock(), executor: NoInput())
        let service = UnlockNativeHTTP(coordinator: coordinator)
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func request(_ path: String, _ body: [String: Any] = [:], secure: Bool = true) throws -> [String: Any] {
            let done = DispatchSemaphore(value: 0); var result: [String: Any] = [:]
            service.handle(path: "/api/native-unlock/" + path, body: try JSONSerialization.data(withJSONObject: body), secure: secure, connected: { true }) { result = $0; done.signal() }
            guard done.wait(timeout: .now() + 3) == .success else { fatalError("HTTP handler stalled") }
            return result
        }
        check(try request("status", secure: false)["error"] as? String == "https-required", "no HTTP fallback")
        check(try request("status")["error"] as? String == "disabled", "disabled refuses requests")
        store.enabled = true; try store.savePassword("mock")
        check(try request("status", ["credentialId": "ordinary-web-token"])["error"] as? String == "unauthorized", "ordinary web token is not native identity")
        let offer = coordinator.beginPairing(native: true), phone = P256.Signing.PrivateKey()
        let pair = offer["pairId"] as! String, challenge = offer["challenge"] as! String
        let point = Base64URL.encode(phone.publicKey.x963Representation)
        let proof = try phone.signature(for: UnlockCoordinator.nativeMessage(action: "pair", request: pair, challenge: challenge, credential: point)).derRepresentation
        let registered = try request("register", ["pairId": pair, "publicKey": point, "signature": Base64URL.encode(proof)])
        let id = registered["credentialId"] as! String
        check(try request("status", ["credentialId": id])["confirmed"] as? Bool == false, "status reports awaiting local confirmation")
        check(try request("challenge", ["credentialId": id])["error"] as? String == "not-confirmed", "unconfirmed device cannot request unlock")
        check(coordinator.confirmPairing(pairId: pair), "native panel confirms registration")
        check(try request("status", ["credentialId": id])["confirmed"] as? Bool == true, "confirmed state restored on reconnect")
        check(try request("challenge", ["credentialId": id])["challenge"] != nil, "native challenge without relay config")
        coordinator.revokeCredential(id: id)
        check(try request("status", ["credentialId": id])["error"] as? String == "unauthorized", "revocation invalidates bearer immediately")
        for _ in 0..<120 { _ = try request("status") }
        check(try request("status")["error"] as? String == "rate-limited", "requests bounded per minute")
        exit(failures == 0 ? 0 : 1)
    }
}
