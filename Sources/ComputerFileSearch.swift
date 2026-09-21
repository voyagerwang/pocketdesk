/**
 * [INPUT]: 用户给出的文件名关键词与可选目录；系统 Spotlight 索引（mdfind）。
 * [OUTPUT]: search_computer_files：有界候选路径与是否截断的如实回报；不读取文件正文、
 *           不猜未命中的路径、不执行用户脚本；locate 可注入供替身测试。
 * [POS]: 小精灵发送前的只读文件发现；索引未收录时由用户提供路径或拖入文件兜底。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum ComputerFileSearch {
    static let limit = 20
    static let outputCap = 64 * 1024
    static let searchTimeout: TimeInterval = 5
    static let tool: [String: Any] = ["type": "function", "function": [
        "name": "search_computer_files", "description": "按文件名关键词搜索电脑 Spotlight 索引。默认搜索用户主目录，可给 directory 缩小范围。最多返回20个普通文件路径；不读正文。同名候选必须让用户选择。找不到可能未被索引，可让用户拖文件到小精灵或提供完整路径。",
        "parameters": ["type": "object", "properties": ["query": ["type": "string"], "directory": ["type": "string"]], "required": ["query"]]
    ] as [String: Any]]

    /// 测试接缝：返回原始（未过滤）路径数组；默认调用 mdfind -0 -onlyin 目录 -name 关键词。
    static var locate: (String, String) -> [String] = { query, folder in
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-0", "-onlyin", folder, "-name", query]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + searchTimeout, execute: timeout)
        var output = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            output.append(chunk)
            if output.count >= outputCap { if process.isRunning { process.terminate() } ; break }
        }
        try? pipe.fileHandleForReading.close()
        process.waitUntilExit()
        timeout.cancel()
        return output.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    static func search(arguments: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard let data = arguments.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = values["query"] as? String, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  query.count <= 200, !query.hasPrefix("-") else { completion("文件查询参数无效，请提供文件名关键词。"); return }
            let folder = ((values["directory"] as? String ?? "~") as NSString).expandingTildeInPath
            guard folder.hasPrefix("/") else { completion("请提供完整搜索目录。"); return }
            let raw = locate(query, folder)
            let paths = raw.filter {
                (try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            }
            let result: [String: Any] = ["files": Array(paths.prefix(limit)), "truncated": raw.count > limit || raw.count > outputCap,
                                       "note": "仅索引内文件；同名需用户选择。"]
            completion(String(data: (try? JSONSerialization.data(withJSONObject: result)) ?? Data(), encoding: .utf8) ?? "搜索结果无法读取。")
        }
    }
}
