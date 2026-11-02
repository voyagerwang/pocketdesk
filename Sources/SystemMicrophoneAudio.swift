/**
 * [INPUT]: AVAudioEngine 默认输入设备、AVAudioConverter 与系统麦克风授权状态；样本率统一到 EasyInputAudioWire.sampleRate。
 * [OUTPUT]: 16 kHz 单声道 Float32 样本块（主线程回调）、授权/启动失败原因与只读诊断；不写文件、不上传、不改系统输入设置。
 * [POS]: 键盘未连接时的兜底收音源，只供 DesktopVoice 装配；不占用键盘 BLE 会话，不声称能替代键盘的全部能力。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import AVFoundation

final class SystemMicrophoneAudio {
    var onSamples: (([Float]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let engine = AVAudioEngine()
    private var running = false
    private var starting = false
    private var asked = false
    private var blocks = 0
    private var startedAt: TimeInterval = 0
    private(set) var phase = "idle"
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 兜底源只要没在收音，就不该让状态栏说“正在用电脑麦克风”。
    var diagnostics: [String: Any] {
        ["phase": phase, "running": running, "blocks": blocks,
         "authorization": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
         "seconds": running ? now - startedAt : 0]
    }

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    func start() {
        guard !running, !starting else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            // 只问一次；用户拒绝后不再反复弹窗，状态里明确说去哪儿开。
            guard !asked else { phase = "denied"; onFailure?("麦克风未授权，键盘连回来后会自动用键盘收音。"); return }
            asked = true; starting = true; phase = "asking"
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.starting = false
                    if granted { self.begin() }
                    else { self.phase = "denied"; self.onFailure?("麦克风未授权，键盘连回来后会自动用键盘收音。") }
                }
            }
        default:
            phase = "denied"
            onFailure?("系统没有允许 PocketDesk 使用麦克风，请在隐私设置里打开。")
        }
    }

    private func begin() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: EasyInputAudioWire.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else {
            phase = "unavailable"; onFailure?("没有可用的电脑麦克风，键盘连回来后会自动用键盘收音。"); return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer, target: target, converter: converter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            phase = "failed"; onFailure?("电脑麦克风启动失败，键盘连回来后会自动用键盘收音。"); return
        }
        running = true; startedAt = now; phase = "capturing"; onStatus?("正在用电脑麦克风收音")
    }

    private func consume(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat, converter: AVAudioConverter) {
        guard running, buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var failure: NSError?
        converter.convert(to: out, error: &failure) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard failure == nil, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let block = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        blocks += 1
        // 采集回调在音频线程上；协调层只认主线程状态，样本统一回到主线程。
        DispatchQueue.main.async { [weak self] in self?.onSamples?(block) }
    }

    func stop() {
        guard running || starting else { return }
        if running {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        running = false; phase = "stopped"
    }
}
