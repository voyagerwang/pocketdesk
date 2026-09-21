/**
 * [INPUT]: 依赖 UnlockCoordinator 的本机授权、SecureTransport 身份与 Foundation/CryptoKit。
 * [OUTPUT]: 提供原生 HTTPS 请求路由和包含证书指纹的五分钟配对邀请；不返回电脑密码；本机控制台可读取仅含阶段、时间和错误的最近回执，不存密码/挑战/签名。
 * [POS]: 安卓/iOS 共用的直连适配层；独立于旧网页 token，未配对只能提交持有邀请的注册。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CryptoKit

final class UnlockNativeHTTP {
    let coordinator: UnlockCoordinator
    var onPairingCode: ((String, String) -> Void)?
    private let queue = DispatchQueue(label: "PocketDesk.nativeUnlock.http")
    private let inputQueue = DispatchQueue(label: "PocketDesk.nativeUnlock.input")
    private var window = Date()
    private var calls = 0
    private var busy = false
    private let diagnosticLock = NSLock()
    private var lastAttempt: [String: Any]?
    var latestAttempt: [String: Any]? {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }; return lastAttempt
    }
    private func record(_ result: [String: Any], stage: String) {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }
        lastAttempt = ["stage": stage, "time": Date().timeIntervalSince1970,
            "outcome": result["outcome"] as? String ?? (result["error"] == nil ? "pending" : "failed"),
            "error": result["error"] as? String ?? "", "detail": result["detail"] as? String ?? ""]
    }
    init(coordinator: UnlockCoordinator) { self.coordinator = coordinator }

    func invitation() -> [String: Any] {
        guard coordinator.credentials.enabled, coordinator.credentials.hasPassword,
              let host = Util.primaryLANAddress(),
              let certificate = try? Data(contentsOf: SecureTransport.directory.appendingPathComponent("server-cert.der")),
              let point = coordinator.credentials.devicePublicKeyPoint else { return ["error": "local-setup-required"] }
        var offer = coordinator.beginPairing(native: true)
        guard offer["error"] == nil else { return offer }
        offer["v"] = 1
        offer["endpoint"] = "https://\(host):\(SecureTransport.port)"
        offer["pin"] = Base64URL.encode(Data(SHA256.hash(data: certificate)))
        offer["deviceKey"] = Base64URL.encode(point)
        offer["name"] = Host.current().localizedName ?? "我的 Mac"
        return offer
    }

    func handle(path: String, body: Data, secure: Bool, connected: @escaping () -> Bool,
                reply: @escaping ([String: Any]) -> Void) {
        let respond: ([String: Any]) -> Void = { result in
            if path.hasSuffix("/assert") || (path.hasSuffix("/challenge") && result["error"] != nil) {
                self.record(result, stage: path.hasSuffix("/assert") ? "执行解锁" : "请求授权")
            }
            reply(result)
        }
        guard secure else { respond(["error": "https-required"]); return }
        guard body.count <= 8192, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            respond(["error": "invalid-request"]); return
        }
        queue.async { [self] in
            if Date().timeIntervalSince(window) >= 60 { calls = 0; window = Date() }
            calls += 1
            guard calls <= 120 else { respond(["error": "rate-limited"]); return }
            guard coordinator.credentials.enabled else { respond(["error": "disabled"]); return }
            if path == "/api/native-unlock/register" {
                guard let pairId = json["pairId"] as? String,
                      let point = (json["publicKey"] as? String).flatMap(Base64URL.decode),
                      let sig = (json["signature"] as? String).flatMap(Base64URL.decode) else {
                    respond(["error": "invalid-request"]); return
                }
                let result = coordinator.registerNative(pairId: pairId, publicKey: point, signature: sig,
                    label: json["label"] as? String ?? "安卓手机")
                if let code = result["code"] as? String { onPairingCode?(code, pairId) }
                respond(result); return
            }
            guard let id = json["credentialId"] as? String,
                  let credential = coordinator.credentials.credential(id: id), credential.transport == "native-v1" else {
                respond(["error": "unauthorized"]); return
            }
            if path == "/api/native-unlock/status" {
                respond(["confirmed": credential.confirmed, "state": coordinator.lockState.state]); return
            }
            guard credential.confirmed else { respond(["error": "not-confirmed"]); return }
            if path == "/api/native-unlock/challenge" {
                guard !busy else { respond(["error": "busy"]); return }
                let request = UUID().uuidString
                var result = coordinator.handleUnlockRequest(requestId: request, nativeCredential: id)
                result["requestId"] = request
                respond(result); return
            }
            if path == "/api/native-unlock/assert" {
                guard !busy, let request = json["requestId"] as? String,
                      let sig = (json["signature"] as? String).flatMap(Base64URL.decode) else {
                    respond(["error": "busy-or-invalid"]); return
                }
                busy = true
                record(["detail": "正在核验手机授权并执行解锁"], stage: "执行解锁")
                inputQueue.async { [self] in
                    coordinator.handleNativeAssertion(requestId: request, credentialId: id, signature: sig,
                        connected: connected) { result in
                            self.queue.async { self.busy = false }
                            respond(result)
                        }
                }
                return
            }
            respond(["error": "not-found"])
        }
    }
}
