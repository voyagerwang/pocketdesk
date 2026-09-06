/**
 * [INPUT]: 依赖 Foundation 的 Codable 与 CoreGraphics 的 CGEventFlags/CGKeyCode。
 * [OUTPUT]: 对外提供传输与配置层的全部值类型：SendCommand/PendingImage/ActivateCommand/IconUpload
 *           请求体、ShortcutConfig/TargetConfig 配置实体、ShortcutKeys 键码翻译表、
 *           ShortcutError/InputError 错误类型。
 * [POS]: Sources 的协议层；Server 反序列化请求体、TargetStore 持久化配置、InputExecutor 消费命令，全部以此为词汇表。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CoreGraphics
import Foundation

struct SendCommand: Decodable {
    let targetId: String
    let text: String
    // 可选：内联 base64 图片（兼容旧客户端）。新流程走 usePendingImage。
    let image: String?
    // true = 图片已随 /api/image 预先上传，发送时由服务端取出。
    let usePendingImage: Bool?
}

// 手机选图后立即预上传的请求体。
struct PendingImage: Decodable {
    let data: String
}

struct ActivateCommand: Decodable {
    let targetId: String
}

struct IconUpload: Decodable {
    let id: String
    let data: String
}

// 手机快捷键按钮：label 显示在按钮上，modifiers/keycode 是 CGEvent 虚拟键码组合。
struct ShortcutConfig: Codable, Equatable {
    var id: String
    var label: String
    var modifiers: [String]
    var keycode: Int
}

enum ShortcutError: Error { case message(String) }

// 快捷键录制 → CGKeyCode 的翻译表（macOS 虚拟键码）。
enum ShortcutKeys {
    // 控制台录制允许的修饰键与主键；主键限功能键与少数安全字符，避免注入文本类按键。
    static let modifierMap: [String: CGEventFlags] = [
        "command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl
    ]
    static let keyMap: [String: CGKeyCode] = [
        "up": 126, "down": 125, "left": 123, "right": 124,
        "return": 36, "delete": 51, "escape": 53, "space": 49, "tab": 48,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]
    static func flags(for modifiers: [String]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, name in
            if let flag = modifierMap[name.lowercased()] { flags.insert(flag) }
        }
    }
    static func code(for key: String) -> CGKeyCode? { keyMap[key.lowercased()] }
}

enum InputError: Error { case message(String) }

// MARK: - 目标应用配置（电脑端为唯一事实来源，顺序与成员都存在本机）

struct TargetConfig: Codable, Equatable {
    var id: String
    var name: String
    var bundleID: String?
    var path: String?
}
