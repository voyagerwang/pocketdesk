/**
 * [INPUT]: Foundation Gregorian Calendar。
 * [OUTPUT]: RFC 3339 日期有效性与精确时区、小数秒换算。
 * [POS]: Sources 的纯协议日期解析，被 CapabilityProtocol 消费。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

// MARK: - RFC 3339 date-time（与 TS 校验器同口径：带时区、真实日历日期、分秒越界拒绝）

enum RFC3339 {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#)

    static func isValidDateTime(_ raw: String) -> Bool { rfc3339Date(raw) != nil }

    /// 解析为 Date；拒绝不带时区的字符串、不存在的日历日期（2026-02-30 类）、时区/分秒越界。
    static func rfc3339Date(_ raw: String) -> Date? {
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = pattern.firstMatch(in: raw, range: range) else { return nil }
        func group(_ i: Int) -> Int { Int((raw as NSString).substring(with: match.range(at: i))) ?? -1 }
        let year = group(1), month = group(2), day = group(3)
        let hour = group(4), minute = group(5), second = group(6)
        let timeZonePart = (raw as NSString).substring(with: match.range(at: 8))
        guard (1...12).contains(month), (1...daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var offset = 0
        if timeZonePart != "Z" {
            let hours = Int(timeZonePart.dropFirst().prefix(2)) ?? -1
            let minutes = Int(timeZonePart.suffix(2)) ?? -1
            guard (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
            offset = (timeZonePart.hasPrefix("-") ? -1 : 1) * (hours * 3600 + minutes * 60)
        }
        let fractionRange = match.range(at: 7)
        let fraction = fractionRange.location == NSNotFound ? 0 :
            (Double((raw as NSString).substring(with: fractionRange)) ?? 0)
        guard let base = calendar.date(from: components) else { return nil }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }
}
