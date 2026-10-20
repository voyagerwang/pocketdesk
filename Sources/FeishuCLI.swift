/**
 * [INPUT]: Foundation Process，当前 macOS 用户的 lark-cli 原生或 npm 安装与授权；不读取或复制令牌。
 * [OUTPUT]: 原生 CLI 入口解析（npm 安装绕过依赖 Node 的启动脚本）、固定业务 argv、帮助/Schema/规范读取、用户本人状态与 JSON 信封解析；超时、启动依赖、网络和登录/权限错误分类。
 * [POS]: 飞书适配的后台进程边界，复用 Workbench 同一 CLI 身份；不依赖交互 shell 的 PATH，不提供任意 shell 工具。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin

enum FeishuCLI {
    struct Failure: Error { let message: String }
    static func executable() -> String? {
        let home = NSHomeDirectory()
        var paths = [ProcessInfo.processInfo.environment["LARK_CLI_PATH"] ?? "", home + "/.local/bin/lark-cli", "/opt/homebrew/bin/lark-cli", "/usr/local/bin/lark-cli"]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/lark-cli" }
        let nvm = home + "/.nvm/versions/node"
        paths += ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted().reversed().map { nvm + "/" + $0 + "/bin/lark-cli" }
        return paths.lazy.compactMap(resolveExecutable).first
    }

    static func resolveExecutable(_ path: String) -> String? {
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let launcher = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let scripts = launcher.deletingLastPathComponent()
        let package = scripts.deletingLastPathComponent()
        // npm 的 run.js 仅转交同包 bin/lark-cli；launchd 的系统 PATH 没有 Node，直接调用原生入口。
        if launcher.lastPathComponent == "run.js", scripts.lastPathComponent == "scripts",
           package.lastPathComponent == "cli", package.deletingLastPathComponent().lastPathComponent == "@larksuite" {
            let native = package.appendingPathComponent("bin/lark-cli").path
            if FileManager.default.isExecutableFile(atPath: native) { return native }
        }
        return path
    }

    // 管道持续排空，最多保留 2 MiB，防止进程填满 pipe 后无法退出。
    private final class Capture: @unchecked Sendable {
        var data = Data()
        func drain(_ handle: FileHandle) {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if data.count < 2 * 1024 * 1024 { data.append(chunk.prefix(2 * 1024 * 1024 - data.count)) }
            }
        }
    }

    static func run(_ args: [String]) -> Result<[String: Any], Failure> { execute(args, mode: "business") }
    static func help(_ command: [String]) -> Result<[String: Any], Failure> { execute(command + ["--help"], mode: "help") }
    static func reference(_ args: [String]) -> Result<[String: Any], Failure> { execute(args, mode: "help") }
    static func capabilities() -> Result<[String: Any], Failure> { execute(["auth", "status", "--json", "--verify"], mode: "auth") }

    private static func execute(_ args: [String], mode: String) -> Result<[String: Any], Failure> {
        guard let path = executable() else { return .failure(Failure(message: "未找到飞书 CLI，请先在 Workbench 配置飞书。")) }
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1"
        env["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1"
        process.environment = env
        process.standardOutput = out; process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return .failure(Failure(message: "飞书 CLI 未能启动。")) }
        let stdout = Capture(), stderr = Capture(), readers = DispatchGroup()
        readers.enter(); DispatchQueue.global().async { stdout.drain(out.fileHandleForReading); readers.leave() }
        readers.enter(); DispatchQueue.global().async { stderr.drain(err.fileHandleForReading); readers.leave() }
        let timedOut = exited.wait(timeout: .now() + 35) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 2) }
        }
        readers.wait()
        if timedOut { return .failure(Failure(message: "飞书响应超时。")) }
        let data = process.terminationStatus == 0 ? stdout.data : stderr.data
        if mode == "help", process.terminationStatus == 0 {
            return .success(["help": String(data: data, encoding: .utf8) ?? ""])
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let diagnostic = String(data: stderr.data, encoding: .utf8) ?? ""
            if process.terminationStatus == 127, diagnostic.lowercased().contains("node") {
                return .failure(Failure(message: "飞书 CLI 启动失败：后台运行环境找不到 Node，请检查 CLI 安装。"))
            }
            if process.terminationStatus != 0 {
                return .failure(Failure(message: "飞书 CLI 执行失败（退出码 \(process.terminationStatus)），未取得可核对的回执。"))
            }
            return .failure(Failure(message: "飞书返回结果无法核对。"))
        }
        if mode == "auth", process.terminationStatus == 0 {
            let user = (json["identities"] as? [String: [String: Any]])?["user"] ?? [:]
            return .success(["verified": user["verified"] as? Bool == true && user["available"] as? Bool == true,
                             "scopes": user["scope"] as? String ?? "",
                             "status": user["status"] as? String ?? "unknown",
                             "tokenStatus": user["tokenStatus"] as? String ?? "unknown"])
        }
        guard process.terminationStatus == 0, json["ok"] as? Bool == true else {
            let error = json["error"] as? [String: Any] ?? [:]
            let subtype = error["subtype"] as? String ?? ""
            let message = (error["message"] as? String ?? "").lowercased()
            if error["missing_scopes"] != nil || subtype.contains("scope") {
                let scopes = (error["missing_scopes"] as? [String] ?? []).filter { $0.range(of: "^[a-zA-Z0-9_:.-]+$", options: .regularExpression) != nil }
                return .failure(Failure(message: "当前操作缺少飞书权限：" + (scopes.isEmpty ? "请在 Workbench 检查授权范围。" : scopes.joined(separator: ", "))))
            }
            if error["type"] as? String == "authentication" || subtype.contains("token") ||
                message.contains("refresh token") || message.contains("auth login") {
                return .failure(Failure(message: "飞书本人登录已失效，请重新完成 CLI 用户授权后再发送；不会改用机器人身份。"))
            }
            if error["type"] as? String == "network" {
                return .failure(Failure(message: "无法连接飞书服务，请检查网络后重试。"))
            }
            if process.terminationStatus == 10 { return .failure(Failure(message: "飞书要求额外授权确认，本次未自动继续。")) }
            return .failure(Failure(message: "飞书操作失败，请检查 Workbench 中的飞书授权与联系人可见范围。"))
        }
        guard json["identity"] as? String == "user" else { return .failure(Failure(message: "飞书返回身份不是用户本人，已停止。")) }
        return .success(json["data"] as? [String: Any] ?? [:])
    }
}
