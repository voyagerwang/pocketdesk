/**
 * [INPUT]: 工具参数里的相对分钟或 HH:mm，以及音箱通道写下的私有 control.json（回环端口与 token）。
 * [OUTPUT]: 到点时刻换算、本地口语描述与回环端点读取；缺文件、非法时刻、越界一律抛出，不猜。
 * [POS]: wake_alarm 的时间与服务定位口径；不依赖 AgentRunner，可独立回归。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum WakeAlarmPlan {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Control {
        let port: Int
        let token: String
    }

    /// 音箱通道服务写下的回环端口与 token；文件缺失说明服务没在跑，绝不能假装已经定好闹钟。
    /// 变量而非常量：回归测试要把它指到不存在的路径，绝不能打到真实音箱上。
    static var controlURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VoiceDeck/xiaoai/control.json")

    /// 只接受“几分钟后”或“HH:mm”两种说法；自然语言与越界值返回 nil，由调用方如实拒绝。
    static func due(_ values: [String: Any], now: Date = Date()) -> Date? {
        if let minutes = values["minutes"] as? Int, minutes > 0 {
            return now.addingTimeInterval(TimeInterval(minutes * 60))
        }
        guard let text = values["at"] as? String else { return nil }
        let parts = text.split(separator: ":").map { String($0) }
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              parts[0].count <= 2, parts[1].count == 2,
              hour >= 0, hour < 24, minute >= 0, minute < 60 else { return nil }
        return Calendar.current.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute),
                                         matchingPolicy: .nextTime)
    }

    /// 本地口语描述：同一天只说几点几分，一小时内的补一句还差多久。
    static func describe(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        let calendar = Calendar.current
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "M月d日 HH:mm"
        let text = formatter.string(from: date)
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0, seconds < 3600 else { return text }
        return "\(text)（约 \(max(1, seconds / 60)) 分钟后）"
    }

    static func endpoint() throws -> Control {
        guard let data = try? Data(contentsOf: controlURL),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = values["port"] as? Int, port > 0, port < 65536,
              let token = values["token"] as? String, token.count >= 32 else {
            throw Failure(message: "音箱通道服务没在运行，先把音箱语音入口启动再定闹钟。")
        }
        return Control(port: port, token: token)
    }
}
