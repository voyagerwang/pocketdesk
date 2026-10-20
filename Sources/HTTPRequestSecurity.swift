/**
 * [INPUT]: HTTP 头部、实际监听协议/端口和连接的本机地址；不读取凭证或访问网络。
 * [OUTPUT]: 统一可信 Host/同源校验、本机 JSON 写入豁免、非负请求体长度解析与图标资源ID路径边界。
 * [POS]: Server 路由前的纯传输边界；回环地址只说明连接位置，必须结合浏览器来源才能授予本机权限。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum HTTPRequestSecurity {
    // MARK: 请求来源

    static func trusted(host: String?, origin: String?, port: UInt16, secure: Bool,
                        localAddress: String?, stableHost: String?, fetchSite: String? = nil) -> Bool {
        if let fetchSite, !["same-origin", "none"].contains(fetchSite.lowercased()) { return false }
        guard let host else { return false }
        let names = ["localhost", "127.0.0.1", "::1", localAddress, stableHost].compactMap { $0 }
        let authorities = Set(names.map { authority($0, port: port) })
        guard authorities.contains(host.lowercased()) else { return false }
        guard let origin else { return true }
        return origin.lowercased() == "\(secure ? "https" : "http")://\(host.lowercased())"
    }

    static func localExemption(loopback: Bool, method: String, host: String?, origin: String?,
                               contentType: String?, port: UInt16, secure: Bool) -> Bool {
        guard loopback, trusted(host: host, origin: origin, port: port, secure: secure,
                               localAddress: nil, stableHost: nil) else { return false }
        if method == "GET" || method == "HEAD" { return true }
        // 原生客户端可凭 Bearer 调用；不把缺少 Origin 的网页写入当作本机管理请求。
        return origin != nil && contentType?.lowercased().split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) == "application/json"
    }

    private static func authority(_ name: String, port: UInt16) -> String {
        let value = name.lowercased()
        return "\(value.contains(":") && !value.hasPrefix("[") ? "[\(value)]" : value):\(port)"
    }

    // 图标 ID 只标识已配置目标，不得把网络参数解释成磁盘相对路径。
    static func safeIconID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && value != "." && value != ".."
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    // MARK: 单请求分帧

    static func bodyLength(in header: String) -> Int? {
        var unique = Set<String>()
        var length = 0
        let singletons: Set<String> = ["host", "origin", "authorization", "content-type", "content-length", "sec-fetch-site"]
        for line in header.components(separatedBy: "\r\n").dropFirst() {
            guard !line.isEmpty, line.first != " ", line.first != "\t", let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, !name.contains(" "), !name.contains("\t"), name != "transfer-encoding" else { return nil }
            if singletons.contains(name), !unique.insert(name).inserted { return nil }
            if name == "content-length" {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let parsed = Int(value) else { return nil }
                length = parsed
            }
        }
        return length
    }
}
