/**
 * [INPUT]: CoreBluetooth、精确EasyInput绑定与EasyInputAudioWire会话协议；仅连接配置服务及音频特征。
 * [OUTPUT]: 有界收音会话、去重PCM、链路状态回调与只读固件能力诊断；断线按退避自动重连，只在固件/权限不可救时放弃。只读0003过滤版本/布尔能力，不暴露配置正文，禁止固件/键位/Wi-Fi配置写入。
 * [POS]: DesktopVoice的首选收音源；持有独立临时会话，停止释放自有订阅，不解除系统键盘配对。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreFoundation
import CoreBluetooth

final class EasyInputAudio: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "7d2f4d10-6f6b-4a2d-8b01-6d4653320001")
    static let audioIDs = [CBUUID(string: "7d2f4d10-6f6b-4a2d-8b01-6d4653320005"), CBUUID(string: "7d2f4d10-6f6b-4a2d-8b01-6d4653320006")]
    /// 只读探测的候选特征（配套应用里出现过的 0002–000d），不写入。
    static let probeIDs = (2...13).map { CBUUID(string: String(format: "7d2f4d10-6f6b-4a2d-8b01-6d465332%04x", $0)) }
    var onSamples: (([Float]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onBinding: ((UUID) throws -> Void)?
    /// 只在放弃时调用；可自愈的断开由重连自己处理，不再一次断线就停掉整条监听。
    var onFailure: ((String) -> Void)?
    /// 链路事实：音频订阅确认或收到首个有效包为 true，进入重试为 false。
    var onLink: ((Bool) -> Void)?
    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var audio: CBCharacteristic?
    private var binding: UUID?
    private var candidates: [UUID: CBPeripheral] = [:]
    private var timer: Timer?
    private var session: UInt64 = 0
    private var sequence: UInt32 = 0
    private var packets = EasyInputAudioWire.SequenceGate()
    private var connectedAt: TimeInterval = 0
    private var lastPacket: TimeInterval = 0
    private var lastKeepalive: TimeInterval = 0
    private var healthy = false
    private var started = false
    private var active = false
    private var phase = "idle"
    private var enumerating = false
    private var lastFailurePhase = ""
    private var packetsReceived = 0
    private var attempt = 0
    private var nextAttemptAt = TimeInterval.infinity
    /// 退避：1、2、4、8 秒后固定 15 秒，插回键盘最迟一刻钟内自动接回。
    static func retryDelay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(15, pow(2, Double(min(attempt, 5) - 1)))
    }
    var deviceCapabilities: [String: Bool] { deviceStatus["capabilities"] as? [String: Bool] ?? [:] }
    var deviceFirmware: String { deviceStatus["firmware"] as? String ?? "" }
    var linkDescription: String { active ? phase : "stopped" }
    private func record(_ service: CBService) {
        let characteristics = (service.characteristics ?? []).map { characteristic -> [String: Any] in
            var flags: [String] = []
            let property = characteristic.properties
            if property.contains(.read) { flags.append("read") }
            if property.contains(.write) { flags.append("write") }
            if property.contains(.writeWithoutResponse) { flags.append("writeNoResponse") }
            if property.contains(.notify) { flags.append("notify") }
            if property.contains(.indicate) { flags.append("indicate") }
            return ["uuid": characteristic.uuid.uuidString, "flags": flags]
        }
        gatt.removeAll { ($0["service"] as? String) == service.uuid.uuidString }
        gatt.append(["service": service.uuid.uuidString, "characteristics": characteristics])
    }
    /// 只读诊断：已发现的服务/特征清单（供核对扬声器通道是否存在），不含音频正文。
    private var gatt: [[String: Any]] = []
    private var deviceStatus: [String: Any] = [:]
    static func safeDeviceStatus(_ data: Data) -> [String: Any] {
        guard data.count <= 4096, let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var result: [String: Any] = [:]
        if let version = value["firmware"] as? String, version.count <= 80,
           version.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_+ ")).contains($0) }) {
            result["firmware"] = version
        }
        if let capabilities = value["capabilities"] as? [String: Any] {
            let allowed = ["speaker_playback", "speaker_stream", "speaker_assets", "speaker_assets_v1", "ble_audio", "host_action_v1"]
            var filtered: [String: Bool] = [:]
            for key in allowed {
                if let number = capabilities[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                    filtered[key] = number.boolValue
                }
            }
            result["capabilities"] = filtered
        }
        return result
    }
    var diagnostics: [String: Any] { ["phase": phase, "lastFailurePhase": lastFailurePhase, "authorization": CBManager.authorization.rawValue, "managerState": manager?.state.rawValue ?? -1, "candidates": candidates.count, "packets": packetsReceived, "gatt": gatt, "deviceStatus": deviceStatus, "attempt": attempt, "retryIn": nextAttemptAt.isFinite ? max(0, nextAttemptAt - now) : -1] }
    private var scanDeadline: TimeInterval?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func start(binding: UUID?) {
        stop(); active = true; self.binding = binding; attempt = 0; session = UInt64.random(in: 1...UInt64.max)
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }; RunLoop.main.add(timer!, forMode: .common)
        beginAttempt()
    }
    func stop() {
        active = false; phase = "stopped"; nextAttemptAt = .infinity
        timer?.invalidate(); timer = nil
        releaseAttempt()
    }
    /// 只结束这一轮尝试，保留 active 与定时器，让退避后的下一次尝试接得上。
    private func releaseAttempt() {
        if let peripheral, let control, started, peripheral.state == .connected,
           let data = EasyInputAudioWire.control(action: 2, session: session, sequence: sequence &+ 1) {
            peripheral.writeValue(data, for: control, type: .withResponse)
        }
        if let peripheral {
            if let audio, peripheral.state == .connected { peripheral.setNotifyValue(false, for: audio) }
            peripheral.delegate = nil
            manager?.cancelPeripheralConnection(peripheral)
        }
        manager?.stopScan(); manager?.delegate = nil; manager = nil; peripheral = nil
        audio = nil; control = nil; started = false; healthy = false; lastPacket = 0
        packets = .init(); candidates = [:]; scanDeadline = nil; enumerating = false
        nextAttemptAt = .infinity
    }
    private func beginAttempt() {
        releaseAttempt()
        connectedAt = now; phase = "waitingBluetooth"; lastFailurePhase = ""; packetsReceived = 0
        gatt = []; deviceStatus = [:]
        if attempt == 0 { onStatus?("正在连接 EasyInput") }
        manager = CBCentralManager(delegate: self, queue: .main)
    }
    private func fail(_ message: String) { let failedPhase = phase; stop(); lastFailurePhase = failedPhase; phase = "failed:" + failedPhase; onLink?(false); onFailure?(message) }
    /// 可自愈的断开：不当成终态，按退避重来；键盘插回来就能自己接上。
    private func retry(_ message: String) {
        let failedPhase = phase
        lastFailurePhase = failedPhase; phase = "retrying:" + failedPhase
        releaseAttempt(); attempt += 1
        let delay = Self.retryDelay(attempt: attempt)
        nextAttemptAt = now + delay
        onLink?(false)
        onStatus?(message + "，正在重新连接")
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === manager, active else { return }
        guard central.state == .poweredOn else {
            if central.state == .unauthorized { fail("请允许 PocketDesk 使用蓝牙。") }
            else if central.state == .poweredOff { retry("请打开蓝牙") }
            return
        }
        phase = "findingDevice"
        let known = central.retrieveConnectedPeripherals(withServices: [Self.service])
        for p in known where matches(p) { candidates[p.identifier] = p }
        if candidates.count == 1 { connect() }
        else if candidates.count > 1 { fail("找到多个 EasyInput，请只连接要使用的那一只后重试。") }
        else {
            phase = "scanning"; scanDeadline = now + 5
            central.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }
    private func matches(_ p: CBPeripheral) -> Bool {
        binding.map { p.identifier == $0 } ?? (p.name == "EasyInput AI")
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === manager, active, matches(p), peripheral == nil else { return }
        candidates[p.identifier] = p
    }
    private func connect() {
        guard active, candidates.count == 1, let p = candidates.values.first else { retry("EasyInput 未连接"); return }
        phase = "connecting"; manager?.stopScan(); scanDeadline = nil; peripheral = p; p.delegate = self
        manager?.connect(p, options: nil)
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard central === manager, active, p === peripheral else { return }
        phase = "discoveringServices"; p.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard central === manager, p === peripheral else { return }; retry("EasyInput 连接失败")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard central === manager, active, p === peripheral else { return }; retry("EasyInput 已断开")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral, active else { return }
        guard error == nil, let all = p.services else { retry("EasyInput 音频服务不可用"); return }
        // 收音跑起来之后再挂一次全量发现，只为了看清这只键盘上还有哪些通道（含扬声器下行）。
        if enumerating {
            for service in all {
                record(service)
                // 厂商服务在本连接里只发现过 0005/0006；用候选表补问其余通道，看看有没有扬声器下行。
                if service.uuid == Self.service { p.discoverCharacteristics(Self.probeIDs, for: service) }
                else if service.characteristics == nil { p.discoverCharacteristics(nil, for: service) }
            }
            return
        }
        let services = all.filter { $0.uuid == Self.service }
        guard services.count == 1 else { retry("EasyInput 音频服务不可用"); return }
        phase = "discoveringAudio"; p.discoverCharacteristics(Self.audioIDs, for: services[0])
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral, active else { return }
        if enumerating {
            record(service)
            if error == nil, service.uuid == Self.service,
               let status = service.characteristics?.first(where: { $0.uuid == Self.probeIDs[1] && $0.properties.contains(.read) }) {
                p.readValue(for: status)
            }
            return
        }
        guard service.uuid == Self.service else { return }
        let chars = service.characteristics?.filter { Self.audioIDs.contains($0.uuid) } ?? []
        let notifications = chars.filter { $0.properties.contains(.notify) }
        let writes = chars.filter { $0.properties.contains(.write) }
        guard error == nil, notifications.count == 1, writes.count == 1, notifications[0].uuid != writes[0].uuid else { fail("键盘固件未提供兼容的蓝牙音频通道。"); return }
        audio = notifications[0]; control = writes[0]
        do { try onBinding?(p.identifier) } catch { fail("设备绑定保存失败，未启动收音。"); return }
        phase = "subscribing"; p.setNotifyValue(true, for: notifications[0])
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, active, c === audio else { return }
        guard error == nil, c.isNotifying else { retry("EasyInput 音频订阅失败"); return }
        phase = "startingAudio"; started = true; connectedAt = now; attempt = 0; onLink?(true); send(action: 1)
        enumerating = true; p.discoverServices(nil)
    }
    private func send(action: UInt8) {
        guard let peripheral, let control else { return }
        sequence &+= 1
        if let data = EasyInputAudioWire.control(action: action, session: session, sequence: sequence) {
            peripheral.writeValue(data, for: control, type: .withResponse); lastKeepalive = now
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p === peripheral, active, c === control, error != nil else { return }; retry("EasyInput 音频控制未确认")
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if p === peripheral, active, c.uuid == Self.probeIDs[1] {
            if error == nil, let data = c.value { deviceStatus = Self.safeDeviceStatus(data) }
            return
        }
        guard p === peripheral, active, c === audio else { return }
        guard error == nil else { retry("EasyInput 音频接收中断"); return }
        guard let data = c.value, let frame = EasyInputAudioWire.decode(data, session: session), packets.accept(frame.sequence) else { return }
        packetsReceived += 1; phase = "receiving"; lastPacket = now; attempt = 0
        if frame.samples.contains(where: { abs($0) > 0.0001 }) { healthy = true }
        onSamples?(frame.samples)
    }
    private func tick() {
        guard active else { return }
        if manager == nil, now >= nextAttemptAt { beginAttempt(); return }
        if let deadline = scanDeadline, now >= deadline { connect(); return }
        if !started, now - connectedAt > 15 { retry("EasyInput 连接超时"); return }
        if started {
            if !healthy, now - connectedAt > 8 { retry("未收到 EasyInput 麦克风声音"); return }
            if healthy, now - lastPacket > 4 { retry("EasyInput 音频已中断"); return }
            if now - lastKeepalive >= 2 { send(action: 3) }
        }
    }
}
