import AppKit
import Foundation

/// Read Chrome's on-disk bookmark tree afresh; IDs include the profile to avoid collisions.
enum ChromeBookmarks {
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    static func matches(_ name: String, entries: [Entry]) -> [Entry] {
        let query = normalized(name)
        guard !query.isEmpty else { return [] }
        let bookmarks = entries.filter { $0.url != nil }
        let exact = bookmarks.filter { normalized($0.name) == query }
        if !exact.isEmpty { return exact }
        return bookmarks.filter { normalized(([$0.name] + $0.folders).joined(separator: " / ")).contains(query) }
    }
    struct Entry {
        var id: String
        var name: String
        var folders: [String]
        var url: String?
        var profile: String
        var json: [String: Any] {
            var value: [String: Any] = ["id": id, "name": name, "folders": folders,
                                        "profile": profile, "kind": url == nil ? "folder" : "bookmark"]
            if let url { value["url"] = url }
            return value
        }
    }

    static func read(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")) throws -> [Entry] {
        let profiles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var entries: [Entry] = []
        var loaded = false
        for profile in profiles {
            let file = profile.appendingPathComponent("Bookmarks")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let data = try Data(contentsOf: file)
            guard let tree = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = tree["roots"] as? [String: Any] else { continue }
            loaded = true
            func walk(_ node: [String: Any], folders: [String]) {
                guard let name = node["name"] as? String, let id = node["id"] as? String else { return }
                let isFolder = node["type"] as? String == "folder"
                let url = node["url"] as? String
                if isFolder || url != nil {
                    entries.append(Entry(id: profile.lastPathComponent + ":" + id, name: name,
                                         folders: folders, url: isFolder ? nil : url, profile: profile.lastPathComponent))
                }
                for child in node["children"] as? [[String: Any]] ?? [] {
                    walk(child, folders: folders + [name])
                }
            }
            for key in roots.keys.sorted() {
                if let node = roots[key] as? [String: Any] { walk(node, folders: []) }
            }
        }
        if !loaded { throw NSError(domain: "ChromeBookmarks", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有找到可读取的 Chrome 书签文件。"] ) }
        return entries
    }

    static func search(_ query: String) -> String {
        do {
            let term = normalized(query)
            let matches = try read().filter { term.isEmpty || normalized(([$0.name] + $0.folders + [$0.url ?? ""]).joined(separator: " / ")).contains(term) }
            let result: [String: Any] = ["matches": matches.prefix(100).map(\.json), "total": matches.count, "truncated": matches.count > 100]
            return String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8) ?? "{}"
        } catch { return "读取失败：" + error.localizedDescription }
    }

    static func open(_ id: String, completion: @escaping (String) -> Void) {
        do {
            guard let entry = try read().first(where: { $0.id == id }), let raw = entry.url,
                  let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "file"].contains(scheme),
                  scheme == "file" || url.host != nil else { completion("未打开：书签不存在、是文件夹或地址类型不支持。"); return }
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { completion("未打开：未安装 Chrome。"); return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { completion("未打开：" + error.localizedDescription) }
                else { completion("已向 Chrome 提交打开书签请求：" + entry.name) }
            }
        } catch { completion("未打开：" + error.localizedDescription) }
    }
}
