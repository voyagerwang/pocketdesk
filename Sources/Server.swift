/**
 * [INPUT]: 依赖 Network 的 NWListener/NWConnection、AppKit 的 NSWorkspace/NSRunningApplication、CoreGraphics 的 CGWindowList 与 Foundation 的 JSON 编解码；消费 ScreenCapture 的鉴权画面读取、Models 的请求体类型、TargetStore 配置、Auth 鉴权、AppDiscovery 搜索、Util 地址与图标、InputExecutor 执行。
 * [OUTPUT]: 对外提供 Server（HTTP :46387 全部端点：状态/局域网与 Tailscale 配对二维码/配对心跳/应用搜索/图标/目标与快捷键管理（保留完整组合键简称）/激活/发送/图片预上传/快捷键触发、静态页面服务；非回环写请求强制 Bearer 校验）。
 * [POS]: Sources 的传输层；只翻译协议不做系统调用，与 WSServer（触控板通道）平行为一对传输兄弟。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation
import Network

final class Server {
    private let screenCapture = ScreenCapture()
    private var captureBusy = false
    private let port: UInt16
    private let webRoot: URL
    private let executor: InputExecutor
    private let store: TargetStore
    private let queue = DispatchQueue(label: "dev.voicedeck.server")
    private var listener: NWListener?
    private var iconCache: [String: Data] = [:]
    private var phoneLastSeen: TimeInterval = 0
    // 图片走 base64 JSON 体，2MB 远远不够；放宽到 12MB（客户端已把图压到 2048px JPEG）。
    private let maxBodyBytes = 12 * 1024 * 1024

    init(port: UInt16, webRoot: URL, store: TargetStore) {
        self.port = port
        self.webRoot = webRoot
        self.store = store
        self.executor = InputExecutor(store: store)
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        // 在局域网服务浏览器中以独立身份出现，不借用 Workbench 等其他本机服务。
        listener.service = NWListener.Service(name: "PocketDesk", type: "_http._tcp")
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { fputs("服务器失败：\(error)\n", stderr) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: [])
    }

    // 完整读取请求头与 Content-Length 声明的请求体（图标上传的 base64 体可达数百 KB）。
    private func receiveRequest(_ connection: NWConnection, buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(contentsOf: data) }
            guard let headerEnd = buffer.firstRange(of: Array("\r\n\r\n".utf8)) else {
                if isComplete || buffer.count > 65_536 { connection.cancel() } else { self.receiveRequest(connection, buffer: buffer) }
                return
            }
            let headerText = String(decoding: buffer[0..<headerEnd.lowerBound], as: UTF8.self)
            let contentLength = Self.contentLength(of: headerText)
            if contentLength > self.maxBodyBytes { self.respond(connection, status: 413, json: ["error": "请求体过大。"]); return }
            let total = headerEnd.upperBound + contentLength
            if buffer.count < total {
                if isComplete { connection.cancel() } else { self.receiveRequest(connection, buffer: buffer) }
                return
            }
            let body = Array(buffer[headerEnd.upperBound..<total])
            self.route(headerText: headerText, body: body, connection: connection)
        }
    }

    private static func contentLength(of headerText: String) -> Int {
        headerText.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
    }

    private static func queryValue(_ name: String, in path: String) -> String? {
        URLComponents(string: "http://voice-deck.local\(path)")?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    private static func headerValue(_ name: String, in headerText: String) -> String? {
        headerText.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }?
            .dropFirst(name.count + 1)
            .trimmingCharacters(in: .whitespaces)
    }

    // 回环豁免：控制台页面在 Mac 本机浏览器打开（localhost 可能解析为 127.0.0.1 或 ::1），
    // 本机即机主，无需 token。
    private static func isLoopback(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.rawValue.withUnsafeBytes { $0.first == 127 }
        case .ipv6(let address):
            return address.rawValue.withUnsafeBytes { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }
        default:
            return false
        }
    }


    private func route(headerText: String, body: [UInt8], connection: NWConnection) {
        let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? "/"
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let bodyData = Data(body)
        let authorization = Self.headerValue("Authorization", in: headerText)

        // 写端点鉴权：手机 token 来自扫码 URL；控制台走 localhost 回环豁免（本机即机主）。
        let isWrite = method != "GET"
        let fromLoopback = Self.isLoopback(connection)
        if (isWrite || path.hasPrefix("/api/screen/")) && !fromLoopback && !Auth.verify(authorizationHeader: authorization) {
            respond(connection, status: 401, json: ["error": "未授权：请重新扫码连接。"])
            return
        }

        switch (method, path) {
        case ("POST", "/api/screen/permission"):
            screenCapture.requestPermission()
            respond(connection, status: 200, json: ["ok": true])
        case ("GET", "/api/screen/displays"), ("GET", "/api/screen/frame"):
            guard !captureBusy else {
                respond(connection, status: 503, json: ["error": "画面采集中，请稍后重试。"]); return
            }
            let displayID = Self.queryValue("display", in: rawPath).flatMap(UInt32.init)
            if path.hasSuffix("/frame") && displayID == nil {
                respond(connection, status: 400, json: ["error": "请选择显示器。"]); return
            }
            captureBusy = true
            Task {
                do {
                    if let displayID {
                        let data = try await screenCapture.snapshot(displayID: displayID)
                        queue.async {
                            self.captureBusy = false
                            self.respond(connection, status: 200, data: data, contentType: "image/jpeg")
                        }
                    } else {
                        let displays = try await screenCapture.displays()
                        queue.async {
                            self.captureBusy = false
                            self.respond(connection, status: 200, json: ["displays": displays])
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    queue.async {
                        self.captureBusy = false
                        self.respond(connection, status: 422, json: ["error": message])
                    }
                }
            }

        case ("GET", "/api/status"):
            let stableURL = Util.stableURL(port)
            let lanIP = Util.primaryLANAddress()
            let tailscaleURL = Util.tailscaleURL(port)
            // 前台应用若命中某个已配置目标，手机端选中态会跟随它；未命中则把 frontmostName
            // 交给手机端做"注入当前前台"的伪目标（不切换应用）。
            // 不用 NSWorkspace.frontmostApplication：长期无窗口的常驻应用里它的缓存会冻结
            // （实测永远返回某个旧应用）；CGWindowList 直接问窗口服务器，谁在前台就是谁。
            let frontmost = Util.frontmostApp()
            let frontmostId = frontmost.flatMap { app in
                store.targets.first { config in
                    (config.bundleID != nil && app.bundleIdentifier == config.bundleID)
                        || (config.path != nil && app.bundleURL?.path == config.path)
                }?.id
            }
            let payload: [String: Any] = [
                "accessibility": AXIsProcessTrusted(),
                "platform": "macOS",
                "phoneLastSeen": Int(phoneLastSeen),
                "theme": store.theme,
                "lanURL": (stableURL ?? lanIP.map { "http://\($0):\(port)" }) as Any?,
                "ipURL": lanIP.map { "http://\($0):\(port)" } as Any?,
                "remoteURL": tailscaleURL ?? "",
                "hostName": Util.stableHost() ?? "",
                "frontmostId": frontmostId as Any?,
                "frontmostName": frontmost?.localizedName as Any?,
                "targets": store.targets.map { config in
                    var entry: [String: Any] = [
                        "id": config.id, "name": config.name, "available": store.appURL(config) != nil,
                        "bundleID": config.bundleID as Any?, "path": config.path as Any?,
                    ]
                    if let shortcuts = config.shortcuts, !shortcuts.isEmpty {
                        entry["shortcuts"] = shortcuts.map { sc -> [String: Any] in
                            var item: [String: Any] = ["id": sc.id, "label": sc.label, "hotkey": sc.hotkey]
                            if let action = sc.action { item["action"] = action }
                            return item
                        }
                    }
                    if let panel = config.openPanel { entry["openPanel"] = panel }
                    if let showGlobal = config.showGlobal { entry["showGlobal"] = showGlobal }
                    return entry
                },
                "shortcuts": store.shortcuts.map { shortcut -> [String: Any] in
                    var item: [String: Any] = ["id": shortcut.id, "label": shortcut.label, "hotkey": shortcut.hotkey]
                    if let action = shortcut.action { item["action"] = action }
                    return item
                },
                // 预设动作目录：录不到的系统/应用操作，控制台据此渲染"点选即添加"的按钮。
                "actions": ShortcutAction.allCases.map { action in
                    ["id": action.rawValue, "label": action.label, "hotkey": action.hotkey(.current)]
                },
                // 最近动作日志：事后排查"我点了但没反应"的唯一依据，控制台第 5 个面板消费。
                "log": ExecutionLog.shared.recent(30),
            ]
            respond(connection, status: 200, json: payload)
        case ("GET", "/console"), ("GET", "/console.html"):
            serveFile("console.html", connection: connection)
        case ("GET", "/api/qr"):
            // type=ip 生成局域网 IP 地址版，type=tailscale 生成跨网私有地址版；默认生成 .local
            // 主机名版。所有 URL 内嵌配对 token，扫码即完成配对。
            let lanIP = Util.primaryLANAddress()
            let target: String?
            switch Self.queryValue("type", in: rawPath) {
            case "ip":
                target = lanIP.map { "http://\($0):\(port)" }
            case "tailscale":
                target = Util.tailscaleURL(port)
            default:
                target = Util.stableURL(port) ?? lanIP.map { "http://\($0):\(port)" }
            }
            guard let url = target.map({ "\($0)/?token=\(Auth.token)" }), let png = Util.qrPNG(url) else {
                respond(connection, status: 503, json: ["error": "未找到对应网络地址，无法生成二维码。"]); return
            }
            respond(connection, status: 200, data: png, contentType: "image/png")
        case ("POST", "/api/pair"):
            phoneLastSeen = Date().timeIntervalSince1970
            respond(connection, status: 200, json: ["ok": true])
        case ("POST", "/api/open-accessibility"):
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            respond(connection, status: 200, json: ["ok": true])
        case ("POST", "/api/theme"):
            // 主题唯一控制点在电脑端控制台；手机页经 /api/status 轮询跟随。
            guard let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
                  let name = body["theme"] as? String else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            store.saveTheme(name)
            respond(connection, status: 200, json: ["ok": true, "theme": store.theme])
        case ("GET", "/api/apps"):
            let query = Self.queryValue("q", in: rawPath) ?? ""
            respond(connection, status: 200, json: ["apps": AppDiscovery.search(query)])
        case ("GET", "/api/app-icon"):
            guard let filePath = Self.queryValue("path", in: rawPath),
                  filePath.hasPrefix("/"), filePath.hasSuffix(".app"),
                  FileManager.default.fileExists(atPath: filePath) else {
                respond(connection, status: 404, json: ["error": "图标不可用。"]); return
            }
            let key = "path:" + filePath
            if let cached = iconCache[key] { respond(connection, status: 200, data: cached, contentType: "image/png"); return }
            guard let png = Util.appIconPNG(forFile: filePath) else {
                respond(connection, status: 404, json: ["error": "图标不可用。"]); return
            }
            iconCache[key] = png
            respond(connection, status: 200, data: png, contentType: "image/png")
        case ("POST", "/api/targets"):
            guard let list = try? JSONDecoder().decode([TargetConfig].self, from: bodyData) else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            var seen = Set<String>()
            let cleaned = list.prefix(24).map { entry -> TargetConfig in
                var config = entry
                if config.id.isEmpty || seen.contains(config.id) { config.id = AppDiscovery.makeID(forName: config.name, existing: store.targets) }
                seen.insert(config.id)
                // openPanel 白名单：input/pad，其余清空回退默认。
                if let panel = config.openPanel, panel != "input", panel != "pad" { config.openPanel = nil }
                // 专属快捷键：每条必须可解析、id 去重（空/撞车补 UUID）、单应用 ≤12 条、label 截断。
                if let shortcuts = config.shortcuts {
                    var seenSC = Set<String>()
                    config.shortcuts = shortcuts.prefix(12).compactMap { sc -> ShortcutConfig? in
                        guard var next = sc.normalized() else { return nil }
                        if next.id.isEmpty || seenSC.contains(next.id) { next.id = UUID().uuidString }
                        next.label = String(next.label.prefix(7))
                        seenSC.insert(next.id)
                        return next
                    }
                    if config.shortcuts?.isEmpty ?? false { config.shortcuts = nil }
                }
                return config
            }
            store.save(cleaned)
            iconCache = [:]
            respond(connection, status: 200, json: ["ok": true])
        case ("POST", "/api/target-icon"):
            guard let upload = try? JSONDecoder().decode(IconUpload.self, from: bodyData),
                  let png = Data(base64Encoded: upload.data), png.count <= 512_000,
                  store.resolve(upload.id) != nil else {
                respond(connection, status: 400, json: ["error": "图标数据无效。"]); return
            }
            try? FileManager.default.createDirectory(at: TargetStore.iconDirectory, withIntermediateDirectories: true)
            try? png.write(to: store.customIconURL(upload.id), options: .atomic)
            iconCache = [:]
            respond(connection, status: 200, json: ["ok": true])
        case ("GET", "/api/icon"):
            let targetId = Self.queryValue("id", in: rawPath) ?? ""
            serveIcon(targetId, connection: connection)
        case ("POST", "/api/activate"):
            guard let command = try? JSONDecoder().decode(ActivateCommand.self, from: bodyData) else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            executor.activate(command.targetId) { result in
                switch result {
                case .success: self.respond(connection, status: 200, json: ["ok": true])
                case .failure(.message(let message)): self.respond(connection, status: 422, json: ["error": message])
                }
            }
        case ("POST", "/api/send"):
            guard let command = try? JSONDecoder().decode(SendCommand.self, from: bodyData) else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            executor.send(command) { result in
                switch result {
                case .success(let feedback):
                    // 发送成功也带结论：sent 表示"发出去了但无法确认是否落到输入框"，detail 已含人话说明。
                    self.respond(connection, status: 200, json: ["ok": true, "outcome": feedback.outcome.rawValue, "detail": feedback.detail])
                case .failure(.message(let message)): self.respond(connection, status: 422, json: ["error": message])
                }
            }
        case ("POST", "/api/shortcuts"):
            // 数量上限 + id 去重补 UUID + 每条语义串必须可解析，任一不合法整批拒绝。
            guard let list = try? JSONDecoder().decode([ShortcutConfig].self, from: bodyData) else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            var seen = Set<String>()
            let cleaned: [ShortcutConfig] = list.prefix(12).compactMap { entry in
                guard var shortcut = entry.normalized() else { return nil }
                if shortcut.id.isEmpty || seen.contains(shortcut.id) { shortcut.id = UUID().uuidString }
                shortcut.label = String(shortcut.label.prefix(7))
                seen.insert(shortcut.id)
                return shortcut
            }
            store.saveShortcuts(cleaned)
            respond(connection, status: 200, json: ["ok": true])
        case ("POST", "/api/image"):
            // 手机选图后立即预上传：先传图、后发文字，发送请求体保持轻量。
            guard let upload = try? JSONDecoder().decode(PendingImage.self, from: bodyData),
                  let png = Data(base64Encoded: upload.data) else {
                respond(connection, status: 400, json: ["error": "图片数据无效。"]); return
            }
            executor.stageImage(png) { result in
                switch result {
                case .success: self.respond(connection, status: 200, json: ["ok": true])
                case .failure(.message(let message)): self.respond(connection, status: 422, json: ["error": message])
                }
            }
        case ("POST", "/api/shortcut-trigger"):
            guard let shortcut = try? JSONDecoder().decode(ShortcutConfig.self, from: bodyData) else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            // 以手机存储的配置为准回查一次；查不到就用上报内容原样执行（服务端重启后手机列表是旧数据的场景）。
            let resolved = store.shortcuts.first { $0.id == shortcut.id } ?? shortcut
            executor.triggerShortcut(resolved) { result in
                switch result {
                case .success(let feedback):
                    // outcome 是本次动作的可信度：delivered=观察到生效，sent=发出去了但没确认。
                    // 前端据此区分"已完成"与"已发送，不确定"，不再一律当成成功。
                    self.respond(connection, status: 200, json: ["ok": true, "outcome": feedback.outcome.rawValue, "detail": feedback.detail])
                case .failure(.message(let message)): self.respond(connection, status: 422, json: ["error": message])
                }
            }
        case ("GET", "/"), ("GET", "/index.html"):
            serveFile("index.html", connection: connection)
        case ("GET", "/screen.js"), ("GET", "/app.js"), ("GET", "/style.css"):
            serveFile(String(path.dropFirst()), connection: connection)
        default:
            respond(connection, status: 404, json: ["error": "未找到资源。"])
        }
    }

    private func serveFile(_ name: String, connection: NWConnection) {
        let url = webRoot.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { respond(connection, status: 404, json: ["error": "页面资源不存在。"]); return }
        let type = name.hasSuffix(".css") ? "text/css; charset=utf-8" : name.hasSuffix(".js") ? "application/javascript; charset=utf-8" : "text/html; charset=utf-8"
        respond(connection, status: 200, data: data, contentType: type)
    }

    private func serveIcon(_ targetId: String, connection: NWConnection) {
        // 图标内容近乎不变（仅控制台换图标时变，且会重置内存缓存），长缓存让浏览器
        // 刷新页面时直接复用本地副本——没有重新下载就没有"先首字后图标"的闪跳。
        if let cached = iconCache["id:" + targetId] {
            respond(connection, status: 200, data: cached, contentType: "image/png", cacheControl: "public, max-age=86400"); return
        }
        let customURL = store.customIconURL(targetId)
        let sourcePath: String?
        if FileManager.default.fileExists(atPath: customURL.path), let data = try? Data(contentsOf: customURL) {
            iconCache["id:" + targetId] = data
            respond(connection, status: 200, data: data, contentType: "image/png", cacheControl: "public, max-age=86400"); return
        }
        if let config = store.resolve(targetId), let url = store.appURL(config) { sourcePath = url.path } else { sourcePath = nil }
        guard let path = sourcePath, let png = Util.appIconPNG(forFile: path) else {
            respond(connection, status: 404, json: ["error": "图标不可用。"]); return
        }
        iconCache["id:" + targetId] = png
        respond(connection, status: 200, data: png, contentType: "image/png", cacheControl: "public, max-age=86400")
    }

    private func respond(_ connection: NWConnection, status: Int, json: Any) {
        // .sortedKeys：字典键序在 Swift 里是不确定的（每次序列化都可能不同）。客户端用
        // JSON.stringify 比较目标/快捷键是否变化，键序抖动会被误判为"变了"→ 每拍重建 DOM →
        // 图标因 no-store 重新下载，表现为图标周期性闪回首字。确定性输出是服务端的契约责任。
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        respond(connection, status: status, data: data, contentType: "application/json; charset=utf-8")
    }

    private func respond(_ connection: NWConnection, status: Int, data: Data, contentType: String, cacheControl: String = "no-store") {
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : status == 413 ? "Payload Too Large" : status == 503 ? "Service Unavailable" : "Unprocessable Entity"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: \(cacheControl)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
