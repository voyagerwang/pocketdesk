/**
 * [INPUT]: 依赖 AppKit 的 NSWorkspace/NSPasteboard、ApplicationServices 的 AXUIElement、CoreGraphics 的 CGEvent/CGEventSource；消费 Models 的 SendCommand/ShortcutConfig/InputError/ShortcutError/ShortcutKeys、ShortcutActions 的平台展开、ExecutionTrace 的结果分级与环境门禁、Util 的前台应用探测、TargetStore 的目标解析。
 * [OUTPUT]: 对外提供 InputExecutor（图片预上传暂存、应用激活、图文发送的 activate → Unicode → 粘贴图片 → Return 注入序列、快捷键组合注入、预设动作的窗口关闭与应用隐藏）；合成键盘事件统一经 postKey（真实 CGEventSource + characters 补齐 + down/up 间隔），解决 Zed 终端这类按 characters 取键的应用对合成 Return 的丢弃。
 * [POS]: Sources 的键盘输入执行层；Server 把 /api/activate、/api/send、/api/image、/api/shortcut-trigger 委托给它，与 PointerExecutor（指针）平行为一对执行兄弟。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import CoreGraphics
import Foundation

final class InputExecutor {
    static let frontmostPseudoId = "__frontmost__"
    // UU 远程特殊通道：UU 的键盘同步不吃合成 Unicode 事件（表现为只透传占位符），
    // 但剪贴板是应用层双向同步的——发往 UU 的内容改走「写剪贴板 + Cmd+V + Return」。
    static let uuRemoteId = "uu"
    private let queue = DispatchQueue(label: "dev.voicedeck.input")
    private let store: TargetStore
    // 手机预上传的待发图片；send(usePendingImage) 时取出消费。
    private var pendingImageData: Data?
    private let pendingLock = NSLock()

    init(store: TargetStore) { self.store = store }

    func stageImage(_ data: Data, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async {
            guard data.count <= 10 * 1024 * 1024 else {
                completion(.failure(.message("图片太大（>10MB）。"))); return
            }
            self.pendingLock.lock()
            self.pendingImageData = data
            self.pendingLock.unlock()
            completion(.success(()))
        }
    }

    private func takePendingImage() -> Data? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let data = pendingImageData
        pendingImageData = nil
        return data
    }

    func activate(_ targetId: String, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async { self.activateTarget(targetId, completion: completion) }
    }

    // 发送回执：成功也带结论。内容是否真的进了输入框无法从外部确认，故顶层是 sent，
    // 但 detail 会把「目标没能在前台」这类高概率落空场景明说出来，而不是笼统报个成功。
    func send(_ command: SendCommand, completion: @escaping (Result<ExecutionFeedback, InputError>) -> Void) {
        queue.async {
            if let reason = EnvironmentGate.blockReason() {
                self.record("send", "发送到 \(command.targetId)", .blocked, reason)
                completion(.failure(.message(reason))); return
            }
            // 新流程：图片随 /api/image 预上传，发送时只带标记。
            let stagedImage = command.usePendingImage == true ? self.takePendingImage() : nil
            let inlineImage = stagedImage == nil ? command.image.flatMap { Data(base64Encoded: $0) } : nil
            let imageData = stagedImage ?? inlineImage
            if command.usePendingImage == true && imageData == nil {
                completion(.failure(.message("图片未找到或已过期，请重新选择。"))); return
            }
            let hasText = !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasText || imageData != nil else {
                completion(.failure(.message("先输入一点内容或选择一张图片。"))); return
            }
            guard command.text.utf16.count <= 8_000 else {
                completion(.failure(.message("单次文本最多 8,000 个 UTF-16 字符。"))); return
            }
            self.dispatchSend(command, imageData: imageData, completion: completion)
        }
    }

    // 统一执行路径：先输入文字，再粘贴可选图片，最后提交。
    private func dispatchSend(_ command: SendCommand, imageData: Data?, completion: @escaping (Result<ExecutionFeedback, InputError>) -> Void) {
        let label = "发送到 \(self.store.resolve(command.targetId)?.name ?? command.targetId)"
        // UU 远程特殊通道：写剪贴板 + Cmd+V（UU 剪贴板同步跨机）+ Return；不走 Unicode 注入。
        if command.targetId == Self.uuRemoteId || isUUFrontmost() {
            queue.asyncAfter(deadline: .now() + .milliseconds(450)) {
                self.performUURemotePaste(text: command.text, imageData: imageData)
                self.finishSend(label: label, targetId: Self.uuRemoteId, completion: completion)
            }
            return
        }
        // 伪目标：不切换应用，直接注入当前前台（前台是非 Dock 应用时的发送路径）。
        if command.targetId == Self.frontmostPseudoId {
            queue.asyncAfter(deadline: .now() + .milliseconds(80)) {
                self.performPaste(imageData: imageData, text: command.text)
                self.finishSend(label: label, targetId: Self.frontmostPseudoId, completion: completion)
            }
            return
        }
        activateTarget(command.targetId) { result in
            guard case .success = result else {
                if case .failure(.message(let message)) = result {
                    self.record("send", label, .failed, message)
                    completion(.failure(.message(message)))
                }
                return
            }
            // 给桌面应用取得前台焦点；后续步骤都在同一串行队列中执行。
            self.queue.asyncAfter(deadline: .now() + .milliseconds(450)) {
                self.performPaste(imageData: imageData, text: command.text)
                // 粘完再看一眼：目标是具体应用时，前台不是它就说明这一发大概率落空了。
                self.queue.asyncAfter(deadline: .now() + .milliseconds(350)) {
                    self.finishSend(label: label, targetId: command.targetId, completion: completion)
                }
            }
        }
    }

    // 发送收尾：把「目标有没有真的在前台」变成一句人话，写进回执与日志。
    // 目标确实在最前面接收 → delivered（这是外部能观察到的最强证据）；前台是别的应用 → sent，
    // 因为这种时候内容多半落在了别人家的窗口里，是"点了没反应"的高发场景。
    private func finishSend(label: String, targetId: String, completion: @escaping (Result<ExecutionFeedback, InputError>) -> Void) {
        let frontName = Util.frontmostApp()?.localizedName
        let outcome: ExecutionOutcome
        let detail: String
        // 伪目标与 UU 走当前前台，前台即目标，无需比对归属。
        if targetId == Self.frontmostPseudoId || targetId == Self.uuRemoteId {
            outcome = .delivered
            detail = "已输入到\(frontName ?? "当前前台应用")。"
        } else if self.frontmostMatches(targetId: targetId) {
            outcome = .delivered
            detail = "已输入到\(frontName ?? "目标应用")。"
        } else {
            outcome = .sent
            let expected = self.store.resolve(targetId)?.name ?? targetId
            detail = "已输入，但当前前台是\(frontName ?? "其他应用")而不是\(expected)，内容可能没落到它的输入框。"
        }
        self.record("send", label, outcome, detail, frontName)
        completion(.success(ExecutionFeedback(outcome: outcome, detail: detail)))
    }

    // 前台应用是不是某个目标应用（按 bundleID 或路径比对，与 /api/status 判定保持一致）。
    private func frontmostMatches(targetId: String) -> Bool {
        guard let config = store.resolve(targetId),
              let front = Util.frontmostApp() else { return false }
        if let bundleID = config.bundleID, front.bundleIdentifier == bundleID { return true }
        if let path = config.path, front.bundleURL?.path == path { return true }
        return false
    }

    // 前台应用是不是 UU 远程（发往伪目标时的兜底判定）。
    private func isUUFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.bundleIdentifier == "com.netease.uuremote"
    }

    // UU 通道注入序列：文字+图片都进剪贴板（图片优先，纯文字给纯文本），
    // Cmd+V 由 UU 的剪贴板同步带跨机器，粘进远程电脑的输入框后 Return 提交。
    private func performUURemotePaste(text: String, imageData: Data?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let imageData, let image = NSImage(data: imageData) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.setString(text, forType: .string)
        }
        usleep(120_000) // 剪贴板写入落定，给 UU 同步留个起跑信号
        postKey(9, flags: .maskCommand) // Cmd+V
        usleep(600_000) // 等远端粘贴落框
        postKey(36) // Return
    }

    // 先在仍持有焦点的编辑器中输入文字，避免图片挂载期间的焦点变化吞掉文字。
    // 等文字落入编辑器后再粘贴图片；等待缩略图挂载后统一按 Return。
    // 图片发送后留在剪贴板上（与手动复制粘贴语义一致，不额外清空）。
    private func performPaste(imageData: Data?, text: String) {
        if !text.isEmpty {
            postUnicode(text)
            usleep(200_000) // 让编辑器处理文字，再开始附件粘贴或提交
        }
        if let imageData, let image = NSImage(data: imageData) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            postKey(9, flags: .maskCommand) // Cmd+V
            usleep(1_000_000) // 等目标应用完成粘贴读取与缩略图挂载
        }
        postKey(36) // Return：图文一起发，或纯图直发
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
                  let down = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: 0, keyDown: false) else { return }
            // Unicode 输入不继承当前系统修饰键，防止被解释为快捷键。
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: length, unicodeString: base)
            up.keyboardSetUnicodeString(stringLength: length, unicodeString: base)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    // 合成键盘事件的公共底座：真实事件源 + characters 补齐 + down/up 间隔。
    // 无源 CGEvent 的 characters 为空，Zed 终端这类按 characters 解释回车/退格的应用会整键丢弃
    //（方向键按键码识别不受影响，故此前"上下能动、回车无效"）；Hammerspoon 等注入工具同样带源。
    private static let eventSource = CGEventSource(stateID: .combinedSessionState)
    // 终端类应用按 characters 解释的特殊键；字母/数字/F 键按键码识别，无需补。
    private static let keyCharacters: [CGKeyCode: String] = [
        36: "\r", 51: "\u{7F}", 48: "\t", 53: "\u{1B}", 49: " ",
    ]

    @discardableResult
    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard let down = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: code, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = flags
            if let text = Self.keyCharacters[code] {
                var units = Array(text.utf16)
                let count = units.count
                units.withUnsafeMutableBufferPointer { buffer in
                    if let base = buffer.baseAddress {
                        event.keyboardSetUnicodeString(stringLength: count, unicodeString: base)
                    }
                }
            }
        }
        down.post(tap: .cghidEventTap)
        usleep(25_000) // 贴合物理按键的 press-release 间隔，避免快速采样应用漏判
        up.post(tap: .cghidEventTap)
        return true
    }

    // 快捷键：组合键注入当前前台应用，不切换目标；与 send 共用串行队列。
    // 回执分两级——能观察到状态变化才算 delivered，纯按键注入只能是 sent（微信不响应合成 Cmd+W
    // 却旧实现照样回 ok，正是这里要补上的诚实）。
    func triggerShortcut(_ shortcut: ShortcutConfig, completion: @escaping (Result<ExecutionFeedback, ShortcutError>) -> Void) {
        queue.async {
            if let reason = EnvironmentGate.blockReason() {
                self.record("shortcut", shortcut.label, .blocked, reason)
                completion(.failure(.message(reason))); return
            }
            let frontName = Util.frontmostApp()?.localizedName
            let frontApp = Util.frontmostApp()
            let beforePID = frontApp?.processIdentifier
            let beforeWindows = beforePID.map { self.windowCount(pid: $0) } ?? 0
            let appName = frontName ?? "当前前台应用"
            // 系统级动作不走按键：锁屏跑系统命令、切换应用用 AppKit，两者都不依赖系统快捷键守护进程。
            if let action = shortcut.action.flatMap(ShortcutAction.find) {
                switch action.delivery {
                case .systemCommand:
                    guard let command = action.command(.current) else {
                        let text = "「\(action.label)」在当前平台没有可用实现。"
                        self.record("shortcut", shortcut.label, .failed, text, frontName)
                        completion(.failure(.message(text))); return
                    }
                    if self.runCommand(command) {
                        let feedback = ExecutionFeedback.delivered("已执行\(action.label)。")
                        self.record("shortcut", shortcut.label, .delivered, feedback.detail, frontName)
                        completion(.success(feedback))
                    } else {
                        let text = "「\(action.label)」执行失败（系统命令返回非零）。"
                        self.record("shortcut", shortcut.label, .failed, text, frontName)
                        completion(.failure(.message(text)))
                    }
                    return
                case .switchPreviousApp:
                    self.switchToPreviousApp { ok in
                        guard ok else {
                            let text = "没有可切换的其他应用。"
                            self.record("shortcut", shortcut.label, .failed, text, frontName)
                            completion(.failure(.message(text))); return
                        }
                        self.verify(label: shortcut.label, frontApp: frontName, delay: .milliseconds(600),
                                    changed: { Util.frontmostApp()?.processIdentifier != beforePID },
                                    okText: { "已切到\(Util.frontmostApp()?.localizedName ?? "上一个应用")。" },
                                    pendingText: "已发出切换指令，但前台应用没有变化。") { feedback in
                            completion(.success(feedback))
                        }
                    }
                    return
                case .keyEvent:
                    break   // 落到下面的 CGEvent 注入
                case .axCloseWindow:
                    // 优先按窗口的关闭按钮；取不到（应用没暴露 AX 关闭按钮）才回退按键注入。
                    if self.closeFrontWindow() {
                        self.verify(label: shortcut.label, frontApp: frontName, delay: .milliseconds(500),
                                    changed: { beforePID.map { self.windowCount(pid: $0) < beforeWindows } ?? false },
                                    okText: { "已关闭\(appName)的窗口。" },
                                    pendingText: "已按下\(appName)的关闭按钮，但窗口数量没有变化，可能没关掉。") { feedback in
                            completion(.success(feedback))
                        }
                        return
                    }
                    // 回退到按键：这类应用（微信是典型）不响应合成 Cmd+W，验证会失败——
                    // 与其报个假成功，不如把「没关掉 + 大概率原因」直接说给用户。
                    guard let resolved = ShortcutKeys.resolve(shortcut.effectiveHotkey) else { break }
                    self.postKey(resolved.keycode, flags: resolved.flags)
                    self.verify(label: shortcut.label, frontApp: frontName, delay: .milliseconds(600),
                                changed: { beforePID.map { self.windowCount(pid: $0) < beforeWindows } ?? false },
                                okText: { "已关闭\(appName)的窗口。" },
                                pendingText: "已向\(appName)发送 \(shortcut.effectiveHotkey)，但没检测到窗口关闭——它不响应合成按键，建议改用「隐藏应用」。") { feedback in
                        completion(.success(feedback))
                    }
                    return
                case .hideFrontApp:
                    guard let frontApp, frontApp.hide() else {
                        let text = "当前没有可隐藏的应用。"
                        self.record("shortcut", shortcut.label, .failed, text, frontName)
                        completion(.failure(.message(text))); return
                    }
                    let name = appName
                    self.verify(label: shortcut.label, frontApp: frontName, delay: .milliseconds(400),
                                changed: { Util.frontmostApp()?.processIdentifier != beforePID },
                                okText: { "已隐藏\(name)。" },
                                pendingText: "已对\(name)下发隐藏，但它仍在最前。") { feedback in
                        completion(.success(feedback))
                    }
                    return
                }
            }
            // 语义串经 ShortcutKeys.resolve 统一解析为 CGEvent 键码 + flags；失败给明确报错。
            // 预设动作（退出应用等）先按当前平台展开成按键串，再走同一链路——不另起注入通道。
            let hotkey = shortcut.effectiveHotkey
            guard let resolved = ShortcutKeys.resolve(hotkey) else {
                let text = "快捷键无法识别：\(hotkey)"
                self.record("shortcut", shortcut.label, .failed, text, frontName)
                completion(.failure(.message(text))); return
            }
            guard self.postKey(resolved.keycode, flags: resolved.flags) else {
                let text = "快捷键事件创建失败。"
                self.record("shortcut", shortcut.label, .failed, text, frontName)
                completion(.failure(.message(text))); return
            }
            // 退出应用是唯一可验证的按键动作：进程没了才算数，否则多半卡在未保存确认框上。
            if shortcut.action == ShortcutAction.quitApp.rawValue, let pid = beforePID {
                self.verify(label: shortcut.label, frontApp: frontName, delay: .milliseconds(1500),
                            changed: { self.isTerminated(pid: pid) },
                            okText: { "已退出\(appName)。" },
                            pendingText: "已发送 \(hotkey)，但\(appName)仍在运行——可能弹出了未保存的确认框，或它拦截了退出。") { feedback in
                    completion(.success(feedback))
                }
                return
            }
            // 其余按键无从验证：目标应用把它当菜单项、当文本输入还是直接丢弃，外部都看不见。
            let feedback = ExecutionFeedback.sent("已把 \(hotkey) 发给\(appName)。")
            self.record("shortcut", shortcut.label, .sent, feedback.detail, frontName)
            completion(.success(feedback))
        }
    }

    // 事后验证：等状态稳定后比对预期变化。变了才算 delivered，没变只能退回 sent 并说明原因——
    // 宁可说「不确定」，也不说一个没人验证过的「成功」。
    private func verify(label: String, frontApp: String?, delay: DispatchTimeInterval,
                        changed: @escaping () -> Bool, okText: @escaping () -> String,
                        pendingText: String,
                        completion: @escaping (ExecutionFeedback) -> Void) {
        queue.asyncAfter(deadline: .now() + delay) {
            let feedback = changed() ? ExecutionFeedback.delivered(okText()) : ExecutionFeedback.sent(pendingText)
            self.record("shortcut", label, feedback.outcome, feedback.detail, frontApp)
            completion(feedback)
        }
    }

    private func record(_ kind: String, _ label: String, _ outcome: ExecutionOutcome, _ detail: String, _ frontApp: String? = nil) {
        ExecutionLog.shared.append(kind: kind, label: label, outcome: outcome, detail: detail, frontApp: frontApp)
    }

    // 某进程的常规窗口数：关窗验证靠它做前后对比（只看 layer 0，排除悬浮面板与桌面元素干扰）。
    private func windowCount(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        let ownerPID = kCGWindowOwnerPID as String
        let windowLayer = kCGWindowLayer as String
        return list.filter { ($0[ownerPID] as? Int32) == pid && ($0[windowLayer] as? Int) == 0 }.count
    }

    private func isTerminated(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return true }
        return app.isTerminated
    }

    // 关闭前台窗口：用辅助功能直接按窗口的关闭按钮，不依赖目标应用实现 Cmd+W。
    // 实测微信在前台时注入 Cmd+W 毫无反应（官方快捷键表列了，主窗口就是不响应合成按键）。
    // 前台应用经 Util.frontmostApp 取（NSWorkspace 的缓存会冻结）。
    private func closeFrontWindow() -> Bool {
        guard let pid = Util.frontmostApp()?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let window = focused, CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        var rawButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXCloseButtonAttribute as CFString, &rawButton) == .success,
              let button = rawButton, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    // 隐藏前台应用已内联到 triggerShortcut 的 .hideFrontApp 分支（需要拿执行前的 PID 做验证）。

    // 锁屏这类"系统能力"动作：直接跑命令，不模拟按键、也不要额外授权。
    private func runCommand(_ command: String) -> Bool {
        let parts = command.split(separator: " ").map(String.init)
        guard let executable = parts.first else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(parts.dropFirst())
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { return false }
    }

    // 切到上一个应用：CGWindowList 的顺序就是最近使用顺序（z-order），跳过当前前台的应用，
    // 取下一个常规应用激活。绕开了 Cmd+Tab 到不了系统快捷键守护进程的问题。
    // 激活沿用 activateTarget 那条已验证的 openApplication 路径（NSRunningApplication.activate 在此失败过）。
    private func switchToPreviousApp(completion: @escaping (Bool) -> Void) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            completion(false); return
        }
        let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != currentPID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let url = app.bundleURL else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in completion(true) }
            return
        }
        completion(false)
    }
}
