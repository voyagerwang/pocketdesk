/**
 * [INPUT]: WakeAlarmPlan 的时刻换算/口语回执/端点读取；临时目录与不存在的控制文件。
 * [OUTPUT]: 验证相对分钟与 HH:mm 只落在未来、非法时刻不猜、跨天要说日期、控制文件缺失必须抛错。
 * [POS]: 到点叫醒的口径回归；不启动音箱通道、不连回环端口、不写正式配置目录。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct WakeAlarmPlanTests {
    static var checks = 0
    static var failures: [String] = []

    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures.append(label) }
    }

    static func main() {
        let now = Date()

        if let due = WakeAlarmPlan.due(["minutes": 5], now: now) {
            let seconds = due.timeIntervalSince(now)
            check(seconds > 290 && seconds < 310, "相对分钟按 5 分钟换算")
        } else {
            check(false, "五分钟后要能算出时刻")
        }
        check(WakeAlarmPlan.due(["minutes": 0], now: now) == nil, "零分钟不算定时")
        check(WakeAlarmPlan.due(["minutes": -3], now: now) == nil, "负分钟不算定时")

        if let due = WakeAlarmPlan.due(["at": "08:00"], now: now) {
            check(due > now, "当天已过的时刻顺延到下一次")
            let parts = Calendar.current.dateComponents([.hour, .minute], from: due)
            check(parts.hour == 8 && parts.minute == 0, "时刻保持 08:00")
            check(due.timeIntervalSince(now) <= 24 * 3600, "顺延不超过一天")
        } else {
            check(false, "HH:mm 要能解析")
        }
        check(WakeAlarmPlan.due(["at": "24:00"], now: now) == nil, "24:00 不是合法时刻")
        check(WakeAlarmPlan.due(["at": "8:5"], now: now) == nil, "缺位分钟不猜")
        check(WakeAlarmPlan.due(["at": "8点"], now: now) == nil, "自然语言时刻不在这里猜")
        check(WakeAlarmPlan.due([:], now: now) == nil, "没有时间参数就不定时")
        check(WakeAlarmPlan.due(["minutes": 5, "at": "08:00"], now: now) != nil, "两者都给时用相对分钟")

        check(WakeAlarmPlan.describe(now.addingTimeInterval(90), now: now).contains("分钟后"), "一小时内要说明还差多久")
        check(WakeAlarmPlan.describe(now.addingTimeInterval(3 * 3600), now: now).count > 0, "更远的定时给本地时刻")
        check(WakeAlarmPlan.describe(now.addingTimeInterval(26 * 3600), now: now).contains("月"), "跨天要说清哪一天")

        // 指到不存在的控制文件：回归不能打到真实音箱上。
        WakeAlarmPlan.controlURL = URL(fileURLWithPath: "/tmp/wake-alarm-missing-\(UUID().uuidString).json")
        do {
            _ = try WakeAlarmPlan.endpoint()
            check(false, "控制文件缺失时必须抛错")
        } catch is WakeAlarmPlan.Failure {
            check(true, "控制文件缺失时如实报服务未运行")
        } catch {
            check(false, "控制文件缺失时要给出可读原因")
        }

        print("wake-alarm checks: \(checks), failures: \(failures.count)")
        for failure in failures { print("FAIL: \(failure)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
