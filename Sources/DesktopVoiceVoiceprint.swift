/**
 * [INPUT]: 本机回环的声纹桥进程（scripts/voiceprint.py + 独立 Python 环境 + 注册画像）、16kHz 单声道 Float32 音频。
 * [OUTPUT]: 是否已注册、注册一条样本、按段校验的相似度与判定，以及桥的按需启动与失败退避。
 * [POS]: 声纹层的本机进程边界；模型与阈值判断留在 Python 侧，Swift 只说“这段音频像不像已注册的人”。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum DesktopVoiceVoiceprint {
    /// 46387 HTTP、46388 控制 WS、46389 画面 WS、46390 神经音色桥都不复用。
    static let port: Int = Int(ProcessInfo.processInfo.environment["POCKETDESK_VOICEPRINT_PORT"] ?? "") ?? 46391
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/VoiceDeck/voiceprint", isDirectory: true)

    static var pythonPath: String {
        ProcessInfo.processInfo.environment["POCKETDESK_VOICEPRINT_PYTHON"] ?? directory.appendingPathComponent("venv/bin/python").path
    }
    static var scriptPath: String? {
        if let path = ProcessInfo.processInfo.environment["POCKETDESK_VOICEPRINT_SCRIPT"] { return path }
        return Bundle.main.resourceURL?.appendingPathComponent("Voiceprint/voiceprint.py").path
    }
    static var modelPath: String { directory.appendingPathComponent("speaker-encoder.onnx").path }
    static var profilePath: String { directory.appendingPathComponent("profile.json").path }
    /// 画像在不在，不依赖桥：桥起不来时这道门也不能自动变成“没有门”。
    static var hasProfile: Bool { FileManager.default.fileExists(atPath: profilePath) }
    static var ready: Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath)
            && scriptPath.map { FileManager.default.fileExists(atPath: $0) } == true
            && FileManager.default.fileExists(atPath: modelPath)
    }

    private static let lock = NSLock()
    private static var process: Process?
    private static var starting = false
    private static var backoffUntil: Date = .distantPast
    private(set) static var lastError = ""

    private static func call(_ method: String, _ path: String, body: Data? = nil, label: String? = nil,
                             timeout: TimeInterval) -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("close", forHTTPHeaderField: "Connection")
        if let label { request.setValue(label, forHTTPHeaderField: "X-Voiceprint-Label") }
        if let body {
            request.httpBody = body
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        var result: [String: Any]?
        var failure: String?
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { failure = "声纹服务请求失败：" + error.localizedDescription }
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { result = json }
            else if let data, !data.isEmpty, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                failure = json["error"] as? String ?? "声纹服务返回异常"
            }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + timeout + 0.5) == .timedOut { return nil }
        lock.lock()
        lastError = result != nil ? "" : (failure ?? "声纹服务没有返回结果")
        lock.unlock()
        return result
    }

    /// 进程只在需要时拉起一次；失败后退避 30 秒，避免每次都重启一个必然失败的进程。
    static func ensureRunning() {
        lock.lock()
        let busy = starting
        if !busy { starting = true }
        lock.unlock()
        guard !busy else { return }
        defer { lock.lock(); starting = false; lock.unlock() }
        if call("GET", "/health", timeout: 1) != nil { return }
        guard ready, Date() >= backoffUntil else { return }
        if let process, process.isRunning { return }
        guard let scriptPath else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: pythonPath)
        child.arguments = ["-I", "-B", scriptPath, "--serve", "--port", "\(port)"]
        child.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch {
            lastError = "声纹服务未能启动"
            backoffUntil = Date().addingTimeInterval(30)
            return
        }
        process = child
        // 首次启动要加载模型，给足时间；超时后退避，不拖住主线程。
        for _ in 0..<120 {
            if call("GET", "/health", timeout: 1) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        lastError = "声纹服务启动超时"
        backoffUntil = Date().addingTimeInterval(30)
    }

    /// 16kHz 单声道 Float32 → 小端字节流，作为注册/校验的请求体。
    static func pcm(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 4)
        for value in samples {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func health() -> [String: Any]? {
        ensureRunning()
        return call("GET", "/health", timeout: 4)
    }

    @discardableResult static func enroll(_ samples: [Float], label: String) -> [String: Any]? {
        guard samples.count >= 16000 else { return nil }
        ensureRunning()
        return call("POST", "/enroll", body: pcm(samples), label: label, timeout: 20)
    }

    static func verify(_ samples: [Float]) -> [String: Any]? {
        guard samples.count >= 16000 else { return nil }
        ensureRunning()
        return call("POST", "/verify", body: pcm(samples), timeout: 12)
    }

    @discardableResult static func clear() -> Bool {
        ensureRunning()
        return call("DELETE", "/profile", timeout: 6) != nil
    }

    static var diagnostics: [String: Any] {
        ["ready": ready, "port": port, "lastError": lastError, "model": FileManager.default.fileExists(atPath: modelPath)]
    }
}
