/**
 * [INPUT]: HTTPRequestSecurity 的纯来源/分帧策略；全部地址和报文为合成数据。
 * [OUTPUT]: 固定本机与LAN合法请求、DNS重绑定/跨源/缺失来源写入拒绝，以及畸形长度不进入数组切片的回归。
 * [POS]: 入口授权隔离测试；不读取真实凭证、不监听端口、不操作桌面或设备。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main enum HTTPRequestSecurityTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            guard value else { fatalError("FAIL: \(label)") }
            checks += 1
        }
        func trusted(_ host: String? = "127.0.0.1:46387", _ origin: String? = nil,
                     secure: Bool = false, port: UInt16 = 46387) -> Bool {
            HTTPRequestSecurity.trusted(host: host, origin: origin, port: port, secure: secure,
                localAddress: "192.168.1.2", stableHost: "My-Mac.local")
        }
        func exempt(_ method: String = "POST", _ origin: String? = "http://127.0.0.1:46387",
                    _ type: String? = "application/json", loopback: Bool = true) -> Bool {
            HTTPRequestSecurity.localExemption(loopback: loopback, method: method, host: "127.0.0.1:46387",
                origin: origin, contentType: type, port: 46387, secure: false)
        }
        check(trusted(), "local CLI read")
        check(trusted("localhost:46387", "http://localhost:46387"), "local browser")
        check(trusted("[::1]:46387", "http://[::1]:46387"), "IPv6 loopback")
        check(trusted("192.168.1.2:46387", "http://192.168.1.2:46387"), "LAN browser exact address")
        check(trusted("my-mac.local:46387", "http://my-mac.local:46387"), "known Bonjour name")
        check(trusted("192.168.1.2:46487", "https://192.168.1.2:46487", secure: true, port: 46487), "secure origin")
        check(!trusted("evil.example:46387", "http://evil.example:46387"), "DNS rebind host")
        check(!trusted("other-mac.local:46387"), "unknown local name")
        check(!trusted("192.168.1.3:46387"), "unrelated numeric address")
        check(!trusted(nil), "Host required")
        check(!trusted("localhost"), "exact listening port required")
        check(!trusted("127.0.0.1:46387", "null"), "opaque browser origin")
        check(!trusted("127.0.0.1:46387", "http://evil.example"), "cross origin")
        check(!trusted("127.0.0.1:46387", "https://127.0.0.1:46387"), "wrong scheme")
        check(!trusted("127.0.0.1:46387", "http://127.0.0.1:46388"), "wrong origin port")
        check(!trusted("127.0.0.1:46387", "http://127.0.0.1:46387.evil.example"), "origin suffix spoof")
        check(!trusted("127.0.0.1:46387@evil.example"), "authority userinfo spoof")
        check(!trusted("localhost:46387", "http://localhost:46387/path"), "origin must not contain path")
        for site in ["cross-site", "same-site"] {
            check(!HTTPRequestSecurity.trusted(host: "localhost:46387", origin: nil, port: 46387,
                secure: false, localAddress: nil, stableHost: nil, fetchSite: site), "cross-origin image blocked without Origin: \(site)")
        }
        for site in ["none", "same-origin"] {
            check(HTTPRequestSecurity.trusted(host: "localhost:46387", origin: nil, port: 46387,
                secure: false, localAddress: nil, stableHost: nil, fetchSite: site), "trusted browser fetch: \(site)")
        }
        check(exempt(), "same-origin JSON local write")
        check(exempt("GET", nil, nil), "local QR image read does not require Origin")
        check(!exempt("POST", nil), "native missing-origin write needs bearer")
        check(!exempt("POST", "http://evil.example"), "simple CSRF cannot bypass auth")
        check(!exempt("POST", "http://127.0.0.1:46387", "text/plain"), "form/plain writes cannot bypass auth")
        check(!exempt("POST", "http://127.0.0.1:46387", "application/x-www-form-urlencoded"), "form encoded writes rejected")
        check(!exempt(loopback: false), "LAN never local-exempt")
        check(exempt("POST", "http://127.0.0.1:46387", "application/json; charset=utf-8"), "JSON charset retained")
        for value in ["chrome", "app-123_abc", "com.example.App", "飞书"] {
            check(HTTPRequestSecurity.safeIconID(value), "ordinary icon ID: \(value)")
        }
        for value in ["", ".", "..", "../private-photo", "foo/../../photo", "/absolute", "foo\\bar", "foo%2Fbar", "x\0y"] {
            check(!HTTPRequestSecurity.safeIconID(value), "unsafe icon ID rejected")
        }
        func length(_ fields: String) -> Int? { HTTPRequestSecurity.bodyLength(in: "POST /fixture HTTP/1.1\r\nHost: localhost:46387\r\n" + fields) }
        check(length("Content-Length: 0") == 0, "zero body")
        check(length("Content-Length: 1024") == 1024, "positive body")
        check(length("Content-Type: application/json") == 0, "absent body")
        check(length("Content-Length: -1") == nil, "negative length rejected before slicing")
        check(length("Content-Length: +1") == nil, "signed length rejected")
        check(length("Content-Length: 1x") == nil, "nondecimal length rejected")
        check(length("Content-Length: 999999999999999999999999") == nil, "integer overflow rejected")
        check(length("Content-Length:") == nil, "empty length rejected")
        check(length("Content-Length: 1\r\nContent-Length: 1") == nil, "duplicate identical length rejected")
        check(length("Content-Length: 1\r\ncontent-length: 9") == nil, "conflicting length rejected")
        check(length("Transfer-Encoding: chunked") == nil, "unsupported framing rejected")
        check(length("Origin: http://localhost:46387\r\nOrigin: http://evil.example") == nil, "duplicate origin rejected")
        check(length("Host: evil.example:46387") == nil, "duplicate host rejected")
        check(length("Authorization: Bearer fixture\r\nAuthorization: Bearer other") == nil, "duplicate authorization rejected")
        check(length(" Content-Length: 1") == nil, "folded header rejected")
        check(length("Content-Length : 1") == nil, "whitespace header-name rejected")
        print("HTTP request security: \(checks) checks passed")
    }
}
