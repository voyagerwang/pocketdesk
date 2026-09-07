/**
 * [INPUT]: 依赖 Foundation 的 Data/URL 与 AppKit 的 NSWorkspace/NSImage、CoreGraphics 的 CGWindowList、CoreImage 的二维码滤镜。
 * [OUTPUT]: 对外提供 Util（主局域网地址与 Tailscale 私网地址探测、稳定 .local 主机名、QR PNG 生成、应用图标 PNG 提取、前台应用探测）。
 * [POS]: Sources 的无状态工具层；Server 的 /api/status、/api/qr、图标端点调用它渲染地址与图像，InputExecutor 的窗口动作调用它定位前台应用。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum Util {
    // 前台应用：不用 NSWorkspace.frontmostApplication——长期无窗口的常驻进程里它的缓存会冻结
    // （实测永远返回某个旧应用）。CGWindowList 直接问窗口服务器：列表按从前到后排序，
    // layer 0 的第一个有归属者的窗口即前台应用的主窗口。
    static func frontmostApp() -> NSRunningApplication? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let windowLayer = kCGWindowLayer as String
        let windowOwnerPID = kCGWindowOwnerPID as String
        guard let entry = list.first(where: { ($0[windowLayer] as? Int) == 0 && $0[windowOwnerPID] != nil }),
              let pid = entry[windowOwnerPID] as? Int32 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    private static func ipv4Interfaces() -> [(name: String, ip: String)] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var addresses: [(name: String, ip: String)] = []
        var pointer = ifaddr
        while let current = pointer {
            let interface = current.pointee
            if let sa = interface.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET),
               interface.ifa_flags & UInt32(IFF_UP) != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                if result == 0 {
                    addresses.append((String(cString: interface.ifa_name), String(cString: host)))
                }
            }
            pointer = interface.ifa_next
        }
        return addresses
    }

    static func primaryLANAddress() -> String? {
        let candidates = ipv4Interfaces().filter { !$0.ip.hasPrefix("127.") && !isTailscaleAddress($0.ip) }
        let rank = { (name: String) -> Int in
            name.hasPrefix("en") ? Int(name.dropFirst(2)) ?? 50 : 60
        }
        return candidates.sorted { rank($0.name) < rank($1.name) }.first?.ip
    }

    // Tailscale 为设备分配 100.64.0.0/10 地址；macOS 通过 utun 虚拟网卡承载该地址。
    // 同时检查地址段与网卡类型，避免把运营商 CGNAT 地址误当成可供手机直连的私网入口。
    static func tailscaleAddress() -> String? {
        ipv4Interfaces().first {
            ($0.name.hasPrefix("utun") || $0.name.hasPrefix("tailscale")) && isTailscaleAddress($0.ip)
        }?.ip
    }

    static func tailscaleURL(_ port: UInt16) -> String? {
        tailscaleAddress().map { "http://\($0):\(port)" }
    }

    private static func isTailscaleAddress(_ ip: String) -> Bool {
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    // 稳定主机名：mDNS 的 <计算机名>.local 不随 DHCP 变化，手机保存一次即可长期使用。
    static func stableHost() -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return nil }
        let raw = String(cString: buf).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw != "localhost", !raw.hasSuffix(".") else { return nil }
        return raw.hasSuffix(".local") ? String(raw.dropLast(".local".count)) + ".local" : raw + ".local"
    }

    static func stableURL(_ port: UInt16) -> String? {
        stableHost().map { "http://\($0):\(port)" }
    }

    static func qrPNG(_ text: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let image = NSImage(size: scaled.extent.size)
        image.addRepresentation(NSCIImageRep(ciImage: scaled))
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func appIconPNG(forFile path: String, size: Int = 256) -> Data? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        // NSWorkspace 默认只给 32px 表示；显式放到目标尺寸让 AppKit 选用 icns 中的大尺寸表示，避免放大发糊。
        icon.size = NSSize(width: size, height: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
