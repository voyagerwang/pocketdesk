/**
 * [INPUT]: 已配对手机的 Bearer、固定 G1/G2 路径、显式环境或 VoiceDeck/workbench-bridge.json 专用配置。
 * [OUTPUT]: 显式笔记提交/查账和只读任务/记忆代理；机主授权由 Workbench 决定，无任意 URL/主体参数。
 * [POS]: AgentHTTP 增量委托层；旧任务循环和手动输入/画面/鼠标通道完全不切流。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
enum WorkbenchBridgeHTTP {
    static func handle(method: String, path: String, body: Data, authorization: String?,
                       respond: @escaping (Int, [String: Any]) -> Void) {
        guard Auth.verify(authorizationHeader: authorization) else { respond(401, ["error": "需要手机配对凭证"]); return }
        guard let config = WorkbenchBridge.Configuration.loadLocal(file: TargetStore.supportDirectory.appendingPathComponent("workbench-bridge.json"))
        else { respond(503, ["error": "Workbench Bridge 尚未准入"]); return }
        let subject = WorkbenchBridge.subject(Auth.token)
        if method == "POST", path == "/api/v1/workbench/notes" {
            guard let value = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  Set(value.keys).isSubset(of: ["requestId", "title", "body"]),
                  let id = value["requestId"] as? String, let title = value["title"] as? String,
                  let text = value["body"] as? String,
                  let payload = try? WorkbenchBridge.invocation(requestID: id, title: title, body: text, subject: subject, configuration: config)
            else { respond(400, ["error": "需要稳定 requestId、title 和 body"]); return }
            WorkbenchBridge.request(configuration: config, subject: subject, path: "api/bridge/pocketdesk/inbound", method: "POST", payload: payload, completion: respond)
            return
        }
        if method == "GET", let target = WorkbenchBridge.readPath(path) {
            WorkbenchBridge.request(configuration: config, subject: subject, path: target, completion: respond); return
        }
        respond(404, ["error": "Bridge 未开放该能力"])
    }
}
