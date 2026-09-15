/**
 * [INPUT]: 消费目标应用 bundle identifier 与本次图片数量。
 * [OUTPUT]: 提供文字/图片剪贴板写入后的稳定等待、Cmd+V 后的消费等待，以及是否需要在相邻图片间重建编辑器插入点；UU 文字与 Chrome 多图采用目标专属节奏。画布类目标（白板等无输入框页面）的多图退化路径另给方向键分离节奏。
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
    /// 目标应用读取本机剪贴板并把新代际同步到远端后，才允许发送 Cmd+V。
    let beforePasteMicros: UInt32
    /// Cmd+V 发出后给目标输入框消费按键的时间。
    let afterPasteMicros: UInt32
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
            ? TextPasteTiming(beforePasteMicros: 1_200_000, afterPasteMicros: 200_000)
            : TextPasteTiming(beforePasteMicros: 0, afterPasteMicros: 200_000)
    }

    static func needsInterImageClick(timing: ImagePasteTiming, imageIndex: Int, imageCount: Int) -> Bool {
        timing.interImageClickMicros != nil && imageIndex >= 0 && imageIndex < imageCount - 1
    }

    /// 画布类目标（Excalidraw 等白板）没有输入框可当锚点，点击画布也改变不了粘贴位置——
    /// 白板把每次粘贴都放在视口中心，连续粘贴完全重叠，看起来就像"只同步了一张"。
    /// 粘贴后的新元素保持选中，方向键能把它挪开给下一张腾位置：右 6 下 4，逐键留消费间隔。
    static let canvasNudgeKeycodes: [UInt16] = [124, 124, 124, 124, 124, 124, 125, 125, 125, 125]
    static let canvasNudgeGapMicros: UInt32 = 30_000

    // 输入是从当前焦点向父级的角色链；传统编辑元素取自身，文档/表格内部角色归一到
    // 最近 WebArea。链中没有这两类范围时拒绝点击，浏览器工具栏因此不会成为锚点。
    static func boundClickScopeIndex(rolesFromFocused roles: [String]) -> Int? {
        roles.firstIndex { editableScopeRoles.contains($0) || $0 == "AXWebArea" }
    }
}
