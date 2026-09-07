/**
 * [INPUT]: 依赖 Foundation 的 Date/DateFormatter/NSLock、AppKit 的 NSWorkspace、CoreGraphics 的 CGWindowList。
 * [OUTPUT]: 对外提供 ExecutionOutcome（结果分级）、ExecutionFeedback（执行回执）、ExecutionRecord（日志条目）、
 *           ExecutionLog（线程安全环形日志）、EnvironmentGate（执行前门禁）。
 * [POS]: Sources 的可观测性层；InputExecutor 产出回执、Server 写进响应体与 /api/status、控制台据此展示「最近动作」。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import CoreGraphics
import Foundation

// 执行结果分级。分的就是两件此前被混为一谈的事：「发出去了」和「生效了」。
// CGEvent 是单向投递：post 成功只代表进了 HID 事件流，目标应用是否消费无从得知（微信不响应合成 Cmd+W
// 却照样返回成功，就是这条鸿沟）。故只有能观察到预期状态变化时才允许标 delivered，其余按键注入一律 sent。
enum ExecutionOutcome: String {
    case delivered  // 已确认生效：执行前后观察到预期状态变化（窗口关了 / 前台换了 / 进程退了）
    case sent       // 已发出但无法确认：普通按键注入的天花板，不代表生效
    case blocked    // 前置条件不满足，压根没执行（已锁屏、未授权）
    case failed     // 执行了但出错（命令返回非 0、AX 拒绝）

    // 控制台与手机端共用的短标签。
    var badge: String {
        switch self {
        case .delivered: return "已生效"
        case .sent: return "已发出"
        case .blocked: return "未执行"
        case .failed: return "失败"
        }
    }
}

// 执行回执：成功路径也要带结论，不能再只回一个 ok。
struct ExecutionFeedback {
    let outcome: ExecutionOutcome
    let detail: String

    static func delivered(_ detail: String) -> ExecutionFeedback { .init(outcome: .delivered, detail: detail) }
    static func sent(_ detail: String) -> ExecutionFeedback { .init(outcome: .sent, detail: detail) }
}

// 一条执行记录。留 frontApp 是因为绝大多数「没生效」最后都归结为「当时前台根本不是你以为的那个应用」。
struct ExecutionRecord {
    let time: Date
    let kind: String            // shortcut / send / activate
    let label: String           // 「关闭窗口」「发到 微信」
    let outcome: ExecutionOutcome
    let detail: String
    let frontApp: String?

    var dictionary: [String: Any] {
        var item: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: time),
            "kind": kind,
            "label": label,
            "outcome": outcome.rawValue,
            "outcomeLabel": outcome.badge,
            "detail": detail,
        ]
        if let frontApp { item["frontApp"] = frontApp }
        return item
    }
}

// 进程内环形日志。只保留最近若干条——这是给「刚才那一下到底怎么了」事后排查用的，不是审计系统。
final class ExecutionLog {
    static let shared = ExecutionLog()
    private let lock = NSLock()
    private let capacity = 40
    private var records: [ExecutionRecord] = []

    func append(kind: String, label: String, outcome: ExecutionOutcome, detail: String, frontApp: String? = nil) {
        let record = ExecutionRecord(time: Date(), kind: kind, label: label,
                                     outcome: outcome, detail: detail, frontApp: frontApp)
        lock.lock()
        records.append(record)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        lock.unlock()
    }

    // 最新的在前：控制台从上往下读，最近的异常要在首屏可见。
    func recent(_ limit: Int = 30) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return records.suffix(limit).reversed().map { $0.dictionary }
    }
}

// 执行前门禁：先问环境同不同意，不同意就别浪费一次注入，也别给用户一个假装成功的回执。
// 注意"宁松不宁紧"：用过的两种锁屏判据（CGWindowList layer≥1000 的 loginwindow、CGSessionScreenIsLocked）
// 在 macOS 15 实测都不准——loginwindow 高 layer 窗口常驻存在会让前者永远命中；后者即便屏幕明显未锁也报 1。
// 误拦比漏报更糟：操作全部废掉，用户连"没反应"的日志都看不到。锁屏场景改由事后验证（无状态变化 → sent）
// + 日志中「前台是 loginwindow」的提示承担，不在入口拦截。
enum EnvironmentGate {
    // 辅助功能授权是公共 API（AXIsProcessTrusted），可信。没有它连 CGEvent 都发不出去。
    static func blockReason() -> String? {
        if !AXIsProcessTrusted() { return "尚未授予「辅助功能」权限，无法向电脑注入操作。请在控制台完成授权。" }
        return nil
    }
}
