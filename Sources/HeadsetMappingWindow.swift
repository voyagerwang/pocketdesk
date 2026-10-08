/** [INPUT]: 检测运行时、规则存储、原生快捷键录制。[OUTPUT]: 检测→反馈→动作→试用→保存的本机窗口。[POS]: 耳机设置下的操作映射。[PROTOCOL]: 同步 Sources/CLAUDE.md。 */
import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class HeadsetShortcutField: NSTextField {
    var recording = false
    var recorded: HeadsetKey?
    private var modifierCandidate: HeadsetKey?
    func startRecording() { recorded = nil; modifierCandidate = nil; recording = true }
    override func becomeFirstResponder() -> Bool { super.becomeFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        capture(event); return true
    }
    override func keyDown(with event: NSEvent) { if recording { capture(event) } else { super.keyDown(with: event) } }
    override func flagsChanged(with event: NSEvent) {
        guard recording else { super.flagsChanged(with: event); return }
        let flags = UInt64(event.modifierFlags.rawValue) & HeadsetKey.allowedFlags
        if flags != 0 { modifierCandidate = .init(code: event.keyCode, flags: flags, modifier: true, label: Self.modifierName(event.keyCode)) }
        else if let candidate = modifierCandidate { accept(candidate) }
    }
    private func capture(_ event: NSEvent) {
        if event.keyCode == 53 { recording = false; modifierCandidate = nil; placeholderString = "LeftOption 或 Cmd+Shift+Space"; return }
        let flags = UInt64(event.modifierFlags.rawValue) & HeadsetKey.allowedFlags
        let mods: [(UInt64,String)] = [(CGEventFlags.maskCommand.rawValue,"Cmd"),(CGEventFlags.maskShift.rawValue,"Shift"),(CGEventFlags.maskAlternate.rawValue,"Opt"),(CGEventFlags.maskControl.rawValue,"Ctrl")]
        let main = [36:"Return",49:"Space",48:"Tab",51:"Delete" ][Int(event.keyCode)] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key\(event.keyCode)"
        accept(.init(code: event.keyCode, flags: flags, modifier: HeadsetKey.modifiers.contains(event.keyCode), label: (mods.filter { flags & $0.0 != 0 }.map(\.1) + [main]).joined(separator:"+")))
    }
    func consume(_ event: NSEvent) { if event.type == .flagsChanged { flagsChanged(with:event) } else { capture(event) } }
    private func accept(_ key: HeadsetKey) { guard key.valid else { return }; recorded = key; stringValue = key.label; recording = false; modifierCandidate = nil }
    static func modifierName(_ code: UInt16) -> String { [58:"LeftOption",61:"RightOption",55:"LeftCommand",54:"RightCommand",56:"LeftShift",60:"RightShift",59:"LeftControl",62:"RightControl"][code] ?? "Modifier" }
    var key: HeadsetKey? { if let recorded, recorded.label == stringValue { return recorded }; return HeadsetKey.parse(stringValue) }
}

