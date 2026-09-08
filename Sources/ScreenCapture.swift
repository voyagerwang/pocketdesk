/**
 * [INPUT]: 依赖 ScreenCaptureKit 的显示器枚举与单帧捕获、CoreGraphics 授权、AppKit JPEG 编码。
 * [OUTPUT]: 提供 ScreenCapture 的显示器列表、授权请求与内存 JPEG 单帧；macOS 14 以下明确拒绝实验功能。
 * [POS]: Sources 的画面读取边界；Server 在鉴权后调用，不保存画面，也不启动持续录屏。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import ScreenCaptureKit

final class ScreenCapture {
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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.sorted { $0.displayID < $1.displayID }.enumerated().map { index, display in
            ["id": display.displayID, "name": "显示器 \(index + 1) · \(display.width) × \(display.height)"]
        }
    }

    func snapshot(displayID: UInt32) async throws -> Data {
        try checkAccess()
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.missingDisplay }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1.0, 1920.0 / Double(display.width))
            config.width = max(1, Int(Double(display.width) * scale))
            config.height = max(1, Int(Double(display.height) * scale))
            config.showsCursor = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw Failure.encoding }
            return data
        }
        throw Failure.unavailable
    }
}
