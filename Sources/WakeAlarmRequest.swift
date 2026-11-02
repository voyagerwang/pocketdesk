/**
 * [INPUT]: 本机运行的 OH2 音箱通道（launchd 服务）写下的 control.json；WakeAlarmPlan 的时刻换算；工具参数 JSON。
 * [OUTPUT]: wake_alarm 工具的模型描述与回执；登记、取消、查看音箱侧的唤醒音乐闹钟，不直接触碰设备。
 * [POS]: AgentRunner 的到点叫醒入口；只把意图交给音箱通道，App 重启或换端口都不影响已登记的闹钟。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

struct WakeAlarmRequest {
    static let tool: [String: Any] = ["type": "function", "function": [
        "name": "wake_alarm",
        "description": "用 OH2 音箱的唤醒音乐在指定时刻叫醒用户，也负责停下正在响的闹钟。用户明确要“几分钟后叫我”“明早八点用音乐叫我”这类到点出声时用 set；说“关掉/停止播放/别响了”时用 stop，只停最近真响过的闹钟，不会掐用户自己在放的音乐；只说“提醒我”而没要求到点出声时记待办更合适。到点只播放用户自己装好的那段音乐，不念话。需要音箱在同一网络且本机音箱通道服务在运行；迟到超过十分钟不补播，睡眠开关不拦闹钟。一次调用只处理一条。",
        "parameters": ["type": "object", "properties": [
            "action": ["type": "string", "enum": ["set", "cancel", "list", "stop"], "description": "set 定闹钟，cancel 取消还没响的，list 查看现有，stop 停下正在响的音乐"],
            "minutes": ["type": "integer", "minimum": 1, "maximum": 43200, "description": "set 用：几分钟后，按相对当前时刻算"],
            "at": ["type": "string", "description": "set 用：当天或下一个 HH:mm 时刻，例如 08:00；与 minutes 二选一"],
            "id": ["type": "string", "description": "cancel 用：list 返回的闹钟 id；留空取消最近一条还没播的"]
        ], "required": ["action"], "additionalProperties": false] as [String: Any]
    ] as [String: Any]]

    static func handle(arguments: String, done: @escaping (AgentRunner.ToolOutcome) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = perform(arguments: arguments)
            DispatchQueue.main.async { done(outcome) }
        }
    }

    static func perform(arguments: String) -> AgentRunner.ToolOutcome {
        guard let data = arguments.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = values["action"] as? String else {
            return .failed("未执行：闹钟参数无效。")
        }
        do {
            switch action {
            case "set":
                guard let due = WakeAlarmPlan.due(values) else {
                    return .failed("未执行：需要给出几分钟后或明确的时刻。")
                }
                guard due.timeIntervalSinceNow > 30 else { return .failed("未执行：这个时刻已经过去了。") }
                guard due.timeIntervalSinceNow < 30 * 86400 else { return .failed("未执行：只支持三十天内。") }
                _ = try request("/alarm", method: "POST", body: ["id": newID(), "due": Int(due.timeIntervalSince1970)])
                return .sent("已定好：\(WakeAlarmPlan.describe(due)) 用音箱音乐叫你。")
            case "cancel":
                var id = (values["id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                if id.isEmpty {
                    guard let first = try pending().first else { return .sent("现在没有要取消的闹钟。") }
                    id = first.id
                }
                _ = try request("/alarm/cancel", method: "POST", body: ["id": id])
                return .sent("已取消那条闹钟，到点不会再响。")
            case "stop":
                let payload = try request("/alarm/stop", method: "POST", body: [:])
                let values = payload as? [String: Any]
                return .sent(values?["reply"] as? String ?? "现在没有闹钟在响。")
            case "list":
                let rows = try pending()
                guard !rows.isEmpty else { return .sent("现在没有排定的音箱闹钟。") }
                let times = rows.map { WakeAlarmPlan.describe(Date(timeIntervalSince1970: $0.due)) }
                return .sent("现在排着 \(rows.count) 条：" + times.joined(separator: "、") + "。")
            default:
                return .failed("未执行：不认识的闹钟动作。")
            }
        } catch let failure as WakeAlarmPlan.Failure {
            return .failed("未完成：\(failure.message)")
        } catch {
            return .failed("未完成：闹钟服务没有给出可用回执。")
        }
    }

    /// 音箱通道要求 8–64 位大小写字母、数字、下划线或连字符。
    static func newID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func request(_ path: String, method: String, body: [String: Any]?) throws -> Any {
        let control = try WakeAlarmPlan.endpoint()
        guard let url = URL(string: "http://127.0.0.1:\(control.port)\(path)") else {
            throw WakeAlarmPlan.Failure(message: "本机回环地址无效。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 8
        request.setValue("Bearer " + control.token, forHTTPHeaderField: "Authorization")
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let finished = DispatchSemaphore(value: 0)
        var outcome: Result<Any, WakeAlarmPlan.Failure> =
            .failure(WakeAlarmPlan.Failure(message: "闹钟请求没有回应。"))
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { finished.signal() }
            if let error = error {
                outcome = .failure(.init(message: "闹钟请求失败：\(error.localizedDescription)"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(.init(message: "闹钟服务没有回执。"))
                return
            }
            switch http.statusCode {
            case 200, 201:
                outcome = .success(data.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:])
            case 409:
                outcome = .failure(.init(message: "这条已经登记过了，没有重复添加。"))
            case 403:
                outcome = .failure(.init(message: "闹钟服务拒绝了这次请求，可能刚重启过，稍后再试。"))
            case 400:
                outcome = .failure(.init(message: "闹钟服务不接受这个时刻。"))
            default:
                outcome = .failure(.init(message: "闹钟服务返回 \(http.statusCode)。"))
            }
        }.resume()
        guard finished.wait(timeout: .now() + 10) == .success else {
            throw WakeAlarmPlan.Failure(message: "闹钟服务在十秒内没有回应。")
        }
        switch outcome {
        case .success(let payload): return payload
        case .failure(let failure): throw failure
        }
    }

    /// 只把还没播的按时间排好，用于 list 与“取消最近一条”。
    private static func pending() throws -> [(id: String, due: Double)] {
        let payload = try request("/alarm", method: "GET", body: nil)
        guard let object = payload as? [String: Any], let rows = object["alarms"] as? [[String: Any]] else {
            throw WakeAlarmPlan.Failure(message: "闹钟清单格式不可识别。")
        }
        return rows.filter { ($0["status"] as? String) == "scheduled" }
            .compactMap { row -> (id: String, due: Double)? in
                guard let id = row["id"] as? String else { return nil }
                return (id, (row["due"] as? Double) ?? 0)
            }
            .sorted { $0.due < $1.due }
    }
}