final class HeadsetMappingModel: ObservableObject {
    enum Phase { case ready, listening, recognized, editing }
    @Published var devices: [HeadsetSignal] = []
    @Published var deviceID = ""
    @Published var preset = "auto"
    @Published var phase: Phase = .ready
    @Published var operation: HeadsetLearnedOperation?
    @Published var message = ""
    @Published var error = false
    @Published var action: HeadsetRule.Action = .voice
    @Published var keyLabel = "LeftOption"
    @Published var recordingKey = false
    @Published var appPath: String?
    @Published var scope: String?
    @Published var scopeName = "所有应用"
    @Published var enabled = true
    @Published var holdsKey = false
    @Published var voiceToggle = false
    @Published var advancedVoice = false
    @Published var testing = false
    var editingID: String?
    var timer: Timer?
    var testToken: UUID?
    let keyField = HeadsetShortcutField()
    var close: (() -> Void)?
    var focusRecorder: (() -> Void)?
    static func identity(_ signal: HeadsetSignal) -> String { signal.kind.rawValue + ":" + signal.device }
    var selected: HeadsetSignal? { devices.first { Self.identity($0) == deviceID } }
    var expected: HeadsetRule.Gesture? { HeadsetRule.Gesture(rawValue: preset) }
    var requiresKey: Bool { [.hotkey, .voice, .spriteVoice].contains(action) }
    var needsVoice: Bool { [.voice, .spriteVoice].contains(action) }
    var canSave: Bool { operation != nil && phase != .listening && !recordingKey && (!requiresKey || keyField.key?.valid == true) && (action != .openApp || appPath != nil) }
    func load(uid: String?, ruleID: String?) {
        stop(); operation = nil; editingID = nil; phase = .ready; preset = "auto"; refresh()
        action = .voice; keyLabel = "LeftOption"; keyField.recorded = HeadsetKey.parse("LeftOption")
        keyField.stringValue = keyLabel; appPath = nil; scope = nil; scopeName = "所有应用"; enabled = true
        holdsKey = false; voiceToggle = false; advancedVoice = false; error = false; message = ""
        if let uid, let d = devices.first(where: { $0.device == uid }) { deviceID = Self.identity(d) }
        if let id = ruleID, let rule = HeadsetRuleStore.shared.rules.first(where: { $0.id == id }) {
            if !devices.contains(where: { Self.identity($0) == Self.identity(rule.signal) }) { var offline = rule.signal; offline.name += " · 未连接"; devices.append(offline) }
            deviceID = Self.identity(rule.signal); editingID = id
            operation = .init(signal: rule.signal, gesture: rule.gesture); phase = .editing
            action = rule.action; keyLabel = rule.key?.label ?? "LeftOption"; keyField.recorded = rule.key; keyField.stringValue = keyLabel
            appPath = rule.appPath; scope = rule.scope; scopeName = rule.scope.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.deletingPathExtension().lastPathComponent } ?? (rule.scope == nil ? "所有应用" : "指定应用")
            enabled = rule.enabled; holdsKey = rule.holdsKey; voiceToggle = rule.voiceToggle
            advancedVoice = keyLabel != "LeftOption" || voiceToggle
        }
    }
    func refresh() {
        var list = HeadsetMappingRuntime.shared.devices()
        for audio in HeadsetAudio.outputs() where audio.volume != nil && !list.contains(where: { $0.kind == .volume && $0.device == audio.uid }) {
            list.append(.init(kind: .volume, device: audio.uid, name: audio.name, usage: 1))
        }
        if let operation, !list.contains(where: { Self.identity($0) == Self.identity(operation.signal) }) {
            var offline = operation.signal; offline.name += " · 未连接"; list.append(offline)
        }
        devices = list
        if !list.contains(where: { Self.identity($0) == deviceID }) { deviceID = list.first.map(Self.identity) ?? "" }
    }
    func changedSource() { stop(); operation = nil; phase = .ready; message = ""; error = false }
    func begin() {
        guard let device = selected else { message = "没有可读取的设备，请连接耳机后刷新。"; error = true; return }
        guard device.kind != .volume || device.device == HeadsetAudio.current()?.uid else { message = "请先把这个耳机设为系统声音输出，再开始录制。"; error = true; return }
        guard expected.map({ HeadsetOperationLearning.supports($0, device: device) }) ?? true else { message = "这个信号不能识别所选手势，请选择直接录制或单击。"; error = true; return }
        timer?.invalidate(); timer = nil
        operation = nil; phase = .listening; error = false
        HeadsetMappingRuntime.shared.feedback = { [weak self] text, _ in
            self?.message = text
            if text.contains("超时") || text.contains("已改变") || text.contains("断开") { self?.phase = .ready; self?.error = true }
        }
        HeadsetMappingRuntime.shared.learnedOperation = { [weak self] operation in
            guard let self else { return }
            self.operation = operation; self.phase = .recognized; self.error = false
            self.message = "已识别。选择下面的动作后保存。"
        }
        HeadsetMappingRuntime.shared.beginLearning(device: device, gesture: expected)
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.phase == .listening && !HeadsetMappingRuntime.shared.learning {
                self.phase = .ready; self.error = true
                self.message = LockScreenInput.locked ? "电脑已锁定，录制已停止。请解锁后重试。" : !AXIsProcessTrusted() ? "录制已停止，请在高级设置中查看辅助功能权限。" : "录制已停止，请重新录制。"
            }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func stop() {
        testToken = nil; testing = false; recordingKey = false; keyField.recording = false
        timer?.invalidate(); timer = nil
        HeadsetMappingRuntime.shared.stopLearning(); HeadsetMappingRuntime.shared.cancel()
        if phase == .listening { phase = .ready; message = "录制已停止，未保存任何操作。" }
    }
    func draft() -> HeadsetRule? {
        guard let operation else { message = "请先录制并确认识别结果。"; error = true; return nil }
        var rule = HeadsetRule(signal: operation.signal, gesture: operation.gesture, action: action)
        rule.id = editingID ?? UUID().uuidString; rule.key = requiresKey ? keyField.key : nil
        rule.appPath = action == .openApp ? appPath : nil; rule.scope = scope
        rule.enabled = enabled; rule.holdsKey = action == .hotkey && operation.gesture == .hold && holdsKey
        rule.voiceToggle = needsVoice && voiceToggle
        guard rule.valid else { message = action == .openApp ? "请选择要打开的应用。" : "请录制有效的快捷键。"; error = true; return nil }
        return rule
    }
    func save() {
        guard let rule = draft() else { return }
        do { try HeadsetRuleStore.shared.save(rule); close?() }
        catch { self.error = true; message = error.localizedDescription }
    }
    func recordKey() {
        HeadsetMappingRuntime.shared.stopLearning(); keyField.startRecording(); recordingKey = true
        message = "请按快捷键；单独 Option 按下后松开即可。Esc 停止录制。"; error = false
        focusRecorder?()
    }
    func chooseApp(scopeOnly: Bool = false) {
        let panel = NSOpenPanel(); panel.title = scopeOnly ? "选择生效应用" : "选择要打开的应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if scopeOnly {
            guard let id = Bundle(url: url)?.bundleIdentifier else { message = "无法读取应用身份，请选择有效应用。"; error = true; return }
            scope = id; scopeName = url.deletingPathExtension().lastPathComponent
        } else { appPath = url.path }
    }
    func test() {
        guard let rule = draft() else { return }
        if rule.action == .hotkey || rule.action == .voice {
            let token = UUID(); testToken = token; testing = true
            message = "请在 3 秒内切到目标输入框。试用只执行一次，Esc 可停止。"; error = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.testToken == token else { return }
                self.testToken = nil; self.testing = false; HeadsetMappingActions.shared.begin(rule)
                if rule.holdsKey { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if HeadsetMappingActions.shared.currentRuleID == rule.id { HeadsetMappingActions.shared.finish() } } }
            }
        } else { HeadsetMappingActions.shared.begin(rule) }
    }
}

