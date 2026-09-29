/** Volume-down push-to-talk on the existing sprite panel; shares TaskService. */
import AppKit
import ApplicationServices

final class SpriteDesktopInput: NSObject, NSTextFieldDelegate {
    private static let localControlSession = UUID().uuidString
    static func authorizes(_ task: AgentTask) -> Bool {
        task.controlSession == localControlSession && !LockScreenInput.locked
    }
    private let panel: SpriteFeedbackPanel
    private let headset = HeadsetLongPress()
    private var optionDown = false
    private var recording = false
    private var voiceObserved = false
    private var triggerAt: Date?
    private var captureGeneration = 0
    private var releasedAt: Date?
    private var changedAt = Date()
    private var previousText = ""
    private var taskId: String?
    private var timer: Timer?
    init(panel: SpriteFeedbackPanel) {
        self.panel = panel
        super.init()
        panel.desktopInput.delegate = self
        panel.onDesktopInterrupted = { [weak self] in self?.cancel() }
        headset.onBegin = { [weak self] in self?.begin() }
        headset.onEnd = { [weak self] in self?.end() }
        headset.onCancel = { [weak self] in self?.cancel() }
        headset.start()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(self, selector: #selector(terminating), name: NSApplication.willTerminateNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(terminating), name: .init("com.apple.screenIsLocked"), object: nil)
    }
    private func option(_ down: Bool) {
        guard down != optionDown else { return }
        optionDown = down
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 58, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20) : []
        event.post(tap: .cghidEventTap)
    }
    private func begin() {
        guard !LockScreenInput.locked, AXIsProcessTrusted() else { return }
        guard !recording else { return }
        // A new deliberate hold replaces a failed/pending transcript immediately.
        if releasedAt != nil { cancel() }
        captureGeneration += 1
        let generation = captureGeneration
        guard panel.beginDesktopCapture() else { return }
        recording = true; voiceObserved = false; triggerAt = nil; previousText = ""; taskId = nil
        panel.desktopStatus("正在启动语音…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.captureGeneration == generation, self.recording, self.panel.isKeyWindow else { return }
            self.option(true)
            self.triggerAt = Date()
            NSLog("PocketDesk headset Option down sent; awaiting dictation")
        }
    }
    private func end() {
        guard recording else { return }
        recording = false; option(false)
        releasedAt = Date(); changedAt = Date()
        panel.desktopStatus("正在完成转写…")
        NSLog("PocketDesk headset released; waiting for transcript")
    }
    private func cancel() {
        captureGeneration += 1
        recording = false; releasedAt = nil; triggerAt = nil; option(false)
    }
    @objc private func terminating() { cancel() }
    private func dictationVisible() -> Bool {
        let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix("com.bytedance.inputmethod") == true }.map(\.processIdentifier))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] else { return false }
        return windows.contains { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let b = w[kCGWindowBounds as String] as? [String:Any],
                  let width = b["Width"] as? Double, let height = b["Height"] as? Double else { return false }
            return width >= 80 && height >= 25
        }
    }
    private func tick() {
        panel.updateDesktopSubtitle()
        if LockScreenInput.locked { cancel(); return }
        if recording, let triggerAt {
            let text = (panel.desktopInput.currentEditor() as? NSTextView)?.string ?? panel.desktopInput.stringValue
            if !voiceObserved && (dictationVisible() || !text.isEmpty) {
                voiceObserved = true
                panel.desktopStatus("正在听 · 松开执行")
                NSLog("PocketDesk headset dictation observed")
            } else if !voiceObserved && Date().timeIntervalSince(triggerAt) > 2 {
                panel.desktopStatus("尚未检测到豆包语音，请松手后重试")
            }
        }
        if let released = releasedAt {
            guard panel.desktopMode, panel.isKeyWindow else { cancel(); return }
            let text = panel.desktopInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text != previousText { previousText = text; changedAt = Date() }
            if Date().timeIntervalSince(released) > 15 {
                cancel(); panel.desktopStatus("未收到完整转写，未执行"); return
            }
            guard !text.isEmpty, Date().timeIntervalSince(released) >= 0.6,
                  Date().timeIntervalSince(changedAt) >= 0.6, !dictationVisible(),
                  ((panel.desktopInput.currentEditor() as? NSTextView)?.hasMarkedText() != true) else { return }
            releasedAt = nil
            do {
                let task = try TaskService.submit(subject: String(Auth.token.prefix(8)), requestId: UUID().uuidString,
                                                 text: text, context: nil, controlSession: Self.localControlSession)
                taskId = task.id
                panel.desktopStatus(task.status.displayName, result: text)
                NSLog("PocketDesk headset submitted task %@", task.id)
            } catch { panel.desktopStatus("未执行", result: error.localizedDescription) }
        } else if let id = taskId, panel.desktopMode, let task = TaskStore.task(id: id) {
            panel.desktopStatus(task.status.displayName, result: task.result ?? task.error ?? task.text)
        }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel(); panel.endDesktopCapture(); panel.orderOut(nil); return true
        }
        // Do not let a stray Enter submit before the held button is released.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { return true }
        return false
    }
}
