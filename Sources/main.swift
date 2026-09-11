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

    // 正常退出时带走本进程的临时钥匙串与密码文件，不在用户机器上留残留（强杀时由下次启动的过期清理兜底）。
    func applicationWillTerminate(_ notification: Notification) {
        SecureTransport.teardown()
    }
}

/// 卡死自愈看门狗。
///
/// Network.framework 的 TLS 握手取私钥**没有超时**：securityd 一旦让这次取用停住（钥匙串被重新上锁后
/// 需要用户授权、securityd 自己重启等），整条网络工作线程会被永久占死——HTTPS、HTTP、心跳、画面
/// 一起静默停摆，而进程看起来还好好的、端口也还在监听，用户只会看到"一直连不上/不同步"。
/// 主线程此时是空闲的，所以由它每 10 秒戳一次自己的 HTTP 端口；连续两次拿不到 200 就重启 App——
/// 重启会重建一个全新的、已解锁的临时钥匙串，通常半分钟内恢复。
final class ServerWatchdog {
    private static var timer: Timer?
    private static var failures = 0
    private static let interval: TimeInterval = 10
    private static let requestTimeout: TimeInterval = 4
    private static let toleratedFailures = 2

    static func start(port: UInt16) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/status") else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            var request = URLRequest(url: url)
            request.timeoutInterval = requestTimeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            URLSession.shared.dataTask(with: request) { _, response, _ in
                let healthy = (response as? HTTPURLResponse)?.statusCode == 200
                DispatchQueue.main.async {
                    guard !healthy else { failures = 0; return }
                    failures += 1
                    guard failures >= toleratedFailures else { return }
                    failures = 0
                    relaunch()
                }
            }.resume()
        }
    }

    /// 先让一个新实例起来，再退出自己：直接自杀会让端口在无人接管时一直空着。
    private static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; exec /usr/bin/open -a \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        exit(0)
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
let server = Server(port: selectedPort, webRoot: root.appendingPathComponent("Web"), store: targetStore)
// 首次启动时让 macOS 显示其官方授权提示；授权决定仍完全由用户控制。
let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
_ = AXIsProcessTrustedWithOptions(promptOptions)
try server.start()
// 启动即生成配对 token（懒加载在此刻触发落盘），QR 与写请求校验都依赖它。
_ = Auth.token
let pointerExecutor = PointerExecutor()
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
