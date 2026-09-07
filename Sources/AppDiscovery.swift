/**
 * [INPUT]: 依赖 Foundation 的 FileManager 与 AppKit 的 NSWorkspace.displayName；消费 Models 的 TargetConfig。
 * [OUTPUT]: 对外提供 AppDiscovery（安装应用扫描——含 .app 平铺与 X.localized 包装两种形态、名称/路径搜索、新增目标的安全 slug 生成）。
 * [POS]: Sources 的应用发现层；Server 的 /api/apps 搜索与 /api/targets 的 id 补齐逻辑依赖它。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

enum AppDiscovery {
    static var searchRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                home + "/Applications"]
    }

    static func allInstalledApps() -> [(name: String, path: String)] {
        let fm = FileManager.default
        var seen = Set<String>()
        var apps: [(String, String)] = []
        for root in searchRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries.sorted() {
                let path = root + "/" + entry
                if entry.hasSuffix(".app") {
                    guard !seen.contains(path), fm.fileExists(atPath: path) else { continue }
                    seen.insert(path)
                    apps.append((fm.displayName(atPath: path), path))
                    continue
                }
                // 本地化包装形态：X.localized/ 内藏真正的 .app。此时用包装目录的显示名而非内部
                // .app 的名字——.localized 是 macOS 官方的目录名本地化机制，中文系统下
                // DingTalk.localized 显示"钉钉"，而内部 DingTalk.app 仍叫 DingTalk。
                // 复用系统本地化，避免自己维护一份中英别名表。
                guard entry.hasSuffix(".localized") else { continue }
                guard let inner = try? fm.contentsOfDirectory(atPath: path) else { continue }
                for sub in inner.sorted() where sub.hasSuffix(".app") {
                    let subPath = path + "/" + sub
                    guard !seen.contains(subPath), fm.fileExists(atPath: subPath) else { continue }
                    seen.insert(subPath)
                    apps.append((fm.displayName(atPath: path), subPath))
                }
            }
        }
        return apps.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    static func search(_ query: String, limit: Int = 50) -> [[String: Any]] {
        let apps = allInstalledApps()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matched = trimmed.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.path.localizedCaseInsensitiveContains(trimmed)
        }
        return matched.prefix(limit).map { ["name": $0.name, "path": $0.path] }
    }

    static func makeID(forName name: String, existing: [TargetConfig]) -> String {
        let base = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : ($0 == " " ? "-" : "") }
            .joined()
        let slug = base.isEmpty ? "app" : String(base.prefix(24))
        var candidate = slug; var counter = 2
        while existing.contains(where: { $0.id == candidate }) {
            candidate = "\(slug)-\(counter)"; counter += 1
        }
        return candidate
    }
}
