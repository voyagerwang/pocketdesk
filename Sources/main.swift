/**
 * [INPUT]: 依赖 AppKit 的 NSApplication/NSWorkspace 与 Foundation 的 FileManager/ProcessInfo；消费 TargetStore/Server/WSServer/PointerExecutor 的装配。
 * [OUTPUT]: 对外提供 PocketDesk 启动引导：web 根目录定位、端口选择（VOICE_DECK_PORT 环境变量）、辅助功能授权提示、双服务启动与 Dock 应用身份（AppDelegate）。
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
// 启动即生成配对 token（懒加载在此刻触发落盘），QR 与写请求校验都依赖它。
_ = Auth.token
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
