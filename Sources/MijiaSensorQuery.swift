/**
 * [INPUT]: 单句温湿度查询、MijiaGateway 家庭授权后的结构化读数，以及 TaskStore/AgentRunner 的任务与租约事实。
 * [OUTPUT]: 保守的零模型只读查询和一句话读数；设备直读与云端历史分开，未知时间不补造，复合/补充任务回原模型循环。
 * [POS]: 米家查询的轻量入口与纯回执格式；不持有设备缓存、不绕过 Gateway 或 Python 的规格白名单，不执行家电写入。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreFoundation

enum MijiaSensorQuery {
    struct Request: Equatable {
        let metric: String
        let query: String?
        var arguments: [String: Any] {
            var value: [String: Any] = ["operation": "query_environment", "metric": metric]
            if let query { value["query"] = query }
            return value
        }
    }
    struct Receipt {
        let text: String
        let current: Bool
    }

    static func request(for task: AgentTask) -> Request? {
        guard task.attempt == 1, task.supplementCount == 0, task.context == nil,
              task.transcript?.isEmpty != false else { return nil }
        return request(in: task.text)
    }

    /// 仅覆盖完整环境读数句式；外地天气、建议、条件控制与多个指标留给模型。
    static func request(in text: String) -> Request? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count <= 80, !input.contains("\n"), !input.contains("\r") else { return nil }
        let pattern = "^(?:(?:请你?|帮我|麻烦你?)\\s*)?(?:(?:查询|查看|查|看)(?:一下)?|看看|查查)?\\s*(?:现在|当前|实时)?\\s*(米家)?\\s*(客厅|卧室|主卧|次卧|书房|厨房|阳台|卫生间|儿童房|房间|家里|室内)?(?:里|里面)?的?(?:现在|当前|实时)?的?(湿度|温度)(?:是|有)?(?:多少|几度)?(?:呢|啊|呀)?[？?。！!]*$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: input).map { String(input[$0]) }
        }
        guard let metric = group(3), group(1) != nil || group(2) != nil else { return nil }
        let place = group(2)
        let query = ["房间", "家里", "室内"].contains(place ?? "") ? nil : place
        return Request(metric: metric == "湿度" ? "humidity" : "temperature", query: query)
    }

    static func receipt(_ payload: String, metric: String, now: Date = Date(), timeZone: TimeZone = .current) -> Receipt? {
        guard ["humidity", "temperature"].contains(metric), let data = payload.data(using: .utf8),
              let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              result["metric"] as? String == metric,
              let number = result["value"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              let property = result["property"] as? [String: Any],
              property["unit"] as? String == (metric == "humidity" ? "percentage" : "celsius"),
              let source = result["source"] as? String, ["device", "cloud"].contains(source) else { return nil }
        let value = number.doubleValue
        guard (metric == "humidity" ? 0...100 : -273.15...1000).contains(value) else { return nil }
        let device = result["device"] as? [String: Any]
        let room = (device?["room"] as? String ?? "").components(separatedBy: .controlCharacters).joined()
        let label = String(room.prefix(20)) + (metric == "humidity" ? "湿度" : "温度")
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false; formatter.maximumFractionDigits = 2
        guard let digits = formatter.string(from: number) else { return nil }
        let reading = digits + (metric == "humidity" ? "%" : "℃")
        if source == "device" { return Receipt(text: "\(label) \(reading)。", current: true) }
        var stamp = "更新时间未知"
        if let timestamp = result["updated_at"] as? NSNumber,
           CFGetTypeID(timestamp) != CFBooleanGetTypeID(), timestamp.doubleValue.isFinite,
           timestamp.doubleValue >= 946684800, timestamp.doubleValue <= now.timeIntervalSince1970 {
            let date = Date(timeIntervalSince1970: timestamp.doubleValue)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
            let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "zh_CN"); dateFormatter.timeZone = timeZone
            dateFormatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "今天HH:mm" :
                (calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "M月d日" : "yyyy年M月d日")
            stamp = dateFormatter.string(from: date)
        }
        return Receipt(text: "\(label)当前值暂时读不到；最近记录 \(reading)（\(stamp)）。", current: false)
    }
}

extension AgentRunner {
    /// 一旦开始只读请求便按真实回执结束；错误不转模型猜测，也不重复查询。
    static func tryQuickSensorQuery(task: AgentTask, completion: @escaping (Outcome) -> Void) -> Bool {
        guard let request = MijiaSensorQuery.request(for: task) else { return false }
        let arguments = MijiaGateway.encode(request.arguments)
        let callID = "mijia-sensor-" + UUID().uuidString
        MijiaGateway.execute(arguments: arguments, taskId: task.id, authorized: { canControl(task.id) }) { result in
            guard let currentTask = TaskStore.task(id: task.id), currentTask.status == .running,
                  currentTask.attempt == task.attempt else {
                completion(Outcome(content: nil, usage: .zero, error: "任务已结束，未继续查询。", pages: [], rounds: 0, drifted: false)); return
            }
            var content: String?, error: String?, needsInput = false
            var recovery: TaskRecovery?
            let raw: String
            switch result {
            case .sent(let payload):
                raw = payload
                if let receipt = MijiaSensorQuery.receipt(payload, metric: request.metric) {
                    content = receipt.text; needsInput = !receipt.current
                    if !receipt.current { recovery = .init(kind: .executionFailure) }
                } else { error = "温湿度读数无法核对，请稍后再试。"; recovery = .init(kind: .executionFailure) }
            case .needsInput(let message):
                raw = message; content = message; needsInput = true; recovery = .init(kind: .clarification)
            case .failed(let message):
                raw = message; error = message; recovery = .init(kind: .executionFailure)
            }
            var saved = currentTask
            saved.transcript = [
                ["role": "user", "content": task.text],
                ["role": "assistant", "tool_calls": [["id": callID, "type": "function", "function": ["name": "mijia", "arguments": arguments]]]],
                ["role": "tool", "tool_call_id": callID, "content": raw],
                ["role": "assistant", "content": content ?? error ?? "查询未完成。"]
            ]
            try? TaskStore.save(saved)
            completion(Outcome(content: content, usage: .zero, error: error, pages: [], rounds: 0,
                               drifted: false, needsInput: needsInput, recovery: recovery))
        }
        return true
    }
}
