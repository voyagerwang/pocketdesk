/**
 * [INPUT]: Server已解析的请求与响应闭包、ConsoleActions来源策略、MijiaHTTP和DesktopVoiceHTTP。
 * [OUTPUT]: 控制台管理路由统一执行严格回环/同源/标记/JSON门禁，再分发领域处理器。
 * [POS]: Server的本机管理接缝；不执行领域操作，所有console子路径共享同一授权边界。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum ConsoleManagementHTTP {
    static func handle(method: String, path: String, rawPath: String, body: Data, loopback: Bool,
                       header: (String) -> String?, port: UInt16, secure: Bool, actions: ConsoleActions?,
                       reply: @escaping (Int, [String: Any]) -> Void,
                       replyData: @escaping (Int, Data, String) -> Void) -> Bool {
        guard path.hasPrefix("/api/console/") else { return false }
        guard let actions, ConsoleActions.allowed(loopback: loopback, method: method,
            host: header("Host"), origin: header("Origin"), marker: header("X-PocketDesk-Console"),
            contentType: header("Content-Type"), port: port, secure: secure) else {
            reply(403, ["error": "请在电脑本机控制台操作。"]); return true
        }
        if DesktopVoiceHTTP.handle(method: method, path: path, body: body, reply: reply) { return true }
        if MijiaHTTP.handle(method: method, path: path, rawPath: rawPath, body: body, reply: replyData) { return true }
        actions.handle(method: method, path: path, body: body, reply: reply)
        return true
    }
}
