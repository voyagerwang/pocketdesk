/**
 * [INPUT]: 依赖真实 Runtime/Actions、临时规则文件与中键边沿；注入权限/健康/前台、异步准备、接收框回执和内存事件投递器。
 * [OUTPUT]: 验证租约与健康回执均绑定唯一当前设备 registry，旧连接迟到回执即使新鲜或已断到单设备也不接管；缺失/同型号其他序列号/身份歧义拒绝，验证按住/释放、迟到准备、scope、旧代际及接收框双击，兼容观察者不消费键盘 Option。
 * [POS]: tests 的默认有线语义路由回归；不启计时器/监听器、不读取真实桌面、不写正式租约、不录音、不发真实按键。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit

private final class NativeRouteHarness {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let signal = HeadsetSignal(kind: .hid, device: "13058:4827:isolated-native", name: "test", vendor: 13058, product: 4827, usage: 0xCD)
    var store: HeadsetRuleStore!
    var actions: HeadsetMappingActions!
    var runtime: HeadsetMappingRuntime!
    var ready = true, allowed = true
    var focus: pid_t? = 123
    var bundle = "app-A"
    var editor = AXUIElementCreateApplication(123)
    var receiver: HeadsetVoiceReceiver?
    var preparations: [(Bool) -> Void] = []
    var keys: [Bool] = []
    var ends = 0, cancels = 0
    var sends: [HeadsetVoiceReceiver] = []
    init() {
        store = HeadsetRuleStore(file: folder.appendingPathComponent("rules.json"))
        actions = HeadsetMappingActions(emitter: HeadsetKeyEmitter { [unowned self] event in keys.append(event.flags.contains(.maskAlternate)) })
        actions.environmentAllows = { [unowned self] in allowed }
        actions.foregroundPID = { [unowned self] in focus }
        actions.voiceKeysAvailable = { true }
        actions.voiceLog = { _ in }
        actions.normalVoiceText = { "" }
        actions.prepareNormalVoice = { [unowned self] completion in receiver = nil; preparations.append(completion) }
        actions.cancelNormalVoice = { [unowned self] in cancels += 1; receiver = nil }
        actions.normalOptionPosted = { }
        actions.endNormalVoice = { [unowned self] in ends += 1 }
        runtime = HeadsetMappingRuntime(volumeRules: store, actions: actions, performVolumeRule: { _ in fatalError("Unexpected volume route") })
        runtime.nativeRouteAllows = { [unowned self] in allowed }
        runtime.nativeSourceReady = { [unowned self] _ in ready }
        runtime.nativePaired = { $0.vendor == 13058 && $0.product == 4827 }
        runtime.nativeForeground = { [unowned self] in focus }
        runtime.nativeApplicationBundle = { [unowned self] in bundle }
        runtime.nativePreparedReceiver = { [unowned self] in receiver }
        runtime.nativeDoubleRelease = { [unowned self] in sends.append($0) }
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
    @discardableResult func down(_ time: Double, registry: UInt64? = nil) -> Bool { runtime.handleNativeCenter(signal, down: true, now: time, registry: registry) }
    @discardableResult func up(_ time: Double, registry: UInt64? = nil) -> Bool { runtime.handleNativeCenter(signal, down: false, now: time, registry: registry) }
    func prepare(index: Int = 0) {
        receiver = focus.map { HeadsetVoiceReceiver(pid: $0, element: editor) }
        preparations.remove(at: index)(true)
    }
    func completedPress(_ time: Double) { down(time); prepare(); up(time + 0.1) }
}

@main struct HeadsetNativeRouteTests {
    static func main() throws {
        leaseBindsCurrentDevice()
        let h = NativeRouteHarness()
        assert(h.down(0) && h.down(0.01) && h.preparations.count == 1 && h.keys.isEmpty)
        h.prepare(); assert(h.keys == [true])
        h.up(1); h.up(1.1)
        assert(h.keys == [true, false] && h.ends == 1, "持有与松开只执行一次，准备先于 Option")

        let early = NativeRouteHarness(); early.down(0); early.up(0.1); early.prepare()
        assert(early.keys.isEmpty && !early.actions.busy && early.ends == 0, "准备前松开不回补录音或迟到按键")

        let unready = NativeRouteHarness(); unready.ready = false; unready.down(0)
        assert(unready.preparations.isEmpty && unready.runtime.effectiveHIDSources(devices: [unready.signal]).isEmpty)
        var scoped = HeadsetRule(signal: unready.signal, gesture: .click, action: .disabled); scoped.scope = "app-B"
        try unready.store.save(scoped); unready.bundle = "app-B"; unready.ready = true
        unready.up(0.2)
        assert(unready.runtime.effectiveHIDSources(devices: [unready.signal]).count == 1,
               "未接管按住后切到自定义 scope，松开仍清来源排除，租约可恢复")
        assert(!unready.down(1), "当前 app 自定义操作优先，不重复执行默认语音")
        unready.bundle = "app-A"; unready.down(2); unready.prepare(); unready.up(3)
        assert(unready.keys == [true, false], "其他 app 的 scope 不破坏默认按住说/松开结束")

        let changed = NativeRouteHarness(); changed.down(0); changed.focus = 456
        changed.runtime.tickNativeCenters(); changed.prepare(); changed.up(1)
        assert(changed.keys.isEmpty && !changed.actions.busy, "前台变化取消迟到准备")
        let removed = NativeRouteHarness(); removed.down(0); removed.runtime.disconnectNativeDevice(removed.signal.device); removed.prepare()
        assert(removed.keys.isEmpty && !removed.actions.busy, "拔插取消迟到准备")
        let interrupted = NativeRouteHarness(); interrupted.down(0); interrupted.prepare(); interrupted.ready = false
        interrupted.runtime.tickNativeCenters(); interrupted.up(1)
        assert(interrupted.keys == [true, false] && interrupted.ends == 0, "健康失效释放所属按键并取消会话")

        let registry = NativeRouteHarness(); registry.down(0, registry: 22); registry.prepare()
        registry.runtime.disconnectNativeDevice(registry.signal.device, registry: 11)
        registry.up(0.1, registry: 11)
        assert(registry.actions.busy && registry.keys == [true], "旧连接的拔插/松开不能结束新连接")
        registry.up(1, registry: 22); assert(registry.keys == [true, false])

        let old = NativeRouteHarness(); old.down(0); old.prepare(); old.actions.cancel()
        old.actions.begin(HeadsetMappingRuntime.nativeCenterRule(old.signal)); old.prepare()
        old.up(0.1)
        assert(old.actions.busy && old.keys == [true, false, true] && old.sends.isEmpty,
               "同规则新代际不受旧松开影响")
        old.runtime.disconnectNativeDevice(old.signal.device)
        assert(old.actions.busy, "旧路由清理不反向取消同规则新代际")
        old.actions.finish()
        let oldCleanup = NativeRouteHarness(); oldCleanup.down(0); oldCleanup.prepare(); oldCleanup.actions.cancel()
        oldCleanup.actions.begin(HeadsetMappingRuntime.nativeCenterRule(oldCleanup.signal)); oldCleanup.prepare()
        oldCleanup.ready = false; oldCleanup.runtime.tickNativeCenters()
        assert(oldCleanup.actions.busy && oldCleanup.keys == [true, false, true], "旧连接健康失效不能取消同规则新代际")
        oldCleanup.actions.finish()

        let same = NativeRouteHarness(); same.completedPress(0); same.completedPress(0.2)
        assert(same.sends.count == 1 && same.sends[0].pid == 123, "同 app 同准备回执的真双击保留")
        let app = NativeRouteHarness(); app.completedPress(0); app.focus = 456; app.editor = AXUIElementCreateApplication(456); app.completedPress(0.2)
        assert(app.sends.isEmpty, "跨 app 两次按压不能合成双击发送")
        let editor = NativeRouteHarness(); editor.completedPress(0); editor.editor = AXUIElementCreateApplication(456); editor.completedPress(0.2)
        assert(editor.sends.isEmpty, "同 app 不同输入框不能继承双击发送回执")
        let manual = NativeRouteHarness(); manual.completedPress(0); manual.runtime.cancelNativeTapSequence(); manual.completedPress(0.2)
        assert(manual.sends.isEmpty, "手动操作清除待双击序列")
        let notPrepared = NativeRouteHarness(); notPrepared.down(0); notPrepared.up(0.1)
        notPrepared.down(0.2); notPrepared.prepare(index: 1); notPrepared.up(0.3); notPrepared.prepare()
        assert(notPrepared.sends.isEmpty, "首按未完成准备没有发送回执，两次快按不得发送正文")

        var attachment = HeadsetMappingRuntime.SourceAttachments()
        assert(!attachment.covers(healthTimestamp: 10, registry: 101))
        attachment.attach(registry: 101, at: 10)
        assert(!attachment.covers(healthTimestamp: 9.99, registry: 101) && attachment.covers(healthTimestamp: 10, registry: 101))
        attachment.detach(registry: 101); attachment.attach(registry: 202, at: 11)
        assert(!attachment.covers(healthTimestamp: 10.9, registry: 202) && attachment.covers(healthTimestamp: 11, registry: 202),
               "同 identity 新 registry 不复用旧健康回执")
        assert(!attachment.covers(healthTimestamp: 100, registry: 101), "101 的迟到新鲜回执不能确认当前202")
        attachment.attach(registry: 303, at: 12)
        assert(!attachment.covers(healthTimestamp: 100, registry: 202) && !attachment.covers(healthTimestamp: 100, registry: 303),
               "同身份多个 registry 时即使 helper 对旧租约产生新鲜回执也拒绝放行")
        attachment.detach(registry: 303)
        assert(!attachment.covers(healthTimestamp: 100, registry: 303) && !attachment.covers(healthTimestamp: 100, registry: 101),
               "断开到唯一202后仍不接受其他连接的晚回执")
        assert(!attachment.covers(healthTimestamp: 10.99, registry: 202) && attachment.covers(healthTimestamp: 100, registry: 202),
               "仅当前202的正确新鲜回执可以放行")
        assert(!attachment.covers(healthTimestamp: 100, registry: 0))
        healthReceiptRequiresRegistry(signal: h.signal)

        assert(HeadsetMappingRuntime.canLeaseHID(listening: true, cancellation: true, trusted: true, inputGranted: true, locked: false, detecting: false))
        for unavailable in 0..<6 {
            assert(!HeadsetMappingRuntime.canLeaseHID(listening: unavailable != 0, cancellation: unavailable != 1,
                trusted: unavailable != 2, inputGranted: unavailable != 3, locked: unavailable == 4, detecting: unavailable == 5))
        }
        assert(HeadsetCenterObserver.shouldObserve(h.signal, paired: true, semanticActive: false))
        assert(!HeadsetCenterObserver.shouldObserve(h.signal, paired: true, semanticActive: true))
        var keyboardOption = h.signal; keyboardOption.page = 7; keyboardOption.usage = 0xE2
        assert(!h.runtime.handleNativeCenter(keyboardOption, down: true) && !HeadsetCenterObserver.shouldObserve(keyboardOption, paired: true, semanticActive: false),
               "真实键盘 Option 不参与有线中键接管")
        assert(HeadsetCenterObserver.shouldDeliver(observedPID: 123, currentPID: 123, semanticActive: false, sameAttachment: true))
        assert(!HeadsetCenterObserver.shouldDeliver(observedPID: 123, currentPID: 456, semanticActive: false, sameAttachment: true))
        assert(!HeadsetCenterObserver.shouldDeliver(observedPID: 123, currentPID: 123, semanticActive: true, sameAttachment: true))
        assert(!HeadsetCenterObserver.shouldDeliver(observedPID: 123, currentPID: 123, semanticActive: false, sameAttachment: false))
        assert(!HeadsetCenterObserver.shouldDeliver(observedPID: 123, currentPID: 123, semanticActive: false, sameAttachment: true, sameSequence: false),
               "新的原生首按使迟到双击回调失效，不借用新 cycle 的输入框")
        print("PASS native headset route: unique current registry lease binding, prepared hold/release, lease/scope/attachment gates, late callback and owner generation isolation, bound receiver double, passive handoff, keyboard Option exclusion; no desktop input")
    }
    static func leaseBindsCurrentDevice() {
        let signal = HeadsetSignal(kind: .hid, device: "13058:4827:serial-A", name: "test", vendor: 13058, product: 4827, usage: 0xCD)
        var other = signal; other.device = "13058:4827:serial-B"
        let source = HeadsetMappingRuntime.operationLeaseSource(signal, attachments: [(signal, 101), (other, 202)])!
        assert(source["registryID"] as? UInt64 == 101 && source["device"] as? String == signal.device,
               "同型号设备保留各自序列号与连接 registry，不能借用其他设备")
        let roundTrip = try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: source)) as! [String: Any]
        assert((roundTrip["registryID"] as? NSNumber)?.uint64Value == 101, "registry 随原租约 JSON 交给 helper")
        assert(HeadsetMappingRuntime.operationLeaseSource(signal, attachments: [(other, 202)]) == nil,
               "已断开规则不借同型号设备续租")
        assert(HeadsetMappingRuntime.operationLeaseSource(signal, attachments: [(signal, 0)]) == nil,
               "未知 registry 不发布接管来源")
        assert(HeadsetMappingRuntime.operationLeaseSource(signal, attachments: [(signal, 101), (signal, 0)]) == nil,
               "同身份的另一连接无法核验时也不猜测")
        assert(HeadsetMappingRuntime.operationLeaseSource(signal, attachments: [(signal, 101), (signal, 202)]) == nil,
               "多个连接具有相同配置身份时拒绝猜测")
        let reconnected = HeadsetMappingRuntime.operationLeaseSource(signal, attachments: [(signal, 303)])!
        assert(reconnected["registryID"] as? UInt64 == 303, "重插只租约本轮 registry，旧连接不能复用")
        var volume = signal; volume.kind = .volume
        assert(HeadsetMappingRuntime.operationLeaseSource(volume, attachments: [(volume, 101)]) == nil)
    }
    static func healthReceiptRequiresRegistry(signal: HeadsetSignal) {
        let legacy: [String: Any] = ["time": 100.0, "sources": [signal.identity]]
        assert(HeadsetMappingRuntime.operationHealthReceipt(legacy, for: signal, now: 101) == nil,
               "旧 helper 未回读 registry 时保持原生回退")
        var health = legacy; health["registries"] = [signal.identity: NSNumber(value: 202)]
        let encoded = try! JSONSerialization.data(withJSONObject: health)
        let decoded = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        assert(HeadsetMappingRuntime.operationHealthReceipt(decoded, for: signal, now: 101)?.registry == 202,
               "接收 helper JSON 的原 identity 与已核验 registry")
        assert(HeadsetMappingRuntime.operationHealthReceipt(decoded, for: signal, now: 103) == nil)
        health["registries"] = [signal.identity: 0]
        assert(HeadsetMappingRuntime.operationHealthReceipt(health, for: signal, now: 101) == nil)
        health["registries"] = ["other-identity": 202]
        assert(HeadsetMappingRuntime.operationHealthReceipt(health, for: signal, now: 101) == nil)
    }
}
