/**
 * [INPUT]: 依赖 AppKit 的 NSApplication/NSWorkspace 与 Foundation 的 FileManager/ProcessInfo；消费 TargetStore/Server/WSServer/FrameServer/PointerExecutor 的装配。
 * [OUTPUT]: 对外提供 PocketDesk 启动引导：web 根目录定位、端口选择（VOICE_DECK_PORT 环境变量）、辅助功能授权提示、HTTP、控制与独立画面服务启动与 Dock 应用身份（AppDelegate）。
 * 安全边界：锁屏密码仅走 HTTPS 专用执行器，普通输入在锁屏时受阻；安全监听共享原控制租约。
 * [POS]: Sources 的唯一入口与组装根；其余文件都是可独立理解的职责模块，本文件不再包含任何业务逻辑。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

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

/// 卡死自愈看门狗。
///
/// TLS 私钥已在内存中装配（全程不进钥匙串），原先"钥匙串上锁 → 取私钥永久阻塞"的场景不复存在；
/// 这层保留为兜底：任何让网络工作线程停住的原因都会让 HTTPS、HTTP、心跳、画面一起静默停摆，
/// 而进程看起来还好好的、端口也还在监听，用户只会看到"一直连不上/不同步"。主线程此时是空闲的，
/// 所以由它周期性地戳自己的 HTTP 端口。
///
/// 三条硬约束（缺一条都会把"自愈"变成"制造事故"）：
/// 1. 只有**连续多次独立探测**都失败才重启——单次超时在局域网抖动、系统负载高时都会出现；
/// 2. 提交、图片粘贴、草稿写入进行中**绝不重启**：这些事务不可重放，杀进程等于让用户以为发了、其实没发；
/// 3. 单实例交接：先写交接标记再让新实例等旧进程真的退出，避免两个实例抢端口、或端口空窗。
final class ServerWatchdog {
    private static var timer: Timer?
    private static var failures = 0
    private static let interval: TimeInterval = 10
    private static let requestTimeout: TimeInterval = 4
    /// 3 × 10 秒 = 连续 30 秒健康探测失败才认定公共服务线程失活。
    private static let toleratedFailures = 3
    /// 输入静默期：最近一次输入事务结束后还要再等这么久，确保键盘事件、粘贴、Return 都已发完。
    private static let quietWindow: TimeInterval = 3
    private static var handoffMarker: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("VoiceDeck/server-watchdog-handoff.json")
    }

    static func start(port: UInt16) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/status") else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            var request = URLRequest(url: url)
            request.timeoutInterval = requestTimeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            URLSession.shared.dataTask(with: request) { _, response, _ in
                let healthy = (response as? HTTPURLResponse)?.statusCode == 200
                DispatchQueue.main.async { record(healthy: healthy) }
            }.resume()
        }
    }

    private static func record(healthy: Bool) {
        guard !healthy else { failures = 0; return }
        failures += 1
        guard failures >= toleratedFailures else { return }
        // 不健康但正在写输入：推迟，并立刻排下一次探测（把计数压回阈值前一格）。
        guard InputActivity.shared.quiet(for: quietWindow) else { failures = toleratedFailures - 1; return }
        failures = 0
        relaunch()
    }

    /// 先让一个新实例起来，再退出自己：直接自杀会让端口在无人接管时一直空着。
    /// 交接标记里写下自己的 PID，新实例启动时会等它真的消失再绑定端口——否则两个实例会抢端口。
    private static func relaunch() {
        if let marker = handoffMarker {
            try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            let payload = ["pid": Int(getpid()), "at": Date().timeIntervalSince1970] as [String: Any]
            try? JSONSerialization.data(withJSONObject: payload).write(to: marker, options: .atomic)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; exec /usr/bin/open -a \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        exit(0)
    }

    /// 新实例在绑定端口前调用：若上一次自愈交接还没结束，等旧进程退出（有上限），再开始监听。
    /// 上限到了也继续启动——宁可冒一次端口冲突，也不要让服务永远起不来。
    static func awaitHandoff() {
        guard let marker = handoffMarker, let data = try? Data(contentsOf: marker),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = payload["pid"] as? Int, pid > 0 else { return }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if kill(pid_t(pid), 0) != 0 { break }   // ESRCH：旧进程已经退出
            usleep(200_000)
        }
        try? FileManager.default.removeItem(at: marker)
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
targetStore.loadTheme()
// 上一次自愈交接若还没收尾，先等旧进程退出再绑定端口：两个实例同时监听只会有一个成功，
// 而失败的那个会静默地什么也不做。
ServerWatchdog.awaitHandoff()
let server = Server(port: selectedPort, webRoot: root.appendingPathComponent("Web"), store: targetStore)
// 首次启动时让 macOS 显示其官方授权提示；授权决定仍完全由用户控制。
let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(promptOptions)
try server.start()
// 启动即生成配对 token（懒加载在此刻触发落盘），QR 与写请求校验都依赖它。
_ = Auth.token
let pointerExecutor = PointerExecutor()
// 应用选择后的鼠标就位由 Server 编排，但注入必须走 PointerExecutor（与其它指针命令同一条队列）。
server.pointerExecutor = pointerExecutor
let cursorMonitor = CursorMonitor()
let wsPort: UInt16 = selectedPort < 65534 ? selectedPort + 1 : 46388
let wsServer = WSServer(port: wsPort, pointer: pointerExecutor, cursor: cursorMonitor)
server.controlAuthorized = { [weak wsServer] session in wsServer?.isController(session) == true }
try? wsServer.start()
let secureTransport = try? SecureTransport()
if let secureTransport { try server.startSecure(secureTransport); try wsServer.startSecure(secureTransport) }
_ = LockScreenInput.shared
var frameService: AnyObject?
if #available(macOS 14.0, *) {
    let frames = FrameServer(port: selectedPort < 65534 ? selectedPort + 2 : 46389)
    try? frames.start()
    if let secureTransport { try frames.startSecure(secureTransport) }
    frameService = frames
}
// 服务都起来之后再看门：网络工作线程被 securityd 占死时，由主线程把 App 重启回来。
ServerWatchdog.start(port: selectedPort)
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
