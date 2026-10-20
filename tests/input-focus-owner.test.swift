/**
 * [INPUT]: InputFocus 的纯应用归属解析器与 AgentTaskComposer.NavigationFocus；AX 状态、PID、权限、安全输入和时钟均由值替身注入。
 * [OUTPUT]: 验证明确 AX 归属优先、缺值的交叉补证与所有反证拒绝；验证 Codex 导航消费同一补证 PID，确认后失焦不恢复等待。
 * [POS]: 共享输入门禁的隔离回归；不调用运行时归属读取、不访问真实 AX/UI、不激活应用或发送任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

@main struct InputFocusOwnerTests {
    static func main() {
        let target: pid_t = 39320, other: pid_t = 39321
        var checks = 0
        func resolve(_ status: AXError, axPID: pid_t? = nil, active: [pid_t] = [39320],
                     immediate: pid_t? = 39320, trusted: Bool = true, secure: Bool = false,
                     uiStatus: AXError = .noValue, uiOwner: pid_t? = nil) -> InputFocus.ApplicationOwner {
            InputFocus.resolveApplicationOwner(axStatus: status, axPID: axPID, activePIDs: active,
                immediatePID: immediate, trusted: trusted, secureInput: secure,
                systemUIStatus: uiStatus, systemUIOwner: uiOwner)
        }
        func expect(_ result: InputFocus.ApplicationOwner, pid: pid_t?,
                    source: InputFocus.ApplicationOwner.Source, status: AXError, _ message: String) {
            assert(result.pid == pid && result.source == source && result.axStatus == status, message)
            checks += 1
        }
        func reject(_ result: InputFocus.ApplicationOwner, status: AXError, _ message: String) {
            expect(result, pid: nil, source: .unavailable, status: status, message)
        }

        // --- 明确 AX 归属优先，畸形成功不得向缓存借权 ---
        expect(resolve(.success, axPID: other, uiStatus: .success, uiOwner: target),
               pid: other, source: .accessibility, status: .success, "明确其他 AX 归属不能被一致的活动应用证据覆盖")
        expect(resolve(.success, axPID: target, active: [other, target], immediate: nil,
                       trusted: false, secure: true, uiStatus: .failure),
               pid: target, source: .accessibility, status: .success, "明确 AX 事实独立于补证条件，环境授权仍由调用方门禁决定")
        for invalidPID in [nil, 0, -1] as [pid_t?] {
            reject(resolve(.success, axPID: invalidPID, uiStatus: .success, uiOwner: target),
                   status: .success, "成功但没有有效 AX PID 时拒绝，不把缓存当作成功返回")
        }

        // --- 缺值补证须同时匹配活动缓存、即时进程与可读系统控件 ---
        for status in [AXError.noValue, .cannotComplete] {
            expect(resolve(status), pid: target, source: .activeApplication, status: status,
                   "应用和控件均实际缺值时，两份独立进程证据可补证")
            expect(resolve(status, uiStatus: .cannotComplete), pid: target, source: .activeApplication,
                   status: status, "系统控件暂不可读不产生反证")
            expect(resolve(status, uiStatus: .success, uiOwner: target), pid: target, source: .activeApplication,
                   status: status, "可读系统控件同属目标时补证成立")
            reject(resolve(status, active: [other]), status: status, "活动缓存与即时进程冲突时拒绝")
            reject(resolve(status, immediate: other), status: status, "即时进程已切走时，旧活动缓存不能放行")
            reject(resolve(status, immediate: nil), status: status, "Carbon 缺 PID 时不能只用缓存")
            for active in [[], [target, other], [target, target], [0], [-1]] as [[pid_t]] {
                reject(resolve(status, active: active), status: status, "没有唯一有效活动应用时拒绝")
            }
            for invalidPID in [nil, 0, -1, other] as [pid_t?] {
                reject(resolve(status, uiStatus: .success, uiOwner: invalidPID), status: status,
                       "系统明确返回焦点控件但归属不符或不可解析时拒绝")
            }
            for hardError in [AXError.apiDisabled, .attributeUnsupported, .invalidUIElement, .illegalArgument, .failure] {
                reject(resolve(status, uiStatus: hardError), status: status, "系统控件硬错误不能伪装成实际缺值")
            }
            reject(resolve(status, trusted: false), status: status, "无辅助功能授权不能补证")
            reject(resolve(status, secure: true), status: status, "安全输入开启不能补证")
        }
        for hardError in [AXError.apiDisabled, .attributeUnsupported, .invalidUIElement, .illegalArgument, .failure] {
            reject(resolve(hardError, axPID: target, uiStatus: .success, uiOwner: target), status: hardError,
                   "应用归属硬错误不能被其他看似一致的证据覆盖")
        }

        // --- Codex 导航与后续门禁消费同一归属，不在 AX 长期缺值时反复拒绝 ---
        var navigation = AgentTaskComposer.NavigationFocus(deadline: 101)
        let unavailable = resolve(.noValue, immediate: nil)
        assert(navigation.observe(expectedPID: target, focusedPID: unavailable.pid, authorized: true,
                                  environmentAllowed: true, now: 100) == .waiting)
        let supplemented = resolve(.noValue, uiStatus: .success, uiOwner: target)
        assert(navigation.observe(expectedPID: target, focusedPID: supplemented.pid, authorized: true,
                                  environmentAllowed: true, now: 100.05) == .ready)
        assert(navigation.confirmed)
        let stillSupplemented = resolve(.cannotComplete)
        assert(navigation.observe(expectedPID: target, focusedPID: stillSupplemented.pid, authorized: true,
                                  environmentAllowed: true, now: 102) == .ready,
               "已有共同归属证据后不再依赖导航等待期")
        let contradicted = resolve(.noValue, uiStatus: .success, uiOwner: other)
        assert(navigation.observe(expectedPID: target, focusedPID: contradicted.pid, authorized: true,
                                  environmentAllowed: true, now: 102.05) == .stopped,
               "确认后的交叉反证立即停止，不恢复首次未知等待")
        var switched = AgentTaskComposer.NavigationFocus(deadline: 101)
        let explicitOther = resolve(.success, axPID: other)
        assert(switched.observe(expectedPID: target, focusedPID: explicitOther.pid, authorized: true,
                                environmentAllowed: true, now: 100) == .stopped)
        var denied = AgentTaskComposer.NavigationFocus(deadline: 101)
        assert(denied.observe(expectedPID: target, focusedPID: supplemented.pid, authorized: false,
                              environmentAllowed: true, now: 100) == .stopped,
               "补证成立仍不能越过本轮控制授权")
        var blocked = AgentTaskComposer.NavigationFocus(deadline: 101)
        assert(blocked.observe(expectedPID: target, focusedPID: supplemented.pid, authorized: true,
                               environmentAllowed: false, now: 100) == .stopped,
               "补证成立仍不能越过环境门禁")
        checks += 8
        print("PASS shared input application owner and Codex navigation: \(checks) checks")
    }
}
