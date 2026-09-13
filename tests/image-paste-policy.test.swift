/**
 * [INPUT]: 依赖 Sources/ImagePastePolicy.swift 的纯时序决策。
 * [OUTPUT]: 验证 UU 文字粘贴在 Cmd+V 前留出剪贴板同步时间、Chrome 多图每张 Cmd+V 前后采用保守间隔，其他应用保持既有节奏。
 * [POS]: tests 的图片粘贴策略隔离回归；不访问剪贴板、不注入按键、不连接真实飞书。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main
enum ImagePastePolicyTests {
    static func main() {
        let chromeMulti = ImagePastePolicy.timing(bundleIdentifier: "com.google.Chrome", imageCount: 3)
        precondition(chromeMulti.clipboardSettleMicros == 250_000)
        precondition(chromeMulti.consumptionMicros == 2_500_000)
        precondition(chromeMulti.interImageClickMicros == 180_000)
        precondition(ImagePastePolicy.needsInterImageClick(timing: chromeMulti, imageIndex: 0, imageCount: 3))
        precondition(ImagePastePolicy.needsInterImageClick(timing: chromeMulti, imageIndex: 1, imageCount: 3))
        precondition(!ImagePastePolicy.needsInterImageClick(timing: chromeMulti, imageIndex: 2, imageCount: 3))
        precondition(ImagePastePolicy.boundClickScopeIndex(
            rolesFromFocused: ["AXStaticText", "AXGroup", "AXWebArea", "AXWindow"]) == 2)
        precondition(ImagePastePolicy.boundClickScopeIndex(
            rolesFromFocused: ["AXTextArea", "AXGroup", "AXWebArea"]) == 0)
        precondition(ImagePastePolicy.boundClickScopeIndex(
            rolesFromFocused: ["AXButton", "AXToolbar", "AXWindow"]) == nil)

        let chromeSingle = ImagePastePolicy.timing(bundleIdentifier: "com.google.Chrome", imageCount: 1)
        precondition(chromeSingle == ImagePasteTiming(clipboardSettleMicros: 0, consumptionMicros: 1_000_000,
            interImageClickMicros: nil))

        let nativeFeishu = ImagePastePolicy.timing(bundleIdentifier: "com.bytedance.Feishu", imageCount: 3)
        precondition(nativeFeishu == ImagePasteTiming(clipboardSettleMicros: 0, consumptionMicros: 1_000_000,
            interImageClickMicros: nil))

        let uu = ImagePastePolicy.timing(bundleIdentifier: "com.netease.uuremote", imageCount: 3)
        precondition(uu == ImagePasteTiming(clipboardSettleMicros: 0, consumptionMicros: 1_000_000,
            interImageClickMicros: nil))

        precondition(ImagePastePolicy.textTiming(bundleIdentifier: "com.netease.uuremote")
            == TextPasteTiming(beforePasteMicros: 1_200_000, afterPasteMicros: 200_000))
        precondition(ImagePastePolicy.textTiming(bundleIdentifier: "com.bytedance.Feishu")
            == TextPasteTiming(beforePasteMicros: 0, afterPasteMicros: 200_000))

        print("image paste policy tests passed")
    }
}
