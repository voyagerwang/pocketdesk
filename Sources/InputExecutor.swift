/**
 * [INPUT]: 依赖 AppKit 的 NSWorkspace/NSPasteboard、ApplicationServices 的 AXUIElement、CoreGraphics 的 CGEvent/CGEventSource；消费 Models 的命令词汇、ImageBatchStore 的有界多图资源、ImagePastePolicy 的目标专属时序、ExecutionTrace 的门禁与结果分级、TargetStore/InputFocus/InputBinding/LiveDraft 的目标和草稿事务。
 * [OUTPUT]: 对外提供 InputExecutor：应用激活与焦点校验（含已确认目标进程与副屏说明）、草稿快照事务、结构化草稿状态（active/interrupted/recoverable/needs-user-focus/committed）与只读恢复探测、显式整段清空（幂等、可从冻结态破冰；文档类目标只清手机侧）、统一的 UU 文字剪贴板时序、有序多图逐张粘贴后单次提交（Chrome 多图在经当前页面核验的鼠标锚点重建附件插入点）、应用切回后从当前焦点继续已输入正文、部分执行失败禁止重放、快捷键注入及最近焦点诊断。
 * 安全边界：锁屏密码仅走 HTTPS 专用执行器，普通输入在锁屏时受阻；安全监听共享原控制租约。
 * [POS]: Sources 的键盘输入执行层；Server 把 /api/activate、/api/send、/api/live-input、/api/image、/api/shortcut-trigger 委托给它，与 PointerExecutor（指针）平行为一对执行兄弟。
 * [PROTOCOL]: 删除键经 postDeleteKey 发送（不携带 DEL 字符），避免 Chromium 把 Backspace 当成 Delete 键；clearScopeAllowsComputer 不再按进程白名单一刀切拦掉聊天类应用（飞书/钉钉等同进程文档与消息无法从 bundle 区分），改由 focusedInDocument 按需保护真实文档正文；变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import CoreGraphics
import Foundation

final class InputExecutor {
    private typealias FocusVerdict = InputFocus.FocusVerdict
    static var lastFocusProbe: [String: Any] { InputFocus.lastFocusProbe }
    static func probeFrontmostFocus() -> [String: Any] { InputFocus.probeFrontmostFocus() }
    static let frontmostPseudoId = "__frontmost__"
    // UU 远程特殊通道：UU 的键盘同步不吃合成 Unicode 事件（表现为只透传占位符），
    // 但剪贴板是应用层双向同步的——发往 UU 的内容改走「写剪贴板 + Cmd+V + Return」。
    static let uuRemoteId = "uu"
    private let queue = DispatchQueue(label: "dev.voicedeck.input")
    private let store: TargetStore
    // 手机预上传的待发图片；send(usePendingImage) 时取出消费。
    private var pendingImageData: Data?
    private let pendingLock = NSLock()
    private let imageBatches = ImageBatchStore()

    init(store: TargetStore) { self.store = store }

    func stageImage(_ data: Data, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async {
            guard data.count <= ImageBatchStore.maxImageBytes else {
                completion(.failure(.message("单张图片不能超过 8MB。"))); return
            }
            self.pendingLock.lock()
            self.pendingImageData = data
            self.pendingLock.unlock()
            completion(.success(()))
        }
    }

    func stageImage(batchId: String, imageId: String, data: Data, completion: @escaping (Result<Void, InputError>) -> Void) {
        queue.async {
            do { try self.imageBatches.stage(batchId: batchId, imageId: imageId, data: data); completion(.success(())) }
            catch let error as InputError { completion(.failure(error)) }
            catch { completion(.failure(.message(error.localizedDescription))) }
        }
    }

    private func takePendingImage() -> Data? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        let data = pendingImageData
        pendingImageData = nil
        return data
    }

    /// 激活结果：确认归位后的目标进程与补充说明。
    /// 定位由**显式入口**（Server，只在手机手动选择应用时）编排并交给 PointerExecutor 执行；
    /// 执行层自己不碰鼠标，自动跟随/发送文本/快捷键的隐式激活也都拿不到鼠标副作用。
    struct ActivateOutcome {
        let pid: pid_t?
        let note: String
    }

    func activate(_ targetId: String, completion: @escaping (Result<ActivateOutcome, InputError>) -> Void) {
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
            let images = [stagedImage ?? inlineImage].compactMap { $0 }
            if command.usePendingImage == true && images.isEmpty {
                completion(.failure(.message("图片未找到或已过期，请重新选择。"))); return
            }
            let hasText = !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasText || !images.isEmpty else {
                completion(.failure(.message("先输入一点内容或选择一张图片。"))); return
            }
            guard command.text.utf16.count <= 8_000 else {
                completion(.failure(.message("单次文本最多 8,000 个 UTF-16 字符。"))); return
            }
            self.dispatchSend(command, imageData: images, completion: completion)
        }
    }

    // 统一执行路径：先输入文字，再粘贴可选图片，最后提交。
    private func dispatchSend(_ command: SendCommand, imageData: [Data], completion: @escaping (Result<ExecutionFeedback, InputError>) -> Void) {
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
                let verdict = InputFocus.ensureEditableFocus(pid: Util.frontmostApp()?.processIdentifier ?? -1)
                self.performPaste(imageData: imageData, text: command.text,
                    bundleIdentifier: Util.frontmostApp()?.bundleIdentifier)
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
                let verdict = InputFocus.ensureEditableFocus(pid: self.runningApp(targetId: command.targetId)?.processIdentifier ?? -1)
                self.performPaste(imageData: imageData, text: command.text,
                    bundleIdentifier: self.runningApp(targetId: command.targetId)?.bundleIdentifier)
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
        // 旧客户端的独立发送改变了编辑器，正在进行的快照会话必须停止。
        if let draft = liveDraft { _ = draft.stop("电脑内容已被独立发送修改，请开始新的草稿。") }
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
            return .sent(InputFocus.noFocusHint(name))
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

    /* ---------- 实时草稿：整值或选区替换；UU 特殊通道才暂存 ---------- */
    private var liveDraft: LiveDraft?
    // 当前轮次的写入器。**必须可替换**：清空之后要重新捕获焦点控件并重建基线——旧元素在
    // Electron 重建编辑器、或被外部（快捷键/应用自身）清空之后，可能已不再代表那个输入框。
    private var liveWriter: KeyboardDraftWriter?
    // 草稿跨多次请求；每次执行使用本次租约，不能永久捕获首次请求的旧 session。
    private var liveAuthorization: () -> Bool = { false }
    private var completedDrafts: [String: (text: String, receipt: LiveInputReceipt)] = [:]
    private var completedOrder: [String] = []
    private var imageExecutionDrafts = Set<String>()
    private var imageExecutionOrder: [String] = []

    func mirror(_ command: LiveInputCommand, authorized: @escaping () -> Bool = { true }, completion: @escaping (Result<LiveInputReceipt, LiveInputFailure>) -> Void) {
        queue.async {
            // 提交/图片粘贴/草稿写入期间置位：看门狗据此推迟自愈重启（这些事务不可重放）。
            InputActivity.shared.begin()
            defer { InputActivity.shared.end() }
            do { completion(.success(try self.applyDraft(command, authorized: authorized))) }
            catch let failure as LiveDraftFailure {
                self.record("live", "草稿输入", .blocked, failure.message)
                completion(.failure(LiveInputFailure(message: failure.message, state: failure.state.rawValue)))
            } catch {
                self.record("live", "草稿输入", .blocked, error.localizedDescription)
                completion(.failure(LiveInputFailure(message: error.localizedDescription,
                                                    state: DraftState.needsUserFocus.rawValue)))
            }
        }
    }

    /// 建写入器：门禁（控制租约 + 绑定）与三个原语只此一份，"开新轮次"与"清空后重捕获"共用。
    private func makeLiveWriter(pid: pid_t, context: String) -> KeyboardDraftWriter {
        KeyboardDraftWriter(pid: pid,
            valid: { [weak self] in self?.liveAuthorization() == true && InputBinding.shared.validate(context) },
            key: { [weak self] code, flags in
                guard let self else { return false }
                // 删除键（51）不携带字符：Backspace 由 keycode 驱动；通用 postKey 会为 51 强制写入
                // DEL 字符，Chromium/Electron 据此把它解析成 Delete 键（向前删），在受控输入框上
                // 表现为删除方向/范围错乱（删不全）。其余键（回车/方向键）保留 characters 补值。
                return code == 51 ? self.postDeleteKey(flags: flags) : self.postKey(code, flags: flags, pressMicros: 1_500) == true
            },
            insert: { [weak self] text in self?.insertLiveText(text) == true })
    }

    /// 删除键专用发送：不设置 characters。Backspace 语义由 keycode 51 决定；若强行带 DEL 字符，
    /// Chromium 会按 "Delete" 键处理（向前删而非向后删），在 ChatGPT / WorkBuddy 等 Electron 输入框上造成删不全。
    private func postDeleteKey(flags: CGEventFlags = []) -> Bool {
        guard LockScreenInput.state == "unlocked",
              let down = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: 51, keyDown: true),
              let up = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: 51, keyDown: false) else { return false }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); usleep(25_000); up.post(tap: .cghidEventTap)
        return true
    }

    // 「清空」的作用范围：会话输入框两边一起清，文档类目标只清手机侧。
    // 整段删除在文档里等于毁掉正文，在会话框里只是删掉草稿——两者风险差着数量级，所以判据取
    // "能证明是文档"的证据，不按应用印象一刀切。
    private static let documentLikeApps: Set<String> = [
        "com.apple.TextEdit", "com.apple.Pages", "com.apple.Notes",
        "com.microsoft.Word", "com.kingsoft.wpsoffice.mac",
        // 仅收录「整窗即文档」的原生编辑器。飞书/钉钉等把文档与消息放在同一进程、无法从 bundle 区分，
        // 故不再在此按进程一刀切拦掉：聊天输入框清空是用户主动操作，应两边一起清；
        // 真正的文档正文保护改由 focusedInDocument（焦点元素所在窗口挂真实文件文档）按需兜底。
    ]

    /// 文档证据：焦点元素往上找窗口，窗口带 AXDocument 且指向真实文件即为文档。
    /// 原生文档编辑器（TextEdit 的 .txt、Pages 文稿）走这条；网页类编辑器通常不暴露该属性。
    private func focusedInDocument(pid: pid_t) -> Bool {
        func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
        }
        guard let focused = InputFocus.focusedElement(pid: pid),
              let raw = attribute(focused, kAXWindowAttribute as CFString),
              CFGetTypeID(raw) == AXUIElementGetTypeID(),
              let document = attribute(raw as! AXUIElement, kAXDocumentAttribute as CFString) as? String,
              let url = URL(string: document) else { return false }
        return url.isFileURL
    }

    private func clearScopeAllowsComputer(front: NSRunningApplication) -> Bool {
        // 认不出应用身份就不动电脑：清空是删除动作，宁可只清手机也不赌。
        guard let bundle = front.bundleIdentifier, !Self.documentLikeApps.contains(bundle) else { return false }
        return !focusedInDocument(pid: front.processIdentifier)
    }

    private func applyDraft(_ command: LiveInputCommand, authorized: @escaping () -> Bool) throws -> LiveInputReceipt {
        if let reason = EnvironmentGate.blockReason() {
            throw LiveDraftFailure(message: reason, state: .needsUserFocus)
        }
        guard authorized(), command.text.utf16.count <= 8_000 else {
            throw LiveDraftFailure(message: "控制权已变化或文本超过 8,000 字符，草稿已保留。", state: .needsUserFocus)
        }
        liveAuthorization = authorized
        guard let id = command.draftId, !id.isEmpty, id.count <= 100 else {
            // 旧手机页面不能再调用逐字退格路径；刷新后使用带草稿身份的新协议。
            throw LiveDraftFailure(message: "输入方式已升级，请保留草稿并刷新手机页面。", state: .needsUserFocus)
        }
        // 只读恢复探测：只核验绑定与内容，绝不写入任何字符。手机在弹窗关闭、页面回前台、
        // 输入框重新聚焦或低频探针时发它，据返回的 state 决定"自动续接 / 继续冻结 / 提示用户点一下"。
        if command.probe == true { return try probeDraft(id: id, command: command) }
        if let done = completedDrafts[id] {
            guard command.submit == true, done.text == command.text else {
                throw LiveDraftFailure(message: "本轮已提交，请开始新的草稿。", state: .committed)
            }
            return done.receipt
        }
        if command.submit == true, imageExecutionDrafts.contains(id) {
            throw LiveDraftFailure(message: "图片发送已开始过，请检查电脑内容并新建草稿，避免重复发送。")
        }
        guard command.reset != true else { throw LiveDraftFailure(message: "请清空手机草稿后重新开始输入。") }
        let target = command.targetId ?? Self.frontmostPseudoId
        guard target == Self.frontmostPseudoId || frontmostMatches(targetId: target),
              let front = Util.frontmostApp() else {
            // 目标应用暂时不在前台属于焦点中断：草稿与基线都保留，用户把应用切回来即可自动续接。
            throw LiveDraftFailure(message: "目标应用已不在前台，草稿已保留；切回它就会自动继续。",
                                   state: .interrupted)
        }
        let context: String
        var resumeAtCurrentFocus = false
        if let draft = liveDraft, draft.id == id, command.retry == true, command.submit == true,
           draft.stopped {
            // 用户在失败后再次发送，代表已把目标应用和插入点切回当前可见位置。正文在暂停前
            // 已经按实时输入写过，重新绑定只接管后续图片/Return，绝不能把全文再注入一次。
            if let requested = command.context, InputBinding.shared.validate(requested) {
                context = requested
            } else {
                let binding = InputBinding.shared.establish()
                guard let established = binding["context"] as? String else {
                    throw LiveDraftFailure(message: binding["error"] as? String ?? "无法确定电脑输入框。")
                }
                context = established
            }
            resumeAtCurrentFocus = true
        } else if let draft = liveDraft, draft.id == id {
            // 同一轮只验证原绑定，不能重新探测并换发令牌。空框开始时 AX 可能只识别到
            // 应用，首字落入后才暴露编辑元素；能力提升不代表用户切换了输入位置。
            context = draft.context
        } else {
            let binding = InputBinding.shared.establish()
            guard let established = binding["context"] as? String else {
                throw LiveDraftFailure(message: binding["error"] as? String ?? "无法确定电脑输入框。")
            }
            context = established
        }
        guard command.context == nil || command.context == context else {
            throw LiveDraftFailure(message: "输入位置已变化，请在电脑上点一下原输入框再继续；手机草稿已保留。",
                                   state: .needsUserFocus)
        }
        if liveDraft?.id != id || resumeAtCurrentFocus {
            // helper 无故丢失会话时不能把全文再追加一次；用户从暂停态再次提交则已明确
            // 采用当前焦点，resumedText 只建立基线而不重放正文，可以安全重建。
            guard resumeAtCurrentFocus ||
                    (command.expectedMode != "replace" && command.expectedMode != "selection") else {
                throw LiveDraftFailure(message: "同步会话已失效，请检查电脑已有内容；手机草稿已保留。",
                                       state: .needsUserFocus)
            }
            liveWriter = makeLiveWriter(pid: front.processIdentifier, context: context)
            liveDraft = LiveDraft(id: id, context: context, target: target, editor: AXDraftEditor.capture(front),
                // 闭包经 self.liveWriter 取用"当前"写入器：清空会换掉它，闭包不能抓旧实例不放。
                selectionWriter: front.bundleIdentifier == "com.netease.uuremote" ? nil : { [weak self] old, new in
                    guard let writer = self?.liveWriter else { return false }
                    let updated = writer.update(from: old, to: new)
                    if !updated {
                        ExecutionLog.shared.append(kind: "live-diagnostic", label: "草稿停止原因", outcome: .failed,
                            detail: writer.diagnostic, frontApp: front.localizedName)
                    }
                    return updated
                },
                reconcileSelection: { [weak self] previous, attempted in
                    self?.liveWriter?.confirmedText(previous: previous, attempted: attempted)
                },
                // 目标应用是否仍在前台：探测据此区分"焦点短暂中断"与"用户已经去了别处"。
                targetFrontmost: { [weak self] in
                    target == Self.frontmostPseudoId || self?.frontmostMatches(targetId: target) == true
                },
                resumedText: resumeAtCurrentFocus ? command.text : nil)
        }
        guard let draft = liveDraft else { throw LiveDraftFailure(message: "无法建立输入会话。") }
        guard draft.context == context, draft.target == target, InputBinding.shared.validate(context) else {
            // 绑定失效：记录绑定层给出的失效原因（不含正文），并交给状态机判定能否自动续接。
            throw draft.stop("同步位置暂时失效，草稿已冻结；回到原输入框会自动继续（\(InputBinding.shared.lastInvalidReason)）。",
                             .interrupted, resumable: true)
        }
        // 显式清空：走幂等路径，**不碰旧基线**（见 LiveDraft.clear）。必须排在 retry/recover 之前——
        // 冻结态的 recover() 要求核对原基线，而清空恰恰发生在基线已经分叉的时候；排在后面就会先被
        // "还不能核对原输入框"挡掉，那正是用户看到的死循环。
        if command.clear == true {
            // 文档类目标只清手机侧：整段删除在文档里等于毁掉正文。
            let clearsComputer = draft.mode != .deferred && clearScopeAllowsComputer(front: front)
            try draft.clear {
                guard clearsComputer else { return true }
                // 重新捕获当前焦点控件再删：旧元素在 Electron 重建编辑器之后可能已失效，
                // 继续对着它读回永远对不上——那正是"清空之后再不同步"的死法。
                let fresh = self.makeLiveWriter(pid: front.processIdentifier, context: context)
                guard fresh.clearAll() else {
                    self.record("live-diagnostic", "清空失败原因", .failed, fresh.diagnostic, front.localizedName)
                    return false
                }
                // 删净之后重建基线：这一轮后续的插入要以"空框 @ 光标 0"为起点。
                self.liveWriter = self.makeLiveWriter(pid: front.processIdentifier, context: context)
                return true
            }
            InputBinding.shared.recordConfirmed(context, text: "")
            let note = clearsComputer ? "已清空电脑与手机上的输入内容。"
                                      : "文档类输入：只清空了手机草稿，电脑内容未动。"
            record("live", "清空会话", clearsComputer ? .delivered : .buffered, note, front.localizedName)
            let feedback = clearsComputer ? ExecutionFeedback.delivered(note)
                                          : ExecutionFeedback(outcome: .buffered, detail: note)
            return LiveInputReceipt(feedback: feedback, mode: draft.mode.rawValue, committed: false,
                                    state: DraftState.active.rawValue, note: note)
        }
        if command.retry == true && !resumeAtCurrentFocus { try draft.recover() }
        try draft.update(command.text)
        InputBinding.shared.recordConfirmed(context, text: draft.text)
        guard command.submit == true else {
            let feedback: ExecutionFeedback
            switch draft.mode {
            case .replace: feedback = .delivered("已同步到\(front.localizedName ?? "当前应用")。")
            case .selection: feedback = .sent("实时输入已发出。")
            case .deferred: feedback = .init(outcome: .buffered, detail: "此远控通道仅支持发送时输入。")
            }
            return LiveInputReceipt(feedback: feedback, mode: draft.mode.rawValue, committed: false,
                                    state: DraftState.active.rawValue, note: "")
        }
        let images: [Data]
        do { images = try resolveImages(batchId: command.imageBatchId, imageIds: command.imageIds) }
        catch InputError.message(let message) { throw LiveDraftFailure(message: message) }
        catch { throw LiveDraftFailure(message: error.localizedDescription) }
        let legacyImage = images.isEmpty && command.usePendingImage == true ? takePendingImage() : nil
        let allImages = images.isEmpty ? [legacyImage].compactMap { $0 } : images
        if command.usePendingImage == true && allImages.isEmpty {
            throw LiveDraftFailure(message: "图片未找到，请重新选择；文字草稿已保留。")
        }
        let pictures = allImages.compactMap(NSImage.init(data:))
        if pictures.count != allImages.count {
            throw LiveDraftFailure(message: "图片无法读取，请重新选择；文字草稿已保留。")
        }
        guard !command.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !allImages.isEmpty else {
            throw LiveDraftFailure(message: "先输入一点内容或选择一张图片。")
        }
        let valid = { authorized() && InputBinding.shared.validate(context) }
        guard valid() else {
            throw draft.stop("草稿文字已经输入，但输入位置或控制权已变化；请检查电脑内容，勿重复发送。",
                             .needsUserFocus)
        }
        // Chrome 飞书多图的点击锚点必须在任何提交期外部写入之前确认。预检失败时既不粘
        // deferred 正文，也不登记图片执行防重放，用户修正鼠标位置后仍可安全重试。
        let pasteTiming = ImagePastePolicy.timing(bundleIdentifier: front.bundleIdentifier, imageCount: pictures.count)
        let clickAnchor: InputFocus.EditableAnchor?
        if pasteTiming.interImageClickMicros != nil {
            let point = CGEvent(source: nil)?.location
            guard let point, let anchor = InputBinding.shared.captureClickAnchor(context, point: point) else {
                throw LiveDraftFailure(message: "请先把电脑鼠标放在飞书输入框内，再发送多张图片。")
            }
            clickAnchor = anchor
        } else { clickAnchor = nil }
        // deferred 从未向电脑写过草稿，只在此处粘贴一次最终全文。replace 只提交已有文本。
        if draft.mode == .deferred && !command.text.isEmpty {
            guard pasteTextViaClipboard(command.text, bundleIdentifier: front.bundleIdentifier) else {
                throw draft.stop("正文粘贴动作失败；请检查电脑内容，勿重复发送。")
            }
        }
        if !pictures.isEmpty {
            imageExecutionDrafts.insert(id); imageExecutionOrder.append(id)
            if imageExecutionOrder.count > 32 { imageExecutionDrafts.remove(imageExecutionOrder.removeFirst()) }
        }
        for (index, picture) in pictures.enumerated() {
            guard valid() else { throw draft.stop("文字可能已经输入，位置已变化；请检查电脑内容，勿重复发送。") }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([picture]) else {
                throw draft.stop("图片粘贴动作失败；请检查电脑内容，勿重复发送。")
            }
            if pasteTiming.clipboardSettleMicros > 0 { usleep(pasteTiming.clipboardSettleMicros) }
            guard postKey(9, flags: .maskCommand) else {
                throw draft.stop("图片粘贴动作失败；请检查电脑内容，勿重复发送。")
            }
            usleep(pasteTiming.consumptionMicros)
            if ImagePastePolicy.needsInterImageClick(timing: pasteTiming, imageIndex: index, imageCount: pictures.count) {
                guard authorized(), InputBinding.shared.validateOwner(context), let clickAnchor,
                      InputFocus.validateStoredAnchor(clickAnchor),
                      postLeftClick(at: clickAnchor.point) else {
                    throw draft.stop("图片已开始粘贴，但无法安全点击飞书输入框；请检查电脑内容，勿重复发送。")
                }
                usleep(pasteTiming.interImageClickMicros!)
                guard valid(), InputBinding.shared.captureClickAnchor(context,
                    point: clickAnchor.point) != nil else {
                    throw draft.stop("图片已开始粘贴，但输入位置或控制权已变化；请检查电脑内容，勿重复发送。")
                }
            }
        }
        guard valid() else { throw draft.stop("内容可能已经输入，位置或控制权已变化；请检查电脑内容，勿重复发送。") }
        guard postKey(36) else { throw draft.stop("提交动作失败；请检查电脑内容，勿重复发送。") }
        if let batchId = command.imageBatchId, let imageIds = command.imageIds { imageBatches.consume(batchId: batchId, imageIds: imageIds) }
        draft.finish()
        let receipt = LiveInputReceipt(feedback: .sent("提交动作已发出，请以电脑显示为准。"), mode: draft.mode.rawValue,
                                       committed: true, state: DraftState.committed.rawValue, note: "")
        completedDrafts[id] = (command.text, receipt)
        imageExecutionDrafts.remove(id)
        completedOrder.append(id)
        if completedOrder.count > 32 { completedDrafts.removeValue(forKey: completedOrder.removeFirst()) }
        record("live", "提交草稿", .sent, receipt.feedback.detail, front.localizedName)
        return receipt
    }

    /// 只读恢复探测：不写入任何字符，只回答"现在能不能续接"。
    ///
    /// 契约（与 docs/wrist-send-reliability-and-pointer-plan.md 的 B 节一致）：
    /// - 没有对应草稿时，若该草稿已提交则报 committed，否则报 needs-user-focus；
    /// - 有草稿时交给 LiveDraft 核验（目标应用是否回到前台、原编辑元素是否仍在、电脑内容是否等于最后确认状态）；
    /// - 返回 recoverable 时 LiveDraft 已按只读方式重新对齐基线，调用方随后只发送差量，**绝不重放全文**。
    private func probeDraft(id: String, command: LiveInputCommand) throws -> LiveInputReceipt {
        guard let draft = liveDraft, draft.id == id else {
            if let done = completedDrafts[id] {
                return LiveInputReceipt(feedback: .init(outcome: .buffered, detail: "本轮已提交，请开始新的草稿。"),
                                        mode: done.receipt.mode, committed: true,
                                        state: DraftState.committed.rawValue, note: "本轮已提交，请开始新的草稿。")
            }
            let note = "请在电脑上点一下原输入框即可继续；手机文字已保留。"
            return LiveInputReceipt(feedback: .init(outcome: .buffered, detail: note), mode: "unknown",
                                    committed: false, state: DraftState.needsUserFocus.rawValue, note: note)
        }
        draft.noteProbe(command.text)
        let result = draft.probe()
        return LiveInputReceipt(feedback: .init(outcome: .buffered, detail: result.note),
                                mode: draft.mode.rawValue, committed: false,
                                state: result.state.rawValue, note: result.note)
    }

    private func isUUFrontmost() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.bundleIdentifier == "com.netease.uuremote"
    }

    // 短追加用既有 Unicode 注入；长文本/换行用一次粘贴，让替换通过编辑器自身输入事件更新模型。
    private func insertLiveText(_ text: String) -> Bool {
        if text.utf16.count <= 20 && !text.contains("\n") && !text.contains("\r") {
            postUnicode(text)
            usleep(20_000)
            return true
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string), postKey(9, flags: .maskCommand) else { return false }
        usleep(80_000)
        return true
    }

    // UU 通道注入序列：文字+图片都进剪贴板（图片优先，纯文字给纯文本），
    // Cmd+V 由 UU 的剪贴板同步带跨机器，粘进远程电脑的输入框后 Return 提交。
    private func performUURemotePaste(text: String, imageData: [Data]) {
        InputActivity.shared.begin()
        defer { InputActivity.shared.end() }
        if !text.isEmpty {
            _ = pasteTextViaClipboard(text, bundleIdentifier: ImagePastePolicy.uuBundleIdentifier)
        }
        let pasteboard = NSPasteboard.general
        for image in imageData.compactMap(NSImage.init(data:)) {
            pasteboard.clearContents(); pasteboard.writeObjects([image])
            usleep(120_000); postKey(9, flags: .maskCommand); usleep(1_000_000)
        }
        postKey(36) // Return
    }

    // 所有“剪贴板文字 + Cmd+V”入口共用这一处，避免旧发送与 deferred 草稿再次产生时序分叉。
    // UU 读取本机剪贴板很快，但传到远端是另一段异步链路：必须在 Cmd+V 前等待远端同步。
    // 按键后的等待只负责目标输入框消费按键，放在那里无法修复“永远粘贴上一代”。
    private func pasteTextViaClipboard(_ text: String, bundleIdentifier: String?) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        let timing = ImagePastePolicy.textTiming(bundleIdentifier: bundleIdentifier)
        if timing.beforePasteMicros > 0 { usleep(timing.beforePasteMicros) }
        guard postKey(9, flags: .maskCommand) else { return false }
        if timing.afterPasteMicros > 0 { usleep(timing.afterPasteMicros) }
        return true
    }

    // 先在仍持有焦点的编辑器中输入文字，避免图片挂载期间的焦点变化吞掉文字。
    // 等文字落入编辑器后再粘贴图片；等待缩略图挂载后统一按 Return。
    // 图片发送后留在剪贴板上（与手动复制粘贴语义一致，不额外清空）。
    private func performPaste(imageData: [Data], text: String, bundleIdentifier: String?) {
        InputActivity.shared.begin()
        defer { InputActivity.shared.end() }
        if !text.isEmpty {
            postUnicode(text)
            usleep(200_000) // 让编辑器处理文字，再开始附件粘贴或提交
        }
        let images = imageData.compactMap(NSImage.init(data:))
        let pasteTiming = ImagePastePolicy.timing(bundleIdentifier: bundleIdentifier, imageCount: images.count)
        for image in images {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            if pasteTiming.clipboardSettleMicros > 0 { usleep(pasteTiming.clipboardSettleMicros) }
            postKey(9, flags: .maskCommand) // Cmd+V
            usleep(pasteTiming.consumptionMicros) // 等目标应用完成粘贴读取与缩略图挂载
        }
        postKey(36) // Return：图文一起发，或纯图直发
    }

    private func postLeftClick(at point: CGPoint) -> Bool {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return false }
        down.post(tap: .cghidEventTap)
        usleep(30_000)
        up.post(tap: .cghidEventTap)
        return true
    }

    private func resolveImages(batchId: String?, imageIds: [String]?) throws -> [Data] {
        guard batchId != nil || imageIds != nil else { return [] }
        guard let batchId, let imageIds else { throw InputError.message("图片批次信息不完整。") }
        return try imageBatches.resolve(batchId: batchId, imageIds: imageIds)
    }

    // 激活分三段：发起 → 校验 → 抢救。之所以不能"发起完就回成功"，是因为 PocketDesk 自己从不是前台应用，
    // 请求递出去之后系统同不同意（窗口在别的桌面空间、被最小化、被远控软件按住焦点）它一概不知。
    // 回执只能由系统说了算：问 AX 现在谁拿着焦点。
    private func activateTarget(_ targetId: String, completion: @escaping (Result<ActivateOutcome, InputError>) -> Void) {
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
    private func verifyActivation(targetId: String, name: String, attempt: Int, completion: @escaping (Result<ActivateOutcome, InputError>) -> Void) {
        let label = "唤醒 \(name)"
        // 没有辅助功能授权时无从判定，退回旧行为（相信系统调用），绝不因为判不了就报失败。
        guard AXIsProcessTrusted() else {
            completion(.success(ActivateOutcome(pid: self.runningApp(targetId: targetId)?.processIdentifier, note: ""))); return
        }
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
                completion(.success(ActivateOutcome(pid: pid > 0 ? pid : nil,
                                                    note: visible ? "" : "窗口可能在另一个桌面空间或另一块显示器。")))
                return
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
                // 用户盯着主屏自然什么都没看见。**这不是激活失败**——窗口是合法可见的，
                // 报成失败会让定位也跟着跳过。改成成功 + 明确说明，定位可在那块屏上就位。
                if Self.hasWindowOutsideMainScreen(pid: pid) {
                    self.record("activate", label, .sent, "已激活，窗口在另一块显示器上（合法副屏窗口，不是失败）。", name)
                    completion(.success(ActivateOutcome(pid: pid > 0 ? pid : nil,
                                                        note: "\(name) 的窗口在另一块显示器上，已按那块屏就位。")))
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
        guard LockScreenInput.state == "unlocked" else { return }
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

    /// 默认 25ms；选区扩展可显式缩短间隔，不让文字纠正排成长队。
    @discardableResult
    private func postKey(_ code: CGKeyCode, flags: CGEventFlags = [], pressMicros: useconds_t = 25_000) -> Bool {
        guard LockScreenInput.state == "unlocked",
              let down = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: code, keyDown: true),
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
        usleep(pressMicros)
        up.post(tap: .cghidEventTap)
        return true
    }

    // 快捷键：组合键注入当前前台应用，不切换目标；与 send 共用串行队列。
    // 回执分两级——能观察到状态变化才算 delivered，纯按键注入只能是 sent（微信不响应合成 Cmd+W
    // 却旧实现照样回 ok，正是这里要补上的诚实）。
    func triggerShortcut(_ shortcut: ShortcutConfig, completion: @escaping (Result<ExecutionFeedback, ShortcutError>) -> Void) {
        queue.async {
            // 快捷键注入同样是不可重放的输入事务：期间看门狗不得重启。
            InputActivity.shared.begin()
            defer { InputActivity.shared.end() }
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
                case .deviceLocal:
                    // 手机端本地动作（「清空会话」）由手机自己执行，服务端只配合电脑侧的清空。
                    // 旧页面或误配若把它发到这里，明确拒绝而不是当成空串快捷键注入。
                    let text = "「\(action.label)」在手机上执行，请刷新手机页面后使用。"
                    self.record("shortcut", shortcut.label, .blocked, text, frontName)
                    completion(.failure(.message(text))); return
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
