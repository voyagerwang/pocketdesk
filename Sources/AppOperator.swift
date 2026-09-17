/**
 * [INPUT]: 依赖 AppKit 的 NSWorkspace 与 Foundation；消费工作台目标配置并扫描标准应用目录解析本地化名字。
 * [OUTPUT]: 对外提供 AppOperator.resolve（应用名 → 已安装 .app 包路径+显示名）与 AppOperator.open（启动 .app）。
 * [POS]: Sources 的「打开应用」执行器（路径 B）；与 BrowserOperator（路径 A 开网页）对称，
 *        明确打开请求经执行时租约核验后调用，不重复弹确认。
 *        tt-bridge（CC BY-NC）只覆盖浏览器、不启动应用，因此本能力由原生 API 自研，未嵌入其代码。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

enum AppOperator {
    /// 允许启动的应用目录（白名单）。只有落在这些目录内的 .app 才启动，杜绝任意可执行文件。
    private static let trustedDirs: [String] = [
        "/System/Applications",
        "/Applications",
        "/Applications/Utilities",
        (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
    ]

    /// 中文名 → 包名/标识符关键字。模型常拿到「飞书」这类中文，而本机包名是 Lark/Feishu。
    private static let alias: [String: [String]] = [
        "uu远程": ["uuremote", "com.netease.uuremote"],
        "uu": ["uuremote", "com.netease.uuremote"],
        "飞书": ["lark", "feishu"],
        "微信": ["wechat", "weixin"],
        "钉钉": ["dingtalk"],
        "备忘录": ["notes"],
        "便签": ["notes"],
        "计算器": ["calculator"],
        "终端": ["terminal"],
        "音乐": ["music"],
        "日历": ["calendar"],
        "邮件": ["mail"],
        "浏览器": ["safari", "chrome"],
        "照片": ["photos"],
        "信息": ["messages"],
        "地图": ["maps"],
        "设置": ["system settings", "systemsettings", "preferences"],
        "系统设置": ["system settings", "systemsettings", "preferences"],
        "访达": ["finder"],
        "预览": ["preview"],
        "文本编辑": ["textedit"],
        "提醒事项": ["reminders"],
        "图书": ["books"],
        "电视": ["tv"],
        "播客": ["podcasts"],
        "facetime": ["facetime"],
        "活动监视器": ["activity monitor"],
        "控制台": ["console"],
    ]

    /// 把应用名解析成已安装 .app 的包路径与显示名；找不到返回 nil。
    /// 匹配：显示名/包名/包标识符的精确或包含匹配；中文经 alias 展开后再匹配。
    static func resolve(_ name: String) -> (display: String, path: String)? {
        resolve(name, configured: [])
    }

    /// 空格不改变应用身份；配置名优先，同分多应用时拒绝猜测。
    static func normalized(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    static func resolve(_ name: String, configured: [TargetConfig]) -> (display: String, path: String)? {
        let query = normalized(name)
        guard !query.isEmpty else { return nil }
        let configuredMatches = configured.filter { normalized($0.name) == query || normalized($0.id) == query }
        if configuredMatches.count > 1 { return nil }
        if let target = configuredMatches.first {
            let path = target.path.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
                ?? target.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
            if let path { return (target.name, path) }
        }
        let keywords = [query] + (alias[query] ?? []).map(normalized)
        var matches: [String: (display: String, score: Int)] = [:]
        for dir in trustedDirs {
            guard let children = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) else { continue }
            for appURL in children where appURL.pathExtension.lowercased() == "app" {
                guard let bundle = Bundle(url: appURL), let info = bundle.infoDictionary else { continue }
                let display = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                    ?? info["CFBundleDisplayName"] as? String
                    ?? info["CFBundleName"] as? String
                    ?? appURL.deletingPathExtension().lastPathComponent
                let candidates = [display, info["CFBundleName"] as? String ?? "",
                                  info["CFBundleIdentifier"] as? String ?? "",
                                  appURL.deletingPathExtension().lastPathComponent].map(normalized).filter { !$0.isEmpty }
                let exact = candidates.contains { keywords.contains($0) }
                let partial = candidates.contains { candidate in keywords.contains { candidate.contains($0) } }
                if exact || partial { matches[appURL.path] = (display, exact ? 2 : 1) }
            }
        }
        guard let score = matches.values.map({ $0.score }).max() else { return nil }
        let best = matches.filter { $0.value.score == score }
        guard best.count == 1, let match = best.first else { return nil }
        return (match.value.display, match.key)
    }

    /// 启动已解析出的 .app 包。只在受信任目录内才允许，避免启动任意可执行文件。
    static func open(_ bundlePath: String) -> Result<Void, Error> {
        let url = URL(fileURLWithPath: bundlePath)
        guard url.pathExtension.lowercased() == "app" else {
            return .failure(NSError(domain: "AppOperator", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "不是 .app 包：\(bundlePath)"]))
        }
        guard trustedDirs.contains(where: { bundlePath.hasPrefix($0 + "/") }) else {
            return .failure(NSError(domain: "AppOperator", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "不在受信任的应用目录内，拒绝启动：\(bundlePath)"]))
        }
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            return .failure(NSError(domain: "AppOperator", code: 3,
                                    userInfo: [NSLocalizedDescriptionKey: "找不到这个应用：\(bundlePath)"]))
        }
        let ok = NSWorkspace.shared.open(url)
        return ok ? .success(()) : .failure(NSError(domain: "AppOperator", code: 2,
                                                    userInfo: [NSLocalizedDescriptionKey: "系统未能启动这个应用：\(bundlePath)"]))
    }
}
