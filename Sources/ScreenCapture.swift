/**
 * [INPUT]: 依赖 ScreenCaptureKit 的显示器枚举与单帧捕获、CoreGraphics 授权、AppKit JPEG 编码。
 * [OUTPUT]: 提供 ScreenCapture 的显示器列表、授权请求与内存 JPEG 单帧（showsCursor 可按请求关闭，供手机叠加箭头时避免双鼠标）；macOS 14 以下明确拒绝实验功能。
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

    /// 抓一帧。showsCursor=false 用于"手机上自己画叠加箭头"的场景：
    /// 画面里烘焙一个鼠标、叠加层再画一个，就会出现两个指针，所以那条路径必须关掉烘焙的。
    /// 默认 true 是给旧客户端兜底——它们没有叠加层，关了就一个鼠标都看不见了。
    func snapshot(displayID: UInt32, showsCursor: Bool = true) async throws -> Data {
        try checkAccess()
        if #available(macOS 14.0, *) {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.missingDisplay }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1.0, 1920.0 / Double(display.width))
            config.width = max(1, Int(Double(display.width) * scale))
            config.height = max(1, Int(Double(display.height) * scale))
            config.showsCursor = showsCursor
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw Failure.encoding }
            return data
        }
        throw Failure.unavailable
    }
}
