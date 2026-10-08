/**
 * [INPUT]: 用户级系统 screencapture 工具、当前 CG 显示器次序与锁屏代际。
 * [OUTPUT]: 锁屏限定的备用 JPEG；独立进程有界退出，私有临时目录与文件用后删除，不提权、不用剪贴板。
 * [POS]: 与 ScreenCaptureKit 不同的系统入口；不承诺其在所有系统版本能捕获锁屏内容。
 */
import Foundation
import AppKit

enum ScreenCaptureFallback {
    private static let processLock = NSLock()
    private static var lastAttempt = -Double.infinity
    struct Display { let id: UInt32; let width: Int; let height: Int }
    static func displays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        // 工具只明确承诺 -D 1 为主屏；未验证其他屏幕的序号映射，不向其发送备用截图。
        let main = CGMainDisplayID()
        let ordered = Array(ids.prefix(Int(count))).sorted { a, b in a == main && b != main }
        return ordered.map { let bounds = CGDisplayBounds($0); return Display(id: $0, width: Int(bounds.width), height: Int(bounds.height)) }
    }
    static func displayIndex(id: UInt32, displays: [Display]) -> Int? {
        guard displays.first?.id == id else { return nil }; return 1
    }

    typealias Runner = (URL, [String], TimeInterval) throws -> Void
    static func capture(displayID: UInt32, showsCursor: Bool, context: ScreenCaptureContext,
                        diagnostics: ScreenCaptureDiagnostics = .shared,
                        available: [Display]? = nil, runner: Runner = run) throws -> Data {
        guard getuid() != 0 else { throw failure(7, "备用截图仅允许用户会话执行。") }
        guard context.state == "locked", diagnostics.isCurrent(context) else { throw failure(2, "电脑锁屏状态已变化，已丢弃备用画面。") }
        let initialDisplays = available ?? displays()
        guard let index = displayIndex(id: displayID, displays: initialDisplays) else { throw failure(4, "备用截图仅支持已确认的主屏，其他屏幕不猜测序号。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pocketdesk-capture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("frame.jpg")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw failure(3, "无法创建本次备用画面的私有临时文件。")
        }
        var arguments = ["-x", "-t", "jpg", "-D\(index)"]
        if showsCursor { arguments.append("-C") }
        arguments.append(file.path)
        try runner(URL(fileURLWithPath: "/usr/sbin/screencapture"), arguments, 2)
        guard diagnostics.isCurrent(context), context.state == "locked" else { throw failure(2, "电脑锁屏状态已变化，已丢弃备用画面。") }
        if available == nil {
            guard displays().map(\.id) == initialDisplays.map(\.id), CGMainDisplayID() == displayID else {
                throw failure(2, "显示器状态已变化，已丢弃备用画面。")
            }
        }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 16 * 1024 * 1024 else { throw failure(3, "备用画面未产生有效图片。") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let data = try Data(contentsOf: file, options: [.mappedIfSafe])
        guard data.count >= 3, data.prefix(3) == Data([0xff, 0xd8, 0xff]), let image = NSBitmapImageRep(data: data)?.cgImage else { throw failure(3, "备用画面无法解码。") }
        let expected = initialDisplays[0]
        let horizontal = Double(image.width) / Double(max(1, expected.width))
        let vertical = Double(image.height) / Double(max(1, expected.height))
        guard horizontal >= 1, vertical >= 1, abs(horizontal - vertical) < 0.02 else {
            throw failure(2, "备用画面的尺寸不符合已确认的主屏，已丢弃结果。")
        }
        guard !ScreenCapturePixels.isBlack(image) else { throw failure(6, "系统备用截图仅返回黑屏，无法确认锁屏画面。") }
        guard diagnostics.isCurrent(context) else { throw failure(2, "电脑会话状态已变化，已丢弃备用画面。") }
        return data
    }
    private static func failure(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "PocketDesk.ScreenCaptureFallback", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func run(_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) throws {
        guard processLock.try() else { throw failure(5, "备用画面正在采集，请稍后再试。") }
        defer { processLock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAttempt >= 0.5, !Task.isCancelled else { throw failure(5, "备用画面采集已暂停，请稍后再试。") }
        lastAttempt = now
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        guard ended.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if ended.wait(timeout: .now() + 0.25) != .success {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = ended.wait(timeout: .now() + 0.25)
            }
            throw failure(1, "备用画面采集超时，已终止本次进程。")
        }
        guard process.terminationStatus == 0 else { throw failure(Int(process.terminationStatus), "系统备用截图没有成功；锁屏画面仍待确认。") }
    }
}
