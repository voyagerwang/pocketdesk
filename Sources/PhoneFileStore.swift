/**
 * [INPUT]: Foundation 文件系统、CryptoKit 主体摘要；调用方提供已配对主体、任务身份与明确选择的文件路径。
 * [OUTPUT]: 持久化文件快照（1–20 文件、单文件/批次 512MiB、暂存 1GiB、32 项、24 小时过期）、同任务重试与并发批次幂等、
 *           短时（10 分钟）下载票据；复制在锁外进行，发布前重查配额；崩溃残留临时文件由维护清扫回收。
 * [POS]: 电脑到手机的文件资源边界；模型只能准备文件，手机确认后 HTTP 层才能凭票据打开快照；
 *        不读文件正文、不执行用户字符串、快照与源文件解耦（准备后源文件变化不影响已发布内容）。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CryptoKit
import Darwin
import Foundation

final class PhoneFileStore {
    static let shared = PhoneFileStore(directory: TargetStore.supportDirectory.appendingPathComponent("phone-files"))
    /// 收件主体：安装级配对 token 的摘要。首版收件箱属于该配对主体，不宣称多手机严格隔离。
    static var subject: String { SHA256.hash(data: Data(Auth.token.utf8)).map { String(format: "%02x", $0) }.joined() }

    struct Offer: Codable {
        let id: String
        let subject: String
        let taskId: String
        /// 幂等身份：单文件是快照路径，批次是成员路径清单；不用于下载寻址。
        let source: String
        let name: String
        let size: Int64
        let expiresAt: Double
        var accepted: Bool = false
        var fileNames: [String]? = nil
        var json: [String: Any] {
            ["id": id, "name": name, "size": size, "expiresAt": expiresAt, "accepted": accepted, "fileNames": fileNames ?? [name]]
        }
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private struct Ticket { let id: String; let subject: String; let expires: Date }

    private let directory: URL
    private let lock = NSLock()
    private var tickets: [String: Ticket] = [:]
    /// 并发同批次准备的去重登记：key → 完成信号量；等待方在信号后重新按幂等身份查重。
    private var batchInFlight: [String: DispatchSemaphore] = [:]
    /// 可注入的当前时间（测试过期/票据）；生产始终是真实时钟。
    private let now: () -> Date
    private let lifetime: TimeInterval
    private let maximumBytes: Int64
    private let totalQuota: Int64
    private let offerLimit: Int
    private let batchLimit: Int
    private let ticketLifetime: TimeInterval
    private var sweeper: DispatchSourceTimer?

    /// maintenance=false 供批量暂存与测试使用：不启动清扫、不回收进程临时目录，
    /// 否则并发批次会互相删除对方正在写入的临时目录。
    init(directory: URL, lifetime: TimeInterval = 24 * 60 * 60,
         maximumBytes: Int64 = 512 * 1024 * 1024, totalQuota: Int64 = 1024 * 1024 * 1024,
         offerLimit: Int = 32, batchLimit: Int = 20, ticketLifetime: TimeInterval = 600,
         now: @escaping () -> Date = { Date() }, maintenance: Bool = true) {
        self.directory = directory
        self.lifetime = lifetime
        self.maximumBytes = maximumBytes
        self.totalQuota = totalQuota
        self.offerLimit = offerLimit
        self.batchLimit = batchLimit
        self.ticketLifetime = ticketLifetime
        self.now = now
        if maintenance { startMaintenance() }
    }
    deinit { sweeper?.cancel() }

    // MARK: 磁盘布局

    private func metadata(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
    private func payload(_ id: String) -> URL { directory.appendingPathComponent(id + ".data") }
    /// 复制期间的半成品快照；崩溃残留由清扫回收，绝不进入下载通路。
    private func partial(_ id: String) -> URL { directory.appendingPathComponent("tmp-" + id + ".data") }
    /// 批次临时目录（files/ + staging/ + zip）。前缀固定，清扫只回收带此前缀的目录。
    private static let batchTempPrefix = "PocketDeskFileBatch-"

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private func all() -> [Offer] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("tmp-") }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(Offer.self, from: data)
        }
    }

    private func save(_ offer: Offer) throws {
        try JSONEncoder().encode(offer).write(to: metadata(offer.id), options: .atomic)
    }

    /// 先删内容再删索引；索引删除失败时保留记录供清扫重试，票据立即失效。
    private func remove(_ offer: Offer) {
        try? FileManager.default.removeItem(at: payload(offer.id))
        try? FileManager.default.removeItem(at: metadata(offer.id))
        tickets = tickets.filter { $0.value.id != offer.id }
    }

    /// 必须持锁调用。清理过期项（不能只依赖下一次收件请求），返回存活列表。
    private func liveLocked() -> [Offer] {
        let current = now()
        tickets = tickets.filter { $0.value.expires > current }
        let offers = all()
        for offer in offers where offer.expiresAt <= current.timeIntervalSince1970 { remove(offer) }
        return offers.filter { $0.expiresAt > current.timeIntervalSince1970 }
    }

    func list(subject: String) -> [Offer] {
        lock.lock(); defer { lock.unlock() }
        return liveLocked().filter { $0.subject == subject }.sorted { $0.expiresAt > $1.expiresAt }
    }

    // MARK: 单文件准备

    /// 复制发生在锁外（大文件复制不能阻塞手机轮询/确认）；发布前在锁内重查幂等、授权、数量与配额，
    /// 任何失败都清理半成品，不产生半批收件。
    func prepare(path: String, subject: String, taskId: String, identity: String? = nil,
                 fileNames: [String]? = nil, authorized: () -> Bool = { true }) throws -> Offer {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw Failure(message: "请提供完整文件路径，或先在访达选中一个文件。") }
        let source = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL
        let sourceIdentity = identity ?? source.path
        if let existing = list(subject: subject).first(where: { $0.taskId == taskId && $0.source == sourceIdentity }) {
            return existing
        }
        // 非阻塞打开后按描述符检查真实类型；O_NOFOLLOW 拒绝目录竞态换成的链接，设备/FIFO/socket 不进入下载通路。
        let fd = Darwin.open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure(message: "无法读取文件，请确认它存在且 PocketDesk 有读取权限。") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure(message: "只能发送普通文件；文件夹请先压缩。")
        }
        let size = Int64(info.st_size)
        guard size <= maximumBytes else { throw Failure(message: "单个文件暂时最多支持 512 MB。") }
        try ensureDirectory()
        let id = UUID().uuidString
        let staging = partial(id)
        guard FileManager.default.createFile(atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure(message: "无法创建文件快照。")
        }
        do {
            let output = try FileHandle(forWritingTo: staging)
            defer { try? output.close() }
            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                copied += Int64(chunk.count)
                guard copied <= size else { throw Failure(message: "文件正在变化，请保存完成后重新发送。") }
                try output.write(contentsOf: chunk)
            }
            var after = stat()
            guard fstat(fd, &after) == 0, copied == size,
                  after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                throw Failure(message: "文件正在变化，请保存完成后重新发送。")
            }
            return try publish(id: id, staging: staging, subject: subject, taskId: taskId,
                               source: sourceIdentity, name: source.lastPathComponent, size: size,
                               fileNames: fileNames, authorized: authorized)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// 必须在快照复制成功后调用：锁内做幂等重查（并发准备同一任务只发布一次）、
    /// 授权/任务状态复查（失权即丢弃半成品，绝不发布）、存量清理、数量与配额核验，
    /// 然后把半成品改名成正式载荷。
    private func publish(id: String, staging: URL, subject: String, taskId: String, source: String,
                         name: String, size: Int64, fileNames: [String]?, authorized: () -> Bool) throws -> Offer {
        lock.lock(); defer { lock.unlock() }
        if let existing = liveLocked().first(where: { $0.subject == subject && $0.taskId == taskId && $0.source == source }) {
            try? FileManager.default.removeItem(at: staging)
            return existing
        }
        // 发布临界点授权复查：复制/打包可能耗时很长，期间控制权失效或任务结束必须中止，
        // 半成品就地清理，手机列表与票据都看不到这次准备。
        guard authorized() else {
            try? FileManager.default.removeItem(at: staging)
            throw Failure(message: "手机控制权已失效，请重新连接后发送。")
        }
        let offers = liveLocked()
        guard offers.count < offerLimit else {
            try? FileManager.default.removeItem(at: staging)
            throw Failure(message: "待收文件太多，请先在手机移除部分文件。")
        }
        guard offers.reduce(Int64(0), { $0 + $1.size }) + size <= totalQuota else {
            try? FileManager.default.removeItem(at: staging)
            throw Failure(message: "文件暂存空间已满，请先在手机移除已下载文件。")
        }
        do {
            try FileManager.default.moveItem(at: staging, to: payload(id))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw Failure(message: "无法保存文件快照，请重试。")
        }
        let offer = Offer(id: id, subject: subject, taskId: taskId, source: source, name: name,
                          size: size, expiresAt: now().timeIntervalSince1970 + lifetime, fileNames: fileNames)
        do { try save(offer) } catch {
            try? FileManager.default.removeItem(at: payload(id))
            throw Failure(message: "无法保存收件记录，请重试。")
        }
        return offer
    }

    // MARK: 批次准备

    /// 多文件整批生成 ZIP：安卓只触发一次下载；任一文件失败整批不发布。
    /// 同任务重试与并发准备通过幂等身份 + 进行中登记收敛到同一个收件项；
    /// authorized 在发布临界点复查控制权与任务状态，失权即整批丢弃。
    func prepare(paths: [String], subject: String, taskId: String, authorized: () -> Bool = { true }) throws -> Offer {
        let unique = Array(Set(paths.map { ($0 as NSString).expandingTildeInPath })).sorted()
        guard !unique.isEmpty else { throw Failure(message: "请先选择至少一个文件。") }
        guard unique.count <= batchLimit else { throw Failure(message: "每次请选择 1 到 20 个文件。") }
        if unique.count == 1 { return try prepare(path: unique[0], subject: subject, taskId: taskId, authorized: authorized) }
        let identity = unique.joined(separator: "\n")
        let key = subject + "|" + taskId + "|" + identity
        lock.lock()
        // 幂等身份必须包含主体：不同配对主体的同任务同路径是彼此独立的收件项。
        if let existing = liveLocked().first(where: { $0.subject == subject && $0.taskId == taskId && $0.source == identity }) {
            lock.unlock()
            return existing
        }
        if let done = batchInFlight[key] {
            lock.unlock()
            done.wait()
            // 接力唤醒：多个并发等待者共用一个信号量，每个醒来后必须补一次 signal，
            // 否则除第一个外全部永远等待。随后按幂等身份重新查证。
            done.signal()
            lock.lock()
            let existing = liveLocked().first(where: { $0.subject == subject && $0.taskId == taskId && $0.source == identity })
            lock.unlock()
            if let existing { return existing }
            throw Failure(message: "文件准备未成功，请重新发送。")
        }
        let done = DispatchSemaphore(value: 0)
        batchInFlight[key] = done
        lock.unlock()
        defer {
            lock.lock(); batchInFlight[key] = nil; lock.unlock()
            done.signal()
        }
        return try prepareBatch(unique: unique, subject: subject, taskId: taskId, identity: identity, authorized: authorized)
    }

    private func prepareBatch(unique: [String], subject: String, taskId: String, identity: String,
                              authorized: () -> Bool) throws -> Offer {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.batchTempPrefix + UUID().uuidString, isDirectory: true)
        let folder = temporary.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staging = PhoneFileStore(directory: temporary.appendingPathComponent("staging", isDirectory: true),
                                     maintenance: false)
        var names: [String] = []
        var total: Int64 = 0
        for (index, path) in unique.enumerated() {
            let item = try staging.prepare(path: path, subject: subject, taskId: taskId)
            total += item.size
            guard total <= maximumBytes else { throw Failure(message: "一批文件总大小暂时最多支持 512 MB。") }
            let original = item.name
            var name = original
            if names.contains(name) { name = "\(index + 1)-" + original }
            while names.contains(name) { name = "_" + name }
            names.append(name)
            try FileManager.default.moveItem(at: staging.payload(item.id), to: folder.appendingPathComponent(name))
        }
        let archive = temporary.appendingPathComponent("PocketDesk-\(unique.count)个文件.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // 只有路径进入参数表；用户字符串不参与命令行解释之外的任何执行。
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", folder.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: "文件打包失败，请重试。") }
        // 发布按实际 ZIP 大小核配额，归档后的体积失真由快照路径本身兜住。
        return try prepare(path: archive.path, subject: subject, taskId: taskId, identity: identity,
                           fileNames: names, authorized: authorized)
    }

    // MARK: 确认 / 拒绝 / 下载

    /// 手机明确接收后签发短时票据；重复确认换新票据并作废旧票据，重放旧票据被拒。
    func accept(id: String, subject: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard var offer = liveLocked().first(where: { $0.id == id && $0.subject == subject }) else {
            throw Failure(message: "文件已过期或已移除，请让小精灵重新发送。")
        }
        offer.accepted = true
        try save(offer)
        tickets = tickets.filter { $0.value.id != id }
        let ticket = UUID().uuidString + UUID().uuidString
        tickets[ticket] = Ticket(id: id, subject: subject, expires: now().addingTimeInterval(ticketLifetime))
        return ticket
    }

    /// 拒绝/移除即删除暂存并撤销票据。
    func dismiss(id: String, subject: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let offer = liveLocked().first(where: { $0.id == id && $0.subject == subject }) { remove(offer) }
    }

    /// 下载只认确认后签发的不可猜票据，绑定同一主体与同一快照；不收任意磁盘路径。
    func download(ticket: String, subject: String) throws -> (Offer, FileHandle) {
        lock.lock(); defer { lock.unlock() }
        let offers = liveLocked()
        guard let permit = tickets[ticket], permit.subject == subject,
              let offer = offers.first(where: { $0.id == permit.id && $0.subject == subject && $0.accepted }) else {
            throw Failure(message: "下载链接已失效，请回手机收件区重新点击接收。")
        }
        return (offer, try FileHandle(forReadingFrom: payload(offer.id)))
    }

    // MARK: 维护

    /// 定期清理过期收件与崩溃残留：不能只等下一次收件请求才清理。
    private func startMaintenance() {
        cleanResiduals()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.voicedeck.phone-files.sweep"))
        timer.schedule(deadline: .now() + 15 * 60, repeating: 15 * 60)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        sweeper = timer
    }

    private func sweep() {
        lock.lock()
        _ = liveLocked()
        lock.unlock()
        cleanResiduals()
    }

    /// 回收崩溃残留：store 目录里的半成品快照（复制中断）与进程临时目录里超过保留期的批次目录。
    private func cleanResiduals() {
        let current = now().timeIntervalSince1970
        if let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in items where item.lastPathComponent.hasPrefix("tmp-") {
                let age = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?
                    .timeIntervalSince1970 ?? .greatestFiniteMagnitude
                if current - age > 3600 { try? FileManager.default.removeItem(at: item) }
            }
        }
        let temporary = FileManager.default.temporaryDirectory
        if let items = try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in items where item.lastPathComponent.hasPrefix(Self.batchTempPrefix) {
                let age = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?
                    .timeIntervalSince1970 ?? 0
                if current - age > lifetime { try? FileManager.default.removeItem(at: item) }
            }
        }
    }
}
