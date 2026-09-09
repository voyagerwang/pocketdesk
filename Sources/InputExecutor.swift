/**
 * [INPUT]: 依赖 AppKit 的 NSWorkspace/NSPasteboard、ApplicationServices 的 AXUIElement、CoreGraphics 的 CGEvent/CGEventSource；消费 Models 的 SendCommand/ShortcutConfig/InputError/ShortcutError/ShortcutKeys、ShortcutActions 的平台展开、ExecutionTrace 的结果分级与环境门禁、Util 的前台应用探测、TargetStore 的目标解析。
 * [OUTPUT]: 对外提供 InputExecutor（图片预上传暂存、应用激活与**唤醒后校验**、**注入前的焦点三态探测与按需自动聚焦**、图文发送的 activate → Unicode → 粘贴图片 → Return 注入序列、**实时同频输入**（手机输入框全文 → 差分退格/补字 → 可选回车提交）、快捷键组合注入、预设动作的窗口关闭与应用隐藏），以及 lastFocusProbe（最近一次焦点探测的现场：应用/role/AXError/结论，经 /api/status 暴露，是排查"报没聚焦却其实进去了"的唯一依据）；合成键盘事件统一经 postKey（真实 CGEventSource + characters 补齐 + down/up 间隔），解决 Zed 终端这类按 characters 取键的应用对合成 Return 的丢弃。
 * [POS]: Sources 的键盘输入执行层；Server 把 /api/activate、/api/send、/api/live-input、/api/image、/api/shortcut-trigger 委托给它，与 PointerExecutor（指针）平行为一对执行兄弟。
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
                // UU 的内容由剪贴板同步到远端机器，本机的焦点状态与它无关、也无从判定，沿用既有结论。
                self.finishSend(label: label, targetId: Self.uuRemoteId, verdict: .editable, completion: completion)
            }
            return
        }
        // 伪目标：不切换应用，直接注入当前前台（前台是非 Dock 应用时的发送路径）。
        if command.targetId == Self.frontmostPseudoId {
            queue.asyncAfter(deadline: .now() + .milliseconds(80)) {
                let verdict = self.ensureEditableFocus(pid: Util.frontmostApp()?.processIdentifier ?? -1)
                self.performPaste(imageData: imageData, text: command.text)
                self.finishSend(label: label, targetId: Self.frontmostPseudoId, verdict: verdict, completion: completion)
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
                let verdict = self.ensureEditableFocus(pid: self.runningApp(targetId: command.targetId)?.processIdentifier ?? -1)
                self.performPaste(imageData: imageData, text: command.text)
                // 粘完再看一眼：目标是具体应用时，前台不是它就说明这一发大概率落空了。
                self.queue.asyncAfter(deadline: .now() + .milliseconds(350)) {
                    self.finishSend(label: label, targetId: command.targetId, verdict: verdict, completion: completion)
                }
            }
        }
    }

    // 发送收尾：把「目标有没有真的在前台」变成一句人话，写进回执与日志。
    // 目标确实在最前面接收 → delivered（这是外部能观察到的最强证据）；前台是别的应用 → sent，
    // 因为这种时候内容多半落在了别人家的窗口里，是"点了没反应"的高发场景。
    private func finishSend(label: String, targetId: String, verdict: FocusVerdict, completion: @escaping (Result<ExecutionFeedback, InputError>) -> Void) {
        // 走整段粘贴/提交的老路径后，目标输入框已被清空，同频基线必须跟着归零；
        // 否则下一次同频会照着旧基线去退格，把刚发出去的内容又"删"一遍。
        mirroredText = ""
        let frontName = Util.frontmostApp()?.localizedName
        let feedback: ExecutionFeedback
        // 伪目标与 UU 走当前前台，前台即目标，无需比对归属。
        if targetId == Self.frontmostPseudoId || targetId == Self.uuRemoteId {
            feedback = Self.receipt(name: frontName ?? "当前前台应用", verdict: verdict)
        } else if self.frontmostMatches(targetId: targetId) {
            feedback = Self.receipt(name: frontName ?? "目标应用", verdict: verdict)
        } else {
            let expected = self.store.resolve(targetId)?.name ?? targetId
            feedback = .sent("已输入，但当前前台是\(frontName ?? "其他应用")而不是\(expected)，内容可能没落到它的输入框。")
        }
        self.record("send", label, feedback.outcome, feedback.detail, frontName)
        completion(.success(feedback))
    }

    /// 焦点结论 → 回执。editable 与 unknown 都按"已输入到 X"处理；只有明确的 notEditable 才降级提示。
    /// 这不是把失败说成成功：unknown 的含义是"外部判不了"，而实际使用中（Electron 把焦点报成
    /// 容器）内容绝大多数是进去了的。判不了却给出确定的负面结论，才是真正的失真。
    /// unknown 的现场一律写进 lastFocusProbe，控制台可查，不留无据的沉默。
    private static func receipt(name: String, verdict: FocusVerdict) -> ExecutionFeedback {
        switch verdict {
        case .editable, .unknown:
            return .delivered("已输入到\(name)。")
        case .notEditable:
            return .sent(Self.noFocusHint(name))
        }
    }

    // 前台应用是不是某个目标应用（按 bundleID 或路径比对，与 /api/status 判定保持一致）。
    private func frontmostMatches(targetId: String) -> Bool {
        guard let config = store.resolve(targetId),
              let front = Util.frontmostApp() else { return false }
        if let bundleID = config.bundleID, front.bundleIdentifier == bundleID { return true }
        if let path = config.path, front.bundleURL?.path == path { return true }
        return false
    }


    private func runningApp(targetId: String) -> NSRunningApplication? {
        guard let config = store.resolve(targetId) else { return nil }
        // 同时按 path 与 bundleID 收集候选：NSRunningApplication(processIdentifier:) 现造的对象
        // bundle 信息常常是 nil，而运行列表里的对象是完整的，匹配要建立在后者上。
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            if let path = config.path, app.bundleURL?.path == path { return true }
            if let bundleID = config.bundleID, app.bundleIdentifier == bundleID { return true }
            return false
        }
        guard !candidates.isEmpty else { return nil }
        // 同一个应用可能跑着多个实例（实测这台机器上就有两个 Chrome，bundle 与路径完全相同，
        // 只有一个带着窗口）。激活没带窗口的那个，界面上什么都不会发生——这就是"唤醒没反应"。
        // 故多个候选时优先挑带可见窗口的那个。
        if candidates.count > 1,
           let withWindow = candidates.first(where: { Self.hasVisibleWindow(pid: $0.processIdentifier) }) {
            return withWindow
        }
        return candidates.first
    }

    /// 该进程有没有像样的可见窗口（layer 0、尺寸正常）。用来从同 bundle 的多个实例里认出"带界面的那个"。
    private static func hasVisibleWindow(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let ownerPID = kCGWindowOwnerPID as String
        let layer = kCGWindowLayer as String
        let bounds = kCGWindowBounds as String
        return list.contains { entry in
            guard (entry[ownerPID] as? Int32) == pid, (entry[layer] as? Int) == 0,
                  let dict = entry[bounds] as? [String: Any],
                  let width = dict["Width"] as? CGFloat, let height = dict["Height"] as? CGFloat else { return false }
            return width > 80 && height > 60
        }
    }

    /* ---------- 实时同频输入 ---------- */
    // 手机输入框与电脑输入框的内容对齐：只注入「差异」，不做整框重写。
    // 之所以不整框重写：AXValue 在 Electron 应用上普遍不可写（ChatGPT 桌面版连"谁拿着焦点"
    // 都不肯回答，见 probeFocus 的 -25212 现场），而 CGEvent 键流是本项目唯一被验证过的通路。
    // 差异 = 公共前缀之后的「退掉旧尾巴 + 打上新尾巴」；手机端绝大多数编辑发生在末尾，代价极小。

    /// 当前已同步到电脑端输入框的文本（基线）。它假定"电脑端输入框里的内容就是我们打进去的"，
    /// 一旦这个前提被别处打破（用户在电脑上手动改了框），两端就会漂——故删除量设了上限，
    /// 越界即停手，绝不把用户别处的内容退掉。
    private var mirroredText = ""
    /// 正在为它做激活的目标：激活在途时放弃本次注入（手机端每 ~90ms 会再发一次全文，
    /// 下一次自然补上，没必要在这里排队堆积）。
    private var mirroringTarget: String?
    /// 一次同频最多允许删除的字符数（字素簇）。超过说明基线八成漂了，真按下去会误删。
    private static let maxMirrorDelete = 800

    func mirror(_ command: LiveInputCommand, completion: @escaping (Result<ExecutionFeedback, InputError>) -> Void) {
        queue.async {
            if let reason = EnvironmentGate.blockReason() {
                self.record("live", "实时同频", .blocked, reason)
                completion(.failure(.message(reason))); return
            }
            guard command.text.utf16.count <= 8_000 else {
                completion(.failure(.message("同频文本超过 8,000 字符上限。"))); return
            }
            let targetId = command.targetId ?? Self.frontmostPseudoId
            if self.mirroringTarget != targetId {
                if !self.mirroredText.isEmpty {
                    self.record("live", "实时同频", .sent,
                                "目标切到 \(targetId)，基线归零；已输到上一个目标的文本不会自动撤回。")
                }
                self.mirroredText = ""
                self.mirroringTarget = targetId
            }
            if command.reset == true {
                self.mirroredText = command.text
                completion(.success(.delivered("同步基线已重置为 \(command.text.utf16.count) 字符。")))
                return
            }
            // 目标就在前台（或本来就只投前台）：直接注入。
            if targetId == Self.frontmostPseudoId || self.frontmostMatches(targetId: targetId) {
                self.applyMirror(text: command.text, submit: command.submit == true, completion: completion)
                return
            }
            if self.mirroringTarget != nil {
                let name = self.store.resolve(targetId)?.name ?? targetId
                completion(.failure(.message("正在把\(name)切到前台，稍候。")))
                return
            }
            // 目标不在前台：先把它叫到前台再注入，与 send 的语义一致（选了谁就发给谁）。
            self.mirroringTarget = targetId
            self.activateTarget(targetId) { result in
                self.mirroringTarget = nil
                guard case .success = result else {
                    if case .failure(.message(let message)) = result { completion(.failure(.message(message))) }
                    return
                }
                // 唤醒后给桌面应用一拍把焦点落定，否则头几个字会打在空气里。
                self.queue.asyncAfter(deadline: .now() + .milliseconds(400)) {
                    self.applyMirror(text: command.text, submit: command.submit == true, completion: completion)
                }
            }
        }
    }

    /// 真正落键：算差异 → 退旧尾巴 → 打新尾巴 →（可选）回车。
    private func applyMirror(text: String, submit: Bool, completion: @escaping (Result<ExecutionFeedback, InputError>) -> Void) {
        guard let front = Util.frontmostApp() else {
            completion(.failure(.message("读不到当前前台应用，无法同频。"))); return
        }
        // UU 远程不吃合成按键（只吃剪贴板），同频对它必然落空——早失败，别让人对着没反应的框打字。
        if self.isUUFrontmost() {
            completion(.failure(.message("UU 远程不接收合成按键，实时同频对它无效——请直接点发送（走剪贴板通道）。")))
            return
        }
        let delta = Self.delta(from: self.mirroredText, to: text)
        // 没有差异也不提交：一次键都不敲。手机端每次 input 都可能触发同步，空转要绝对廉价。
        if delta.delete == 0, delta.insert.isEmpty, !submit {
            completion(.success(.delivered("已同频（无变化）。"))); return
        }
        let verdict = self.ensureEditableFocus(pid: front.processIdentifier)
        guard delta.delete <= Self.maxMirrorDelete else {
            let detail = "基线漂移：要删 \(delta.delete) 个字符（上限 \(Self.maxMirrorDelete)），已停手。"
            self.record("live", "实时同频", .failed, detail, front.localizedName)
            completion(.failure(.message(
                "电脑端输入框里的内容和我们同步过去的不一致了（要删 \(delta.delete) 个字才对得上）。为避免误删，已停手——请在电脑上清空那个输入框，再重新输入。")))
            return
        }
        self.deleteBackward(delta.delete)
        self.typeText(delta.insert)
        self.mirroredText = text
        if submit {
            usleep(60_000)           // 让最后一个字落定，再回车
            self.postKey(36)        // Return：内容已经在框里，发送就等价于按一次回车
            self.mirroredText = ""  // 提交后目标框被清空，基线跟着归零
        }
        let name = front.localizedName ?? "当前前台应用"
        let detail = submit ? "已同频并回车提交到\(name)。"
            : "已同频到\(name)（删 \(delta.delete)、补 \(delta.insert.count)）。"
        let feedback: ExecutionFeedback = verdict == .notEditable
            ? .sent(Self.noFocusHint(name)) : .delivered(detail)
        self.record("live", "实时同频", feedback.outcome, feedback.detail, name)
        completion(.success(feedback))
    }

    /// 求新旧文本的差异：公共前缀保留，旧尾巴退掉，新尾巴补上。
    /// 按 Character（字素簇）而不是 UTF-16 计数：一次退格在几乎所有应用里删掉的是一个字素簇，
    /// 若按 UTF-16 计，一个 emoji（代理对）会算成两次退格，从而多删掉它前面那个字。
    private static func delta(from old: String, to new: String) -> (delete: Int, insert: String) {
        let before = Array(old)
        let after = Array(new)
        var index = 0
        while index < before.count && index < after.count && before[index] == after[index] { index += 1 }
        return (before.count - index, String(after[index...]))
    }

    /// 逐字退格。量大时缩短按下时长：几百次退格若沿用贴合物理键盘的 25ms 会拖到好几秒。
    private func deleteBackward(_ count: Int) {
        guard count > 0 else { return }
        let pressMicros: useconds_t = count > 24 ? 3_000 : 25_000
        for index in 0..<count {
            postKey(51, pressMicros: pressMicros)
            if index < count - 1 { usleep(pressMicros) }
        }
    }

    /// 打字。换行不塞进 Unicode 串——"\n" 直接投进聊天输入框会被当成回车发出去，
    /// 故改用 Shift+Return（各家的"换行"键）；其余内容按 32 字一批注入，
    /// 既控制单事件的 Unicode 串长度，也顺带打出逐段落字的观感。
    private func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        for (lineIndex, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if lineIndex > 0 { postKey(36, flags: .maskShift); usleep(30_000) }
            let units = Array(line)
            var offset = 0
            while offset < units.count {
                let end = min(offset + 32, units.count)
                postUnicode(String(units[offset..<end]))
                offset = end
                if offset < units.count { usleep(8_000) }
            }
        }
    }

    /* ---------- 注入前的焦点确认 ---------- */
    // 激活（activate）只保证应用到了前台，不保证里面有输入框拿着键盘焦点。
    // Electron/Chromium 应用尤其典型：窗口起来了，页面里却没有任何 first responder，
    // 此时 postUnicode 投出去的按键石沉大海——这正是"点了发送却什么都没进去"的根因。
    // 用户手动点一下输入框就好，因为那一步才真正把焦点放进去。

    /// 探测某应用里现在谁拿着键盘焦点。
    /// 连 AXError 一起带出来：只有看得到失败原因，才能区分「真的没焦点」「AX 不许我问」
    /// 「焦点停在容器上」——这三种在旧实现里都塌缩成同一个 false，正是误报的来源。
    private static func probeFocus(pid: pid_t) -> (verdict: FocusVerdict, note: String) {
        guard pid > 0 else { return (.unknown, "pid 无效，未探测") }
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw)
        if focusStatus == .success, let element = raw, CFGetTypeID(element) == AXUIElementGetTypeID() {
            return Self.classify(element as! AXUIElement, source: "应用级")
        }
        // 应用级问不出来时（实测 ChatGPT 桌面版直接返回 noValue -25212），不代表没有输入框——
        // 它只是不肯回答。退回系统级 AX 再问一次：系统级问的是"全系统当前谁拿着键盘焦点"，
        // 对这类应用常常答得上来。
        var systemRaw: CFTypeRef?
        let systemStatus = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                        kAXFocusedUIElementAttribute as CFString, &systemRaw)
        if systemStatus == .success, let element = systemRaw, CFGetTypeID(element) == AXUIElementGetTypeID() {
            var ownerPID: pid_t = 0
            AXUIElementGetPid(element as! AXUIElement, &ownerPID)
            // pid 对不上说明焦点在别的应用上，这份答案不属于本次探测的目标，不能采信。
            guard ownerPID == pid else {
                return (.unknown, "系统级焦点属于 pid \(ownerPID)，与目标 \(pid) 不符")
            }
            return Self.classify(element as! AXUIElement, source: "系统级回退")
        }
        return (.unknown, "读不到聚焦元素（应用级 \(focusStatus.rawValue)，系统级 \(systemStatus.rawValue)）")
    }

    /// 给一个已确认拿到手的聚焦元素分类。
    private static func classify(_ element: AXUIElement, source: String) -> (verdict: FocusVerdict, note: String) {
        var value: CFTypeRef?
        let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
        guard roleStatus == .success, let role = value as? String else {
            return (.unknown, "\(source)：读不到 role（AXError \(roleStatus.rawValue)）")
        }
        if editableRoles.contains(role) { return (.editable, "\(source)：聚焦 \(role)") }
        if nonInputRoles.contains(role) { return (.notEditable, "\(source)：聚焦 \(role)，不是可输入控件") }
        // 认不出的角色（容器、web 页面、新角色）一律 unknown：不替用户下负面结论。
        return (.unknown, "\(source)：聚焦 \(role)，无法判定能否接字")
    }

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &raw) == .success,
           let window = raw, CFGetTypeID(window) == AXUIElementGetTypeID() { return (window as! AXUIElement) }
        // 少数应用不给"聚焦窗口"（尤其是刚被激活、窗口还没稳定的时候），退回取第一个窗口。
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement], let first = list.first { return first }
        return nil
    }

    // 抢焦点：先直接设 AXFocused，不行就退化为"按一下"——对输入框而言按一下就是聚焦，与用户手动点击等效。
    // 关键是写完必须等一拍再读：Chromium/Electron 对 AX 聚焦是异步生效的，调用返回 success 时
    // 焦点还没到位，立刻读会读到旧的 AXWebArea，从而误判失败（实测踩到过）。
    private static func takeFocus(_ element: AXUIElement, pid: pid_t) -> Bool {
        if AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success {
            usleep(150_000)
            if hasEditableFocus(pid: pid) { return true }
        }
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else { return false }
        usleep(150_000)
        return hasEditableFocus(pid: pid)
    }

    /// 注入前确保有地方能接字，并给出探测结论供回执分级。
    ///
    /// 只在**明确没有输入框**时才去抢焦点。焦点状态都读不出来（unknown）时绝不乱按：
    /// BFS 找到的第一个输入框未必是用户想要的那个（搜索框常排在更浅层），按下即改焦点，
    /// 把内容送进错误的框比送不进去更难发现。
    @discardableResult
    private func ensureEditableFocus(pid: pid_t) -> FocusVerdict {
        guard pid > 0 else {
            Self.noteProbe(pid: pid, verdict: .unknown, note: "pid 无效，未探测")
            return .unknown
        }
        let probe = Self.probeFocus(pid: pid)
        if probe.verdict != .notEditable {
            Self.noteProbe(pid: pid, verdict: probe.verdict, note: probe.note + "（未干预焦点）")
            return probe.verdict
        }
        let candidates = Self.editableCandidates(pid: pid)
        // 只去抢「输入框」：BFS 是层序的，浅层的搜索框/下拉会排在前头，而把内容打进搜索框
        // 比打不进去更难发现。所以既不能"找到第一个就用"，也不碰 ComboBox/SearchField。
        for role in Self.focusPriority {
            guard let hit = candidates.first(where: { $0.role == role }) else { continue }
            guard Self.takeFocus(hit.element, pid: pid) else { continue }
            // 抢完必须重新探一次：焦点可能已经变了。探测仍是 unknown 也照实返回——
            // 尽力干预过就把 unknown 交回去，不再升级成"没有输入框"的负面结论。
            let after = Self.probeFocus(pid: pid)
            Self.noteProbe(pid: pid, verdict: after.verdict, note: after.note + "（已尝试聚焦 \(role)）")
            return after.verdict
        }
        Self.noteProbe(pid: pid, verdict: .notEditable, note: probe.note + "（未找到可聚焦的输入框）")
        return .notEditable
    }

    /// 记下最近一次焦点探测的现场。只看到"没有聚焦的输入框"无法区分「真没聚焦」与
    /// 「AX 把 Electron 的 contenteditable 报成了容器」，排查全靠这份现场。控制台可读。
    private static let probeLock = NSLock()
    private static var lastProbe: [String: Any] = [:]
    static var lastFocusProbe: [String: Any] {
        probeLock.lock(); defer { probeLock.unlock() }
        return lastProbe
    }
    private static func noteProbe(pid: pid_t, verdict: FocusVerdict, note: String, via: String = "发送前探测") {
        let app = NSRunningApplication(processIdentifier: pid)
        let snapshot: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "app": app?.localizedName ?? "(未知)",
            "bundleID": app?.bundleIdentifier ?? "",
            "pid": Int(pid),
            "verdict": String(describing: verdict),
            "note": note,
            "via": via,
        ]
        probeLock.lock()
        lastProbe = snapshot
        probeLock.unlock()
    }

    /// 只读探测当前前台应用的焦点现场：不注入任何事件，只回答"现在谁拿着键盘焦点"。
    /// 排查「报没有聚焦的输入框」这类误报时，这是唯一能分清「真没聚焦」与
    /// 「AX 把 Electron 的 contenteditable 报成容器角色」的手段。
    static func probeFrontmostFocus() -> [String: Any] {
        guard let front = Util.frontmostApp() else { return ["error": "读不到前台应用"] }
        let probe = Self.probeFocus(pid: front.processIdentifier)
        Self.noteProbe(pid: front.processIdentifier, verdict: probe.verdict,
                       note: probe.note, via: "/api/focus-probe（只读）")
        return Self.lastFocusProbe
    }

    private static func hasEditableFocus(pid: pid_t) -> Bool {
        Self.probeFocus(pid: pid).verdict == .editable
    }

    // 窗口里所有可输入元素（有界 BFS，最多 400 个节点）。
    private static func editableCandidates(pid: pid_t) -> [(element: AXUIElement, role: String)] {
        guard let window = focusedWindow(pid) else { return [] }
        var found: [(element: AXUIElement, role: String)] = []
        var level = [window]
        var visited = 0
        while !level.isEmpty, visited < 400 {
            var next: [AXUIElement] = []
            for element in level {
                visited += 1
                var roleValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
                   let role = roleValue as? String, editableRoles.contains(role) {
                    found.append((element, role))
                }
                var childrenValue: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                   let children = childrenValue as? [AXUIElement] { next.append(contentsOf: children) }
            }
            level = next
        }
        return found
    }

    // 焦点探测的三态结论。之所以不能只有「有 / 没有」两态：探测不到不等于没有。
    // Electron / Chromium 常把聚焦元素报成 AXWebArea（页面容器）而不是真正的输入框，
    // 此时 CGEvent 照样会路由到 DOM 的 document.activeElement，内容确实进去了——
    // 把这种情况说成"没有聚焦的输入框"，就是每次发送都误报一次。
    // 取舍：误报会让人不再相信这条提示（进而忽略真正需要它的那一次），代价高于漏报。
    // 故只有拿到"聚焦的不是输入框"这个**正面证据**才提示，其余一律不打扰用户。
    private enum FocusVerdict {
        case editable       // 聚焦元素明确是可输入控件：内容有去处
        case unknown        // 无从判定（探测失败 / 焦点停在容器上 / 认不出的角色）
        case notEditable    // 聚焦元素明确不是可输入控件：内容大概率没有去处
    }

    // 可输入角色：AX 里能接住键盘输入的元素。Chromium/Electron 把 <textarea> 与 contenteditable
    // 暴露成 AXTextArea，把 <input> 暴露成 AXTextField，搜索框是 AXSearchField。
    private static let editableRoles: Set<String> = [
        kAXTextFieldRole as String, kAXTextAreaRole as String,
        kAXComboBoxRole as String, "AXSearchField",
    ]

    // 「确定不是输入框」的角色。只有命中这些才敢说"内容没进去"。
    // 认不出的角色一律归 unknown——遇到新角色时宁可沉默，也不误伤。
    private static let nonInputRoles: Set<String> = [
        kAXButtonRole as String, kAXCheckBoxRole as String, kAXRadioButtonRole as String,
        kAXPopUpButtonRole as String, kAXMenuItemRole as String, kAXMenuBarItemRole as String,
        kAXMenuBarRole as String, kAXMenuRole as String, kAXImageRole as String,
        kAXStaticTextRole as String, kAXSliderRole as String,
        kAXToolbarRole as String, kAXProgressIndicatorRole as String, kAXValueIndicatorRole as String,
        "AXLink",   // SDK 没导出 kAXLinkRole，只能用字面量（web 页面里的超链接）
    ]

    // 抢焦点的角色优先级：只认输入框，不碰下拉与搜索（理由见 ensureEditableFocus）。
    private static let focusPriority: [String] = [
        kAXTextAreaRole as String, kAXTextFieldRole as String,
    ]

    // 「应用在前台但里面没有聚焦输入框」这句人话：既说清现象，也给出一步可执行的补救。
    private static func noFocusHint(_ appName: String) -> String {
        "\(appName)已在前台，但它没有聚焦的输入框，内容可能没进去——请先在电脑上点一下要输入的位置，再发送。"
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

    // 激活分三段：发起 → 校验 → 抢救。之所以不能"发起完就回成功"，是因为 PocketDesk 自己从不是前台应用，
    // 请求递出去之后系统同不同意（窗口在别的桌面空间、被最小化、被远控软件按住焦点）它一概不知。
    // 回执只能由系统说了算：问 AX 现在谁拿着焦点。
    private func activateTarget(_ targetId: String, completion: @escaping (Result<Void, InputError>) -> Void) {
        guard let config = store.resolve(targetId) else {
            completion(.failure(.message("未知的目标应用。"))); return
        }
        guard let url = store.appURL(config) else {
            completion(.failure(.message("未找到 \(config.name)。请确认应用已安装或在控制台重新选择。"))); return
        }
        // 一律走 NSWorkspace.openApplication：它是 LaunchServices 的"用户意图"通道，实测能把应用带到前台，
        // 已运行的应用也只是被激活、不会重复开。
        // 不能用 NSRunningApplication.activate() 代替：PocketDesk 是常驻后台的 agent，从不是活动应用，
        // 由此发起的 activate 会被系统丢弃（实测对 Chrome 必失败，而 openApplication 稳定成功）；
        // 想靠 .activateIgnoringOtherApps 加强也不行了——macOS 14 起它被废弃且明确不再有效果。
        // 这里的 activate 只是 openApplication 之后的轻推，不是主力。
        let wasRunning = runningApp(targetId: targetId) != nil
        let activate: (NSRunningApplication?) -> Void = { app in
            app?.unhide()
            app?.activate(options: [.activateAllWindows])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            if let error {
                self.record("activate", "唤醒 \(config.name)", .failed, "无法打开：\(error.localizedDescription)")
                completion(.failure(.message("无法打开 \(config.name)：\(error.localizedDescription)"))); return
            }
            activate(application)
            // 冷启动要等应用把窗口建起来再开始轮询；已运行的直接进入轮询。
            self.queue.asyncAfter(deadline: .now() + .milliseconds(wasRunning ? 150 : 800)) {
                self.verifyActivation(targetId: targetId, name: config.name, attempt: 1, completion: completion)
            }
        }
    }

    /// 校验激活是否真的生效：轮询等待，中途抢救一次，到期仍不生效就如实报错。
    /// 宁可让用户看到"它没起来，你去电脑上点一下"，也不返回一个假 ok——假 ok 只会让人反复点手机。
    private func verifyActivation(targetId: String, name: String, attempt: Int, completion: @escaping (Result<Void, InputError>) -> Void) {
        let label = "唤醒 \(name)"
        // 没有辅助功能授权时无从判定，退回旧行为（相信系统调用），绝不因为判不了就报失败。
        guard AXIsProcessTrusted() else { completion(.success(())); return }
        // 实测：目标窗口在另一块显示器 / 另一个桌面空间时，激活到焦点落定可能要 2~3 秒
        //（显示器或空间切换本身有开销）。只等几百毫秒会把"慢"误判成"失败"——
        // 用户看到报错，可几秒后画面其实已经切过去了。故轮询到 3.5 秒再下结论。
        let maxAttempts = 7   // 7 × 500ms ≈ 3.5s
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
            // 判定复用 frontmostMatches（按 bundleID/path 认应用），别拿 pid 硬比：
            // 多进程应用里"目标 pid"和"AX 焦点 pid"未必是同一个进程。
            if self.frontmostMatches(targetId: targetId) {
                let pid = self.runningApp(targetId: targetId)?.processIdentifier ?? -1
                // 焦点对了不等于用户看得见：窗口可能在另一个桌面空间或另一块显示器上（多屏时很常见，
                // 用户盯着内建屏就会以为"没唤醒"）。日志里说清楚，回执仍算成功——毕竟它确实在最前了。
                let visible = pid <= 0 || self.windowCount(pid: pid) > 0
                self.record("activate", label, visible ? .delivered : .sent,
                            visible ? "已置于前台。"
                                    : "已激活，但当前桌面看不到它的窗口——可能在另一个桌面空间或另一块显示器。", name)
                completion(.success(())); return
            }
            guard attempt < maxAttempts else {
                let front = Util.frontmostApp()
                let frontName = front?.localizedName ?? "其他应用"
                // 锁屏时前台是 loginwindow：这是硬限制，不是 PocketDesk 的毛病，文案必须说准，
                // 否则用户会去翻"窗口是不是最小化了"这种不存在的可能。
                if front?.bundleIdentifier == "com.apple.loginwindow" {
                    self.record("activate", label, .blocked, "电脑处于锁屏/登录界面。", frontName)
                    completion(.failure(.message("这台电脑当前停在锁屏或登录界面，切不了应用。请先在电脑上解锁，再点一次唤醒。")))
                    return
                }
                let pid = self.runningApp(targetId: targetId)?.processIdentifier ?? -1
                // 多显示器下最常见的一种"唤醒没反应"：应用其实起来了，只是窗口在旁边那块屏，
                // 用户盯着主屏自然什么都没看见。与其让他去猜，不如直说窗口在哪儿。
                if Self.hasWindowOutsideMainScreen(pid: pid) {
                    self.record("activate", label, .sent, "已激活，但窗口不在主屏（在另一块显示器上）。", name)
                    completion(.failure(.message(
                        "\(name) 已经起来了，可它的窗口在另一块显示器上——请看看旁边那块屏；想在主屏操作，把它拖过来再唤醒。")))
                    return
                }
                self.record("activate", label, .failed, "未能置于前台，当前前台是 \(frontName)。", frontName)
                completion(.failure(.message(
                    "\(name) 没能切到前台（画面仍停在 \(frontName)）。它的窗口可能最小化了，或在另一个桌面空间——请先在这台电脑上点一下它，再试一次。")))
                return
            }
            // 抢救：取消最小化并把窗口提到最前。救的是"应用已被激活、窗口却没跟过来"这一种
            //（多桌面、多显示器、最小化后都可能这样）。只在第一次没落定时做，之后纯粹等。
            if attempt == 1 { Self.raiseWindow(pid: self.runningApp(targetId: targetId)?.processIdentifier ?? -1) }
            self.verifyActivation(targetId: targetId, name: name, attempt: attempt + 1, completion: completion)
        }
    }

    /// 应用有像样的可见窗口，但没有一个落在主屏上——多显示器下"唤醒了却什么都没变"的典型成因。
    /// CGWindowList 的 bounds 是左上原点，NSScreen.frame 是左下原点，这里只比横向范围，
    /// 不做坐标换算（够用，也不引入翻转出错的机会）。
    private static func hasWindowOutsideMainScreen(pid: pid_t) -> Bool {
        guard pid > 0, let main = NSScreen.main,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let ownerPID = kCGWindowOwnerPID as String
        let layer = kCGWindowLayer as String
        let bounds = kCGWindowBounds as String
        var sawWindow = false
        for entry in list where (entry[ownerPID] as? Int32) == pid && (entry[layer] as? Int) == 0 {
            guard let dict = entry[bounds] as? [String: Any],
                  let x = dict["X"] as? CGFloat, let width = dict["Width"] as? CGFloat,
                  let height = dict["Height"] as? CGFloat, width > 80, height > 60 else { continue }
            sawWindow = true
            if x < main.frame.width && x + width > 0 { return false }   // 与主屏有横向交集，算在主屏
        }
        return sawWindow
    }

    /// 把某应用的窗口提到最前：先设 frontmost，再逐个取消最小化并 raise。
    /// 跨桌面空间的窗口 AX 未必列得出来，那时这里会安静地失败，交给上层如实报错。
    @discardableResult
    private static func raiseWindow(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &raw) == .success,
              let windows = raw as? [AXUIElement], !windows.isEmpty else { return false }
        for window in windows.prefix(3) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        return true
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

    /// pressMicros 是按下与抬起的间隔：默认 25ms 贴合物理按键；连续退格上百次时调用方会缩短它，
    /// 否则光删一段话就要好几秒。
    @discardableResult
    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = [], pressMicros: useconds_t = 25_000) -> Bool {
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