struct HeadsetShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: HeadsetMappingModel
    func makeNSView(context: Context) -> HeadsetShortcutField {
        let field = model.keyField
        field.font = .monospacedSystemFont(ofSize: 13, weight: .medium); field.isBezeled = false; field.drawsBackground = false
        field.isEditable = false; field.isSelectable = true
        field.focusRingType = .none; field.setAccessibilityLabel("录制的快捷键")
        return field
    }
    func updateNSView(_ field: HeadsetShortcutField, context: Context) { if !field.recording { field.stringValue = model.keyLabel } }
}

struct HeadsetMappingView: View {
    @ObservedObject var model: HeadsetMappingModel
    private let presets: [(String, String)] = [("auto", "直接录制"), ("click", "单击"), ("doubleClick", "双击"), ("hold", "长按")]
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.editingID == nil ? "添加耳机操作" : "编辑耳机操作").font(.system(size: 22, weight: .semibold))
                    Text("先操作耳机，识别成功后再选择它要做什么。").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "headphones").font(.system(size: 26)).foregroundStyle(.secondary)
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HeadsetCard {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("耳机与信号").font(.system(size: 13, weight: .semibold)); Spacer()
                                HeadsetChoice(label: "设备", selection: $model.deviceID, options: model.devices.map { (HeadsetMappingModel.identity($0), $0.name + ($0.kind == .volume ? " · 音量信号" : " · 独立按键")) })
                                    .frame(maxWidth: 370).disabled(model.phase == .listening || model.operation != nil)
                                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新设备")
                            }
                            if model.operation == nil {
                                HStack(spacing: 3) {
                                    ForEach(presets, id: \.0) { value, title in
                                        let supported = value == "auto" || model.selected.map { HeadsetOperationLearning.supports(HeadsetRule.Gesture(rawValue: value)!, device: $0) } == true
                                        Button { model.preset = value } label: {
                                            Text(title).font(.system(size: 13, weight: model.preset == value ? .semibold : .regular))
                                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                                                .background(model.preset == value ? HeadsetUI.card : Color.clear).clipShape(RoundedRectangle(cornerRadius: 7))
                                        }.buttonStyle(.plain).disabled(!supported)
                                            .help(supported ? "录制并确认实际信号" : "当前信号不支持这个手势")
                                    }
                                }.padding(4).background(HeadsetUI.control).clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(spacing: 12) {
                                    Image(systemName: model.phase == .listening ? "dot.radiowaves.left.and.right" : "hand.tap").font(.system(size: 32)).foregroundStyle(.secondary)
                                    Text(model.phase == .listening ? "现在操作耳机" : "录制一次耳机操作").font(.system(size: 16, weight: .semibold))
                                    Text(model.phase == .listening ? "收到信号后，会在这里显示识别结果。" : "直接录制，或先选择单击、双击、长按。").font(.system(size: 12)).foregroundStyle(.secondary)
                                    if model.phase == .listening { Button("停止录制") { model.stop() }.buttonStyle(HeadsetSecondaryButton()) }
                                    else { Button("开始录制") { model.begin() }.buttonStyle(HeadsetPrimaryButton()).disabled(model.selected == nil) }
                                }.frame(maxWidth: .infinity).padding(.vertical, 20)
                            } else if let operation = model.operation {
                                HStack(spacing: 12) {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(operation.title).font(.system(size: 16, weight: .semibold))
                                        Text(model.phase == .editing ? "已保存的操作，无需重新录制。" : "已收到并识别这个信号。").font(.system(size: 12)).foregroundStyle(.secondary)
                                    }; Spacer()
                                    Button("重新录制") { model.changedSource() }.buttonStyle(.borderless)
                                }
                            }
                            if model.selected?.kind == .volume { HeadsetMessage(text: "当前仅能读取音量变化，不能区分左右耳、双击或长按。其他程序调整音量也可能被识别。") }
                            else {
                                HeadsetMessage(text: "录制期间不执行自定义功能；耳机原生的媒体或输入法功能仍可能响应。")
                                if model.selected?.vendor == 31 && model.selected?.product == 2849 { HeadsetMessage(text: "这个设备不能可靠识别双击，可以录制单击或长按。") }
                            }
                        }
                    }
                    if model.operation != nil {
                        HeadsetCard {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("执行动作").font(.system(size: 14, weight: .semibold)); Spacer()
                                    HeadsetChoice(label: "执行动作", selection: $model.action, options: HeadsetRule.Action.allCases.map { ($0, $0.label) }).frame(width: 310)
                                }
                                if model.action == .openApp {
                                    HStack { Text(model.appPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "尚未选择应用").foregroundStyle(.secondary); Spacer(); Button("选择应用…") { model.chooseApp() } }
                                }
                                if model.action == .hotkey || model.advancedVoice && model.needsVoice {
                                    HStack { HeadsetShortcutRecorder(model: model).frame(height: 24).padding(8).background(HeadsetUI.control).clipShape(RoundedRectangle(cornerRadius: 8)); Button(model.recordingKey ? "等待按键…" : "录制快捷键") { model.recordKey() }.disabled(model.recordingKey) }
                                }
                                if model.action == .hotkey && model.operation?.gesture == .hold { Toggle("按住期间保持快捷键，松开后释放", isOn: $model.holdsKey).toggleStyle(.switch).tint(Color(nsColor: .labelColor)) }
                                if model.needsVoice {
                                    HeadsetMessage(text: model.operation?.gesture == .hold ? "按住开始说话，松开结束。" : "操作一次开始语音，再操作一次结束。")
                                    DisclosureGroup("语音快捷键与输入法", isExpanded: $model.advancedVoice) {
                                        HeadsetChoice(label: "输入法快捷键方式", selection: $model.voiceToggle, options: [(false, "按住快捷键开始，松开结束"), (true, "点按快捷键开始，再点结束")]).padding(.top, 8)
                                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Divider()
                                HStack { Text("生效范围"); Spacer(); Menu(model.scopeName) { Button("所有应用") { model.scope = nil; model.scopeName = "所有应用" }; Button("选择应用…") { model.chooseApp(scopeOnly: true) } }.menuStyle(.borderlessButton).fixedSize().padding(8).background(HeadsetUI.control).clipShape(RoundedRectangle(cornerRadius: 8)) }
                                if model.editingID != nil { Toggle("启用此操作", isOn: $model.enabled).toggleStyle(.switch).tint(Color(nsColor: .labelColor)) }
                            }.font(.system(size: 13))
                        }
                    }
                    if !model.message.isEmpty { HeadsetMessage(text: model.message, error: model.error) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            HStack { Button("取消") { model.close?() }.buttonStyle(HeadsetSecondaryButton()).keyboardShortcut(.cancelAction); Spacer()
                if model.operation != nil { Button(model.testing ? "停止试用" : "试用动作") { if model.testing { model.stop() } else { model.test() } }.buttonStyle(HeadsetSecondaryButton()).disabled(model.recordingKey) }
                Button("保存操作") { model.save() }.buttonStyle(HeadsetPrimaryButton()).disabled(!model.canSave).opacity(model.canSave ? 1 : 0.4).keyboardShortcut(.defaultAction)
            }.padding(20).background(HeadsetUI.card)
        }.background(HeadsetUI.canvas)
            .onChange(of: model.deviceID) { _ in if model.operation == nil { model.changedSource() } }
            .onChange(of: model.preset) { _ in
                guard model.operation == nil else { return }
                let restart = model.phase == .listening; model.changedSource(); if restart { model.begin() }
            }
            .onChange(of: model.action) { _ in if model.recordingKey || model.testing { model.stop() }; model.message = ""; model.error = false }
    }
}

