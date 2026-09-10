/**
 * [INPUT]: 依赖 ScreenCaptureKit 持续采样、CoreImage JPEG 编码及调用方的订阅生命周期。
 * [OUTPUT]: 提供 ScreenStream，保留最新待编码帧，回传带捕获时刻的 JPEG 或故障，以 30fps 为采集上限并丢弃积压旧帧。
 * [POS]: Sources 的持续画面采集边界；不持有网络连接、不落盘，最后观看者退出后停止。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import ScreenCaptureKit
import CoreImage

@available(macOS 14.0, *)
final class ScreenStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame {
        let jpeg: Data
        let captured: Double
        let width: Int
        let height: Int
    }
    var onFrame: ((Frame) -> Void)?
    var onFailure: ((String) -> Void)?
    private var stream: SCStream?
    private let samples = DispatchQueue(label: "dev.voicedeck.capture")
    private let encoder = DispatchQueue(label: "dev.voicedeck.jpeg")
    private let lock = NSLock()
    private var latest: CMSampleBuffer?
    private var idleQueued = false
    private var encoding = false
    private var stopped = false
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var last: Frame?
    private var lastEmit = 0.0
    private var dimensions = (0, 0)

    func start(displayID: UInt32, width: Int) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCapture.Failure.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenCapture.Failure.missingDisplay }
        let config = SCStreamConfiguration()
        let factor = min(1, Double(width) / Double(display.width))
        config.width = max(1, Int(Double(display.width) * factor))
        config.height = max(1, Int(Double(display.height) * factor))
        config.showsCursor = false; config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        dimensions = (config.width, config.height)
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: samples)
        install(capture)
        try await capture.startCapture()
        if isStopped { try? await capture.stopCapture() }
    }
    // stream/stopped/latest 的跨队列访问由 lock 保护；last/lastEmit 仅在 encoder 队列读写。
    private func install(_ capture: SCStream) { lock.lock(); stream = capture; lock.unlock() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() {
        lock.lock(); stopped = true; latest = nil; let capture = stream; lock.unlock()
        if let stream = capture { Task { try? await stream.stopCapture() } }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, !isStopped,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int else { return }
        let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        if status == SCFrameStatus.idle.rawValue {
            // 捕获器明确报告内容未变，才允许以新时刻确认静态画面；不凭网络心跳复活旧图。
            lock.lock()
            if idleQueued { lock.unlock(); return }
            idleQueued = true; lock.unlock()
            encoder.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.idleQueued = false; self.lock.unlock()
                guard !self.isStopped, let last = self.last, now - self.lastEmit > 0.8 else { return }
                self.lastEmit = now
                self.onFrame?(Frame(jpeg: last.jpeg, captured: now, width: last.width, height: last.height))
            }
            return
        }
        guard status == SCFrameStatus.complete.rawValue else { return }
        lock.lock(); latest = buffer
        let shouldStart = !encoding; encoding = true; lock.unlock()
        if shouldStart { encoder.async { [weak self] in self?.encodeLatest() } }
    }
    private func encodeLatest() {
        while true {
            lock.lock()
            guard !stopped, let sample = latest else { encoding = false; lock.unlock(); return }
            latest = nil; lock.unlock()
            autoreleasepool {
                guard let pixel = sample.imageBuffer else { return }
                let image = CIImage(cvPixelBuffer: pixel)
                guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.75]) else { return }
                let frame = Frame(jpeg: jpeg, captured: CMTimeGetSeconds(sample.presentationTimeStamp), width: dimensions.0, height: dimensions.1)
                last = frame; lastEmit = frame.captured; onFrame?(frame)
            }
        }
    }
}
