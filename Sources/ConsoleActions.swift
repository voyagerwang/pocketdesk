/**
 * [INPUT]: 本机请求边界、UnlockCoordinator/NativeHTTP/凭据门面、系统文件选择器与文件快照。
 * [OUTPUT]: 本机网页文件发送、快捷解锁与显式钥匙串授权检查；Host/Origin/自定义头限制写入，密码不回传，授权仅限已解锁电脑。
 * [POS]: 控制台操作适配层，与手机远控和原生签名解锁路由隔离；所有 AppKit 操作交主线程。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

final class ConsoleActions {
    private let coordinator: UnlockCoordinator
    private let native: UnlockNativeHTTP
    private let configured: () -> Bool
    private let isLocked: () -> Bool
    private let queue = DispatchQueue(label: "dev.voicedeck.console-actions")
    private var pair: [String: Any]?
    init(coordinator: UnlockCoordinator, native: UnlockNativeHTTP, configured: @escaping () -> Bool, isLocked: @escaping () -> Bool = { LockScreenInput.locked }) {
        self.coordinator = coordinator; self.native = native; self.configured = configured; self.isLocked = isLocked
        let previous = native.onPairingCode
        native.onPairingCode = { [weak self] code, id in
            previous?(code, id)
            self?.queue.async { [weak self] in
                guard self?.pair?["pairId"] as? String == id else { return }
                self?.pair?["code"] = code
            }
        }
    }
    // 不依赖回环豁免推断信任：拒绝远程、DNS 重绑定、跨站表单及缺少专用头的写请求。
    static func allowed(loopback: Bool, method: String, host: String?, origin: String?, marker: String?,
                        contentType: String?, port: UInt16, secure: Bool) -> Bool {
        guard loopback, let host, ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host.lowercased()) else { return false }
        let expected = "\(secure ? "https" : "http")://\(host)"
        if method == "GET" { return origin == nil || origin == expected }
        return method == "POST" && origin == expected && marker == "1"
            && contentType?.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json"
    }
    func handle(method: String, path: String, body: Data, reply: @escaping (Int, [String: Any]) -> Void) {
        guard body.count <= 8192 else { reply(413, ["error": "请求过大。"]); return }
        queue.async { [self] in
            if method == "GET", path == "/api/console/files" {
                reply(200, ["files": PhoneFileStore.shared.list(subject: PhoneFileStore.subject).map(\.json)]); return
            }
            if method == "GET", path == "/api/console/unlock" { reply(200, snapshot()); return }
            guard method == "POST", let input = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                reply(400, ["error": "请求格式无效。"]); return
            }
            if path == "/api/console/files/pick" {
                DispatchQueue.main.async { PhoneFilePicker.shared.presentPicker { reply($0["error"] == nil ? 200 : 422, $0) } }; return
            }
            guard !isLocked() else { reply(423, ["error": "请在已解锁的电脑上修改设置。"]); return }
            do {
                switch path {
                case "/api/console/unlock/keychain-authorize":
                    guard coordinator.credentials.authorizeKeychain() else {
                        reply(422, ["error": "钥匙串后台读取仍不可用。请在系统提示中为当前 PocketDesk 选择“始终允许”，再检查一次；未保存密码时请先保存密码。"]); return
                    }
                case "/api/console/unlock/password":
                    guard let password = input["password"] as? String, !password.isEmpty else {
                        reply(400, ["error": "请输入电脑登录密码。"]); return
                    }
                    coordinator.cancelAuthorization()
                    try coordinator.credentials.savePassword(password)
                case "/api/console/unlock/password/delete":
                    coordinator.disable(); cancelPair(); coordinator.credentials.deletePassword()
                case "/api/console/unlock/enabled":
                    guard let enabled = input["enabled"] as? Bool else { reply(400, ["error": "缺少开关状态。"]); return }
                    if enabled {
                        guard configured(), coordinator.credentials.hasPassword else { reply(422, ["error": "请先保存登录密码，并确认安全通道已就绪。"]); return }
                        coordinator.credentials.enabled = true
                    } else { coordinator.disable(); cancelPair() }
                case "/api/console/unlock/pair":
                    let offer = native.invitation()
                    guard offer["error"] == nil, let id = offer["pairId"] as? String else {
                        reply(422, ["error": "请先保存密码、开启快捷解锁，并连接局域网。"]); return
                    }
                    let bytes = try JSONSerialization.data(withJSONObject: offer, options: [.sortedKeys])
                    let link = "pocketdesk://pair#" + Base64URL.encode(bytes)
                    guard let png = Util.qrPNG(link) else { reply(500, ["error": "无法生成二维码，请重试。"]); return }
                    pair = ["pairId": id, "link": link, "qr": "data:image/png;base64," + png.base64EncodedString(),
                            "expiresAt": Date().addingTimeInterval(300).timeIntervalSince1970]
                case "/api/console/unlock/confirm":
                    guard let id = input["pairId"] as? String, pair?["pairId"] as? String == id,
                          pair?["code"] != nil, coordinator.confirmPairing(pairId: id) else {
                        reply(409, ["error": "配对已失效，请重新生成二维码。"]); return
                    }
                    pair = nil
                case "/api/console/unlock/cancel": cancelPair()
                case "/api/console/unlock/revoke":
                    guard let id = input["id"] as? String, coordinator.credentials.credential(id: id) != nil else {
                        reply(404, ["error": "该设备已不存在。"]); return
                    }
                    coordinator.revokeCredential(id: id)
                default: reply(404, ["error": "未找到操作。"]); return
                }
                reply(200, snapshot())
            } catch { reply(500, ["error": "保存失败，原有设置未被替换。请重试。"]) }
        }
    }
    private func cancelPair() {
        if let id = pair?["pairId"] as? String { coordinator.denyPairing(pairId: id) }
        pair = nil
    }
    private func snapshot() -> [String: Any] {
        if let expiry = pair?["expiresAt"] as? Double, expiry <= Date().timeIntervalSince1970 { cancelPair() }
        var result: [String: Any] = ["configured": configured(), "enabled": coordinator.credentials.enabled,
            "hasPassword": coordinator.credentials.hasPassword,
            "credentials": coordinator.credentials.credentials.filter(\.confirmed).map { ["id": $0.credentialId, "label": $0.label] }]
        if let pair { result["pair"] = pair }
        if let attempt = native.latestAttempt { result["lastAttempt"] = attempt }
        return result
    }
}
