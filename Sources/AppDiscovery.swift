/**
 * [INPUT]: 依赖 Foundation 的 FileManager 与 AppKit 的 NSWorkspace.displayName；消费 Models 的 TargetConfig。
 * [OUTPUT]: 对外提供 AppDiscovery（安装应用扫描、名称/路径搜索、新增目标的安全 slug 生成）。
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
            for entry in entries.sorted() where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                guard !seen.contains(path), fm.fileExists(atPath: path) else { continue }
                seen.insert(path)
                apps.append((fm.displayName(atPath: path), path))
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
