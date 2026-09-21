/**
 * [INPUT]: Network 连接、Auth 配对身份与可注入 PhoneFileStore 快照/超时；Server 委托文件路由。
 * [OUTPUT]: 收件列表、确认/移除接口与有背压的附件下载；列表/确认/移除一律要求 Bearer（不依赖回环豁免），
 *           GET/HEAD下载仅认手机确认签发的十分钟票据；每次只读 256KiB，最多并行三路，断线/超时恰好释放一次。
 * [POS]: 独立文件传输通路，磁盘与下载不占画面或控制队列；长期配对 token 不进下载 URL。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Network

enum PhoneFileHTTP {
    static let prefix = "/api/v1/phone-files"
    private static let chunkSize = 256 * 1024
    private static let maxStreams = 3
    private static let queue = DispatchQueue(label: "dev.voicedeck.phone-files.http")
    private static var streams = 0

    static func handle(method: String, path: String, authorization: String?, connection: NWConnection,
                       store: PhoneFileStore = .shared, streamTimeout: TimeInterval = 600,
                       respond: @escaping (Int, [String: Any]) -> Void) -> Bool {
        guard path == prefix || path.hasPrefix(prefix + "/") else { return false }
        // 下载票据仅允许读取已确认的那一个快照；其余操作要求配对 token。
        let downloadPrefix = prefix + "/download/"
        let isDownload = (method == "GET" || method == "HEAD") && path.hasPrefix(downloadPrefix)
        guard isDownload || Auth.verify(authorizationHeader: authorization) else {
            respond(401, ["error": "请重新扫码连接后接收文件。"]); return true
        }
        queue.async {
            let subject = PhoneFileStore.subject
            do {
                if isDownload {
                    guard streams < maxStreams else { respond(503, ["error": "正在下载其他文件，请稍后重试。"]); return }
                    let ticket = String(path.dropFirst(downloadPrefix.count))
                    let (offer, file) = try store.download(ticket: ticket, subject: subject)
                    streams += 1
                    stream(offer: offer, file: file, connection: connection, duration: streamTimeout, headOnly: method == "HEAD")
                } else if method == "GET" && path == prefix {
                    respond(200, ["files": store.list(subject: subject).map(\.json)])
                } else {
                    let parts = path.dropFirst(prefix.count).split(separator: "/").map(String.init)
                    guard method == "POST", parts.count == 2, UUID(uuidString: parts[0]) != nil else {
                        respond(400, ["error": "无效的收件操作。"]); return
                    }
                    switch parts[1] {
                    case "accept":
                        let ticket = try store.accept(id: parts[0], subject: subject)
                        respond(200, ["url": downloadPrefix + ticket])
                    case "dismiss":
                        try store.dismiss(id: parts[0], subject: subject)
                        respond(200, ["ok": true])
                    default: respond(404, ["error": "未找到收件操作。"])
                    }
                }
            } catch { respond(422, ["error": error.localizedDescription]) }
        }
        return true
    }

    private static func stream(offer: PhoneFileStore.Offer, file: FileHandle, connection: NWConnection, duration: TimeInterval, headOnly: Bool) {
        let name = offer.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(offer.size)\r\n"
            + "Content-Disposition: attachment; filename=\"download\"; filename*=UTF-8''\(name)\r\n"
            + "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        // 完成/断线/超时共用一次性释放；清空 timer 与连接回调，打断闭包引用环。
        // 单次只发送一个块，网络背压不会把整个文件读入内存。
        var timeout: DispatchSourceTimer?
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            timeout?.setEventHandler {}
            timeout?.cancel()
            timeout = nil
            connection.stateUpdateHandler = nil
            streams -= 1
            try? file.close()
            connection.cancel()
        }
        func next() {
            guard !finished else { return }
            do {
                guard let chunk = try file.read(upToCount: chunkSize), !chunk.isEmpty else { finish(); return }
                connection.send(content: chunk, completion: .contentProcessed { error in
                    queue.async { if error != nil { finish() } else { next() } }
                })
            } catch { finish() }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: queue.async { finish() }
            default: break
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + duration)
        timer.setEventHandler { finish() }
        timeout = timer
        timer.resume()
        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            queue.async { if error != nil || headOnly { finish() } else { next() } }
        })
    }
}
