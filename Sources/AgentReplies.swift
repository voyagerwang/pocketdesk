/**
 * [INPUT]: 无外部依赖；只保存“打开类”回执的统一措辞。
 * [OUTPUT]: 一句能念给人听的打开回执，以及“这次到底打开了没有”的唯一判定。
 * [POS]: Agent 回执文案的单一来源；判定与文案解耦，以后改话术不再牵动流程逻辑。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum AgentReplies {
    /// 打开成功的统一收尾；判断成功只看这个后缀，不看动词也不看主语。
    static let opened = "打开了。"
    static func isOpened(_ payload: String) -> Bool { payload.hasSuffix(opened) }
    static func app(_ name: String) -> String { name + opened }
    static func page() -> String { "网页" + opened }
    static func bookmark(_ name: String) -> String { "书签「" + name + "」" + opened }
}
