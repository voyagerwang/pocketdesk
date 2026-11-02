/**
 * [INPUT]: 只依赖 Foundation；输入是模型的最终回答原文，或流式到达的累计片段。
 * [OUTPUT]: 把回答开头的“口播：……”总括行拆出来（屏幕只显示正文，语音只念这一句），并在流式片段里第一时间认出写完的那一行。
 * [POS]: AgentRunner 与桌面语音之间的纯文本约定；不播报、不改任务状态，拆不出就原样返回，不猜。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum SpokenSummary {
    /// 模型可能写成全角或半角冒号，或者套个方括号；都认。
    static let markers = ["口播：", "口播:", "【口播】", "[口播]"]
    /// 念出来的总括上限：再长就不是“一句话”了，宁可交回桌面语音自己的挑句规则。
    static let maxLength = 80

    /// 回答第一行（或模型写反了放在最后一行）是口播行时拆开；否则 spoken 为 nil、正文原样。
    static func split(_ content: String) -> (display: String, spoken: String?) {
        var lines = content.components(separatedBy: "\n")
        func spokenLine(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let marker = markers.first(where: { trimmed.hasPrefix($0) }) else { return nil }
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return (content, nil)
        }
        var spoken: String?
        if let line = spokenLine(lines[first]) {
            spoken = line; lines.remove(at: first)
        } else if let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  last != first, let line = spokenLine(lines[last]) {
            spoken = line; lines.remove(at: last)
        }
        let display = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let said = spoken else { return (content, nil) }
        // 模型只写了一行口播、没写正文：屏幕上也显示这句话。
        let shown = display.isEmpty ? (said.isEmpty ? content : said) : display
        // 口播行太长或是空的：仍从屏幕上拿掉那行标记，但不当作可念的总括。
        guard !said.isEmpty, said.count <= maxLength else { return (shown, nil) }
        return (shown, said)
    }

    /// 流式累计片段里，口播行写完（遇到换行）就返回它；开头不是口播标记就永远返回 nil。
    static func completedLine(_ partial: String) -> String? {
        let trimmed = partial.drop(while: { $0.isWhitespace })
        guard let marker = markers.first(where: { trimmed.hasPrefix($0) }) else { return nil }
        let rest = trimmed.dropFirst(marker.count)
        guard let newline = rest.firstIndex(of: "\n") else { return nil }
        let line = rest[..<newline].trimmingCharacters(in: .whitespaces)
        return line.isEmpty || line.count > maxLength ? nil : line
    }

    /// 流式观察者：口播行一写完只通知一次，之后的片段不再理会。
    static func watcher(_ emit: @escaping (String) -> Void) -> (String) -> Void {
        var fired = false
        return { partial in
            guard !fired, let line = completedLine(partial) else { return }
            fired = true
            emit(line)
        }
    }
}
