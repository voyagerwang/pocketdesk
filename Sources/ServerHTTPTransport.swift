/**
 * [INPUT]: Server的请求体上限与业务路由、HTTPRequestSecurity的严格长度解析，依赖Network连接与Foundation编解码。
 * [OUTPUT]: 有界HTTP请求分帧、头部/参数/实际回环地址读取和统一安全响应头；一连接处理一次请求后关闭。
 * [POS]: Server的传输扩展；只接收和输出报文，业务授权与执行留在主路由，避免传输细节淹没业务边界。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Network

extension Server {
    func accept(_ connection: NWConnection, secure: Bool) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: [], secure: secure)
    }

    // 完整读取请求头与 Content-Length 声明的请求体（图标上传的 base64 体可达数百 KB）。
    func receiveRequest(_ connection: NWConnection, buffer: [UInt8], secure: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(contentsOf: data) }
            guard let headerEnd = buffer.firstRange(of: Array("\r\n\r\n".utf8)) else {
                if isComplete || buffer.count > 65_536 { connection.cancel() } else { self.receiveRequest(connection, buffer: buffer, secure: secure) }
                return
            }
            let headerText = String(decoding: buffer[0..<headerEnd.lowerBound], as: UTF8.self)
            guard headerEnd.upperBound <= 65_536, let contentLength = HTTPRequestSecurity.bodyLength(in: headerText) else {
                self.respond(connection, status: 400, json: ["error": "请求头格式无效。"]); return
            }
            if contentLength > self.maxBodyBytes { self.respond(connection, status: 413, json: ["error": "请求体过大。"]); return }
            let total = headerEnd.upperBound + contentLength
            if buffer.count < total {
                if isComplete { connection.cancel() } else { self.receiveRequest(connection, buffer: buffer, secure: secure) }
                return
            }
            let body = Array(buffer[headerEnd.upperBound..<total])
            self.route(headerText: headerText, body: body, connection: connection, secure: secure)
        }
    }

    static func queryValue(_ name: String, in path: String) -> String? {
        URLComponents(string: "http://voice-deck.local\(path)")?
            .queryItems?.first(where: { $0.name == name })?.value
    }

    static func headerValue(_ name: String, in headerText: String) -> String? {
        headerText.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }?
            .dropFirst(name.count + 1)
            .trimmingCharacters(in: .whitespaces)
    }

    // 仅判断连接位置；是否授予本机权限还必须通过请求来源检查。
    static func isLoopback(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.rawValue.withUnsafeBytes { $0.first == 127 }
        case .ipv6(let address):
            return address.rawValue.withUnsafeBytes { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }
        default:
            return false
        }
    }


    func respond(_ connection: NWConnection, status: Int, json: Any) {
        // .sortedKeys：字典键序在 Swift 里是不确定的（每次序列化都可能不同）。客户端用
        // JSON.stringify 比较目标/快捷键是否变化，键序抖动会被误判为"变了"→ 每拍重建 DOM →
        // 图标因 no-store 重新下载，表现为图标周期性闪回首字。确定性输出是服务端的契约责任。
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        respond(connection, status: status, data: data, contentType: "application/json; charset=utf-8")
    }

    func respond(_ connection: NWConnection, status: Int, data: Data, contentType: String, cacheControl: String = "no-store", extraHeaders: [String: String] = [:]) {
        let reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : status == 413 ? "Payload Too Large" : status == 503 ? "Service Unavailable" : "Unprocessable Entity"
        let additions = extraHeaders.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: \(cacheControl)\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nCross-Origin-Resource-Policy: same-origin\r\nContent-Security-Policy: frame-ancestors 'none'; base-uri 'self'; object-src 'none'\r\nReferrer-Policy: no-referrer\r\n\(additions)Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
