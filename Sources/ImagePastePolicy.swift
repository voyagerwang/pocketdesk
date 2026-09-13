/**
 * [INPUT]: 消费目标应用 bundle identifier 与本次图片数量。
 * [OUTPUT]: 提供文字/图片剪贴板写入后的稳定等待、Cmd+V 后的消费等待，以及是否需要在相邻图片间重建编辑器插入点；UU 文字与 Chrome 多图采用目标专属节奏。
 * [POS]: Sources 的剪贴板粘贴时序策略；InputExecutor 负责执行，策略本身无桌面副作用并可隔离测试。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

struct ImagePasteTiming: Equatable {
    let clipboardSettleMicros: UInt32
    let consumptionMicros: UInt32
    let interImageClickMicros: UInt32?
}

struct TextPasteTiming: Equatable {
    let clipboardSettleMicros: UInt32
    let consumptionMicros: UInt32
}

enum ImagePastePolicy {
    static let chromeBundleIdentifier = "com.google.Chrome"
    static let uuBundleIdentifier = "com.netease.uuremote"
    private static let editableScopeRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func timing(bundleIdentifier: String?, imageCount: Int) -> ImagePasteTiming {
        if bundleIdentifier == chromeBundleIdentifier, imageCount > 1 {
            // 飞书网页会在粘贴事件返回后异步读取剪贴板并挂载附件；下一张覆盖得太早时，
            // 前面的事件可能读到最后一张。这里无法观察网页 DOM，只能在应用边界保守串行。
            return ImagePasteTiming(clipboardSettleMicros: 250_000, consumptionMicros: 2_500_000,
                interImageClickMicros: 180_000)
        }
        return ImagePasteTiming(clipboardSettleMicros: 0, consumptionMicros: 1_000_000,
            interImageClickMicros: nil)
    }

    static func textTiming(bundleIdentifier: String?) -> TextPasteTiming {
        bundleIdentifier == uuBundleIdentifier
            ? TextPasteTiming(clipboardSettleMicros: 120_000, consumptionMicros: 600_000)
            : TextPasteTiming(clipboardSettleMicros: 0, consumptionMicros: 200_000)
    }

    static func needsInterImageClick(timing: ImagePasteTiming, imageIndex: Int, imageCount: Int) -> Bool {
        timing.interImageClickMicros != nil && imageIndex >= 0 && imageIndex < imageCount - 1
    }

    // 输入是从当前焦点向父级的角色链；传统编辑元素取自身，文档/表格内部角色归一到
    // 最近 WebArea。链中没有这两类范围时拒绝点击，浏览器工具栏因此不会成为锚点。
    static func boundClickScopeIndex(rolesFromFocused roles: [String]) -> Int? {
        roles.firstIndex { editableScopeRoles.contains($0) || $0 == "AXWebArea" }
    }
}
