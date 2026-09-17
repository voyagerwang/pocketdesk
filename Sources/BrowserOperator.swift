/**
 * [INPUT]: 依赖 AppKit 的 NSWorkspace；只接受 http(s) 绝对地址。
 * [OUTPUT]: 对外提供 BrowserOperator.open——在用户的默认浏览器中打开一个网址（新标签页）。
 * [POS]: Sources 的浏览器写操作执行器；与 PageReader（只读）对称，承担 M2 的受控写入（方案 §10）。
 *        由 AgentRunner 核验控制会话后执行明确打开意图，不再生成二次确认票据。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

enum BrowserOperator {
    /// 在默认浏览器打开一个 http(s) 网址（新标签页）。返回成功或带人话的错误。
    static func open(_ urlString: String) -> Result<Void, Error> {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https") else {
            return .failure(NSError(domain: "BrowserOperator", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "不是合法的 http(s) 网址：\(urlString)"]))
        }
        let ok = NSWorkspace.shared.open(url)
        if ok { return .success(()) }
        return .failure(NSError(domain: "BrowserOperator", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "系统未能打开这个网址：\(urlString)"]))
    }
}
