import Foundation

@main struct ChromeBookmarkTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let tree: [String: Any] = ["roots": ["bookmark_bar": ["id": "1", "type": "folder", "name": "书签栏", "children": [
            ["id": "2", "type": "folder", "name": "工作", "children": [
                ["id": "3", "type": "url", "name": "个人工作台", "url": "http://localhost:8787"],
                ["id": "4", "type": "url", "name": "本地文档", "url": "file:///tmp/example.html"]
            ]]
        ]]]]
        for profile in ["Default", "Profile 1"] {
            let directory = root.appendingPathComponent(profile)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: tree).write(to: directory.appendingPathComponent("Bookmarks"))
        }
        let entries = try ChromeBookmarks.read(root: root)
        let workbenches = entries.filter { $0.name == "个人工作台" }
        precondition(ChromeBookmarks.matches(" 个人工作台\n", entries: entries).count == 2)
        let padded = ChromeBookmarks.Entry(id: "Default:9", name: " 个人工作台", folders: [], url: "https://example.com", profile: "Default")
        precondition(ChromeBookmarks.matches("个人工作台", entries: [padded]).count == 1)
        precondition(workbenches.count == 2 && Set(workbenches.map(\.id)).count == 2)
        precondition(workbenches.allSatisfy { $0.folders == ["书签栏", "工作"] && $0.url == "http://localhost:8787" })
        precondition(entries.filter { $0.url == nil }.count == 4)
        precondition(entries.filter { $0.url?.hasPrefix("file:") == true }.count == 2)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Default/Bookmarks"))
        let refreshed = try ChromeBookmarks.read(root: root)
        precondition(refreshed.count == 4)
        print("Chrome bookmarks: nested folders, names, file URLs, profile IDs and fresh reads passed")
    }
}
