/**
 * [INPUT]: 依赖 AppKit、ScreenCaptureKit、Carbon 的本机会话与权限状态；启动脚本提供报告目录。
 * [OUTPUT]: 独立的 45 秒会话验证窗口、明确的权限阻断提示和只含状态/计数的 JSON 报告，不保存画面或密码。
 * [POS]: SessionProbe 验证入口；与正式应用、网络、草稿、历史和高权限服务隔离。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import ScreenCaptureKit
import Carbon

// MARK: - 只记录固定字段，不读取窗口标题、输入值或密码

struct Sample: Codable {
    let elapsed: Int
    let locked: Bool?
    let secureInput: Bool
    let onConsole: Bool?
    let frames: Int
    let idle: Int
    let blank: Int
    let lastFrameAge: Double?
}

final class CaptureProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private(set) var frames = 0, idle = 0, blank = 0
    private(set) var lastFrame: Double?
    private(set) var errorCode: Int?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw NSError(domain: "Probe", code: 1) }
        let config = SCStreamConfiguration()
        config.width = 320; config.height = 180
        config.showsCursor = false; config.capturesAudio = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        let capture = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        stream = capture
        try await capture.startCapture()
    }

    func stop() async { if let stream { try? await stream.stopCapture() }; stream = nil }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.errorCode = (error as NSError).code }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int else { return }
        switch status {
        case SCFrameStatus.complete.rawValue:
            frames += 1; lastFrame = ProcessInfo.processInfo.systemUptime
        case SCFrameStatus.idle.rawValue: idle += 1
        case SCFrameStatus.blank.rawValue: blank += 1
        default: break
        }
        // 不转换或保存 imageBuffer；complete 帧也不等于确认锁屏内容可见。
    }
}

final class ProbeApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "正在检查权限…")
    private let testInput = NSButton(checkboxWithTitle: "锁屏后测试一次字符 q，再尝试删除；不按回车", target: nil, action: nil)
    private var startButton: NSButton!
    private var timer: Timer?
    private var capture: CaptureProbe?
    private var samples: [Sample] = []
    private var notifications: [String] = []
    private var tokens: [NSObjectProtocol] = []
    private var started = 0.0
    private var running = false
    private var lockNotice = false
    private var attempted = false
    private var mayTestInput = false
    private var lockedTicks = 0
    private var inputEvents: [String] = []
    private var runID = UUID()
    private var captureStartCode: Int?
    private let reportURL: URL
    private let variant: String

    init(reportURL: URL, variant: String) { self.reportURL = reportURL; self.variant = variant }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "PocketDesk · 本机会话验证")
        title.font = .boldSystemFont(ofSize: 20)
        let detail = NSTextField(wrappingLabelWithString: "验证期间请手动锁屏，再现场解锁。45 秒后自动停止。\n只记录状态和帧计数，不保存画面、输入内容或密码。")
        let access = NSButton(title: "授权辅助功能", target: self, action: #selector(requestInput))
        let screen = NSButton(title: "授权屏幕录制", target: self, action: #selector(requestScreen))
        startButton = NSButton(title: "开始 45 秒验证", target: self, action: #selector(startRun))
        let stop = NSButton(title: "停止", target: self, action: #selector(stopRun))
        let report = NSButton(title: "查看报告", target: self, action: #selector(openReport))
        let row = NSStackView(views: [startButton, stop, report]); row.spacing = 10
        [title, detail, status, access, screen, testInput, row].forEach { stack.addArrangedSubview($0) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 345), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PocketDesk 会话验证（\(variant)）"
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            tokens.append(DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self, self.running else { return }
                self.lockNotice = name == "com.apple.screenIsLocked"
                self.notifications.append(self.lockNotice ? "locked" : "unlocked")
            })
        }
        updatePermissions()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        // 启动快照也只含权限和身份，不以权限存在推断锁屏支持。
        saveReport(phase: "ready")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidBecomeActive(_ notification: Notification) {
        if !running && started == 0 { updatePermissions() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); running = false
        if started > 0 { saveReport(phase: "closed") }
    }

    private func updatePermissions() {
        status.stringValue = "辅助功能：\(AXIsProcessTrusted() ? "已允许" : "未允许")；屏幕录制：\(CGPreflightScreenCaptureAccess() ? "已允许" : "未允许")。\n本程序不开放网络端口、不安装管理员服务。"
    }
    @objc private func requestInput() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        updatePermissions()
    }
    @objc private func requestScreen() {
        let allowed = CGRequestScreenCaptureAccess()
        updatePermissions()
        saveReport(phase: allowed ? "screen_permission_granted" : "screen_permission_pending")
        guard !allowed else { return }
        status.stringValue = "录屏权限尚未生效，已打开系统录屏设置。\n请允许 PocketDeskSessionProbe；若已开启，请按系统提示重新打开应用。"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func openReport() { NSWorkspace.shared.selectFile(reportURL.path, inFileViewerRootedAtPath: "") }

    @objc private func startRun() {
        guard !running else { return }
        let needsScreen = !CGPreflightScreenCaptureAccess()
        let needsInput = testInput.state == .on && !AXIsProcessTrusted()
        guard !needsScreen && !needsInput else {
            let missing = [needsScreen ? "屏幕录制" : nil, needsInput ? "辅助功能" : nil].compactMap { $0 }.joined(separator: "、")
            status.stringValue = "验证尚未开始：缺少\(missing)权限。\n请先授权这个独立测试程序，再点击开始；现在无需锁屏或输入。"
            saveReport(phase: "blocked_permissions")
            let alert = NSAlert()
            alert.messageText = "验证尚未开始"
            alert.informativeText = "请允许 PocketDeskSessionProbe 的\(missing)权限。正式 PocketDesk 的权限不会自动授予这个独立程序。授权后返回重试；如果系统要求重新打开应用，请按系统提示操作。\n\n本测试不需要在手机或 PocketDesk 中输入任何内容。"
            alert.addButton(withTitle: "知道了")
            alert.beginSheetModal(for: window)
            return
        }
        samples = []; notifications = []; inputEvents = []; captureStartCode = nil
        lockNotice = false; attempted = false; lockedTicks = 0
        mayTestInput = testInput.state == .on
        started = ProcessInfo.processInfo.systemUptime; running = true; runID = UUID()
        let generation = runID
        testInput.isEnabled = false; startButton.isEnabled = false
        let probe = CaptureProbe(); capture = probe
        Task { @MainActor in
            do { try await probe.start() }
            catch { if self.runID == generation { self.captureStartCode = (error as NSError).code } }
            if !self.running || self.runID != generation { await probe.stop() }
        }
        status.stringValue = "观察中：请按 Control–Command–Q 手动锁屏，随后现场解锁。\n若勾选输入测试，锁屏约 3 秒后尝试一次 q；不会提交。"
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        saveReport(phase: "observing")
    }

    private func snapshot() -> (Bool?, Bool?, Bool) {
        let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (dictionary?["CGSSessionScreenIsLocked"] as? Bool,
                dictionary?[kCGSessionOnConsoleKey as String] as? Bool, IsSecureEventInputEnabled())
    }

    private func tick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let (locked, onConsole, secure) = snapshot()
        samples.append(Sample(elapsed: Int(now - started), locked: locked, secureInput: secure,
                              onConsole: onConsole, frames: capture?.frames ?? 0,
                              idle: capture?.idle ?? 0, blank: capture?.blank ?? 0,
                              lastFrameAge: capture?.lastFrame.map { max(0, now - $0) }))
        lockedTicks = locked == true && lockNotice && secure ? lockedTicks + 1 : 0
        if mayTestInput && !attempted && lockedTicks >= 3 { tryInput() }
        saveReport(phase: "observing")
        if now - started >= 45 { stopRun() }
    }

    // 本实验无网络入口；三项只作为防误触条件，不能升级成生产安全认证。
    private func inputAllowed() -> Bool {
        let (locked, _, secure) = snapshot()
        return running && mayTestInput && lockNotice && locked == true && secure && AXIsProcessTrusted()
    }
    private func post(_ code: CGKeyCode) -> Bool {
        guard inputAllowed(), let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        down.flags = []; up.flags = []
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        return true
    }
    private func tryInput() {
        attempted = true
        guard post(12) else { inputEvents.append("test_blocked"); return }
        inputEvents.append("q_sent_unverified")
        let generation = runID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard self.runID == generation else { return }
            self.inputEvents.append(self.post(51) ? "delete_sent_unverified" : "delete_blocked_state_changed")
        }
    }

    @objc private func stopRun() {
        guard running else { return }
        running = false; timer?.invalidate(); timer = nil
        let probe = capture
        Task { await probe?.stop() }
        testInput.isEnabled = true; testInput.state = .off; startButton.isEnabled = true
        status.stringValue = "验证已停止。已记录 \(samples.count) 秒状态。\n字符是否出现在系统密码框、画面是否可用仍需人工确认；没有执行解锁。"
        saveReport(phase: "finished")
    }

    private func saveReport(phase: String) {
        struct Report: Encodable {
            let phase: String, variant: String, os: String
            let uid: UInt32, pid: Int32
            let accessibility: Bool, screenCapture: Bool, unlockVerified: Bool
            let inputTestOptIn: Bool
            let notifications: [String], inputEvents: [String], samples: [Sample]
            let captureStartError: Int?, captureStopError: Int?
        }
        let report = Report(phase: phase, variant: variant, os: ProcessInfo.processInfo.operatingSystemVersionString,
                            uid: getuid(), pid: getpid(), accessibility: AXIsProcessTrusted(),
                            screenCapture: CGPreflightScreenCaptureAccess(), unlockVerified: false,
                            inputTestOptIn: mayTestInput, notifications: notifications, inputEvents: inputEvents,
                            samples: samples, captureStartError: captureStartCode, captureStopError: capture?.errorCode)
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch { status.stringValue = "报告写入失败；停止本轮验证。"; running = false; timer?.invalidate(); Task { await capture?.stop() } }
    }
}

guard getuid() != 0, CommandLine.arguments.count == 3 else {
    fputs("仅允许普通用户由会话验证脚本启动；不以 root 运行。\n", stderr); exit(2)
}
let app = NSApplication.shared
let delegate = ProbeApp(reportURL: URL(fileURLWithPath: CommandLine.arguments[1]), variant: CommandLine.arguments[2])
app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
