/**
 * [INPUT]: Foundation/CryptoKit、显式环境或仅机主可读的本机 Bridge 配置、可信配对主体与稳定请求编号。
 * [OUTPUT]: note.create 的 canonical v1 调用及 G1/G2 固定只读路径；超时仅报告待查，不调用本机 Agent。
 * [POS]: Workbench 增量客户端；不接管 TaskService，不持有业务事实，不接受手机指定 URL 或凭证。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CryptoKit

enum WorkbenchBridge {
    struct Configuration {
        let baseURL: URL
        let token: String
        let device: String
        /// 普通 App 启动不继承终端环境；文件只作显式部署配置，缺失/不安全均关闭。
        static func loadLocal(file: URL, env: [String: String] = ProcessInfo.processInfo.environment) -> Configuration? {
            if env["POCKETDESK_BRIDGE_ENABLED"] != nil { return load(env) }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
                  let data = try? Data(contentsOf: file),
                  let values = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
            return load(values)
        }
        static func load(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Configuration? {
            guard env["POCKETDESK_BRIDGE_ENABLED"] == "1",
                  let token = env["POCKETDESK_BRIDGE_TOKEN"], token.count >= 32,
                  let device = env["POCKETDESK_DEVICE_ID"], !device.isEmpty,
                  let url = URL(string: env["WORKBENCH_BRIDGE_URL"] ?? "http://127.0.0.1:8787"),
                  url.scheme == "http", url.host == "127.0.0.1", url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/"
            else { return nil }
            return Configuration(baseURL: url, token: token, device: device)
        }
    }
    static func subject(_ pairingToken: String) -> String { hash(Data(pairingToken.utf8)) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil
    }
    /// 只映射固定路由；不接受查询串、编码斜线、任意路径或手机传入的 owner。
    static func readPath(_ path: String) -> String? {
        let prefix = "/api/v1/workbench/"
        guard path.hasPrefix(prefix) else { return nil }
        let suffix = String(path.dropFirst(prefix.count))
        if ["capabilities", "views/tasks", "views/memories"].contains(suffix) { return "api/bridge/" + suffix }
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0] == "requests", validID(parts[1]) { return "api/bridge/" + suffix }
        if parts.count == 2, parts[0] == "artifacts", parts[1].range(of: "^[0-9]+$", options: .regularExpression) != nil {
            return "api/bridge/" + suffix
        }
        if parts.count == 3, parts[0] == "views" {
            if parts[1] == "tasks", parts[2].range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) != nil,
               let cursor = Int64(parts[2]), cursor <= 9_007_199_254_740_991 { return "api/bridge/" + suffix }
            if parts[1] == "task-result", parts[2].range(of: "^(WB-)?[0-9]{8}-[0-9]+$", options: .regularExpression) != nil {
                return "api/bridge/" + suffix
            }
        }
        return nil
    }
    static func invocation(requestID: String, title: String, body: String, subject: String,
                           configuration: Configuration, now: Date = Date()) throws -> [String: Any] {
        guard validID(requestID), title.count <= 1000, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.utf8.count <= 100_000 else { throw BridgeError.invalidInput }
        let canonical = try JSONSerialization.data(withJSONObject: [title, body], options: [.withoutEscapingSlashes])
        return ["protocolVersion": 1, "requestId": requestID, "operationId": "note-\(requestID)",
                "invocationId": "invoke-\(requestID)", "bindingId": "workbench-note-default",
                "capabilityId": "note.create", "capabilityVersion": "1",
                "arguments": ["title": title, "body": body], "argumentHash": hash(canonical),
                "contextRefs": [String](), "authorizationRef": "pocketdesk:\(configuration.device):\(subject)",
                "deadlineAt": ISO8601DateFormatter().string(from: now.addingTimeInterval(30))]
    }
    enum BridgeError: Error { case invalidInput }
    /// 不跟随重定向，避免把用途凭证交给其他地址。
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static func request(configuration: Configuration, subject: String, path: String, method: String = "GET",
                        payload: [String: Any]? = nil, completion: @escaping (Int, [String: Any]) -> Void) {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 12
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.device, forHTTPHeaderField: "X-PocketDesk-Device")
        request.setValue(subject, forHTTPHeaderField: "X-PocketDesk-Subject")
        if let payload {
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { completion(400, ["error": "请求格式不合法"]); return }
            request.httpBody = data; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let response = response as? HTTPURLResponse, let data, data.count <= 512_000,
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(502, ["state": "uncertain", "error": "Workbench 回执待查询，未交给本机 Agent 重做。"]); return
            }
            guard !(300..<400).contains(response.statusCode) else { completion(502, ["error": "Bridge 拒绝重定向"]); return }
            completion(response.statusCode, value)
        }.resume()
    }
}
