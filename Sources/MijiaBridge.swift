/**
 * [INPUT]: Foundation Process、用户独立安装的 mijiaAPI 5.0.0 Python 环境及随 App 打包的 JSON 桥接脚本。
 * [OUTPUT]: 固定 argv/stdin 的米家调用与限时 JSON 回执；支持独立暂存凭证核验，不把 stderr、账号凭证或任意命令交给模型。
 * [POS]: 米家适配的本机进程边界；MijiaGateway 负责任务租约及持久副作用占用，Python 负责设备规格校验。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreFoundation
import Darwin

enum MijiaBridge {
    struct Failure: Error {
        let kind: String
        let message: String
        var candidates: [[String: Any]] = []
    }
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/VoiceDeck/mijia", isDirectory: true)
    static var pythonPath: String {
        ProcessInfo.processInfo.environment["POCKETDESK_MIJIA_PYTHON"] ?? directory.appendingPathComponent("venv/bin/python").path
    }
    static var authPath: String {
        ProcessInfo.processInfo.environment["POCKETDESK_MIJIA_AUTH"] ?? directory.appendingPathComponent("auth.json").path
    }
    static var helperPath: String? {
        if let path = ProcessInfo.processInfo.environment["POCKETDESK_MIJIA_BRIDGE"] { return path }
        return Bundle.main.resourceURL?.appendingPathComponent("Mijia/mijia-bridge.py").path
    }
    static var timeout: Double = 40
    private static let outputLimit = 2 * 1024 * 1024

    private final class Capture: @unchecked Sendable {
        var data = Data()
        var truncated = false
        func drain(_ handle: FileHandle) {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                let remaining = max(0, outputLimit - data.count)
                data.append(chunk.prefix(remaining))
                if chunk.count > remaining { truncated = true }
            }
        }
    }

    static func run(_ request: [String: Any]) -> Result<[String: Any], Failure> { run(request, authPath: authPath) }

    static func run(_ request: [String: Any], authPath: String) -> Result<[String: Any], Failure> {
        guard FileManager.default.isExecutableFile(atPath: pythonPath), let helperPath,
              FileManager.default.fileExists(atPath: helperPath) else {
            return .failure(Failure(kind: "setup", message: "米家接入尚未准备好，请在 PocketDesk 电脑控制台的“米家连接”中扫码连接。"))
        }
        guard let input = try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), input.count <= 16000 else {
            return .failure(Failure(kind: "invalid", message: "米家参数无效或过长。"))
        }
        let process = Process(), output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-I", "-B", helperPath, "--auth", authPath]
        process.standardOutput = output; process.standardError = errors; process.standardInput = stdin
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { return .failure(Failure(kind: "setup", message: "米家桥接未能启动，请重新运行安装脚本。")) }
        let stdout = Capture(), stderr = Capture(), readers = DispatchGroup()
        readers.enter(); DispatchQueue.global().async { stdout.drain(output.fileHandleForReading); readers.leave() }
        readers.enter(); DispatchQueue.global().async { stderr.drain(errors.fileHandleForReading); readers.leave() }
        do { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
        catch { try? stdin.fileHandleForWriting.close() }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 2)
            }
        }
        readers.wait()
        if timedOut { return .failure(Failure(kind: "network", message: "米家响应超时，未取得可核对回执。")) }
        guard !stdout.truncated, let json = (try? JSONSerialization.jsonObject(with: stdout.data)) as? [String: Any],
              let ok = json["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else {
            return .failure(Failure(kind: "unknown", message: "米家返回结果无法核对。"))
        }
        if ok.boolValue, process.terminationStatus == 0, let data = json["data"] as? [String: Any] { return .success(data) }
        guard let error = json["error"] as? [String: Any], let kind = error["kind"] as? String,
              let message = error["message"] as? String else {
            return .failure(Failure(kind: "unknown", message: "米家操作没有有效回执。"))
        }
        return .failure(Failure(kind: kind, message: String(message.prefix(2000)), candidates: error["candidates"] as? [[String: Any]] ?? []))
    }
}
