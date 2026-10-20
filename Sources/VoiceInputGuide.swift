/**
 * [INPUT]: 依赖 Carbon TIS 的只读输入源查询（含已安装未启用项）与 /Library、~/Library 下的豆包输入法安装锚点；切换动作仅在显式请求时调用 TISSelectInputSource。
 * [OUTPUT]: 语音输入四态（未安装 / 未启用 / 未选中 / 就绪）、稳定 stage 标识与 /api/status 的 voiceInput 字段；不读正文、除显式切换外不改系统输入源。
 * [POS]: Sources 的语音前置条件检查；语音键（耳机与小精灵）依赖豆包输入法的系统 ASR 快捷键，这里只回答"现在按语音键有没有用"。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Carbon
import Foundation

/// 控制台据此渲染引导；rawValue 是 Web 侧契约，改名等于改协议。
enum VoiceInputStage: String {
    case ready      // 已装、已启用、当前就是豆包
    case missing    // 没装豆包输入法
    case disabled   // 装了但没在「系统设置 → 键盘 → 输入法」里启用
    case inactive   // 启用但当前输入源不是豆包，按语音键不会唤起豆包
}

struct VoiceInputSnapshot {
    let installed: Bool
    let enabled: Bool
    let selected: Bool

    var stage: VoiceInputStage {
        if !installed { return .missing }
        if !enabled { return .disabled }
        if !selected { return .inactive }
        return .ready
    }

    var payload: [String: Any] {
        ["stage": stage.rawValue, "installed": installed, "enabled": enabled,
         "selected": selected, "ready": stage == .ready, "downloadURL": VoiceInputGuide.downloadPage]
    }
}

enum VoiceInputGuide {
    /// 豆包输入法（macOS）bundle 前缀；输入模式 ID 形如 `com.bytedance.inputmethod.doubaoime.pinyin`。
    static let bundleID = "com.bytedance.inputmethod.doubaoime"
    static let downloadPage = "https://shurufa.doubao.com/"
    /// TIS 在输入法未启用时可能不列出条目，安装锚点作为"确实装了"的补证。
    private static let installAnchors = [
        "/Library/Input Methods/DoubaoIme.app",
        NSHomeDirectory() + "/Library/Input Methods/DoubaoIme.app",
    ]

    /// TIS 属性读取必须在主线程；HTTP 处理不在主线程，统一在这里换线程。
    static func snapshot() -> VoiceInputSnapshot {
        onMain { read() }
    }

    /// 只由控制台的显式点击触发：把当前键盘输入源切到豆包，返回切换后的状态。
    static func select() -> VoiceInputSnapshot {
        onMain {
            let candidates = inputSources(includeAllInstalled: true).filter(matches)
            let target = candidates.first { boolValue($0, kTISPropertyInputSourceIsEnabled) == true }
            if let target, boolValue(target, kTISPropertyInputSourceIsSelectCapable) != false {
                TISSelectInputSource(target)
            }
            return read()
        }
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    private static func read() -> VoiceInputSnapshot {
        let sources = inputSources(includeAllInstalled: true)
        let doubao = sources.filter(matches)
        let installed = !doubao.isEmpty || installAnchors.contains { FileManager.default.fileExists(atPath: $0) }
        let enabled = doubao.contains { boolValue($0, kTISPropertyInputSourceIsEnabled) == true }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let selected = current.map { matches($0) } ?? false
        return VoiceInputSnapshot(installed: installed, enabled: enabled, selected: selected)
    }

    private static func inputSources(includeAllInstalled: Bool) -> [TISInputSource] {
        guard let list = TISCreateInputSourceList(nil, includeAllInstalled)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list
    }

    /// bundle id 优先；输入模式源没有 bundle id 时退回输入源 ID 前缀匹配。
    private static func matches(_ source: TISInputSource) -> Bool {
        if let bundle = string(source, kTISPropertyBundleID), bundle.hasPrefix(bundleID) { return true }
        if let identifier = string(source, kTISPropertyInputSourceID), identifier.hasPrefix(bundleID) { return true }
        return false
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func boolValue(_ source: TISInputSource, _ key: CFString) -> Bool? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue() == kCFBooleanTrue
    }
}
