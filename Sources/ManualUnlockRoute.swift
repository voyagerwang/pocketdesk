/**
 * [INPUT]: Network 请求连接、Auth 配对验证、ManualUnlockHTTP 和当前控制租约。
 * [OUTPUT]: 拦截手动解锁请求；强制可信 HTTPS 页面、Bearer、同源 JSON 与断线失效，无回环豁免。
 * [POS]: 手动密码的传输边界；不保存或输出请求体，系统输入仍由专用执行器负责。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Network

enum ManualUnlockAccess {
    static func permits(secure: Bool, method: String, bearerValid: Bool,
                        host: String?, origin: String?, contentType: String?, bodySize: Int) -> Bool {
        guard secure, method == "POST", bearerValid, bodySize <= 8192,
              contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json",
              let host, let origin, let source = URLComponents(string: origin),
              source.scheme == "https", source.user == nil, source.password == nil,
              source.query == nil, source.fragment == nil, source.path.isEmpty || source.path == "/",
              let expected = URLComponents(string: "https://" + host), expected.host != nil,
              source.host?.lowercased() == expected.host?.lowercased(),
              (source.port ?? 443) == (expected.port ?? 443) else { return false }
        return true
    }
}

enum ManualUnlockRoute {
    static func handle(method: String, path: String, body: Data, secure: Bool,
                       host: String?, origin: String?, contentType: String?, authorization: String?,
                       connection: NWConnection, handler: ManualUnlockHTTP?,
                       controlAuthorized: @escaping (String) -> Bool,
                       respond: @escaping (Int, [String: Any]) -> Void) -> Bool {
        guard path.hasPrefix("/api/manual-unlock/") else { return false }
        guard ManualUnlockAccess.permits(secure: secure, method: method,
                bearerValid: Auth.verify(authorizationHeader: authorization),
                host: host, origin: origin, contentType: contentType, bodySize: body.count) else {
            respond(403, ["outcome": "failed", "error": "secure-controller-required",
                          "detail": "请从可信 HTTPS 页面连接，并接管电脑控制后解锁。"])
            return true
        }
        guard let handler, let request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let session = request["session"] as? String, !session.isEmpty, session.utf8.count <= 128 else {
            respond(400, ["outcome": "failed", "error": "invalid-session", "detail": "控制会话不可用，请重新连接画面。"])
            return true
        }
        // FIN、额外请求或连接失败会立即取消本连接，执行器在每键前复查。
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { extra, _, finished, error in
            if finished || error != nil || !(extra?.isEmpty ?? true) { connection.cancel() }
        }
        if !handler.handle(method: method, path: path, body: body, secure: secure,
                           authorized: { controlAuthorized(session) },
                           connected: { connection.state == .ready }, completion: respond) {
            respond(404, ["outcome": "failed", "error": "unknown-route", "detail": "解锁入口不可用。"])
        }
        return true
    }
}
