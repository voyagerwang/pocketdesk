/**
 * [INPUT]: Foundation、现有会话状态适配器与捕获器的非像素事件。
 * [OUTPUT]: 共享捕获代际、帧状态计数、NSError domain/code 与进程会话诊断；不保存画面、网络凭据或输入。
 * [POS]: 画面采集的只读诊断及有界恢复策略；系统状态不等于画面内容已验证。
 */
import Foundation
import AppKit
import CoreImage
import CoreVideo

enum ScreenCapturePixels {
    /// 只统计已知 RGB 字节布局，未知格式保留给正常编码，不借助可能失败的 GPU 渲染推断黑图。
    static func isBlack(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 8, [24, 32].contains(image.bitsPerPixel),
            let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let step = image.bitsPerPixel / 8
        var skip: Int?
        if step == 4 {
            let first = [CGImageAlphaInfo.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo)
            let last = [CGImageAlphaInfo.last, .premultipliedLast, .noneSkipLast].contains(image.alphaInfo)
            let little = image.bitmapInfo.contains(.byteOrder32Little)
            if first { skip = little ? 3 : 0 }; if last { skip = little ? 0 : 3 }
        }
        guard CFDataGetLength(data) >= image.bytesPerRow * image.height else { return false }
        return black(bytes, width: image.width, height: image.height, rowBytes: image.bytesPerRow, step: step, skip: skip)
    }
    static func isBlack(_ pixel: CVPixelBuffer) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixel)
        let skip: Int
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA: skip = 3
        case kCVPixelFormatType_32ARGB: skip = 0
        default: return false
        }
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { return false }
        return black(base.assumingMemoryBound(to: UInt8.self), width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel),
            rowBytes: CVPixelBufferGetBytesPerRow(pixel), step: 4, skip: skip)
    }
    private static func black(_ bytes: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int, step: Int, skip: Int?) -> Bool {
        for y in 0..<height { for x in 0..<width {
            for channel in 0..<step where channel != skip {
                if bytes[y * rowBytes + x * step + channel] != 0 { return false }
            }
        } }
        return true
    }
}

struct ScreenCaptureContext: Equatable {
    let epoch: UInt64
    let state: String
}

final class ScreenCaptureDiagnostics: @unchecked Sendable {
    static let shared = ScreenCaptureDiagnostics()
    private let mutex = NSLock()
    private let stateProvider: () -> String
    private var state = "unknown"
    private var epoch: UInt64 = 1
    private var statuses: [String: Int] = [:]
    private var lastEvent: [String: Any] = [:]
    private var recentErrors: [[String: Any]] = []
    private var observers: [NSObjectProtocol] = []

    init(stateProvider: @escaping () -> String = { LockScreenInput.state }, observe: Bool = true) {
        self.stateProvider = stateProvider
        if observe {
            for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
                observers.append(DistributedNotificationCenter.default().addObserver(
                    forName: NSNotification.Name(name), object: nil, queue: nil) { [weak self] _ in
                        self?.invalidate()
                    })
            }
        }
    }
    deinit { observers.forEach { DistributedNotificationCenter.default().removeObserver($0) } }

    func context() -> ScreenCaptureContext {
        let fresh = stateProvider()
        mutex.lock(); defer { mutex.unlock() }
        if fresh != state { epoch &+= 1; state = fresh }
        return ScreenCaptureContext(epoch: epoch, state: state)
    }
    func invalidate() { mutex.lock(); epoch &+= 1; mutex.unlock() }
    func isCurrent(_ context: ScreenCaptureContext) -> Bool { self.context() == context }

    @discardableResult
    func event(stage: String, display: UInt32, backend: String, error: Error? = nil,
               status: String? = nil, recovering: Bool = false, terminal: Bool = false,
               generation: UInt64 = 0) -> [String: Any] {
        let context = self.context()
        var event: [String: Any] = ["captureEpoch": context.epoch, "captureState": context.state,
            "state": context.state, "stage": stage, "display": display, "backend": backend,
            "at": Date().timeIntervalSince1970, "recovering": recovering, "terminal": terminal,
            "contentVerified": false, "captureGeneration": generation]
        if let error {
            let native = error as NSError
            event["domain"] = native.domain; event["code"] = native.code
            // 不转发可能含文件路径/用户信息的任意 userInfo。
            event["message"] = "电脑端画面采集未完成，请查看采集诊断。"
        }
        if let status { event["frameStatus"] = status }
        mutex.lock()
        if let status { statuses[status, default: 0] += 1 }
        if error != nil { recentErrors.append(event); recentErrors = Array(recentErrors.suffix(8)) }
        lastEvent = event
        mutex.unlock()
        return event
    }
    func snapshot() -> [String: Any] {
        let context = self.context()
        mutex.lock(); let counts = statuses, event = lastEvent, errors = recentErrors; mutex.unlock()
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let onConsole: Any = (session?[kCGSessionOnConsoleKey as String] as? Bool).map { $0 as Any } ?? NSNull()
        return ["captureEpoch": context.epoch, "captureState": context.state,
            "frameStatuses": counts, "lastEvent": event, "recentErrors": errors, "pid": getpid(), "uid": getuid(),
            "processSession": getuid() == 0 ? "system" : "user-app",
            "onConsole": onConsole,
            "os": ProcessInfo.processInfo.operatingSystemVersionString, "contentVerified": false]
    }
}

/// 只允许连续两次重建；一帧真实 complete 成功后才能重置预算。
struct ScreenCaptureRecoveryBudget {
    private(set) var attempts = 0
    mutating func retry() -> Bool { guard attempts < 2 else { return false }; attempts += 1; return true }
    mutating func completed() { attempts = 0 }
}

enum ScreenCaptureDeadline {
    private static let inflightLock = NSLock()
    private static var inflight = Set<String>()
    private static func acquire(_ key: String) -> Bool {
        inflightLock.lock(); defer { inflightLock.unlock() }
        return inflight.insert(key).inserted
    }
    private static func release(_ key: String) { inflightLock.lock(); inflight.remove(key); inflightLock.unlock() }
    private final class Completion<Value>: @unchecked Sendable {
        let mutex = NSLock()
        var continuation: CheckedContinuation<Value, Error>?
        @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
            mutex.lock(); let continuation = self.continuation; self.continuation = nil; mutex.unlock()
            continuation?.resume(with: result)
            return continuation != nil
        }
    }
    // 不使用 TaskGroup：某些系统 API 不响应 cancel，group 退出仍会等它，导致 HTTP busy 永久占用。
    static func run<Value>(seconds: Double, key: String? = nil, operation: @escaping () async throws -> Value) async throws -> Value {
        if let key, !acquire(key) {
            throw NSError(domain: "PocketDesk.ScreenCapture", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "系统画面采集仍在等待，本次未新增任务。"])
        }
        return try await withCheckedThrowingContinuation { continuation in
            let completion = Completion<Value>(); completion.continuation = continuation
            let operationTask = Task {
                defer { if let key { release(key) } }
                do { completion.finish(.success(try await operation())) }
                catch { completion.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if completion.finish(.failure(NSError(domain: "PocketDesk.ScreenCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "电脑画面采集超时，已停止等待。"]))) { operationTask.cancel() }
            }
        }
    }
}
