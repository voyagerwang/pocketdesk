/**
 * [INPUT]: 依赖 Foundation 的 Data/URL 与 AppKit 的 NSWorkspace/NSImage、CoreGraphics 的 CGWindowList 与 CGSession、系统 caffeinate 命令行（唤醒显示器）、CoreImage 的二维码滤镜。
 * [OUTPUT]: 对外提供 Util（主局域网地址与 Tailscale 私网地址探测、稳定 .local 主机名、QR PNG 生成、应用图标 PNG 提取、前台应用探测、锁屏状态判定 isScreenLocked 与显示器唤醒 wakeDisplay）。前台探测以用户视角为准：CGWindowList 当前桌面最前的 layer 0 窗口，pid 经 NSWorkspace 运行列表换成带完整 bundle 信息的应用对象。
 * [POS]: Sources 的无状态工具层；Server 的 /api/status、/api/qr、图标端点调用它渲染地址与图像，InputExecutor 的窗口动作调用它定位前台应用。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum Util {
    // 前台应用：CGWindowList 直接问窗口服务器，列表按从前到后排序，
    // layer 0 的第一个有归属者的窗口即用户眼前最前的那个应用。
    // 不用 NSWorkspace.frontmostApplication——长期无窗口的常驻进程里它的缓存会冻结
    // （实测永远返回某个旧应用）。
    //
    // 也不要改用 AX 的 kAXFocusedApplicationAttribute（试过，已回退）：AX 问的是"键盘焦点归谁"，
    // 与"用户眼前是哪个应用"不是一回事。目标应用的窗口在另一块显示器或另一个桌面空间时，
    // 它可以被激活成 active app（lsappinfo 会答它），键盘焦点却还留在原来那个应用上——
    // 于是 AX 答错、CGWindowList 答对。用户报的"唤醒没反应"正是这种：应用确实起来了，
    // 只是没出现在他正看着的那块屏幕上。判定要与用户视角一致，故维持 CGWindowList。
    static func frontmostApp() -> NSRunningApplication? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let windowLayer = kCGWindowLayer as String
        let windowOwnerPID = kCGWindowOwnerPID as String
        guard let entry = list.first(where: { ($0[windowLayer] as? Int) == 0 && $0[windowOwnerPID] != nil }),
              let pid = entry[windowOwnerPID] as? Int32 else { return nil }
        return Self.app(processIdentifier: pid)
    }

    /// pid → 应用对象。优先从 NSWorkspace 的运行列表里取同一个 pid：列表里的对象带完整 bundle 信息，
    /// 而 NSRunningApplication(processIdentifier:) 现造的对象 bundleIdentifier/bundleURL 常常是 nil，
    /// 一 nil 就匹配不上任何 Dock 目标（前台是谁认不出来，激活校验也跟着全误判为失败）。
    private static func app(processIdentifier pid: pid_t) -> NSRunningApplication? {
        if let hit = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }) { return hit }
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

    /* ---------- 锁屏状态与唤醒 ----------
       macOS 出于安全不允许第三方 App 获取锁屏会话的画面（否则任何 App 都能偷看密码框），
       ScreenCaptureKit 在锁屏时要么失败、要么只给黑帧。这条限制绕不过去，
       所以必须能区分两种"看不到画面"：
         · 真锁屏 —— 只能让人去电脑前输密码，任何代码都帮不上；
         · 只是显示器睡了 / 屏保 —— 可以唤醒，画面立刻回来。
       区分开才能给出正确引导，而不是一律显示"暂时无法获取画面"让人瞎猜。 */

    // CGSessionCopyCurrentDictionary 返回的字典只在会话被锁时才带 CGSSessionScreenIsLocked=1，
    // 未锁屏时压根没有这个键——所以"键存在且为真"才算锁屏，取不到字典一律按未锁处理。
    static func isScreenLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return dict["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // 唤醒显示器：等价于一次真实用户活动（和动一下鼠标同效）。
    // **不会绕过锁屏**——真锁屏时它只会把锁屏界面点亮，依然拿不到画面。
    //
    // 走 `caffeinate -u` 而不是 IOPMAssertionDeclareUserActivity：后者的符号
    // （IOPMAssertionID / kIOPMUserActiveLocal）在 Swift 里没有随 IOKit 导出，
    // 且 `import IOKit.power` 这个子模块根本不存在；caffeinate 是系统自带的同一套机制的命令行入口。
    // -t 1 让它 1 秒后自行退出，不常驻；放后台队列执行，不阻塞 HTTP 响应。
    static func wakeDisplay() {
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            task.arguments = ["-u", "-t", "1"]
            do { try task.run(); task.waitUntilExit(); } catch { /* 唤醒失败不影响取帧，静默 */ }
        }
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
