/**
 * [INPUT]: 依赖 CGSession 会话字典、DistributedNotificationCenter 的锁屏/解锁通知；不依赖 LockScreenInput（独立单一状态源）。
 * [OUTPUT]: 对外提供 LockStateMonitor（locked/unlocked/unknown 单一状态源、锁屏代际 epoch、通知促发的失效缓存）与 LockStateProviding 协议。
 * [POS]: Sources 的快捷解锁锁屏事实适配器；UnlockCoordinator 消费它，UnlockRelayClient 广播它。与 LockScreenInput.state 并存但语义更保守——那是旧端点的直读，这里是封装适配器。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

protocol LockStateProviding {
    /// locked / unlocked / unknown。unknown 永远不降级为 unlocked。
    var state: String { get }
    /// 锁屏代际：任何锁/解锁事件、通知触发的怀疑都推进它；挑战记录绑定它，代际变化即作废。
    var epoch: UInt64 { get }
    /// 当前会话用户 ID（kCGSSessionUserIDKey）；拿不到返回 nil，授权核验时按不匹配处理。
    var sessionUserID: Int64? { get }
}

/// 保守的锁屏状态适配器。
///
/// 实测（G0，macOS 26.6.2）：解锁态下 `CGSSessionScreenIsLocked` 键**缺失**而非 false；
/// locked 判定只能取"键存在且为 true"。unlocked 需要字典完整且 loginDone == true 才确认；
/// 字典拿不到、键值形态异常、或 15 秒内收到过锁屏通知而字典尚未翻面，一律 unknown。
/// 分布式通知不是稳定公开契约：只用于"立即失效缓存、促发重查"，不单独作为状态依据。
final class LockStateMonitor: LockStateProviding {
    static let shared = LockStateMonitor()
    private let mutex = NSLock()
    private var cachedState: String?
    private var cachedAt: TimeInterval = 0
    private var lastSuspicion = -Double.infinity
    private var _epoch: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    /// 缓存寿命：与工单建议一致（心跳 5 秒、15 秒无有效状态视为过期），集中定义。
    static let cacheTTL: TimeInterval = 5
    static let stalenessLimit: TimeInterval = 15

    var epoch: UInt64 {
        mutex.lock(); defer { mutex.unlock() }
        return _epoch
    }

    init() {
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name), object: nil, queue: nil) { [weak self] _ in
                self?.bump(reason: "notification")
            })
        }
    }
    deinit { observers.forEach { DistributedNotificationCenter.default().removeObserver($0) } }

    /// 任何"状态可能变了"的信号都走这里：推进代际（作废进行中的挑战记录）并清缓存。
    func bump(reason: String) {
        mutex.lock()
        _epoch &+= 1
        cachedState = nil
        lastSuspicion = ProcessInfo.processInfo.systemUptime
        mutex.unlock()
    }

    var sessionUserID: Int64? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        if let v = dict["kCGSSessionUserIDKey"] as? Int64 { return v }
        if let v = dict["kCGSSessionUserIDKey"] as? Int { return Int64(v) }
        if let v = dict["kCGSSessionUserIDKey"] as? Int32 { return Int64(v) }
        return nil
    }

    var state: String {
        mutex.lock(); defer { mutex.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        // 锁屏通知刚到（缓存已清）：短时间内字典可能还没翻面，重复查询只会在 unknown 上抖动，
        // 直接给 unknown，等下一次查询窗口。
        if now - lastSuspicion < 1.0 && now - cachedAt > 0 { return cachedState ?? "unknown" }
        if let cached = cachedState, now - cachedAt < Self.cacheTTL { return cached }
        let fresh = Self.readState()
        if fresh != "unknown" || cachedState == nil || now - cachedAt >= Self.stalenessLimit {
            cachedState = fresh
            cachedAt = now
        }
        return cachedState ?? fresh
    }

    /// 直读会话字典。规则见类注释：字段缺失不能解释为 unlocked 的唯一依据，
    /// 必须有 loginDone == true 兜底；其余形态一律 unknown。
    static func readState() -> String {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return "unknown" }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
            return locked ? "locked" : (dict["kCGSessionLoginDoneKey"] as? Bool == true ? "unlocked" : "unknown")
        }
        // 键缺失：解锁态的正常形态，但必须 loginDone 确认这是已登录会话才认。
        return dict["kCGSessionLoginDoneKey"] as? Bool == true ? "unlocked" : "unknown"
    }
}
