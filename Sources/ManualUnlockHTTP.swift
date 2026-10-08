/**
 * [INPUT]: HTTPS/token 路由闭包、当前控制租约、LockStateProviding 与锁屏专用输入执行器。
 * [OUTPUT]: 一次性手动密码挑战与提交回执；绑定会话/用户/锁屏代际/期限，逐键撤销，未知结果不重放。
 * [POS]: 手动解锁 HTTP 适配边界；密码只在当前请求执行期间使用，不读写钥匙串、不记录或持久化。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

protocol ManualUnlockInputExecuting {
    func prepare(session: String, authorized: @escaping () -> Bool, deadline: TimeInterval) -> [String: Any]
    func submit(password: String, id: String, session: String, authorized: @escaping () -> Bool,
                deadline: TimeInterval, targetConfirmed: Bool, completion: @escaping ([String: Any]) -> Void)
}
extension LockScreenInput: ManualUnlockInputExecuting {}

final class ManualUnlockHTTP {
    typealias Reply = (Int, [String: Any]) -> Void
    private struct Challenge {
        let session: String
        let epoch: UInt64
        let user: Int64
        let expires: TimeInterval
    }
    private final class Attempt {
        let session: String
        let context: Challenge
        let deadline: TimeInterval
        let reply: Reply
        private let mutex = NSLock()
        private var finished = false
        private var invoked = false
        init(session: String, context: Challenge, deadline: TimeInterval, reply: @escaping Reply) {
            self.session = session; self.context = context; self.deadline = deadline; self.reply = reply
        }
        var live: Bool { mutex.lock(); defer { mutex.unlock() }; return !finished }
        var mayHaveInput: Bool { mutex.lock(); defer { mutex.unlock() }; return invoked }
        func beginInput() { mutex.lock(); invoked = true; mutex.unlock() }
        func claimFinish() -> Bool {
            mutex.lock(); defer { mutex.unlock() }
            guard !finished else { return false }; finished = true; return true
        }
    }
    private let state: LockStateProviding
    private let executor: ManualUnlockInputExecuting
    private let clock: () -> TimeInterval
    private let budget: TimeInterval
    private let challengeTTL: TimeInterval
    private let mutex = NSLock()
    private let queue = DispatchQueue(label: "PocketDesk.manualUnlock.input")
    private var pending: [String: Challenge] = [:]
    private var active: Attempt?
    private var rateWindow: TimeInterval = 0
    private var calls = 0
    var onBeforeInput: (() -> Void)?
    var onUnlocked: (() -> Void)?

    init(lockState: LockStateProviding = LockStateMonitor.shared,
         executor: ManualUnlockInputExecuting = LockScreenInput.shared,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         budget: TimeInterval = 10, challengeTTL: TimeInterval = 30) {
        self.state = lockState; self.executor = executor; self.clock = clock
        self.budget = max(0.01, min(budget, 10)); self.challengeTTL = max(0.01, min(challengeTTL, 30))
    }

    /// 上层必须先验证 token；authorized 必须绑定 JSON session 与当前控制租约，不能只验证 token。
    @discardableResult
    func handle(method: String, path: String, body: Data, secure: Bool,
                authorized: @escaping () -> Bool, connected: @escaping () -> Bool,
                completion: @escaping Reply) -> Bool {
        guard path == "/api/manual-unlock/challenge" || path == "/api/manual-unlock/submit" else { return false }
        func reject(_ status: Int, _ error: String, _ detail: String) {
            completion(status, ["outcome": "failed", "error": error, "detail": detail])
        }
        guard method == "POST" else { reject(405, "method-not-allowed", "请使用专用提交入口。"); return true }
        guard secure else { reject(403, "https-required", "手动密码只允许通过 HTTPS 提交。"); return true }
        guard body.count <= 8192,
              let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let session = json["session"] as? String, !session.isEmpty, session.utf8.count <= 128 else {
            reject(400, "invalid-request", "请求格式无效。"); return true
        }
        guard connected(), authorized() else { reject(403, "unauthorized", "当前控制会话已失效。"); return true }
        let now = clock()
        mutex.lock()
        if now - rateWindow >= 60 || calls == 0 { rateWindow = now; calls = 0 }
        calls += 1
        let throttled = calls > 60
        mutex.unlock()
        guard !throttled else { reject(429, "rate-limited", "操作过于频繁，请稍后再试。"); return true }

        if path.hasSuffix("/challenge") {
            guard state.state == "locked", let user = state.sessionUserID else {
                reject(409, "not-locked-or-unknown", "无法确认当前用户处于锁屏状态，本次未输入。"); return true
            }
            let record = Challenge(session: session, epoch: state.epoch, user: user, expires: now + challengeTTL)
            mutex.lock()
            pending = pending.filter { $0.value.expires > now && $0.value.session != session }
            guard active == nil, pending.count < 64 else {
                mutex.unlock(); reject(409, "busy", "另一项解锁仍在处理，请等待回执。"); return true
            }
            let id = UUID().uuidString
            pending[id] = record
            mutex.unlock()
            completion(200, ["id": id, "expiresIn": challengeTTL, "state": "locked"])
            return true
        }

        guard let id = json["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let password = json["password"] as? String, !password.isEmpty, password.utf16.count <= 256,
              json["screenConfirmed"] as? Bool == true else {
            reject(400, "invalid-request", "请确认画面显示当前账户密码框，再明确提交一次。"); return true
        }
        mutex.lock()
        // 先消费，任何后续失败（包括会话不匹配、超时和未知结果）均不能复用这次提交。
        let record = pending.removeValue(forKey: id)
        guard active == nil, let record, record.session == session, record.expires > now else {
            mutex.unlock(); reject(409, "challenge-invalid", "本次请求已失效，请重新确认锁屏画面。"); return true
        }
        let attempt = Attempt(session: session, context: record, deadline: now + budget, reply: completion)
        active = attempt
        mutex.unlock()
        let lease = { [weak self, weak attempt] () -> Bool in
            guard let self, let attempt else { return false }
            return attempt.live && self.clock() < attempt.deadline && connected() && authorized()
                && self.state.sessionUserID == record.user && self.state.epoch == record.epoch
                && self.state.state == "locked"
        }
        // 独立截止回执。执行器仍通过 lease 检查同一截止；迟到回调不能再发键或再回一次。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + budget) { [weak self, weak attempt] in
            guard let self, let attempt else { return }
            self.finish(attempt, outcome: attempt.mayHaveInput ? "unconfirmed" : "failed",
                        error: "deadline", detail: "本次操作已到期限；未确认结果时不会自动重试。")
        }
        queue.async { [self] in
            guard lease() else {
                finish(attempt, outcome: "failed", error: "context-changed", detail: "锁屏、用户或控制授权已变化，本次未输入。"); return
            }
            onBeforeInput?()
            guard lease() else {
                finish(attempt, outcome: "failed", error: "context-changed", detail: "控制授权已变化，本次未输入。"); return
            }
            let prepared = executor.prepare(session: session, authorized: lease, deadline: attempt.deadline)
            guard let inputID = prepared["challenge"] as? String, lease() else {
                finish(attempt, outcome: "failed", error: "prepare-rejected",
                       detail: prepared["error"] as? String ?? "输入准备未通过，本次未输入。"); return
            }
            attempt.beginInput()
            executor.submit(password: password, id: inputID, session: session, authorized: lease,
                            deadline: attempt.deadline, targetConfirmed: true) { [weak self] result in
                guard let self, attempt.live else { return }
                self.queue.async {
                    guard result["sent"] as? Bool == true else {
                        self.finish(attempt, outcome: result["inputStarted"] as? Bool == false ? "failed" : "unconfirmed",
                                    error: "input-stopped", detail: result["error"] as? String ?? "输入未完成；请检查画面，不会自动重试。"); return
                    }
                    // 提交后允许锁屏 epoch 因成功解锁而变化，但会话用户与控制租约仍必须有效。
                    while attempt.live && self.clock() < attempt.deadline {
                        guard connected(), authorized(), self.state.sessionUserID == record.user else {
                            self.finish(attempt, outcome: "unconfirmed", error: "context-changed", detail: "提交后控制或用户状态变化，结果未确认；不会自动重试。"); return
                        }
                        let observed = self.state.state
                        if observed == "unlocked" {
                            self.finish(attempt, outcome: "unlocked", detail: "当前用户会话已解锁。"); return
                        }
                        // 解锁通知与会话字典之间可能暂时 unknown；此段只观察、不再输入，
                        // 等待到截止或同用户明确 unlocked，绝不把 unknown 降级成成功。
                        if observed == "locked" && self.state.epoch != record.epoch {
                            self.finish(attempt, outcome: "unconfirmed", error: "state-changed", detail: "已提交但系统状态无法确认；不会自动重试。"); return
                        }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    self.finish(attempt, outcome: "unconfirmed", error: "deadline", detail: "已提交但未确认解锁；请检查画面，不会自动重试。")
                }
            }
        }
        return true
    }

    /// 断线、撤销或控制会话替换时可主动调用；逐键 lease 也独立阻止迟到输入。
    func cancel(session: String? = nil) {
        mutex.lock()
        pending = pending.filter { session != nil && $0.value.session != session }
        let attempt = active.flatMap { session == nil || $0.session == session ? $0 : nil }
        mutex.unlock()
        if let attempt {
            finish(attempt, outcome: attempt.mayHaveInput ? "unconfirmed" : "failed",
                   error: "cancelled", detail: "控制连接已撤销，已停止；不会自动重试。")
        }
    }

    private func finish(_ attempt: Attempt, outcome: String, error: String? = nil, detail: String) {
        guard attempt.claimFinish() else { return }
        mutex.lock(); if active === attempt { active = nil }; mutex.unlock()
        if outcome == "unlocked" { onUnlocked?() }
        var result: [String: Any] = ["outcome": outcome, "detail": detail]
        if let error { result["error"] = error }
        attempt.reply(200, result)
    }
}
