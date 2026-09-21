/**
 * [INPUT]: Foundation/CryptoKit；仅编译 Sources/PhoneFileStore.swift（Auth/TargetStore 用测试替身注入）。
 * [OUTPUT]: 验证快照哈希一致、空文件、Unicode 名称、单文件/批次/总量/数量限额、目录与 FIFO 拒绝、
 *           同任务重试与并发批次幂等、接受/拒绝/过期/票据失效、跨主体隔离、快照与源文件解耦、
 *           ZIP 解压内容哈希一致且同名不覆盖。
 * [POS]: tests 的文件暂存隔离回归；全部在临时目录进行，不读写真实用户文件，不启动真实下载。
 *        运行：swiftc -parse-as-library Sources/PhoneFileStore.swift tests/phone-file-store.test.swift -o /tmp/pf-store-test && /tmp/pf-store-test
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CryptoKit
import Foundation

// 生产 PhoneFileStore 引用安装级鉴权与支持目录；测试以最小替身隔离，不触碰真实数据。
enum Auth { static let token = "unit-test-token" }
enum TargetStore { static let supportDirectory = URL(fileURLWithPath: "/tmp/pd-phone-file-store-test-support") }

@main struct PhoneFileStoreTests {
    static var failures = 0
    static func check(_ condition: Bool, _ label: String) {
        if condition { print("  ok - \(label)") } else { failures += 1; print("  FAIL - \(label)") }
    }

    /// 可推进的时钟：过期与票据测试不依赖真实等待。
    final class Clock {
        var current = Date()
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
        var time: Date { current }
    }

    static func tempRoot(_ label: String) -> URL {
        URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("pd-pf-\(label)-\(UUID().uuidString)", isDirectory: true)
    }
    static func write(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
    static func sha(_ url: URL) -> String {
        SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    static func downloadPayload(_ store: PhoneFileStore, _ offer: PhoneFileStore.Offer, subject: String, into url: URL) -> Bool {
        guard let ticket = try? store.accept(id: offer.id, subject: subject),
              let (_, handle) = try? store.download(ticket: ticket, subject: subject) else { return false }
        let data = handle.readDataToEndOfFile()
        try? handle.close()
        try? data.write(to: url, options: .atomic)
        return true
    }

    static func main() {
        print("phone file store: 单文件快照")
        let clock = Clock()
        let root = tempRoot("single")
        let store = PhoneFileStore(directory: root, now: { clock.time })
        let sourceURL = root.appendingPathComponent("源 文件.txt")
        let payload = Data("你好，PocketDesk 文件正文。\n".utf8)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! write(payload, at: sourceURL)
        let subject = "subject-a"

        do {
            let offer = try store.prepare(path: sourceURL.path, subject: subject, taskId: "task-1")
            check(offer.name == "源 文件.txt", "Unicode 文件名保留")
            check(offer.size == Int64(payload.count), "记录大小与源一致")
            check(offer.accepted == false, "初始为待接收")
            check(offer.json["fileNames"] != nil, "对外暴露文件清单")
            let out = tempRoot("single-out").appendingPathComponent("out.bin")
            try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            check(downloadPayload(store, offer, subject: subject, into: out), "接受后可下载")
            check(sha(out) == sha(sourceURL), "下载内容 SHA-256 与源一致")

            // 快照解耦：源文件被改/删都不影响已发布内容。
            try! write(Data("changed".utf8), at: sourceURL)
            let out2 = out.deletingLastPathComponent().appendingPathComponent("out2.bin")
            check(downloadPayload(store, offer, subject: subject, into: out2), "源变化后仍可下载快照")
            check(sha(out2) == sha(out), "快照内容不随后续源变化")

            // 同任务重试幂等；不同任务可再次发送。
            let retry = try store.prepare(path: sourceURL.path, subject: subject, taskId: "task-1")
            check(retry.id == offer.id, "同任务同文件重试返回同一收件项")
            let fresh = try store.prepare(path: sourceURL.path, subject: subject, taskId: "task-2")
            check(fresh.id != offer.id, "不同任务生成独立收件项")
            check(store.list(subject: subject).count == 2, "两个任务各自可见")
        } catch { failures += 1; print("  FAIL - 单文件准备异常：\(error.localizedDescription)") }

        print("phone file store: 空文件与类型边界")
        do {
            let empty = root.appendingPathComponent("empty.log")
            try! Data().write(to: empty)
            let offer = try store.prepare(path: empty.path, subject: subject, taskId: "task-empty")
            check(offer.size == 0, "空文件记录大小 0")
            let out = tempRoot("empty-out").appendingPathComponent("e.bin")
            try! FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            check(downloadPayload(store, offer, subject: subject, into: out) && sha(out) == sha(empty), "空文件下载哈希一致")

            let folder = root.appendingPathComponent("文件夹", isDirectory: true)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            check((try? store.prepare(path: folder.path, subject: subject, taskId: "task-dir")) == nil, "目录被拒绝")
            let fifo = root.appendingPathComponent("pipe")
            mkfifo(fifo.path, 0o600)
            check((try? store.prepare(path: fifo.path, subject: subject, taskId: "task-fifo")) == nil, "FIFO 被拒绝")
            check(store.list(subject: subject).count == 3, "被拒绝项不留半批记录")
        } catch { failures += 1; print("  FAIL - 类型边界异常：\(error.localizedDescription)") }

        print("phone file store: 限额与失败不发布")
        do {
            let tiny = PhoneFileStore(directory: tempRoot("tiny"), maximumBytes: 8, totalQuota: 20,
                                      offerLimit: 2, now: { clock.time })
            let tinyRoot = tempRoot("tiny-root")
            try! FileManager.default.createDirectory(at: tinyRoot, withIntermediateDirectories: true)
            let a = tinyRoot.appendingPathComponent("a.bin")
            let b = tinyRoot.appendingPathComponent("b.bin")
            let big = tinyRoot.appendingPathComponent("big.bin")
            try! Data(repeating: 1, count: 6).write(to: a)
            try! Data(repeating: 2, count: 6).write(to: b)
            try! Data(repeating: 3, count: 64).write(to: big)
            check((try? tiny.prepare(path: big.path, subject: subject, taskId: "t")) == nil, "单文件超限拒绝")
            _ = try tiny.prepare(path: a.path, subject: subject, taskId: "q1")
            _ = try tiny.prepare(path: b.path, subject: subject, taskId: "q2")
            check(tiny.list(subject: subject).count == 2, "数量配额内可发布")
            check((try? tiny.prepare(path: big.path, subject: subject, taskId: "q3")) == nil, "数量配额超限拒绝（同一文件此前单文件超限也不误留）")
            // 总量配额：已存 12 字节，再放 9 字节超 20。
            let c = tinyRoot.appendingPathComponent("c.bin")
            try! Data(repeating: 4, count: 9).write(to: c)
            check((try? tiny.prepare(path: c.path, subject: subject, taskId: "q4")) == nil, "总量配额超限拒绝")
            check(tiny.list(subject: subject).reduce(0) { $0 + $1.size } == 12, "超限项未发布、暂存不膨胀")
        } catch { failures += 1; print("  FAIL - 限额异常：\(error.localizedDescription)") }

        print("phone file store: 过期、拒绝与票据")
        do {
            let ticketRoot = tempRoot("ticket")
            let store = PhoneFileStore(directory: ticketRoot, ticketLifetime: 300, now: { clock.time })
            let file = tempRoot("ticket-root").appendingPathComponent("t.bin")
            try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data([9, 9, 9]).write(to: file)
            let offer = try store.prepare(path: file.path, subject: subject, taskId: "tk")

            check((try? store.download(ticket: "伪造票据", subject: subject)) == nil, "伪造票据拒绝")
            check((try? store.download(ticket: "伪造票据", subject: "subject-b")) == nil, "跨主体拒绝")
            check(store.list(subject: "subject-b").isEmpty, "其他主体列表为空")
            check((try? store.accept(id: offer.id, subject: "subject-b")) == nil, "其他主体确认拒绝")

            let ticket1 = try store.accept(id: offer.id, subject: subject)
            let ticket2 = try store.accept(id: offer.id, subject: subject)
            check(ticket1 != ticket2, "重复确认换新票据")
            check((try? store.download(ticket: ticket1, subject: subject)) == nil, "旧票据作废")
            check((try? store.download(ticket: ticket2, subject: subject)) != nil, "新票据可下载")

            clock.advance(299)
            check((try? store.download(ticket: ticket2, subject: subject)) != nil, "票据有效期内可下载")
            clock.advance(2)
            check((try? store.download(ticket: ticket2, subject: subject)) == nil, "票据过期拒绝")
            let ticket3 = try store.accept(id: offer.id, subject: subject)
            check((try? store.download(ticket: ticket3, subject: subject)) != nil, "过期票据可重新确认领取")

            try store.dismiss(id: offer.id, subject: subject)
            check((try? store.download(ticket: ticket3, subject: subject)) == nil, "拒绝后票据失效")
            check((try? store.accept(id: offer.id, subject: subject)) == nil, "拒绝后不能再确认")
            check(store.list(subject: subject).isEmpty, "拒绝后列表为空")

            clock.advance(0)
            let expires = try store.prepare(path: file.path, subject: subject, taskId: "tk-exp")
            clock.advance(24 * 60 * 60 + 5)
            check(store.list(subject: subject).isEmpty, "保留期到自动清理")
            check((try? store.accept(id: expires.id, subject: subject)) == nil, "过期项确认拒绝")

            // 重启语义：收件元数据与载荷都在磁盘上，新实例（进程重启）应能找回待收项并重新签发票据。
            let rebootedOffer = try store.prepare(path: file.path, subject: subject, taskId: "tk-reboot")
            let rebooted = PhoneFileStore(directory: ticketRoot, now: { clock.time })
            let survivors = rebooted.list(subject: subject)
            check(survivors.count == 1 && survivors[0].id == rebootedOffer.id, "重启后待收项仍在")
            check((try? rebooted.accept(id: rebootedOffer.id, subject: subject)) != nil, "重启后可重新确认领取票据")
        } catch { failures += 1; print("  FAIL - 票据异常：\(error.localizedDescription)") }

        print("phone file store: 崩溃残留清理")
        do {
            let residueRoot = tempRoot("residue")
            try! FileManager.default.createDirectory(at: residueRoot, withIntermediateDirectories: true)
            let stale = residueRoot.appendingPathComponent("tmp-stale.data")
            try! Data([1, 2, 3]).write(to: stale)
            let oldDate = Date().addingTimeInterval(-7200)
            try! FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: stale.path)
            let fresh = residueRoot.appendingPathComponent("tmp-fresh.data")
            try! Data([4]).write(to: fresh)
            let sweeper = PhoneFileStore(directory: residueRoot)
            check(!FileManager.default.fileExists(atPath: stale.path), "超过 1 小时的崩溃残留半成品被清扫")
            check(FileManager.default.fileExists(atPath: fresh.path), "进行中的复制半成品不受影响")
            _ = sweeper
        } catch { failures += 1; print("  FAIL - 残留清理异常：\(error.localizedDescription)") }

        print("phone file store: 文件系统失败")
        do {
            let failedRoot = tempRoot("write-failure")
            try FileManager.default.createDirectory(at: failedRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: failedRoot) }
            let blocked = failedRoot.appendingPathComponent("not-a-directory")
            try Data([7]).write(to: blocked)
            let failedStore = PhoneFileStore(directory: blocked, maintenance: false)
            let originalHash = sha(sourceURL)
            check((try? failedStore.prepare(path: sourceURL.path, subject: subject, taskId: "write-failed")) == nil,
                  "快照目录不可写时明确失败")
            check(failedStore.list(subject: subject).isEmpty && sha(sourceURL) == originalHash,
                  "写失败不发布且不修改源文件")
            let deleted = failedRoot.appendingPathComponent("deleted.txt")
            try Data([1]).write(to: deleted)
            try FileManager.default.removeItem(at: deleted)
            check((try? store.prepare(path: deleted.path, subject: subject, taskId: "deleted")) == nil,
                  "准备前源文件删除时失败")
        } catch { failures += 1; print("  FAIL - 文件系统失败测试：\(error)") }

        print("phone file store: 批次 ZIP")
        do {
            let batchStore = PhoneFileStore(directory: tempRoot("batch"), now: { clock.time })
            let dir = tempRoot("batch-root")
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let first = dir.appendingPathComponent("合同.pdf")
            let second = dir.appendingPathComponent("报价表.pdf")
            let same = dir.appendingPathComponent("合同.pdf.bak")
            try! Data("合同正文".utf8).write(to: first)
            try! Data("报价表正文".utf8).write(to: second)
            try! Data("同名备件".utf8).write(to: same)
            try! FileManager.default.createDirectory(at: dir.appendingPathComponent("子目录", isDirectory: true), withIntermediateDirectories: true)

            check((try? batchStore.prepare(paths: [], subject: subject, taskId: "b0")) == nil, "空批次拒绝")
            check((try? batchStore.prepare(paths: [dir.appendingPathComponent("子目录").path], subject: subject, taskId: "b1")) == nil, "目录成员整批拒绝")
            check(batchStore.list(subject: subject).isEmpty, "失败批次不留收件项")
            let many = (0..<21).map { dir.appendingPathComponent("f\($0).txt").path }
            check((try? batchStore.prepare(paths: many, subject: subject, taskId: "b2")) == nil, "超过 20 个拒绝")
            check(batchStore.list(subject: subject).isEmpty, "被拒绝批次不留收件项")

            let offer = try batchStore.prepare(paths: [first.path, second.path, same.path, first.path], subject: subject, taskId: "b3")
            check(offer.fileNames?.count == 3, "重复路径去重后打包")
            check(offer.fileNames?.contains("合同.pdf") == true, "清单含原始名")
            check(offer.fileNames?.filter { $0.hasSuffix(".bak") || $0.hasSuffix(".pdf") }.count == 3, "清单成员齐全")
            check(offer.name.contains(".zip"), "多文件以 ZIP 收件")

            let zip = tempRoot("batch-out").appendingPathComponent("out.zip")
            try! FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
            check(downloadPayload(batchStore, offer, subject: subject, into: zip), "批次接受后可下载")
            let extract = tempRoot("batch-extract")
            try! FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, extract.path]
            try! unzip.run(); unzip.waitUntilExit()
            check(unzip.terminationStatus == 0, "ZIP 可解压")
            check(sha(extract.appendingPathComponent("合同.pdf")) == sha(first), "成员 1 哈希一致")
            check(sha(extract.appendingPathComponent("报价表.pdf")) == sha(second), "成员 2 哈希一致")
            check(sha(extract.appendingPathComponent("合同.pdf.bak")) == sha(same), "同名前缀成员哈希一致（不互相覆盖）")

            let retry = try batchStore.prepare(paths: [first.path, second.path, same.path], subject: subject, taskId: "b3")
            check(retry.id == offer.id, "同批次重试幂等")

            // 20 个文件 = 批次上限内整批 ZIP。
            let many20 = (0..<20).map { dir.appendingPathComponent("m\($0).txt") }
            for item in many20 { try! Data(String("m-" + item.lastPathComponent).utf8).write(to: item) }
            let zip20 = try batchStore.prepare(paths: many20.map(\.path), subject: subject, taskId: "b20")
            check(zip20.fileNames?.count == 20, "20 个文件上限内整批打包")
            let zip20Path = tempRoot("batch-out").appendingPathComponent("out20.zip")
            try! FileManager.default.createDirectory(at: zip20Path.deletingLastPathComponent(), withIntermediateDirectories: true)
            check(downloadPayload(batchStore, zip20, subject: subject, into: zip20Path), "20 文件 ZIP 接受后可下载")
        } catch { failures += 1; print("  FAIL - 批次异常：\(error.localizedDescription)") }

        print("phone file store: 发布边界授权与跨主体幂等")
        do {
            let revokeDir = tempRoot("revoke")
            let revokeStore = PhoneFileStore(directory: revokeDir, now: { clock.time })
            let revokeRoot = tempRoot("revoke-root")
            try! FileManager.default.createDirectory(at: revokeRoot, withIntermediateDirectories: true)
            let single = revokeRoot.appendingPathComponent("s.txt")
            let other = revokeRoot.appendingPathComponent("o.txt")
            try! Data("s".utf8).write(to: single)
            try! Data("o".utf8).write(to: other)
            // 单文件：复制完成后、发布前失权 → 拒绝且暂存目录不留任何文件。
            check((try? revokeStore.prepare(path: single.path, subject: "A", taskId: "t",
                                            authorized: { false })) == nil, "发布边界失权拒绝单文件")
            check(revokeStore.list(subject: "A").isEmpty, "失权准备不进入手机列表")
            check((try? FileManager.default.contentsOfDirectory(atPath: revokeDir.path))?.isEmpty == true,
                  "失权半成品已清理，暂存目录为空")
            // 批次：成员全部复制并打包后失权 → 整批不发布。
            check((try? revokeStore.prepare(paths: [single.path, other.path], subject: "A", taskId: "t2",
                                            authorized: { false })) == nil, "发布边界失权拒绝整批")
            check(revokeStore.list(subject: "A").isEmpty, "失权批次不进入手机列表")
            // 失权后同一文件在授权恢复后可重新发布。
            let republished = try revokeStore.prepare(path: single.path, subject: "A", taskId: "t", authorized: { true })
            check(republished.name == "s.txt", "授权恢复后重新发布成功")

            // 跨主体：同 taskId 同路径，两个主体必须各得独立收件项（首轮复核 P2）。
            let crossA = try revokeStore.prepare(paths: [single.path, other.path], subject: "A", taskId: "shared")
            let crossB = try revokeStore.prepare(paths: [single.path, other.path], subject: "B", taskId: "shared")
            check(crossA.subject == "A" && crossB.subject == "B", "跨主体同批次返回各自主体的收件项")
            check(crossA.id != crossB.id, "跨主体同批次不共享 id")
            check(revokeStore.list(subject: "B").count == 1, "主体 B 列表可见自己的批次")
            check(revokeStore.list(subject: "A").count == 2, "主体 A 列表不受 B 影响（重发的单文件 + 自己的批次）")
        } catch { failures += 1; print("  FAIL - 授权/跨主体异常：\(error.localizedDescription)") }

        print("phone file store: 并发同批次幂等")
        let concurrentStore = PhoneFileStore(directory: tempRoot("concurrent"), now: { clock.time })
        let dir = tempRoot("concurrent-root")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f1 = dir.appendingPathComponent("one.txt"), f2 = dir.appendingPathComponent("two.txt")
        try! Data("one".utf8).write(to: f1)
        try! Data("two".utf8).write(to: f2)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test", attributes: .concurrent)
        var ids: [String] = []
        let lock = NSLock()
        for _ in 0..<4 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do {
                    let offer = try concurrentStore.prepare(paths: [f1.path, f2.path], subject: "subject-a", taskId: "same-task")
                    lock.lock(); ids.append(offer.id); lock.unlock()
                } catch { lock.lock(); ids.append("error:" + error.localizedDescription); lock.unlock() }
            }
        }
        group.wait()
        check(ids.allSatisfy { $0 == ids.first && !$0.hasPrefix("error") }, "四个并发同批次收敛为一个收件项（实际 \(Set(ids).count) 个）")
        check(concurrentStore.list(subject: "subject-a").count == 1, "暂存中只有一个批次")

        print(failures == 0 ? "phone file store: 全部通过" : "phone file store: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
