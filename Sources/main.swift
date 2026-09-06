/**
 * [INPUT]: 依赖 Foundation、Network、AppKit 与 Quartz 的本机 HTTP、应用激活和 CGEvent 能力。
 * [OUTPUT]: 对外提供 VoiceDeck 本地 HTTP 服务：静态网页、状态查询、应用置顶和文本发送端点。
 * [POS]: Sources 的 macOS 执行边界；Web 层只发送稳定的 SendCommand，不接触系统 API。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import CoreGraphics
import Foundation
import Network

struct SendCommand: Decodable {
    let targetId: String
    let text: String
}

struct ActivateCommand: Decodable {
    let targetId: String
}

enum InputError: Error { case message(String) }

struct Target: Encodable {
    let id: String
    let name: String
    let bundleIdentifiers: [String]
    let applicationNames: [String]
    let paths: [String]

    func installedURL() -> URL? {
        let normalizedNames = Set(applicationNames.map { $0.lowercased() })
        if let namedRunningURL = NSWorkspace.shared.runningApplications.first(where: {
            guard let name = $0.localizedName?.lowercased() else { return false }
            return normalizedNames.contains(name)
        })?.bundleURL {
            return namedRunningURL
        }
        for bundleIdentifier in bundleIdentifiers {
            if let runningURL = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.bundleURL {
                return runningURL
            }
            if let registeredURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return registeredURL
            }
        }
        return paths.map { URL(fileURLWithPath: $0) }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }
}

let targets = [
    Target(id: "codex", name: "Codex", bundleIdentifiers: ["com.openai.codex"], applicationNames: ["Codex", "ChatGPT"], paths: ["/Applications/Codex.app", "/Applications/ChatGPT.app"]),
    Target(id: "chatgpt", name: "ChatGPT", bundleIdentifiers: ["com.openai.chat", "com.openai.codex"], applicationNames: ["ChatGPT", "Codex"], paths: ["/Applications/ChatGPT.app"]),
    Target(id: "feishu", name: "飞书", bundleIdentifiers: ["com.electron.lark", "com.bytedance.Feishu", "com.larksuite.suite"], applicationNames: ["飞书", "Feishu", "Lark"], paths: ["/Applications/Feishu.app", "/Applications/Lark.app"]),
    Target(id: "chrome", name: "Chrome", bundleIdentifiers: ["com.google.Chrome"], applicationNames: ["Google Chrome", "Chrome"], paths: ["/Applications/Google Chrome.app"]),
    Target(id: "zcode", name: "ZCode", bundleIdentifiers: ["dev.zcode.app"], applicationNames: ["ZCode"], paths: ["/Applications/ZCode.app"]),
    Target(id: "workbody", name: "Workbody", bundleIdentifiers: [], applicationNames: ["Workbody", "WorkBody"], paths: ["/Applications/Workbody.app", "/Applications/WorkBody.app"]),
    Target(id: "wechat", name: "微信", bundleIdentifiers: ["com.tencent.xinWeChat"], applicationNames: ["微信", "WeChat"], paths: ["/Applications/WeChat.app", "/Applications/微信.app"])
]

final class InputExecutor {
    private let queue = DispatchQueue(label: "dev.voicedeck.input")

    func activate(_ targetId: String, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async { self.activateTarget(targetId, completion: completion) }
    }

    func send(_ command: SendCommand, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async {
            guard !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                completion(.failure(.message("请输入要发送的内容。"))); return
            }
            guard command.text.utf16.count <= 8_000 else {
                completion(.failure(.message("单次文本最多 8,000 个 UTF-16 字符。"))); return
            }
            guard AXIsProcessTrusted() else {
                completion(.failure(.message("尚未授予“辅助功能”权限。请允许运行 VoiceDeck 的终端或应用。"))); return
            }
            self.activateTarget(command.targetId) { result in
                guard case .success = result else { completion(result); return }
                // 给桌面应用取得前台焦点；后续步骤都在同一串行队列中执行。
                self.queue.asyncAfter(deadline: .now() + .milliseconds(450)) {
                    self.postUnicode(command.text)
                    self.postKey(36) // Return
                    completion(.success(()))
                }
            }
        }
    }

    private func activateTarget(_ targetId: String, completion: @escaping (Result<Void, InputError>) -> Void) {
        guard let target = targets.first(where: { $0.id == targetId }) else {
            completion(.failure(.message("未知的目标应用。"))); return
        }
        guard let url = target.installedURL() else {
            completion(.failure(.message("未找到 \(target.name)。请确认应用已安装或正在运行。"))); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            if let error {
                completion(.failure(.message("无法打开 \(target.name)：\(error.localizedDescription)"))); return
            }
            application?.unhide()
            application?.activate(options: [.activateAllWindows])
            completion(.success(()))
        }
    }

    private func postUnicode(_ text: String) {
        var units = Array(text.utf16)
        let length = units.count
        units.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return }
            down.keyboardSetUnicodeString(stringLength: length, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: length, unicodeString: base)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func postKey(_ code: CGKeyCode) {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

final class Server {
    private let port: UInt16
    private let webRoot: URL
    private let executor = InputExecutor()
    private let queue = DispatchQueue(label: "dev.voicedeck.server")
    private var listener: NWListener?

    init(port: UInt16, webRoot: URL) { self.port = port; self.webRoot = webRoot }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        // 在局域网服务浏览器中以独立身份出现，不借用 Workbench 等其他本机服务。
        listener.service = NWListener.Service(name: "Voice Deck", type: "_http._tcp")
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { fputs("服务器失败：\(error)\n", stderr) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, _, _ in
            guard let self, let data else { connection.cancel(); return }
            self.route(data: data, connection: connection)
        }
    }

    private func route(data: Data, connection: NWConnection) {
        let raw = String(decoding: data, as: UTF8.self)
        let lines = raw.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? ""
        let path = parts.dropFirst().first.map(String.init) ?? "/"
        let body = raw.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        if method == "GET" && path == "/api/status" {
            let targetPayload: [[String: Any]] = targets.map {
                ["id": $0.id, "name": $0.name, "available": $0.installedURL() != nil]
            }
            respond(connection, status: 200, json: ["accessibility": AXIsProcessTrusted(), "targets": targetPayload])
        } else if method == "POST" && path == "/api/activate" {
            guard let command = try? JSONDecoder().decode(ActivateCommand.self, from: Data(body.utf8)) else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            executor.activate(command.targetId) { result in
                switch result {
                case .success: self.respond(connection, status: 200, json: ["ok": true])
                case .failure(.message(let message)): self.respond(connection, status: 422, json: ["error": message])
                }
            }
        } else if method == "POST" && path == "/api/send" {
            guard let command = try? JSONDecoder().decode(SendCommand.self, from: Data(body.utf8)) else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            executor.send(command) { result in
                switch result {
                case .success: self.respond(connection, status: 200, json: ["ok": true])
                case .failure(.message(let message)): self.respond(connection, status: 422, json: ["error": message])
                }
            }
        } else if method == "GET" && ["/", "/index.html", "/app.js", "/style.css"].contains(path.components(separatedBy: "?").first ?? path) {
            let resourcePath = path.components(separatedBy: "?").first ?? path
            serveFile(resourcePath == "/" ? "index.html" : String(resourcePath.dropFirst()), connection: connection)
        } else {
            respond(connection, status: 404, json: ["error": "未找到资源。"])
        }
    }

    private func serveFile(_ name: String, connection: NWConnection) {
        let url = webRoot.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { respond(connection, status: 404, json: ["error": "页面资源不存在。"]); return }
        let type = name.hasSuffix(".css") ? "text/css; charset=utf-8" : name.hasSuffix(".js") ? "application/javascript; charset=utf-8" : "text/html; charset=utf-8"
        respond(connection, status: 200, data: data, contentType: type)
    }

    private func respond(_ connection: NWConnection, status: Int, json: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        respond(connection, status: status, data: data, contentType: "application/json; charset=utf-8")
    }

    private func respond(_ connection: NWConnection, status: Int, data: Data, contentType: String) {
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : "Unprocessable Entity"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

let executableDirectory = URL(fileURLWithPath: CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath).deletingLastPathComponent()
let bundledWebRoot = executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources/Web")
let root = FileManager.default.fileExists(atPath: bundledWebRoot.appendingPathComponent("index.html").path)
    ? bundledWebRoot.deletingLastPathComponent()
    : executableDirectory
let defaultPort: UInt16 = 46387
let selectedPort = UInt16(ProcessInfo.processInfo.environment["VOICE_DECK_PORT"] ?? "") ?? defaultPort
let server = Server(port: selectedPort, webRoot: root.appendingPathComponent("Web"))
// 首次启动时让 macOS 显示其官方授权提示；授权决定仍完全由用户控制。
let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(promptOptions)
try server.start()
print("Voice Deck 已启动。打开 http://localhost:\(selectedPort)")
dispatchMain()
