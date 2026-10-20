/**
 * [INPUT]: Server 已核验的本机同源请求、MijiaConnection 会话和 MijiaHomeScope 账号绑定家庭范围。
 * [OUTPUT]: 米家扫码/状态与异步家庭选择端点；仅返回脱敏状态，二维码不缓存，网络不阻塞 Server 队列。
 * [POS]: 控制台米家协议适配层；Server 统一访问边界，协调器独立管理账号生命周期。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum MijiaHTTP {
    static func handle(method: String, path: String, rawPath: String, body: Data,
                       connection: MijiaConnection = .shared,
                       scope: MijiaHomeScope = .shared,
                       reply: @escaping (Int, Data, String) -> Void) -> Bool {
        guard path.hasPrefix("/api/console/mijia/") else { return false }
        let json: (Int, [String: Any]) -> Void = { code, value in
            reply(code, (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8), "application/json; charset=utf-8")
        }
        let homeReply: (Result<[String: Any], MijiaBridge.Failure>) -> Void = { result in
            switch result {
            case .success(let value): json(200, value)
            case .failure(let error): json(error.kind == "scope" ? 409 : 502, ["error": error.message, "message": error.message])
            }
        }
        if method == "GET", path == "/api/console/mijia/status" { json(200, connection.status()); return true }
        if method == "GET", path == "/api/console/mijia/homes" { scope.homes(completion: homeReply); return true }
        if method == "GET", path == "/api/console/mijia/qr" {
            let values = URLComponents(string: rawPath)?.queryItems?.filter { $0.name == "sessionId" } ?? []
            guard values.count == 1, let session = values.first?.value, UUID(uuidString: session) != nil,
                  let png = connection.qr(session: session) else { json(404, ["error": "二维码已失效，请刷新后重新扫码。"]); return true }
            reply(200, png, "image/png"); return true
        }
        guard method == "POST", body.count <= 1024,
              let input = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            json(400, ["error": "请求格式无效。"]); return true
        }
        switch path {
        case "/api/console/mijia/home":
            guard input.count == 1, let homeID = input["homeId"] as? String, !homeID.isEmpty, homeID.count <= 256 else {
                json(400, ["error": "请选择列表中的一个家庭。"]); return true
            }
            scope.select(homeID: homeID, completion: homeReply)
        case "/api/console/mijia/connect", "/api/console/mijia/check":
            guard input.isEmpty else { json(400, ["error": "请求参数无效。"]); return true }
            json(200, path.hasSuffix("/connect") ? connection.connect() : connection.check())
        case "/api/console/mijia/cancel":
            guard input.count == 1, let session = input["sessionId"] as? String, UUID(uuidString: session) != nil else {
                json(400, ["error": "连接会话无效。"]); return true
            }
            guard let state = connection.cancel(session: session) else { json(409, ["error": "该扫码会话已结束，请刷新连接状态。"]); return true }
            json(200, state)
        default: json(404, ["error": "未找到米家操作。"])
        }
        return true
    }
}
