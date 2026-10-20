/**
 * [INPUT]: Auth 的可注入私有目录与真实 Darwin 文件权限/链接语义，TargetStore 指向隔离临时目录。
 * [OUTPUT]: 验证旧 token 原样保留及权限收紧、首次原子创建、异常路径拒绝、并发一致与空鉴权关闭。
 * [POS]: tests 的配对凭证存储安全回归；不读取正式凭证、不启动服务、不生成实际手机配对。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin

enum TargetStore {
    static let supportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pocketdesk-auth-security-" + UUID().uuidString)
}

@main struct AuthSecurityTests {
    static var checks = 0
    static let fm = FileManager.default
    static let sample = String(repeating: "A", count: 43)

    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: " + label) }
    }
    static func mode(_ path: URL) -> Int {
        var info = stat()
        guard lstat(path.path, &info) == 0 else { return -1 }
        return Int(info.st_mode & 0o777)
    }
    static func directory(_ name: String) throws -> URL {
        let result = TargetStore.supportDirectory.appendingPathComponent(name)
        try fm.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    static func put(_ text: String, _ file: URL) throws {
        try Data(text.utf8).write(to: file)
    }
    static func main() throws {
        defer { try? fm.removeItem(at: TargetStore.supportDirectory) }
        let old = try directory("old"), oldFile = old.appendingPathComponent("token")
        let original = Data(("  " + sample + "\n").utf8)
        try original.write(to: oldFile)
        chmod(old.path, 0o755); chmod(oldFile.path, 0o644)
        expect(Auth.loadToken(directory: old) == sample, "原 token 不轮换")
        expect(try! Data(contentsOf: oldFile) == original, "旧文件字节原样保留")
        expect(mode(old) == 0o700, "原目录收紧为 0700")
        expect(mode(oldFile) == 0o600, "原 token 收紧为 0600")

        let fresh = TargetStore.supportDirectory.appendingPathComponent("fresh")
        let value = Auth.loadToken(directory: fresh)
        expect(value.count == 43 && value != sample, "生成 32 字节随机 token")
        expect(Auth.loadToken(directory: fresh) == value, "重载稳定")
        expect(mode(fresh) == 0o700 && mode(fresh.appendingPathComponent("token")) == 0o600, "首次创建即私有权限")
        expect((try! fm.contentsOfDirectory(atPath: fresh.path)) == ["token"], "不遗留临时凭证")

        let linked = try directory("linked"), external = TargetStore.supportDirectory.appendingPathComponent("outside")
        try put(sample, external); chmod(external.path, 0o644)
        try fm.createSymbolicLink(at: linked.appendingPathComponent("token"), withDestinationURL: external)
        expect(Auth.loadToken(directory: linked).isEmpty, "拒绝 token 符号链接")
        expect(mode(external) == 0o644 && (try! String(contentsOf: external, encoding: .utf8)) == sample, "链接目标未修改")

        let parentLink = TargetStore.supportDirectory.appendingPathComponent("parent-link")
        try fm.createSymbolicLink(at: parentLink, withDestinationURL: old)
        expect(Auth.loadToken(directory: parentLink).isEmpty, "拒绝凭证目录符号链接")

        let hard = try directory("hard"), hardFile = hard.appendingPathComponent("token")
        expect(link(external.path, hardFile.path) == 0, "创建硬链替身")
        expect(Auth.loadToken(directory: hard).isEmpty, "拒绝多链接凭证")
        expect(mode(external) == 0o644, "硬链目标未改权限")

        let fifo = try directory("fifo"), fifoFile = fifo.appendingPathComponent("token")
        expect(mkfifo(fifoFile.path, 0o600) == 0, "创建 FIFO 替身")
        let started = Date()
        expect(Auth.loadToken(directory: fifo).isEmpty, "拒绝 FIFO")
        expect(Date().timeIntervalSince(started) < 1, "FIFO 不阻塞")

        for (label, contents) in [("empty", ""), ("malformed", "unexpected credential"), ("large", String(repeating: "A", count: 4097))] {
            let dir = try directory(label), file = dir.appendingPathComponent("token")
            try put(contents, file)
            expect(Auth.loadToken(directory: dir).isEmpty, "拒绝异常内容 " + label)
            expect((try! String(contentsOf: file, encoding: .utf8)) == contents, "不覆盖异常文件 " + label)
        }
        let nonDirectory = TargetStore.supportDirectory.appendingPathComponent("non-directory")
        try put(sample, nonDirectory)
        expect(Auth.loadToken(directory: nonDirectory).isEmpty, "存储准备失败保守拒绝")

        let parallel = TargetStore.supportDirectory.appendingPathComponent("parallel")
        let lock = NSLock()
        var values = [String]()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let loaded = Auth.loadToken(directory: parallel)
            lock.lock(); values.append(loaded); lock.unlock()
        }
        expect(Set(values).count == 1 && values.first?.count == 43, "并发首次读取一致")

        // 单例目录故意放异常文件，验证鉴权失败不会接受空凭证。
        try put("", TargetStore.supportDirectory.appendingPathComponent("token"))
        expect(Auth.token.isEmpty, "单例在存储异常时关闭")
        expect(!Auth.verify(token: ""), "WebSocket 拒绝空 token")
        expect(!Auth.verify(authorizationHeader: "Bearer "), "HTTP 拒绝空 Bearer")
        expect(!Auth.verify(token: sample), "失败状态不接受任意 token")
        print("Auth security: \(checks) checks passed")
    }
}
