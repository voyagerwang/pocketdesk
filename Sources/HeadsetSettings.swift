import AppKit
import SwiftUI

struct HeadsetSettingsDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var kind: HeadsetSignal.Kind
    var connected: Bool
}
struct HeadsetSettingsOperation: Identifiable, Equatable {
    let id: String
    let signal: HeadsetSignal
    let gesture: HeadsetRule.Gesture
    let rule: HeadsetRule?
    var title: String { signal.kind == .volume ? signal.label : signal.label + " · " + gesture.label }
}
final class HeadsetSettingsModel: ObservableObject {
    @Published var devices: [HeadsetSettingsDevice] = []
    @Published var selectedUID = ""
    @Published var operations: [HeadsetSettingsOperation] = []
    @Published var defaultEnabled = false
    @Published var finishMode: HeadsetFinishMode = .manual
    @Published var pauseText = "3"
    @Published var autoSend = false
    @Published var delay = 2
    @Published var message = ""
    @Published var error = false
    var pauseEditing = false
    var pauseEditingUID: String?
    var timer: Timer?
    var selected: HeadsetSettingsDevice? { devices.first { $0.id == selectedUID } }
    var usesVolume: Bool { selected?.kind == .volume }
    func refresh() {
        var entries = HeadsetAudio.outputs().map { HeadsetSettingsDevice(id: $0.uid, name: $0.name, kind: .volume, connected: true) }
        for d in HeadsetMappingRuntime.shared.devices() where d.kind == .hid && !entries.contains(where: { $0.id == d.device }) { entries.append(.init(id: d.device, name: d.name, kind: .hid, connected: true)) }
        for p in HeadsetClickPreferences.shared.all where !entries.contains(where: { $0.id == p.uid }) { entries.append(.init(id: p.uid, name: p.name, kind: .volume, connected: false)) }
        for r in HeadsetRuleStore.shared.rules where !entries.contains(where: { $0.id == r.signal.device }) { entries.append(.init(id: r.signal.device, name: r.signal.name, kind: r.signal.kind, connected: false)) }
        if entries != devices { devices = entries }
        if !entries.contains(where: { $0.id == selectedUID }) { selectedUID = HeadsetAudio.current()?.uid ?? entries.first?.id ?? "" }
        reload()
    }
    func reload() {
        let p = HeadsetClickPreferences.shared.preference(for: selectedUID)
        if defaultEnabled != (p?.enabled == true) { defaultEnabled = p?.enabled == true }
        if finishMode != (p?.effectiveFinishMode ?? .manual) { finishMode = p?.effectiveFinishMode ?? .manual }
        if !pauseEditing && pauseText != (p?.textPauseLabel ?? "3") { pauseText = p?.textPauseLabel ?? "3" }
        if autoSend != HeadsetController.shared.autoSend { autoSend = HeadsetController.shared.autoSend }
        if delay != Int(HeadsetController.shared.delay) { delay = Int(HeadsetController.shared.delay) }
        let rules = HeadsetRuleStore.shared.rules.filter { $0.signal.device == selectedUID }
        var rows: [HeadsetSettingsOperation] = []
        if usesVolume, let step = HeadsetMappingRuntime.shared.volumeStep(uid: selectedUID) ?? p?.step, let device = selected {
            for side in [1, -1] {
                let signal = HeadsetSignal(kind: .volume, device: selectedUID, name: device.name, usage: side, step: step)
                let rule = rules.first { $0.signal.identity == signal.identity && $0.scope == nil && $0.gesture == .click }
                rows.append(.init(id: "default:\(side)", signal: signal, gesture: .click, rule: rule))
            }
        }
        for rule in rules where !rows.contains(where: { $0.rule?.id == rule.id }) {
            if rule.signal.kind == .volume && rule.scope == nil && rows.contains(where: { $0.signal.identity == rule.signal.identity }) { continue }
            rows.append(.init(id: rule.id, signal: rule.signal, gesture: rule.gesture, rule: rule))
        }
        if rows != operations { operations = rows }
    }
    func selectionChanged() { if pauseEditing { savePause() }; message = ""; error = false; reload() }
    func preference(uid: String? = nil, _ change: (inout HeadsetClickPreference) -> Void) {
        guard let device = devices.first(where: { $0.id == (uid ?? selectedUID) }), device.kind == .volume else { return }
        var p = HeadsetClickPreferences.shared.preference(for: device.id) ?? .init(uid: device.id, name: device.name, enabled: false, step: nil)
        change(&p)
        do { try HeadsetClickPreferences.shared.save(p); HeadsetClickControl.shared.cancelCurrent(); message = "已保存。"; error = false }
        catch { message = "保存失败：\(error.localizedDescription)"; self.error = true }
        reload()
    }
    func savePause() {
        let uid = pauseEditingUID ?? selectedUID; pauseEditingUID = nil; pauseEditing = false
        guard let seconds = Double(pauseText.trimmingCharacters(in: .whitespacesAndNewlines)), HeadsetClickPreference.validPauseSeconds(seconds) else { message = "请输入 0.5–30 秒，以 0.5 秒为单位。"; error = true; reload(); return }
        let old = HeadsetClickPreferences.shared.preference(for: uid)?.effectiveTextPauseSeconds ?? 3
        if seconds != old { preference(uid: uid) { $0.textPauseSeconds = seconds } }
    }
    func setFunction(_ action: HeadsetRule.Action?, row: HeadsetSettingsOperation) {
        do {
            if let action {
                var rule = row.rule ?? HeadsetRule(signal: row.signal, gesture: row.gesture, action: action)
                rule.action = action; rule.enabled = true; rule.key = [.voice, .spriteVoice].contains(action) ? HeadsetKey.parse("LeftOption") : nil
                rule.voiceToggle = false; rule.holdsKey = false; rule.appPath = nil
                try HeadsetRuleStore.shared.save(rule)
            } else if var rule = row.rule { rule.enabled = false; try HeadsetRuleStore.shared.save(rule) }
            HeadsetClickControl.shared.cancelCurrent(); message = "已保存按键功能。"; error = false
        } catch { message = "保存失败：\(error.localizedDescription)"; self.error = true }
        reload()
    }
    func restore(_ row: HeadsetSettingsOperation) {
        guard let rule = row.rule else { return }
        do { try HeadsetRuleStore.shared.remove(rule.id); message = "已恢复原有功能。"; error = false }
        catch { message = "保存失败：\(error.localizedDescription)"; self.error = true }
        reload()
    }
    func functionLabel(_ row: HeadsetSettingsOperation) -> String {
        if let rule = row.rule, rule.enabled { return rule.action.label + (rule.action == .hotkey ? " · " + (rule.key?.label ?? "") : "") }
        if row.signal.kind == .volume && row.rule?.scope == nil && defaultEnabled { return row.signal.usage > 0 ? "默认：普通语音" : "默认：小精灵语音" }
        return "保留原有功能"
    }
    func scopeLabel(_ row: HeadsetSettingsOperation) -> String {
        guard let scope = row.rule?.scope else { return "所有应用" }
        return (NSWorkspace.shared.urlForApplication(withBundleIdentifier: scope)?.deletingPathExtension().lastPathComponent ?? "指定应用") + " · 优先于通用设置"
    }
}
struct HeadsetSettingsView: View {
    @ObservedObject var model: HeadsetSettingsModel
    @FocusState private var pauseFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("耳机控制").font(.system(size: 23, weight: .semibold))
                    Text("用耳机操作，触发你常用的功能。").font(.system(size: 13)).foregroundStyle(.secondary)
                }; Spacer(); Image(systemName: "headphones").font(.system(size: 27)).foregroundStyle(.secondary)
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeadsetCard {
                        HStack(spacing: 12) {
                            Image(systemName: "headphones").font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.selected?.name ?? "连接你的耳机").font(.system(size: 14, weight: .semibold))
                                Text(model.selected?.connected == true ? (model.selectedUID == HeadsetAudio.current()?.uid ? "当前声音输出" : "已连接") : "未连接").font(.system(size: 12)).foregroundStyle(.secondary)
                            }; Spacer()
                            HeadsetChoice(label: "耳机", selection: $model.selectedUID, options: model.devices.map { ($0.id, $0.name + ($0.connected ? "" : " · 未连接")) }).frame(maxWidth: 300)
                            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("刷新设备")
                        }
                    }
                    HStack { HeadsetSectionTitle(text: "按键操作"); Spacer(); Button { HeadsetMappingWindow.shared.show(deviceUID: model.selectedUID) } label: { Label("录制新操作", systemImage: "plus") }.buttonStyle(.borderless).disabled(model.selected == nil) }
                    HeadsetCard {
                        if model.operations.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "hand.tap").font(.system(size: 29)).foregroundStyle(.secondary)
                                Text("先录制一个耳机操作").font(.system(size: 15, weight: .semibold))
                                Text("识别成功后，再选择它要执行的动作。").font(.system(size: 12)).foregroundStyle(.secondary)
                                Button("录制操作") { HeadsetMappingWindow.shared.show(deviceUID: model.selectedUID) }.buttonStyle(HeadsetPrimaryButton()).disabled(model.selected == nil)
                            }.frame(maxWidth: .infinity).padding(.vertical, 16)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(model.operations.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { Divider().padding(.vertical, 13) }
                                    HStack(spacing: 12) {
                                        Image(systemName: row.signal.kind == .volume ? (row.signal.usage > 0 ? "speaker.wave.2" : "speaker.wave.1") : "hand.tap").font(.system(size: 18)).frame(width: 24).foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 5) { Text(row.title).font(.system(size: 14, weight: .medium)); Text(model.scopeLabel(row)).font(.system(size: 11)).foregroundStyle(.secondary) }
                                        Spacer()
                                        Menu {
                                            ForEach([HeadsetRule.Action.voice, .spriteVoice, .spriteWake, .cancel, .disabled], id: \.self) { action in Button(action.label) { model.setFunction(action, row: row) } }
                                            Divider(); Button("快捷键 / 更多设置…") { HeadsetMappingWindow.shared.show(deviceUID: model.selectedUID, ruleID: row.rule?.id, operation: .init(signal: row.signal, gesture: row.gesture)) }
                                            if row.rule != nil { Button("恢复原有功能") { model.restore(row) } }
                                        } label: { HStack { Text(model.functionLabel(row)).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9)) }.padding(.horizontal, 12).padding(.vertical, 9).background(HeadsetUI.control).clipShape(RoundedRectangle(cornerRadius: 9)) }.menuStyle(.borderlessButton).frame(minWidth: 170, maxWidth: 280).help(model.functionLabel(row))
                                        if row.rule != nil { Button { HeadsetMappingWindow.shared.show(deviceUID: model.selectedUID, ruleID: row.rule?.id, operation: .init(signal: row.signal, gesture: row.gesture)) } label: { Image(systemName: "slider.horizontal.3") }.buttonStyle(.plain).help("编辑操作") }
                                    }
                                }
                            }
                        }
                    }
                    if model.usesVolume {
                        HeadsetSectionTitle(text: "默认语音")
                        HeadsetCard {
                            VStack(spacing: 14) {
                                Toggle(isOn: Binding(get: { model.defaultEnabled }, set: { value in model.preference { $0.enabled = value } })) {
                                    VStack(alignment: .leading, spacing: 4) { Text("启用默认单击语音").font(.system(size: 13, weight: .medium)); Text("未自定义的音量增加用于普通语音，音量减少用于小精灵。").font(.system(size: 11)).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                                }.toggleStyle(.switch).tint(Color(nsColor: .labelColor))
                                HStack { Text("结束方式"); Spacer(); HeadsetChoice(label: "结束方式", selection: Binding(get: { model.finishMode }, set: { value in model.preference { $0.finishMode = value } }), options: [(.manual, "再次操作结束"), (.textPause, "转写文字停顿时结束")]).frame(width: 250).disabled(!model.defaultEnabled) }.font(.system(size: 13))
                                if model.finishMode == .textPause {
                                    HStack { Text("文字不再变化后等待"); Spacer(); TextField("秒数", text: Binding(get: { model.pauseText }, set: { if !model.pauseEditing { model.pauseEditingUID = model.selectedUID }; model.pauseEditing = true; model.pauseText = $0 })).focused($pauseFocused).onSubmit { model.savePause() }.frame(width: 58).textFieldStyle(.roundedBorder); Text("秒").foregroundStyle(.secondary) }.font(.system(size: 13)).disabled(!model.defaultEnabled)
                                    HeadsetMessage(text: "文字停顿不等于静音，转写延迟可能提前结束。等待范围 0.5–30 秒。")
                                }
                                HeadsetMessage(text: "自定义语音按自己的操作结束方式执行，不受这里的默认结束设置影响。")
                            }
                        }
                    }
                    HeadsetSectionTitle(text: "普通语音发送")
                    HeadsetCard {
                        HStack {
                            Toggle("结束后自动发送", isOn: Binding(get: { model.autoSend }, set: { value in if value != HeadsetController.shared.autoSend { HeadsetController.shared.toggleAuto() }; model.reload() })).toggleStyle(.switch).tint(Color(nsColor: .labelColor))
                            Spacer()
                            HeadsetChoice(label: "发送等待", selection: Binding(get: { model.delay }, set: { value in let item = NSMenuItem(); item.tag = value; HeadsetController.shared.setDelay(item); model.reload() }), options: [1, 2, 3, 5, 10].map { ($0, "等待 \($0) 秒") }).frame(width: 130).disabled(!model.autoSend)
                        }.font(.system(size: 13))
                    }
                    if !model.message.isEmpty { HeadsetMessage(text: model.message, error: model.error) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            HStack { Text("修改自动保存").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Menu("高级设置") { Button("添加独立按键设备…") { HeadsetPairing.shared.show() }; Button("检测蓝牙信号…") { HeadsetTouchDiagnostic.shared.show() }; Button("权限说明…") { HeadsetController.shared.showSetup() } }.menuStyle(.borderlessButton).fixedSize() }.padding(20).background(HeadsetUI.card)
        }.background(HeadsetUI.canvas).onChange(of: model.selectedUID) { _ in pauseFocused = false; model.selectionChanged() }.onChange(of: pauseFocused) { focused in if !focused && model.pauseEditing { model.savePause() } }
    }
}
final class HeadsetSettings: NSObject, NSWindowDelegate {
    static let shared = HeadsetSettings()
    private(set) var window: NSWindow?
    let model = HeadsetSettingsModel()
    var isVisible: Bool { window?.isVisible == true }
    @objc func show() {
        model.refresh()
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 730, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window = w; w.title = "PocketDesk · 耳机设置"; w.minSize = .init(width: 660, height: 580); w.isReleasedWhenClosed = false; w.delegate = self
        w.contentView = NSHostingView(rootView: HeadsetSettingsView(model: model))
        model.timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.model.reload() }; RunLoop.main.add(model.timer!, forMode: .common)
        w.center(); w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { if model.pauseEditing { model.savePause() }; model.timer?.invalidate(); model.timer = nil; window = nil }
}
