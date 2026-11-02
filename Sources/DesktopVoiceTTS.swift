/**
 * [INPUT]: 本机回环的 TTS 桥进程（scripts/tts-say.py + 独立 Python 环境）、控制台选定的音色与语速档位。
 * [OUTPUT]: 可直接播放的音频字节、中文音色清单，以及桥的按需启动与失败退避。
 * [POS]: 发声层的本机进程边界；协议与鉴权细节留在 Python 侧，Swift 只按「给我这句话的音频」办事。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum DesktopVoiceTTS {
    /// 46388 是控制/光标 WebSocket（HTTP 端口 +1），音色桥必须另占一个口，
    /// 否则两条服务靠 IPv4/IPv6 分别绑定才勉强共存，撞上就表现为“音色服务不可用”。
    static let port: Int = Int(ProcessInfo.processInfo.environment["POCKETDESK_TTS_PORT"] ?? "") ?? 46390
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/VoiceDeck/tts", isDirectory: true)

    static var pythonPath: String {
        ProcessInfo.processInfo.environment["POCKETDESK_TTS_PYTHON"] ?? directory.appendingPathComponent("venv/bin/python").path
    }
    static var scriptPath: String? {
        if let path = ProcessInfo.processInfo.environment["POCKETDESK_TTS_SCRIPT"] { return path }
        return Bundle.main.resourceURL?.appendingPathComponent("TTS/tts-say.py").path
    }
    static var ready: Bool {
        FileManager.default.isExecutableFile(atPath: pythonPath) && scriptPath.map { FileManager.default.fileExists(atPath: $0) } == true
    }

    private static let lock = NSLock()
    private static var process: Process?
    private static var starting = false
    private static var backoffUntil: Date = .distantPast
    private static var frozen: [[String: Any]]?
    private(set) static var lastError = ""

    private static func request(_ path: String, timeout: TimeInterval) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("close", forHTTPHeaderField: "Connection")
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                lock.lock(); lastError = "音色服务请求失败：" + error.localizedDescription; lock.unlock()
            }
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { result = data }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 0.5) == .timedOut { task.cancel(); return nil }
        return result
    }

    /// 进程只在需要时拉起一次；失败后退避 30 秒，避免每次唤醒都重启一个必然失败的进程。
    static func ensureRunning() {
        lock.lock()
        let busy = starting
        if !busy { starting = true }
        lock.unlock()
        guard !busy else { return }
        defer { lock.lock(); starting = false; lock.unlock() }
        if request("/health", timeout: 1) != nil { return }
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
            lastError = "音色服务未能启动"
            backoffUntil = Date().addingTimeInterval(30)
            return
        }
        process = child
        for _ in 0..<40 {
            if request("/health", timeout: 1) != nil { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        lastError = "音色服务启动超时"
        backoffUntil = Date().addingTimeInterval(30)
    }

    /// 一句话的音频；失败返回 nil，由调用方退化成系统音色，绝不静默。
    static func audio(_ text: String, voice: String, rate: String, pitch: String) -> Data? {
        var components = URLComponents()
        components.path = "/say"
        components.queryItems = [URLQueryItem(name: "text", value: text), URLQueryItem(name: "voice", value: voice),
                                 URLQueryItem(name: "rate", value: rate), URLQueryItem(name: "pitch", value: pitch)]
        guard let query = components.percentEncodedQuery else { return nil }
        // URLQueryItem 不转义「+」，而查询串里的「+」会被当成空格，语速档位就会变成「 8%」而被拒。
        let encoded = query.replacingOccurrences(of: "+", with: "%2B")
        ensureRunning()
        guard let data = request("/say?" + encoded, timeout: 10), data.count > 512 else {
            if lastError.isEmpty { lastError = "音色服务没有返回音频" }
            return nil
        }
        lock.lock(); lastError = ""; lock.unlock()
        return data
    }

    /// 控制台下拉用的音色清单：先给一份固定候选，桥就绪后在后台换成服务端的最新列表。
    static func voices() -> [[String: Any]] {
        lock.lock()
        let known = frozen
        lock.unlock()
        if let known { return known }
        DispatchQueue.global(qos: .utility).async {
            ensureRunning()
            guard let data = request("/voices", timeout: 4),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !list.isEmpty else { return }
            lock.lock(); frozen = list; lock.unlock()
        }
        return labeled
    }

    static let labeled: [[String: Any]] = [
        ["id": "zh-CN-XiaoxiaoNeural", "name": "温柔姐姐", "hint": "温暖、稳，适合日常对话"],
        ["id": "zh-CN-XiaoyiNeural", "name": "活泼少女", "hint": "轻快、动漫感"],
        ["id": "zh-CN-liaoning-XiaobeiNeural", "name": "东北小北", "hint": "俏皮、有性格"],
        ["id": "zh-CN-shaanxi-XiaoniNeural", "name": "陕西小妮", "hint": "利落、方言味"],
        ["id": "zh-TW-HsiaoChenNeural", "name": "台湾小臻", "hint": "软糯、轻"],
        ["id": "zh-HK-HiuMaanNeural", "name": "粤语小曼", "hint": "粤语女声"],
    ]
}