final class HeadsetMappingWindow: NSObject, NSWindowDelegate {
    static let shared = HeadsetMappingWindow()
    private(set) var window: NSWindow?
    let model = HeadsetMappingModel()
    private var keyMonitor: Any?
    var isVisible: Bool { window?.isVisible == true }
    @objc func show() { show(deviceUID: nil) }
    func show(deviceUID: String?, ruleID: String? = nil, operation: HeadsetLearnedOperation? = nil) {
        model.load(uid: deviceUID, ruleID: ruleID)
        if let operation, ruleID == nil { model.operation = operation; model.phase = .editing }
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 710, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window = w; w.title = "PocketDesk · 耳机操作"; w.minSize = .init(width: 650, height: 580); w.isReleasedWhenClosed = false; w.delegate = self
        w.contentView = NSHostingView(rootView: HeadsetMappingView(model: model))
        model.close = { [weak self] in self?.window?.close() }
        model.focusRecorder = { [weak self] in self?.window?.makeFirstResponder(self?.model.keyField) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.model.recordingKey, self.window?.isKeyWindow == true else { return event }
            self.model.keyField.consume(event)
            if !self.model.keyField.recording { self.model.recordingKey = false; self.model.keyLabel = self.model.keyField.stringValue }
            return nil
        }
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func cancelFromEscape() { model.stop() }
    func windowWillClose(_ notification: Notification) {
        model.stop(); HeadsetMappingRuntime.shared.feedback = nil; HeadsetMappingRuntime.shared.learnedOperation = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil; window = nil
    }
}
