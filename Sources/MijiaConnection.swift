/**
 * [INPUT]: MijiaLoginProcess 的限时事件、MijiaBridge 的只读账号核验、MijiaHomeScope 的账号替换互斥、Util 本地二维码与私有凭证目录。
 * [OUTPUT]: 串行扫码状态、短期二维码和显式刷新/取消；新账号核验成功后原子替换凭证，旧会话永不回写。
 * [POS]: 电脑控制台米家连接协调器；与小精灵共享正式 auth.json，网络和依赖安装都在后台执行。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin

final class MijiaConnection {
    struct Dependencies {
        var authURL = URL(fileURLWithPath: MijiaBridge.authPath)
        var python = MijiaBridge.pythonPath
        var helper = MijiaBridge.helperPath ?? ""
        var installer = Bundle.main.resourceURL?.appendingPathComponent("Mijia/setup-mijia.sh").path ?? ""
        var now: () -> Date = Date.init
        var qr: (String) -> Data? = Util.qrPNG
        var launch: (String, [String], TimeInterval, @escaping ([String: Any]) -> Void, @escaping (Int32) -> Void) -> MijiaCancellable = {
            MijiaLoginProcess.start(executable: $0, arguments: $1, timeout: $2, event: $3, completion: $4)
        }
        var verify: (String, @escaping (Result<[String: Any], MijiaBridge.Failure>) -> Void) -> Void = { path, done in
            DispatchQueue.global(qos: .utility).async { done(MijiaBridge.run(["operation": "status"], authPath: path)) }
        }
    }
    static let shared = MijiaConnection()
    private let dependencies: Dependencies
    private let queue = DispatchQueue(label: "dev.voicedeck.mijia-connection")
    private var initialized = false
    private var generation = UUID()
    private var job: MijiaCancellable?
    private var state = "unconfigured"
    private var message = "连接米家后，可以让小精灵查询和控制家中设备。"
    private var sessionId: String?
    private var expiresAt: TimeInterval?
    private var checkedAt: TimeInterval?
    private var qrData: Data?
    private var revision = 0
    private var knownConnected = false
    private var stagingDirectory: URL?
    private var completedEvent = false
    private var terminalEvent = false
    private var runtimeReady = false
    private var loginRunning = false
    private var busy: Bool { ["installing", "starting", "waiting", "authorizing"].contains(state) }
    private var hasCredentials: Bool { FileManager.default.fileExists(atPath: dependencies.authURL.path) }

    init(dependencies: Dependencies = Dependencies()) { self.dependencies = dependencies }

    func status() -> [String: Any] {
        queue.sync {
            if !initialized { initialized = true; if hasCredentials { checkAccount() } }
            expireIfNeeded(); return snapshot()
        }
    }

    func check() -> [String: Any] {
        queue.sync { initialized = true; expireIfNeeded(); if !busy && state != "checking" { checkAccount() }; return snapshot() }
    }

    func connect() -> [String: Any] {
        queue.sync {
            initialized = true; invalidate()
            let id = UUID(); generation = id; sessionId = id.uuidString
            do {
                let parent = dependencies.authURL.deletingLastPathComponent()
                try Self.privateDirectory(parent)
                let staging = parent.appendingPathComponent("login-" + id.uuidString, isDirectory: true)
                try Self.privateDirectory(staging); stagingDirectory = staging
                transition("starting", "正在准备米家登录二维码…")
                checkRuntime(id, canInstall: true)
            } catch { fail("failed", "无法准备米家连接目录，请检查电脑存储权限后重试。") }
            return snapshot()
        }
    }

    func cancel(session: String) -> [String: Any]? {
        queue.sync {
            guard sessionId == session else { return nil }
            invalidate()
            transition(knownConnected ? "connected" : "unconfigured", hasCredentials ? "已取消扫码，原有米家连接已保留。" : "已取消扫码，可随时重新连接。")
            return snapshot()
        }
    }

    func qr(session: String) -> Data? {
        queue.sync { expireIfNeeded(); return sessionId == session && state == "waiting" ? qrData : nil }
    }

    private func snapshot() -> [String: Any] {
        var value: [String: Any] = ["state": state, "message": message, "hasCredentials": hasCredentials,
            "qrReady": qrData != nil && state == "waiting", "revision": revision]
        if let sessionId { value["sessionId"] = sessionId }
        if let expiresAt { value["expiresAt"] = expiresAt }
        if let checkedAt { value["checkedAt"] = checkedAt }
        return value
    }
    private func transition(_ state: String, _ message: String) {
        self.state = state; self.message = message; revision += 1
    }
    private func invalidate() {
        generation = UUID(); job?.cancel(); job = nil
        // 工作进程退出回调负责清理旧目录，避免取消与子进程最后一次写盘竞争。
        if !loginRunning, let directory = stagingDirectory { try? FileManager.default.removeItem(at: directory) }
        stagingDirectory = nil; qrData = nil; expiresAt = nil; sessionId = nil
        completedEvent = false; terminalEvent = false; loginRunning = false
    }
    private func expireIfNeeded() {
        if state == "waiting", let expiresAt, expiresAt <= dependencies.now().timeIntervalSince1970 {
            fail("expired", "二维码已过期，请刷新后重新扫码。")
        }
    }
    private func fail(_ state: String, _ message: String) {
        invalidate(); transition(state, message + (hasCredentials ? " 原有授权已保留。" : ""))
    }

    private func checkAccount() {
        guard hasCredentials else { knownConnected = false; transition("unconfigured", "连接米家后，可以让小精灵查询和控制家中设备。"); return }
        generation = UUID(); let id = generation
        transition("checking", "正在检查米家连接…")
        dependencies.verify(dependencies.authURL.path) { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self, generation == id else { return }
                checkedAt = dependencies.now().timeIntervalSince1970
                switch result {
                case .success(let data) where data["authenticated"] as? Bool == true:
                    knownConnected = true; transition("connected", "米家账号已连接，设备控制以已保存的家庭范围为准。")
                case .failure(let error) where error.kind == "auth":
                    knownConnected = false; transition("unconfigured", "米家授权已失效，请重新扫码连接。")
                default:
                    knownConnected = false; transition("failed", "暂时无法确认米家连接，请检查网络后重试。")
                }
            }
        }
    }

    private func checkRuntime(_ id: UUID, canInstall: Bool) {
        runtimeReady = false
        job = dependencies.launch(dependencies.python, ["-I", "-B", dependencies.helper, "--check-runtime"], 20, { [weak self] event in
            self?.queue.async { [weak self] in
                guard let self, generation == id else { return }
                runtimeReady = event["ok"] as? Bool == true && event["sdk_version"] as? String == "5.0.0"
            }
        }, { [weak self] code in
            self?.queue.async { [weak self] in
                guard let self, generation == id else { return }
                job = nil
                if code == 0 && runtimeReady { startLogin(id) }
                else if canInstall { installRuntime(id) }
                else { fail("failed", "米家连接组件准备失败，请检查网络及本机 uv 安装后重试。") }
            }
        })
    }
    private func installRuntime(_ id: UUID) {
        guard !dependencies.installer.isEmpty else { fail("failed", "米家连接组件缺失，请重新安装 PocketDesk。 "); return }
        transition("installing", "首次连接正在准备米家组件，可能需要一两分钟…")
        job = dependencies.launch("/bin/zsh", [dependencies.installer, "--no-login"], 180, { _ in }, { [weak self] code in
            self?.queue.async { [weak self] in
                guard let self, generation == id else { return }
                job = nil
                if code == 0 { transition("starting", "正在生成米家登录二维码…"); checkRuntime(id, canInstall: false) }
                else { fail("failed", "米家组件安装失败，请检查网络及本机 uv 安装后重试。") }
            }
        })
    }
    private func startLogin(_ id: UUID) {
        guard let directory = stagingDirectory else { fail("failed", "无法准备米家连接，请重试。"); return }
        let auth = directory.appendingPathComponent("auth.json")
        loginRunning = true
        job = dependencies.launch(dependencies.python, ["-I", "-B", dependencies.helper, "--auth", auth.path, "--login-events"], 160,
            { [weak self] event in self?.queue.async { [weak self] in self?.receive(event, id: id) } },
            { [weak self] code in
                self?.queue.async { [weak self] in
                    guard let self else { try? FileManager.default.removeItem(at: directory); return }
                    guard generation == id else { try? FileManager.default.removeItem(at: directory); return }
                    job = nil; loginRunning = false
                    guard code == 0 && completedEvent else {
                        try? FileManager.default.removeItem(at: directory)
                        fail("failed", "扫码连接未完成，请刷新二维码重试。"); return
                    }
                    verifyAndCommit(auth, id: id)
                }
            })
    }
    private func receive(_ event: [String: Any], id: UUID) {
        guard generation == id, !terminalEvent else { return }
        switch event["event"] as? String {
        case "qr":
            guard state == "starting", let link = event["login_url"] as? String, Self.validLoginURL(link),
                  let png = dependencies.qr(link) else { fail("failed", "无法生成有效的米家二维码，请重试。"); return }
            qrData = png; expiresAt = dependencies.now().timeIntervalSince1970 + 120
            transition("waiting", "用米家 App 扫码，并在手机上确认。")
            queue.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, generation == id else { return }; expireIfNeeded()
            }
        case "complete":
            guard state == "waiting" else { fail("failed", "米家授权步骤不完整，请重新扫码。"); return }
            expireIfNeeded(); guard generation == id else { return }
            completedEvent = true; terminalEvent = true; qrData = nil; expiresAt = nil
            transition("authorizing", "已收到扫码确认，正在验证并保存米家连接…")
        case "error":
            let expired = event["kind"] as? String == "expired"
            fail(expired ? "expired" : "failed", expired ? "二维码已过期，请刷新后重新扫码。" : "米家授权未完成，请检查网络后重新扫码。")
        default: fail("failed", "米家登录返回异常，请重新扫码。")
        }
    }
    private func verifyAndCommit(_ auth: URL, id: UUID) {
        dependencies.verify(auth.path) { [weak self] result in
            self?.queue.async { [weak self] in
                guard let self, generation == id else { try? FileManager.default.removeItem(at: auth.deletingLastPathComponent()); return }
                guard case .success(let data) = result, data["authenticated"] as? Bool == true else {
                    fail("failed", "扫码后未能确认账号连接，请检查网络后重试。"); return
                }
                // 等待设备执行锁不能占住连接队列：取消/刷新必须能先作废代际。
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    defer { try? FileManager.default.removeItem(at: auth.deletingLastPathComponent()) }
                    MijiaHomeScope.shared.withAccountReplacement {
                        self?.queue.sync { [weak self] in
                            guard let self, generation == id else { return }
                            do {
                                try Self.commit(auth, to: dependencies.authURL)
                                stagingDirectory = nil; qrData = nil; expiresAt = nil; sessionId = nil
                                knownConnected = true; checkedAt = dependencies.now().timeIntervalSince1970
                                transition("connected", "米家账号已连接，设备控制以已保存的家庭范围为准。")
                            } catch { fail("failed", "米家授权未能保存，请检查电脑存储权限后重试。") }
                        }
                    }
                }
            }
        }
    }
    static func validLoginURL(_ text: String) -> Bool {
        guard text.count <= 8192, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              let url = URLComponents(string: text) else { return false }
        let host = (url.host ?? "").lowercased()
        let xiaomiAccount = host == "account.xiaomi.com" || host.hasSuffix(".account.xiaomi.com")
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let dnsHost = host.count <= 253 && labels.allSatisfy { String($0).range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil }
        let authority = text.dropFirst(8).prefix { $0 != "/" && $0 != "?" && $0 != "#" }.lowercased()
        return text.hasPrefix("https://") && xiaomiAccount && dnsHost && authority == host && url.port == nil
            && url.user == nil && url.password == nil && url.fragment == nil
            && url.path == "/longPolling/login" && !(url.query ?? "").isEmpty
    }
    private static func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteNoPermission) }
        } else { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private static func commit(_ source: URL, to target: URL) throws {
        let fm = FileManager.default, attrs = try fm.attributesOfItem(atPath: source.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue & 0o777 == 0o600,
              let size = attrs[.size] as? NSNumber, size.intValue > 0 && size.intValue < 65536 else { throw CocoaError(.fileWriteNoPermission) }
        if fm.fileExists(atPath: target.path), try fm.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType != .typeRegular {
            throw CocoaError(.fileWriteNoPermission)
        }
        // 同一私有父目录内 rename 原子替换；读设备的进程只会取得完整旧版或新版。
        guard rename(source.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
