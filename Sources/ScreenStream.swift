/**
 * [INPUT]: ScreenCaptureKit、会话代际诊断、CoreImage 编码与订阅生命周期。
 * [OUTPUT]: 带会话/捕获代际的 JPEG、帧状态与 NSError 分类；锁屏不复活 idle 旧图，故障最多重建两次。
 * [POS]: 持续采集边界；不保存画面、不提权，最后观看者退出即停止。
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
        let captureEpoch: UInt64
        let captureState: String
        let captureGeneration: UInt64
        let backend: String
    }
    var onFrame: ((Frame) -> Void)?
    var onFailure: (([String: Any]) -> Void)?
    var onStatus: (([String: Any]) -> Void)?
    private var stream: SCStream?
    private let samples = DispatchQueue(label: "dev.voicedeck.capture")
    private let encoder = DispatchQueue(label: "dev.voicedeck.jpeg")
    private let lock = NSLock()
    private var latest: (CMSampleBuffer, ScreenCaptureContext, UInt64)?
    private var encoding = false
    private var stopped = false
    private var restartScheduled = false
    private var monitor: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var captureContext = ScreenCaptureContext(epoch: 0, state: "unknown")
    private var epochBeganAt = 0.0
    private var displayID: UInt32 = 0
    private var requestedWidth = 1280
    private var dimensions = (0, 0)
    private var badFramesSince: Double?
    private var badFrameStatus: Int?
    private var recovery = ScreenCaptureRecoveryBudget()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var last: Frame?
    private var lastEmit = 0.0

    func start(displayID: UInt32, width: Int) async throws {
        self.displayID = displayID; requestedWidth = width
        setInitialContext()
        installMonitor()
        do { try await build() }
        catch { samples.async { [weak self] in self?.recover(stage: "stream-start", error: error) } }
    }
    private func setInitialContext() {
        lock.lock(); captureContext = ScreenCaptureDiagnostics.shared.context(); epochBeganAt = Self.now(); lock.unlock()
    }
    private static func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
    private func build() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCapture.Failure.permission }
        let requestedContext = ScreenCaptureDiagnostics.shared.context()
        let content = try await ScreenCaptureDeadline.run(seconds: 2.5, key: "sck-enumeration") {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ScreenCapture.Failure.missingDisplay }
        let config = SCStreamConfiguration()
        let factor = min(1, Double(requestedWidth) / Double(display.width))
        config.width = max(1, Int(Double(display.width) * factor)); config.height = max(1, Int(Double(display.height) * factor))
        config.showsCursor = false; config.queueDepth = 3; config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: samples)
        guard ScreenCaptureDiagnostics.shared.isCurrent(requestedContext) else { return }
        guard install(capture, dimensions: (config.width, config.height)) else { return }
        try await ScreenCaptureDeadline.run(seconds: 2.5, key: "sck-stream-start-\(displayID)") {
            try await capture.startCapture()
            if Task.isCancelled { try? await capture.stopCapture(); throw CancellationError() }
        }
        if !isCurrent(capture) { try? await capture.stopCapture() }
    }
    private func install(_ capture: SCStream, dimensions: (Int, Int)) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        stream = capture; self.dimensions = dimensions; generation &+= 1; latest = nil
        return true
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func isCurrent(_ capture: SCStream) -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped && stream === capture }
    private func installMonitor() {
        let timer = DispatchSource.makeTimerSource(queue: samples)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.checkSession() }
        lock.lock(); monitor = timer; lock.unlock(); timer.resume()
    }
    private func checkSession() {
        guard !isStopped else { return }
        let fresh = ScreenCaptureDiagnostics.shared.context()
        lock.lock()
        let changed = captureContext != fresh
        if changed { captureContext = fresh; epochBeganAt = Self.now(); latest = nil }
        lock.unlock()
        guard changed else {
            if let since = badFramesSince, let status = badFrameStatus, Self.now() - since >= 1 {
                recover(stage: "stream-" + Self.statusName(status), error: NSError(domain: "PocketDesk.ScreenCapture.FrameStatus", code: status))
            }
            return
        }
        badFramesSince = nil; badFrameStatus = nil
        encoder.async { [weak self] in self?.last = nil; self?.lastEmit = 0 }
        var event = ScreenCaptureDiagnostics.shared.event(stage: "session-transition", display: displayID, backend: "sck")
        event["invalidate"] = true; onStatus?(event)
        recover(stage: "session-transition", error: nil)
    }
    func stop() {
        lock.lock(); stopped = true; latest = nil; let capture = stream; stream = nil; let timer = monitor; monitor = nil; lock.unlock()
        timer?.cancel()
        encoder.async { [weak self] in self?.last = nil }
        if let capture { Task { try? await capture.stopCapture() } }
    }
    private func recover(stage: String, error: Error?) {
        lock.lock()
        guard !stopped, !restartScheduled else { lock.unlock(); return }
        restartScheduled = true; latest = nil; let old = stream; stream = nil; let currentGeneration = generation
        lock.unlock()
        badFramesSince = nil; badFrameStatus = nil
        encoder.async { [weak self] in self?.last = nil; self?.lastEmit = 0 }
        let retry = stage == "session-transition" ? true : recovery.retry()
        var event = ScreenCaptureDiagnostics.shared.event(stage: stage, display: displayID, backend: "sck", error: error,
            recovering: retry, terminal: !retry, generation: currentGeneration)
        event["invalidate"] = true
        if let old { Task { try? await old.stopCapture() } }
        if retry { onStatus?(event) }
        else { onFailure?(event); return }
        samples.asyncAfter(deadline: .now() + 0.5 * Double(max(1, recovery.attempts))) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.lock.lock(); self.restartScheduled = false; self.lock.unlock()
            Task {
                do { try await self.build() }
                catch { self.samples.async { self.recover(stage: "stream-rebuild", error: error) } }
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        samples.async { [weak self] in
            guard let self, self.isCurrent(stream) else { return }; self.recover(stage: "stream-stopped", error: error)
        }
    }
    private static func statusName(_ raw: Int) -> String {
        switch SCFrameStatus(rawValue: raw) {
        case .complete: return "complete"
        case .idle: return "idle"
        case .blank: return "blank"
        case .suspended: return "suspended"
        case .started: return "started"
        case .stopped: return "stopped"
        default: return "unknown-\(raw)"
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, isCurrent(stream),
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int else { return }
        checkSession()
        guard isCurrent(stream) else { return }
        lock.lock(); let capturedContext = captureContext, currentGeneration = generation, began = epochBeganAt; lock.unlock()
        let now = Self.now()
        ScreenCaptureDiagnostics.shared.event(stage: "stream-frame", display: displayID, backend: "sck", status: Self.statusName(status), generation: currentGeneration)
        if status == SCFrameStatus.idle.rawValue {
            // 锁屏或未知会话不使用 idle 更新旧图时钟；必须等新的 complete 像素。
            guard capturedContext.state == "unlocked" else { return }
            encoder.async { [weak self] in
                guard let self, !self.isStopped, ScreenCaptureDiagnostics.shared.isCurrent(capturedContext),
                    let last = self.last, last.captureEpoch == capturedContext.epoch,
                    last.captureGeneration == currentGeneration, now - self.lastEmit > 0.8 else { return }
                self.lastEmit = now
                self.onFrame?(Frame(jpeg: last.jpeg, captured: now, width: last.width, height: last.height,
                    captureEpoch: last.captureEpoch, captureState: last.captureState, captureGeneration: currentGeneration, backend: "sck-idle"))
            }
            return
        }
        guard status == SCFrameStatus.complete.rawValue else {
            if status == SCFrameStatus.blank.rawValue || status == SCFrameStatus.suspended.rawValue || status == SCFrameStatus.stopped.rawValue {
                badFramesSince = badFramesSince ?? now
                badFrameStatus = status
                if now - (badFramesSince ?? now) >= 1.0 {
                    recover(stage: "stream-" + Self.statusName(status), error: NSError(domain: "PocketDesk.ScreenCapture.FrameStatus", code: status))
                }
            }
            return
        }
        let captured = CMTimeGetSeconds(buffer.presentationTimeStamp)
        guard captured.isFinite, captured >= began else { return }
        badFramesSince = nil; badFrameStatus = nil
        lock.lock(); latest = (buffer, capturedContext, currentGeneration)
        let shouldStart = !encoding; encoding = true; lock.unlock()
        if shouldStart { encoder.async { [weak self] in self?.encodeLatest() } }
    }
    private func encodeLatest() {
        while true {
            lock.lock()
            guard !stopped, let sample = latest else { encoding = false; lock.unlock(); return }
            latest = nil; let size = dimensions, currentGeneration = generation; lock.unlock()
            autoreleasepool {
                guard sample.2 == currentGeneration, ScreenCaptureDiagnostics.shared.isCurrent(sample.1), let pixel = sample.0.imageBuffer else { return }
                let image = CIImage(cvPixelBuffer: pixel)
                if ScreenCapturePixels.isBlack(pixel) {
                    samples.async { [weak self] in
                        guard let self else { return }
                        ScreenCaptureDiagnostics.shared.event(stage: "stream-frame", display: self.displayID, backend: "sck", status: "black", generation: sample.2)
                        self.recover(stage: "stream-black", error: NSError(domain: "PocketDesk.ScreenCapture", code: 3))
                    }
                    return
                }
                guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.75]),
                    ScreenCaptureDiagnostics.shared.isCurrent(sample.1) else { return }
                lock.lock(); let valid = !stopped && generation == sample.2; lock.unlock()
                guard valid else { return }
                let frame = Frame(jpeg: jpeg, captured: CMTimeGetSeconds(sample.0.presentationTimeStamp), width: size.0, height: size.1,
                    captureEpoch: sample.1.epoch, captureState: sample.1.state, captureGeneration: sample.2, backend: "sck")
                last = frame; lastEmit = frame.captured
                samples.async { [weak self] in self?.recovery.completed() }
                onFrame?(frame)
            }
        }
    }
}
