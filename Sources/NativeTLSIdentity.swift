/**
 * [INPUT]: 依赖本机 openssl、SecureTransport 私有目录和 Foundation 文件原子操作。
 * [OUTPUT]: 首次运行自动生成只供 App 固定指纹的 TLS 身份；已有身份保持不动，不安装系统 CA。
 * [POS]: 原生直连启动准备；证书只用于通道加密，信任由用户在电脑前扫码建立。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum NativeTLSIdentity {
    static func prepareIfMissing() throws {
        let fm = FileManager.default, directory = SecureTransport.directory
        let cert = directory.appendingPathComponent("server-cert.der")
        let key = directory.appendingPathComponent("server-key.der")
        if fm.fileExists(atPath: cert.path) && fm.fileExists(atPath: key.path) { return }
        // 残缺的旧身份不能静默轮换；保留其材料，让安装修复流程处理。
        guard !fm.fileExists(atPath: directory.path) else { return }
        let stage = directory.deletingLastPathComponent().appendingPathComponent("native-tls-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        func run(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.currentDirectoryURL = stage
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-subj", "/CN=PocketDesk Local App",
                 "-keyout", "key.pem", "-out", "cert.pem"])
        try run(["rsa", "-in", "key.pem", "-outform", "DER", "-out", "server-key.der"])
        try run(["x509", "-in", "cert.pem", "-outform", "DER", "-out", "server-cert.der"])
        try fm.removeItem(at: stage.appendingPathComponent("key.pem"))
        try fm.removeItem(at: stage.appendingPathComponent("cert.pem"))
        for name in ["server-key.der", "server-cert.der"] {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage.appendingPathComponent(name).path)
        }
        try fm.moveItem(at: stage, to: directory)
    }
}
