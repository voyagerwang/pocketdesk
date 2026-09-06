/**
 * [INPUT]: 依赖 Foundation、Network、AppKit、CoreImage 与 Quartz 的本机 HTTP、应用激活、QR 与 CGEvent 能力。
 * [OUTPUT]: 对外提供 PocketDesk 本地服务：手机页与电脑控制台、目标应用配置持久化、本地应用搜索、
 *           二维码、授权跳转、应用置顶和文本发送端点（HTTP :46387）；触控板手势通道（WebSocket :46388）。
 * [POS]: Sources 的 macOS 执行边界；Web 层只发送稳定的 SendCommand，不接触系统 API。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Network

struct SendCommand: Decodable {
    let targetId: String
    let text: String
    // 可选：JPEG/PNG 的 base64（无 data: 前缀）。经 Mac 剪贴板 + Cmd+V 粘贴进目标应用。
    let image: String?
}

struct ActivateCommand: Decodable {
    let targetId: String
}

struct IconUpload: Decodable {
    let id: String
    let data: String
}

// 手机快捷键按钮：label 显示在按钮上，modifiers/keycode 是 CGEvent 虚拟键码组合。
struct ShortcutConfig: Codable, Equatable {
    var id: String
    var label: String
    var modifiers: [String]
    var keycode: Int
}

enum ShortcutError: Error { case message(String) }

// 快捷键录制 → CGKeyCode 的翻译表（macOS 虚拟键码）。
enum ShortcutKeys {
    // 控制台录制允许的修饰键与主键；主键限功能键与少数安全字符，避免注入文本类按键。
    static let modifierMap: [String: CGEventFlags] = [
        "command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl
    ]
    static let keyMap: [String: CGKeyCode] = [
        "up": 126, "down": 125, "left": 123, "right": 124,
        "return": 36, "delete": 51, "escape": 53, "space": 49, "tab": 48,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]
    static func flags(for modifiers: [String]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, name in
            if let flag = modifierMap[name.lowercased()] { flags.insert(flag) }
        }
    }
    static func code(for key: String) -> CGKeyCode? { keyMap[key.lowercased()] }
}

enum InputError: Error { case message(String) }

// MARK: - 目标应用配置（电脑端为唯一事实来源，顺序与成员都存在本机）

struct TargetConfig: Codable, Equatable {
    var id: String
    var name: String
    var bundleID: String?
    var path: String?
}

final class TargetStore {
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoiceDeck", isDirectory: true)
    static let configFile = supportDirectory.appendingPathComponent("targets.json")
    static let iconDirectory = supportDirectory.appendingPathComponent("icons", isDirectory: true)
    static let defaultTargets: [TargetConfig] = [
        .init(id: "chatgpt", name: "ChatGPT", bundleID: "com.openai.chat", path: "/Applications/ChatGPT.app"),
        .init(id: "feishu", name: "飞书", bundleID: "com.electron.lark", path: "/Applications/Feishu.app"),
        .init(id: "chrome", name: "Chrome", bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app"),
        .init(id: "zcode", name: "ZCode", bundleID: "dev.zcode.app", path: "/Applications/ZCode.app"),
        .init(id: "workbody", name: "Workbody", bundleID: nil, path: "/Applications/Workbody.app"),
        .init(id: "wechat", name: "微信", bundleID: "com.tencent.xinWeChat", path: "/Applications/WeChat.app"),
        .init(id: "uu", name: "UU远程", bundleID: "com.netease.uuremote", path: "/Applications/UURemote.app"),
    ]

    private(set) var targets: [TargetConfig] = TargetStore.defaultTargets

    init() {
        if let data = try? Data(contentsOf: TargetStore.configFile),
           let decoded = try? JSONDecoder().decode([TargetConfig].self, from: data), !decoded.isEmpty {
            targets = decoded
        }
    }

    func save(_ list: [TargetConfig]) {
        targets = list
        try? FileManager.default.createDirectory(at: TargetStore.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: TargetStore.configFile, options: .atomic)
        }
        // 清理已删除目标遗留的自定义图标。
        let live = Set(list.map { $0.id })
        if let files = try? FileManager.default.contentsOfDirectory(atPath: TargetStore.iconDirectory.path) {
            for file in files where file.hasSuffix(".png") && !live.contains(String(file.dropLast(4))) {
                try? FileManager.default.removeItem(at: TargetStore.iconDirectory.appendingPathComponent(file))
            }
        }
    }

    func resolve(_ id: String) -> TargetConfig? { targets.first { $0.id == id } }

    func appURL(_ config: TargetConfig) -> URL? {
        if let path = config.path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bundleID = config.bundleID {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }
        return nil
    }

    func customIconURL(_ id: String) -> URL { TargetStore.iconDirectory.appendingPathComponent("\(id).png") }

    // MARK: 快捷键配置（与目标应用同一支持目录，独立文件）
    static let shortcutFile = supportDirectory.appendingPathComponent("shortcuts.json")
    static let defaultShortcuts: [ShortcutConfig] = [
        .init(id: "undo", label: "撤销", modifiers: ["command"], keycode: 7),   // Cmd+Z
        .init(id: "copy", label: "复制", modifiers: ["command"], keycode: 8),   // Cmd+C
        .init(id: "paste", label: "粘贴", modifiers: ["command"], keycode: 9),  // Cmd+V
    ]

    private(set) var shortcuts: [ShortcutConfig] = TargetStore.defaultShortcuts

    func loadShortcuts() {
        if let data = try? Data(contentsOf: TargetStore.shortcutFile),
           let decoded = try? JSONDecoder().decode([ShortcutConfig].self, from: data) {
            shortcuts = decoded
        }
    }

    func saveShortcuts(_ list: [ShortcutConfig]) {
        shortcuts = list
        try? FileManager.default.createDirectory(at: TargetStore.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: TargetStore.shortcutFile, options: .atomic)
        }
    }
}

// MARK: - 本地应用发现（控制台搜索用）

enum AppDiscovery {
    static var searchRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                home + "/Applications"]
    }

    static func allInstalledApps() -> [(name: String, path: String)] {
        let fm = FileManager.default
        var seen = Set<String>()
        var apps: [(String, String)] = []
        for root in searchRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                guard !seen.contains(path), fm.fileExists(atPath: path) else { continue }
                seen.insert(path)
                apps.append((fm.displayName(atPath: path), path))
            }
        }
        return apps.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    static func search(_ query: String, limit: Int = 50) -> [[String: Any]] {
        let apps = allInstalledApps()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matched = trimmed.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.path.localizedCaseInsensitiveContains(trimmed)
        }
        return matched.prefix(limit).map { ["name": $0.name, "path": $0.path] }
    }

    static func makeID(forName name: String, existing: [TargetConfig]) -> String {
        let base = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : ($0 == " " ? "-" : "") }
            .joined()
        let slug = base.isEmpty ? "app" : String(base.prefix(24))
        var candidate = slug; var counter = 2
        while existing.contains(where: { $0.id == candidate }) {
            candidate = "\(slug)-\(counter)"; counter += 1
        }
        return candidate
    }
}

// MARK: - 网络与渲染工具

enum Util {
    static func primaryLANAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(name: String, ip: String)] = []
        var pointer = ifaddr
        while let current = pointer {
            let interface = current.pointee
            if let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if result == 0 {
                    let ip = String(cString: host)
                    let name = String(cString: interface.ifa_name)
                    if !ip.hasPrefix("127.") { candidates.append((name, ip)) }
                }
            }
            pointer = interface.ifa_next
        }
        let rank = { (name: String) -> Int in
            name.hasPrefix("en") ? Int(name.dropFirst(2)) ?? 50 : 60
        }
        return candidates.sorted { rank($0.name) < rank($1.name) }.first?.ip
    }

    // 稳定主机名：mDNS 的 <计算机名>.local 不随 DHCP 变化，手机保存一次即可长期使用。
    static func stableHost() -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return nil }
        let raw = String(cString: buf).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw != "localhost", !raw.hasSuffix(".") else { return nil }
        return raw.hasSuffix(".local") ? String(raw.dropLast(".local".count)) + ".local" : raw + ".local"
    }

    static func stableURL(_ port: UInt16) -> String? {
        stableHost().map { "http://\($0):\(port)" }
    }

    static func qrPNG(_ text: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let image = NSImage(size: scaled.extent.size)
        image.addRepresentation(NSCIImageRep(ciImage: scaled))
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func appIconPNG(forFile path: String, size: Int = 256) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        // NSWorkspace 默认只给 32px 表示；显式放到目标尺寸让 AppKit 选用 icns 中的大尺寸表示，避免放大发糊。
        icon.size = NSSize(width: size, height: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - 输入执行

final class InputExecutor {
    static let frontmostPseudoId = "__frontmost__"
    private let queue = DispatchQueue(label: "dev.voicedeck.input")
    private let store: TargetStore

    init(store: TargetStore) { self.store = store }

    func activate(_ targetId: String, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async { self.activateTarget(targetId, completion: completion) }
    }

    func send(_ command: SendCommand, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async {
            let hasText = !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasText || command.image != nil else {
                completion(.failure(.message("先输入一点内容或选择一张图片。"))); return
            }
            guard command.text.utf16.count <= 8_000 else {
                completion(.failure(.message("单次文本最多 8,000 个 UTF-16 字符。"))); return
            }
            guard let imageData = command.image.flatMap({ Data(base64Encoded: $0) }), command.image != nil else {
                if command.image != nil {
                    completion(.failure(.message("图片数据无效。"))); return
                }
                // 没有图片字段：走纯文本路径。
                self.dispatchSend(command, imageData: nil, completion: completion)
                return
            }
            guard imageData.count <= 10 * 1024 * 1024 else {
                completion(.failure(.message("图片太大（>10MB）。"))); return
            }
            self.dispatchSend(command, imageData: imageData, completion: completion)
        }
    }

    // 统一执行路径：imageData 非空时先写剪贴板，注入时"粘贴图片 → 文本 → Return"。
    private func dispatchSend(_ command: SendCommand, imageData: Data?, completion: @escaping (Result<Void, InputError>) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(.failure(.message("尚未授予“辅助功能”权限。请在控制台完成授权。"))); return
        }
        // 伪目标：不切换应用，直接注入当前前台（前台是非 Dock 应用时的发送路径）。
        if command.targetId == Self.frontmostPseudoId {
            queue.asyncAfter(deadline: .now() + .milliseconds(80)) {
                self.performPaste(imageData: imageData, text: command.text)
                completion(.success(()))
            }
            return
        }
        activateTarget(command.targetId) { result in
            guard case .success = result else { completion(result); return }
            // 给桌面应用取得前台焦点；后续步骤都在同一串行队列中执行。
            self.queue.asyncAfter(deadline: .now() + .milliseconds(450)) {
                self.performPaste(imageData: imageData, text: command.text)
                completion(.success(()))
            }
        }
    }

    // 注入序列：有图先写剪贴板再 Cmd+V，有文再注入文本，最后 Return。
    // 图片发送后留在剪贴板上（与手动复制粘贴语义一致，不额外清空）。
    private func performPaste(imageData: Data?, text: String) {
        if let imageData, let image = NSImage(data: imageData) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            postKey(9, flags: .maskCommand) // Cmd+V
            usleep(350_000) // 等目标应用完成粘贴读取
        }
        if !text.isEmpty {
            postUnicode(text)
            postKey(36) // Return
        }
    }

    private func activateTarget(_ targetId: String, completion: @escaping (Result<Void, InputError>) -> Void) {
        guard let config = store.resolve(targetId) else {
            completion(.failure(.message("未知的目标应用。"))); return
        }
        guard let url = store.appURL(config) else {
            completion(.failure(.message("未找到 \(config.name)。请确认应用已安装或在控制台重新选择。"))); return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            if let error {
                completion(.failure(.message("无法打开 \(config.name)：\(error.localizedDescription)"))); return
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

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // 快捷键：组合键注入当前前台应用，不切换目标；与 send 共用串行队列。
    func triggerShortcut(_ shortcut: ShortcutConfig, completion: @escaping (Result<Void, ShortcutError>) -> Void) {
        queue.async {
            guard AXIsProcessTrusted() else {
                completion(.failure(.message("尚未授予“辅助功能”权限。请在控制台完成授权。"))); return
            }
            // 录制时已把主键翻译成 macOS 虚拟键码存储；此处直接用，超出范围视为无效。
            guard let key = CGKeyCode(exactly: shortcut.keycode), shortcut.keycode >= 0, shortcut.keycode <= 0x7F else {
                completion(.failure(.message("快捷键主键无效。"))); return
            }
            let flags = ShortcutKeys.flags(for: shortcut.modifiers)
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) {
                down.flags = flags
                up.flags = flags
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                completion(.success(()))
            } else {
                completion(.failure(.message("快捷键事件创建失败。")))
            }
        }
    }
}

// MARK: - HTTP 服务

final class Server {
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

    private func route(headerText: String, body: [UInt8], connection: NWConnection) {
        let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? "/"
        let path = rawPath.components(separatedBy: "?").first ?? rawPath
        let bodyData = Data(body)

        switch (method, path) {
        case ("GET", "/api/status"):
            let stableURL = Util.stableURL(port)
            let lanIP = Util.primaryLANAddress()
            // 前台应用若命中某个已配置目标，手机端选中态会跟随它；未命中则把 frontmostName
            // 交给手机端做"注入当前前台"的伪目标（不切换应用）。
            let frontmost = NSWorkspace.shared.frontmostApplication
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
                "lanURL": (stableURL ?? lanIP.map { "http://\($0):\(port)" }) as Any?,
                "ipURL": lanIP.map { "http://\($0):\(port)" } as Any?,
                "hostName": Util.stableHost() ?? "",
                "frontmostId": frontmostId as Any?,
                "frontmostName": frontmost?.localizedName as Any?,
                "targets": store.targets.map { config in
                    ["id": config.id, "name": config.name, "available": store.appURL(config) != nil,
                     "bundleID": config.bundleID as Any?, "path": config.path as Any?]
                },
                "shortcuts": store.shortcuts.map { shortcut in
                    ["id": shortcut.id, "label": shortcut.label,
                     "modifiers": shortcut.modifiers, "keycode": shortcut.keycode]
                },
            ]
            respond(connection, status: 200, json: payload)
        case ("GET", "/console"), ("GET", "/console.html"):
            serveFile("console.html", connection: connection)
        case ("GET", "/api/qr"):
            // type=ip 生成局域网 IP 地址版二维码；默认生成 .local 主机名版（iOS 可保存为永久地址，
            // 但安卓 Chrome 不解析 mDNS，需用 IP 版）。
            let lanIP = Util.primaryLANAddress()
            let target: String?
            if Self.queryValue("type", in: rawPath) == "ip" {
                target = lanIP.map { "http://\($0):\(port)" }
            } else {
                target = Util.stableURL(port) ?? lanIP.map { "http://\($0):\(port)" }
            }
            guard let url = target, let png = Util.qrPNG(url) else {
                respond(connection, status: 503, json: ["error": "未找到局域网地址，无法生成二维码。"]); return
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
                case .success: self.respond(connection, status: 200, json: ["ok": true])
                case .failure(.message(let message)): self.respond(connection, status: 422, json: ["error": message])
                }
            }
        case ("POST", "/api/shortcuts"):
            // 与 /api/targets 同样的清洗策略：数量上限 + id 去重补齐。
            guard let list = try? JSONDecoder().decode([ShortcutConfig].self, from: bodyData) else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            var seen = Set<String>()
            let cleaned = list.prefix(12).map { entry -> ShortcutConfig in
                var shortcut = entry
                let base = shortcut.id.isEmpty ? "shortcut" : shortcut.id
                if seen.contains(base) || shortcut.id.isEmpty { shortcut.id = base + "-\(seen.count + 1)" }
                shortcut.label = String(shortcut.label.prefix(6))
                seen.insert(shortcut.id)
                return shortcut
            }
            store.saveShortcuts(cleaned)
            respond(connection, status: 200, json: ["ok": true])
        case ("POST", "/api/shortcut-trigger"):
            guard let shortcut = try? JSONDecoder().decode(ShortcutConfig.self, from: bodyData) else {
                respond(connection, status: 400, json: ["error": "请求格式无效。"]); return
            }
            // 以手机存储的配置为准回查一次；查不到就用上报内容原样执行（服务端重启后手机列表是旧数据的场景）。
            let resolved = store.shortcuts.first { $0.id == shortcut.id } ?? shortcut
            executor.triggerShortcut(resolved) { result in
                switch result {
                case .success: self.respond(connection, status: 200, json: ["ok": true])
                case .failure(.message(let message)): self.respond(connection, status: 422, json: ["error": message])
                }
            }
        case ("GET", "/"), ("GET", "/index.html"):
            serveFile("index.html", connection: connection)
        case ("GET", "/app.js"), ("GET", "/style.css"):
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
        if let cached = iconCache["id:" + targetId] {
            respond(connection, status: 200, data: cached, contentType: "image/png"); return
        }
        let customURL = store.customIconURL(targetId)
        let sourcePath: String?
        if FileManager.default.fileExists(atPath: customURL.path), let data = try? Data(contentsOf: customURL) {
            iconCache["id:" + targetId] = data
            respond(connection, status: 200, data: data, contentType: "image/png"); return
        }
        if let config = store.resolve(targetId), let url = store.appURL(config) { sourcePath = url.path } else { sourcePath = nil }
        guard let path = sourcePath, let png = Util.appIconPNG(forFile: path) else {
            respond(connection, status: 404, json: ["error": "图标不可用。"]); return
        }
        iconCache["id:" + targetId] = png
        respond(connection, status: 200, data: png, contentType: "image/png")
    }

    private func respond(_ connection: NWConnection, status: Int, json: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        respond(connection, status: status, data: data, contentType: "application/json; charset=utf-8")
    }

    private func respond(_ connection: NWConnection, status: Int, data: Data, contentType: String) {
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : status == 413 ? "Payload Too Large" : status == 503 ? "Service Unavailable" : "Unprocessable Entity"
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - 触控板指针注入

// 手势命令来自 WebSocket（端口 46388）：
// {"t":"move","dx":..,"dy":..} 相对移动光标；拖动时客户端改发 {"t":"drag"}（左键按住移动）
// {"t":"down"}/{"t":"up"} 左键按下/抬起；{"t":"click","button":"left"|"right"}
// {"t":"scroll","dx":..,"dy":..} 自然滚动（内容跟随手指方向）
// {"t":"zoom","delta":..} 捏合缩放，经 Cmd+滚轮 合成（Chrome/Safari 页面缩放）
final class PointerExecutor {
    private let queue = DispatchQueue(label: "dev.voicedeck.pointer")
    private var position: CGPoint?
    private var dragging = false
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var scrollPhaseActive = false
    private var lastScrollAt: TimeInterval = 0

    // 新的触控板会话（WS 连接建立）时调用：强制抬起可能卡住的左键，避免后续点击失效。
    func resetSession() {
        queue.async {
            if self.dragging {
                self.dragging = false
                self.post(.leftMouseUp, at: self.currentPosition())
            }
            self.scrollPhaseActive = false
        }
    }

    private func currentPosition() -> CGPoint {
        if let position { return position }
        let current = CGEvent(source: nil)?.location ?? CGPoint(x: 600, y: 400)
        position = current
        return current
    }

    // 所有活动显示器的包围盒：双屏时光标可以跨屏移动。
    private func clamped(_ point: CGPoint) -> CGPoint {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        var bounds = CGRect.null
        for i in 0..<Int(count) { bounds = bounds.union(CGDisplayBounds(ids[i])) }
        if bounds.isNull { bounds = CGDisplayBounds(CGMainDisplayID()) }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                       y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clickState: Int64 = 1) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        // 显式标记 clickState：Electron/Chromium 系应用会丢弃未带按下次数的合成点击（表现为点不动、无法聚焦）。
        event?.setIntegerValueField(.mouseEventClickState, value: clickState)
        event?.post(tap: .cghidEventTap)
    }

    func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        queue.async { self.apply(command) }
    }

    private func apply(_ command: [String: Any]) {
        let type = command["t"] as? String ?? ""
        let dx = command["dx"] as? Double ?? 0
        let dy = command["dy"] as? Double ?? 0
        switch type {
        case "move", "drag":
            let next = clamped(CGPoint(x: currentPosition().x + dx, y: currentPosition().y + dy))
            position = next
            if dragging || type == "drag" {
                if !dragging { dragging = true; post(.leftMouseDown, at: next) }
                post(.leftMouseDragged, at: next)
            } else {
                post(.mouseMoved, at: next)
            }
        case "down":
            dragging = true
            post(.leftMouseDown, at: currentPosition())
        case "up":
            guard dragging else { return }
            dragging = false
            post(.leftMouseUp, at: currentPosition())
        case "click":
            let right = (command["button"] as? String) == "right"
            let button: CGMouseButton = right ? .right : .left
            let count = min(3, max(1, command["count"] as? Int ?? 1))
            let point = currentPosition()
            // 按下与抬起间隔 40ms，双击按真实系统的 clickState 1→2 序列注入。
            for i in 1...count {
                let base = Double(i - 1) * 0.12
                let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
                let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
                queue.asyncAfter(deadline: .now() + base) { [weak self] in
                    guard let self else { return }
                    self.post(down, at: point, button: button, clickState: Int64(i))
                    self.queue.asyncAfter(deadline: .now() + 0.04) {
                        self.post(up, at: point, button: button, clickState: Int64(i))
                    }
                }
            }
        case "scroll":
            // 像素级平滑滚动；小数残差留在服务端累积，避免高频小位移被取整吞掉。
            let totalX = scrollRemainder.x + dx
            let totalY = scrollRemainder.y + dy
            let wheelX = Int32(round(totalX))
            let wheelY = Int32(round(totalY))
            scrollRemainder = (totalX - Double(wheelX), totalY - Double(wheelY))
            guard wheelX != 0 || wheelY != 0 else { return }
            let now = Date().timeIntervalSince1970
            let began = !scrollPhaseActive || (now - lastScrollAt) > 0.15
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: wheelY, wheel2: wheelX, wheel3: 0) {
                // 滚动相位让 Chrome/Safari 按触控板式直接位移处理，而不是逐格滚轮动画，消除迟滞。
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: began ? 1 : 2)
                event.post(tap: .cghidEventTap)
            }
            scrollPhaseActive = true
            lastScrollAt = now
        case "scrollEnd":
            guard scrollPhaseActive else { return }
            scrollPhaseActive = false
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: 0, wheel2: 0, wheel3: 0) {
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4) // ended
                event.post(tap: .cghidEventTap)
            }
        case "zoom":
            let delta = command["delta"] as? Double ?? 0
            let wheel = Int32(round(delta * 8))
            guard wheel != 0 else { return }
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: wheel, wheel2: 0, wheel3: 0) {
                event.flags = .maskCommand
                event.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }
}

// MARK: - 触控板 WebSocket 服务

final class WSServer {
    private let port: UInt16
    private let pointer: PointerExecutor
    private let queue = DispatchQueue(label: "dev.voicedeck.ws")
    private var listener: NWListener?

    init(port: UInt16, pointer: PointerExecutor) {
        self.port = port
        self.pointer = pointer
    }

    func start() throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { fputs("触控板通道失败：\(error)\n", stderr) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        pointer.resetSession() // 新会话：抬起可能残留的左键，防止点击失灵
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, let context,
               context.protocolMetadata(definition: NWProtocolWebSocket.definition) is NWProtocolWebSocket.Metadata,
               let text = String(data: data, encoding: .utf8) {
                self.pointer.handle(text)
            }
            if error == nil { self.receive(connection) } else { connection.cancel() }
        }
    }
}

// MARK: - 启动

// 正式应用身份：Dock 显示图标；点击 Dock 图标（reopen 事件）即打开控制台。
final class AppDelegate: NSObject, NSApplicationDelegate {
    let consoleURL: URL
    init(consoleURL: URL) { self.consoleURL = consoleURL }

    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSWorkspace.shared.open(consoleURL)
        return true
    }
}

let executableDirectory = URL(fileURLWithPath: CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath).deletingLastPathComponent()
let bundledWebRoot = executableDirectory.deletingLastPathComponent().appendingPathComponent("Resources/Web")
let root = FileManager.default.fileExists(atPath: bundledWebRoot.appendingPathComponent("index.html").path)
    ? bundledWebRoot.deletingLastPathComponent()
    : executableDirectory
let defaultPort: UInt16 = 46387
let selectedPort = UInt16(ProcessInfo.processInfo.environment["VOICE_DECK_PORT"] ?? "") ?? defaultPort
let targetStore = TargetStore()
targetStore.loadShortcuts()
let server = Server(port: selectedPort, webRoot: root.appendingPathComponent("Web"), store: targetStore)
// 首次启动时让 macOS 显示其官方授权提示；授权决定仍完全由用户控制。
let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(promptOptions)
try server.start()
let pointerExecutor = PointerExecutor()
let wsPort: UInt16 = 46388
let wsServer = WSServer(port: wsPort, pointer: pointerExecutor)
try? wsServer.start()
let consoleURL = URL(string: "http://localhost:\(selectedPort)/console")!
print("PocketDesk 已启动。控制台：\(consoleURL.absoluteString)（触控板通道 ws:\(wsPort)）")
// 首次运行或尚未授权时，自动打开电脑端控制台引导流程。
let firstRun = !FileManager.default.fileExists(atPath: TargetStore.configFile.path)
if firstRun || !AXIsProcessTrusted() { NSWorkspace.shared.open(consoleURL) }
let application = NSApplication.shared
let launcherDelegate = AppDelegate(consoleURL: consoleURL)
application.delegate = launcherDelegate
application.setActivationPolicy(.regular)
application.run()
