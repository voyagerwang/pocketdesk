/**
 * [INPUT]: VoiceInputGuide 的纯状态映射与 Resources/Web 中的控制台契约（console-main.js 的 VOICE_INPUT_COPY、console.html 的元素 id 与下载页地址）；不查询真实输入源。
 * [OUTPUT]: 四态优先级、payload 字段一致性与 Web 契约（stage 键名、按钮 id、下载 URL 同源）回归。
 * [POS]: 语音输入前置引导的隔离开关测试；不切输入法、不发快捷键、不读系统输入源。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main enum VoiceInputGuideTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        func snapshot(_ installed: Bool, _ enabled: Bool, _ selected: Bool) -> VoiceInputSnapshot {
            VoiceInputSnapshot(installed: installed, enabled: enabled, selected: selected)
        }

        // ---------- 四态优先级：安装 → 启用 → 选中，越靠前越"更缺" ----------
        check(snapshot(false, false, false).stage == .missing, "未安装是 missing")
        check(snapshot(false, true, true).stage == .missing, "未安装优先于启用/选中，不被误报成就绪")
        check(snapshot(true, false, false).stage == .disabled, "装了没启用是 disabled")
        check(snapshot(true, false, true).stage == .disabled, "未启用优先于选中，避免提示去切换")
        check(snapshot(true, true, false).stage == .inactive, "启用了但没选中是 inactive")
        check(snapshot(true, true, true).stage == .ready, "三条件齐备才是 ready")

        // ---------- payload：控制台只认 stage 与 downloadURL，其余用于排查 ----------
        let missing = snapshot(false, false, false).payload
        check(missing["stage"] as? String == "missing", "payload 带 stage")
        check(missing["ready"] as? Bool == false, "未就绪时 ready 为 false")
        check(missing["downloadURL"] as? String == VoiceInputGuide.downloadPage, "payload 带下载页地址")
        check(snapshot(true, true, true).payload["ready"] as? Bool == true, "就绪时 ready 为 true")

        // ---------- stage 键名是 Web 契约，改名等于改协议 ----------
        let stages = Set([VoiceInputStage.ready, .missing, .disabled, .inactive].map(\.rawValue))
        check(stages == ["ready", "missing", "disabled", "inactive"], "stage 键名集合固定")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let consoleJS = (try? String(contentsOf: root.appendingPathComponent("Web/console-main.js"), encoding: .utf8)) ?? ""
        let consoleHTML = (try? String(contentsOf: root.appendingPathComponent("Web/console.html"), encoding: .utf8)) ?? ""
        check(!consoleJS.isEmpty && !consoleHTML.isEmpty, "能读到控制台静态文件")
        for stage in stages {
            check(consoleJS.contains("\(stage): ["), "控制台为 \(stage) 提供文案")
        }
        for id in ["viState", "viHint", "viDownload", "viKeyboard", "viSelect"] {
            check(consoleHTML.contains("id=\"\(id)\""), "控制台存在元素 \(id)")
        }
        check(consoleHTML.contains(VoiceInputGuide.downloadPage), "下载页地址与控制台链接一致")
        check(consoleJS.contains("/api/voice-input/select"), "控制台调用切换接口")
        check(consoleJS.contains("/api/open-keyboard-settings"), "控制台调用键盘设置接口")

        print("PASS: voice input guidance — \(checks) checks (four stages, payload, console contract)")
    }
}
