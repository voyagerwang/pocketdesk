/**
 * [INPUT]: ScreenCaptureKit、现有锁屏事实、ScreenCaptureDiagnostics 与锁屏限定的用户级备用截图。
 * [OUTPUT]: 提供有界显示器枚举、带代际/来源的 JPEG 单帧、只读诊断；迟到与跨会话结果丢弃。
 * [POS]: Sources 画面边界；备用截图仅有短期私有文件，用后回收，不宣称已验证锁屏内容。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import ScreenCaptureKit

final class ScreenCapture {
    struct Snapshot {
        let jpeg: Data
        let captureEpoch: UInt64
        let captureState: String
        let backend: String
    }
    enum Failure: LocalizedError {
        case unavailable, permission, missingDisplay, encoding
        var errorDescription: String? {
            switch self {
            case .unavailable: return "查看电脑需要 macOS 14 或更新版本。"
            case .permission: return "请在 Mac 系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 PocketDesk；必要时重启应用。"
            case .missingDisplay: return "显示器已断开，请收起后重新打开查看电脑。"
            case .encoding: return "画面编码失败，请重试。"
            }
        }
    }

    func requestPermission() {
        DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }
    }

    private func checkAccess() throws {
        guard #available(macOS 14.0, *) else { throw Failure.unavailable }
        guard CGPreflightScreenCaptureAccess() else { throw Failure.permission }
    }

    func displays() async throws -> [[String: Any]] {
        try checkAccess()
        let context = ScreenCaptureDiagnostics.shared.context()
        if context.state == "locked" {
            let native = ScreenCaptureFallback.displays()
            guard !native.isEmpty else { throw Failure.missingDisplay }
            guard ScreenCaptureDiagnostics.shared.isCurrent(context) else { throw stale() }
            return native.enumerated().map { index, display in
                ["id": display.id, "name": "显示器 \(index + 1) · \(display.width) × \(display.height)",
                    "width": display.width, "height": display.height]
            }
        }
        do {
            let content = try await ScreenCaptureDeadline.run(seconds: 2.5, key: "sck-enumeration") {
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            }
            guard ScreenCaptureDiagnostics.shared.isCurrent(context) else { throw stale() }
            return content.displays.sorted { $0.displayID < $1.displayID }.enumerated().map { index, display in
                // width/height 与 CGEvent 全局坐标同为逻辑点。
                ["id": display.displayID, "name": "显示器 \(index + 1) · \(display.width) × \(display.height)",
                 "width": display.width, "height": display.height]
            }
        } catch {
            ScreenCaptureDiagnostics.shared.event(stage: "display-enumeration", display: 0, backend: "sck", error: error)
            throw error
        }
    }

    /// 抓一帧。showsCursor=false 用于"手机上自己画叠加箭头"的场景：
    /// 画面里烘焙一个鼠标、叠加层再画一个，就会出现两个指针，所以那条路径必须关掉烘焙的。
    /// 默认 true 是给旧客户端兜底——它们没有叠加层，关了就一个鼠标都看不见了。
    func snapshot(displayID: UInt32, showsCursor: Bool = true) async throws -> Data {
        try await snapshotFrame(displayID: displayID, showsCursor: showsCursor).jpeg
    }

    func diagnostics() -> [String: Any] { ScreenCaptureDiagnostics.shared.snapshot() }

    func snapshotFrame(displayID: UInt32, showsCursor: Bool = true) async throws -> Snapshot {
        try checkAccess()
        let context = ScreenCaptureDiagnostics.shared.context()
        // 锁屏先走不同的用户级入口，避免 SCK 枚举先卡住；失败仍保留原生错误后有界试 SCK。
        if context.state == "locked" {
            do {
                let data = try ScreenCaptureFallback.capture(displayID: displayID, showsCursor: showsCursor, context: context)
                ScreenCaptureDiagnostics.shared.event(stage: "snapshot", display: displayID, backend: "screencapture", status: "complete")
                return Snapshot(jpeg: data, captureEpoch: context.epoch, captureState: context.state, backend: "screencapture")
            } catch {
                ScreenCaptureDiagnostics.shared.event(stage: "snapshot", display: displayID, backend: "screencapture", error: error)
                guard ScreenCaptureDiagnostics.shared.isCurrent(context) else { throw error }
            }
        }
        if #available(macOS 14.0, *) {
            do {
                let data: Data = try await ScreenCaptureDeadline.run(seconds: 2.5, key: "sck-snapshot") {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.missingDisplay }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    let scale = min(1.0, 1920.0 / Double(display.width))
                    config.width = max(1, Int(Double(display.width) * scale))
                    config.height = max(1, Int(Double(display.height) * scale)); config.showsCursor = showsCursor
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard !ScreenCapturePixels.isBlack(image) else {
                        throw NSError(domain: "PocketDesk.ScreenCapture", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "系统仅返回黑屏，无法确认锁屏画面。"])
                    }
                    guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw Failure.encoding }
                    return data
                }
                guard ScreenCaptureDiagnostics.shared.isCurrent(context) else { throw stale() }
                ScreenCaptureDiagnostics.shared.event(stage: "snapshot", display: displayID, backend: "sck", status: "complete")
                return Snapshot(jpeg: data, captureEpoch: context.epoch, captureState: context.state, backend: "sck")
            } catch {
                ScreenCaptureDiagnostics.shared.event(stage: "snapshot", display: displayID, backend: "sck", error: error)
                throw error
            }
        }
        throw Failure.unavailable
    }
    private func stale() -> NSError {
        NSError(domain: "PocketDesk.ScreenCapture", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "电脑会话状态已变化，已丢弃旧画面。"])
    }
}
