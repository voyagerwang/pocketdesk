/**
 * [INPUT]: 本机控制台分块上传的文件名、声明大小与 base64 数据。
 * [OUTPUT]: 有界临时文件会话；完成后复用 PhoneFileStore 的快照、ZIP、配额和手机确认流程。
 * [POS]: 浏览器拖放适配层；不扩大 Server 单请求上限，不接受路径，不暴露临时文件。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

final class ConsoleFileUpload {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }
    private struct Item { let name: String; let size: Int64; let url: URL; var written: Int64 }
    private struct Session { let directory: URL; let createdAt: Date; var items: [Item] }
    private var sessions: [String: Session] = [:]
    private let maximumBytes: Int64 = 512 * 1024 * 1024
    private let maximumFiles = 20
    private let maximumChunkBytes = 6 * 1024 * 1024

    func start(_ input: [String: Any]) throws -> [String: Any] {
        reap()
        guard let raw = input["files"] as? [[String: Any]], !raw.isEmpty, raw.count <= maximumFiles else {
            throw Failure(message: "每次请拖入 1 到 20 个文件。")
        }
        var total: Int64 = 0
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketDesk-console-upload-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            var items: [Item] = []
            for (index, value) in raw.enumerated() {
                guard let name = value["name"] as? String, !name.isEmpty,
                      name == (name as NSString).lastPathComponent, name != ".", name != "..",
                      !name.contains("\0"), let number = value["size"] as? NSNumber else {
                    throw Failure(message: "文件名称或大小无效。")
                }
                let size = number.int64Value
                guard size >= 0, size <= maximumBytes else { throw Failure(message: "单个文件暂时最多支持 512 MB。") }
                total += size
                guard total <= maximumBytes else { throw Failure(message: "一批文件总大小暂时最多支持 512 MB。") }
                let folder = directory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let url = folder.appendingPathComponent(name)
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw Failure(message: "无法创建上传临时文件。")
                }
                items.append(Item(name: name, size: size, url: url, written: 0))
            }
            let id = UUID().uuidString
            sessions[id] = Session(directory: directory, createdAt: Date(), items: items)
            return ["uploadId": id, "chunkBytes": maximumChunkBytes]
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func append(_ input: [String: Any]) throws -> [String: Any] {
        guard let id = input["uploadId"] as? String, var session = sessions[id],
              let index = (input["index"] as? NSNumber)?.intValue,
              session.items.indices.contains(index),
              let offset = (input["offset"] as? NSNumber)?.int64Value,
              let encoded = input["data"] as? String, let data = Data(base64Encoded: encoded),
              data.count <= maximumChunkBytes else { throw Failure(message: "上传分块无效，请重新拖入文件。") }
        var item = session.items[index]
        guard offset == item.written, item.written + Int64(data.count) <= item.size else {
            throw Failure(message: "上传顺序已中断，请重新拖入文件。")
        }
        let handle = try FileHandle(forWritingTo: item.url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        item.written += Int64(data.count)
        session.items[index] = item
        sessions[id] = session
        return ["received": item.written]
    }

    func finish(_ input: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard let id = input["uploadId"] as? String, let session = sessions.removeValue(forKey: id) else {
            completion(["error": "上传已失效，请重新拖入文件。"]); return
        }
        DispatchQueue.global(qos: .utility).async {
            defer { try? FileManager.default.removeItem(at: session.directory) }
            do {
                guard session.items.allSatisfy({ $0.written == $0.size }) else {
                    throw Failure(message: "文件尚未上传完整，请重新拖入。")
                }
                let offer = try PhoneFileStore.shared.prepare(paths: session.items.map(\.url.path),
                    subject: PhoneFileStore.subject, taskId: UUID().uuidString,
                    authorized: { !LockScreenInput.locked })
                completion(["ok": true, "file": offer.json, "message": "已准备好「\(offer.name)」，等待手机下载。"])
            } catch { completion(["error": error.localizedDescription]) }
        }
    }

    func cancel(_ input: [String: Any]) {
        guard let id = input["uploadId"] as? String, let session = sessions.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: session.directory)
    }

    private func reap() {
        let expired = sessions.filter { Date().timeIntervalSince($0.value.createdAt) > 30 * 60 }.map(\.key)
        for id in expired { if let session = sessions.removeValue(forKey: id) { try? FileManager.default.removeItem(at: session.directory) } }
    }
}
