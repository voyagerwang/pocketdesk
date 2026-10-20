/**
 * [INPUT]: MijiaConnection 的可注入进程、只读核验、时钟与二维码生成器，MijiaHTTP 路由及隔离凭证目录。
 * [OUTPUT]: 验证扫码会话代际、二维码来源/期限、取消/失败保留旧账号、核验后的原子提交与 HTTP 参数边界。
 * [POS]: tests 的米家连接生命周期回归；全部子进程和网络均为替身，不访问正式账号或设备。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin

enum Util { static func qrPNG(_ text: String) -> Data? { Data(text.utf8) } }

private final class FakeJob: MijiaCancellable {
    let executable: String
    let arguments: [String]
    let timeout: TimeInterval
    let emit: ([String: Any]) -> Void
    let finish: (Int32) -> Void
    private let lock = NSLock()
    private var cancellations = 0
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    init(_ executable: String, _ arguments: [String], _ timeout: TimeInterval,
         _ emit: @escaping ([String: Any]) -> Void, _ finish: @escaping (Int32) -> Void) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout
        self.emit = emit; self.finish = finish
    }
    func cancel() { lock.lock(); cancellations += 1; lock.unlock() }
    var authURL: URL {
        URL(fileURLWithPath: arguments[arguments.firstIndex(of: "--auth")! + 1])
    }
}

private final class FakeDriver {
    struct Verification {
        let path: String
        let finish: (Result<[String: Any], MijiaBridge.Failure>) -> Void
    }
    private let lock = NSLock()
    private var runs: [FakeJob] = []
    private var verifications: [Verification] = []
    private var time: TimeInterval = 1_800_000_000
    var qrWorks = true
    var jobs: [FakeJob] { lock.lock(); defer { lock.unlock() }; return runs }
    var checks: [Verification] { lock.lock(); defer { lock.unlock() }; return verifications }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: time) }
    func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
    func launch(_ executable: String, _ arguments: [String], _ timeout: TimeInterval,
                _ emit: @escaping ([String: Any]) -> Void, _ finish: @escaping (Int32) -> Void) -> MijiaCancellable {
        let job = FakeJob(executable, arguments, timeout, emit, finish)
        lock.lock(); runs.append(job); lock.unlock(); return job
    }
    func verify(_ path: String, _ finish: @escaping (Result<[String: Any], MijiaBridge.Failure>) -> Void) {
        lock.lock(); verifications.append(Verification(path: path, finish: finish)); lock.unlock()
    }
}

private final class Fixture {
    static let oldAuth = Data("{\"account\":\"old-isolated-test\"}".utf8)
    static let newAuth = Data("{\"account\":\"new-isolated-test\"}".utf8)
    static let loginURL = "https://account.xiaomi.com/longPolling/login?test=isolated-session"
    let root: URL
    let auth: URL
    let fake = FakeDriver()
    let connection: MijiaConnection
    init(credentials: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mijia-connect-\(UUID().uuidString)")
        auth = root.appendingPathComponent("mijia/auth.json")
        try FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if credentials {
            try Self.oldAuth.write(to: auth)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path)
        }
        var dependencies = MijiaConnection.Dependencies()
        dependencies.authURL = auth; dependencies.python = "/isolated/python"
        dependencies.helper = "/isolated/mijia-bridge.py"; dependencies.installer = "/isolated/setup-mijia.sh"
        let fake = self.fake
        dependencies.now = fake.now; dependencies.launch = fake.launch; dependencies.verify = fake.verify
        dependencies.qr = { fake.qrWorks ? Data(("qr:" + $0).utf8) : nil }
        connection = MijiaConnection(dependencies: dependencies)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func flush() -> [String: Any] { connection.status() }
    func state() -> String { flush()["state"] as? String ?? "missing" }
    func eventually(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() {
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }
    func authenticateExisting() {
        _ = connection.status()
        fake.checks.last!.finish(.success(["authenticated": true])); flush()
    }
    func startLogin() -> FakeJob {
        _ = connection.connect()
        let runtime = fake.jobs.last!
        runtime.emit(["ok": true, "sdk_version": "5.0.0"]); runtime.finish(0); flush()
        return fake.jobs.last!
    }
    func waiting(_ job: FakeJob) -> String {
        job.emit(["event": "qr", "login_url": Self.loginURL, "expires_in": 120])
        return flush()["sessionId"] as! String
    }
    func stage(_ job: FakeJob, mode: Int = 0o600, data: Data = Fixture.newAuth) throws {
        try data.write(to: job.authURL)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: job.authURL.path)
    }
    func complete(_ job: FakeJob) {
        job.emit(["event": "complete"]); job.finish(0); flush()
    }
    func authData() -> Data? { try? Data(contentsOf: auth) }
}

@main struct MijiaConnectionTests {
    static var checks = 0
    static var failures: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        checks += 1; if !value() { failures.append(label) }
    }
    static func main() throws {
        // ---------- 首次访问只核验，不产生扫码与安装 ----------
        do {
            let f = try Fixture()
            check(f.state() == "unconfigured", "无凭证初访是未连接")
            _ = f.connection.check(); f.flush()
            check(f.fake.jobs.isEmpty && f.fake.checks.isEmpty, "无凭证访问与检查均不启动网络/进程")
            check(f.flush()["hasCredentials"] as? Bool == false, "无凭证快照如实报告")
        }
        do {
            let f = try Fixture(credentials: true)
            check(f.state() == "checking", "已有凭证首次只读检查")
            f.flush(); f.flush()
            check(f.fake.jobs.isEmpty && f.fake.checks.count == 1, "轮询不重复核验或生成二维码")
            check(f.fake.checks[0].path == f.auth.path, "初始核验只读正式凭证")
            check(f.authData() == Fixture.oldAuth, "只读检查不改凭证")
            f.fake.checks[0].finish(.success(["authenticated": true]))
            check(f.state() == "connected", "真实核验成功后才显示已连接")
            check(f.flush()["checkedAt"] as? TimeInterval == f.fake.now().timeIntervalSince1970, "连接快照记录核验时刻")
            _ = f.connection.check()
            check(f.fake.checks.count == 2 && f.state() == "checking", "用户明确检查可重新核验")
            f.fake.checks[1].finish(.failure(.init(kind: "auth", message: "expired")))
            check(f.state() == "unconfigured" && f.authData() == Fixture.oldAuth, "授权失效不冒称已连接，不删除原凭证")
        }

        // ---------- 可选运行时与固定子进程参数 ----------
        do {
            let f = try Fixture()
            let first = f.connection.connect()
            check(first["state"] as? String == "starting", "显式连接进入准备状态")
            let runtime = f.fake.jobs[0]
            check(runtime.executable == "/isolated/python" && runtime.arguments == ["-I", "-B", "/isolated/mijia-bridge.py", "--check-runtime"], "固定参数检查运行时，无账号信息")
            check(runtime.timeout == 20, "运行时检查有界")
            runtime.emit(["ok": true, "sdk_version": "4.0.0"]); runtime.finish(0); f.flush()
            check(f.state() == "installing", "版本不匹配进入显式安装")
            let install = f.fake.jobs[1]
            check(install.executable == "/bin/zsh" && install.arguments == ["/isolated/setup-mijia.sh", "--no-login"] && install.timeout == 180, "安装使用固定脚本，且不自行登录")
            install.finish(0); f.flush()
            let retry = f.fake.jobs[2]
            retry.emit(["ok": true, "sdk_version": "5.0.0"]); retry.finish(0); f.flush()
            let login = f.fake.jobs[3]
            check(login.arguments.suffix(3) == ["--auth", login.authURL.path, "--login-events"] && login.timeout == 160, "核验运行时后只启动独立事件登录")
            check(login.authURL != f.auth && login.authURL.deletingLastPathComponent().deletingLastPathComponent() == f.auth.deletingLastPathComponent(), "扫码凭证写入同一私有父目录的隔离会话")
            let permissions = try FileManager.default.attributesOfItem(atPath: login.authURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o700, "登录会话目录限制为0700")
        }
        do {
            let f = try Fixture()
            _ = f.connection.connect(); f.fake.jobs[0].finish(-1); f.flush()
            f.fake.jobs[1].finish(1)
            check(f.state() == "failed" && f.fake.jobs.count == 2, "安装失败停止流程，不无限重试")
        }
        do {
            let f = try Fixture()
            _ = f.connection.connect(); f.fake.jobs[0].finish(-1); f.flush()
            f.fake.jobs[1].finish(0); f.flush()
            f.fake.jobs[2].finish(-1)
            check(f.state() == "failed" && f.fake.jobs.count == 3, "安装后运行时仍失败不再次安装")
        }

        // ---------- 二维码地址、有效期与对外快照 ----------
        check(MijiaConnection.validLoginURL(Fixture.loginURL), "允许小米 HTTPS 固定登录入口")
        let regionalLogin = "https://sgp.account.xiaomi.com/longPolling/login?test=isolated-regional-session"
        check(MijiaConnection.validLoginURL(regionalLogin), "允许小米账号服务的地区子域二维码入口")
        for bad in [
            "http://account.xiaomi.com/longPolling/login?a=b", "https://account.xiaomi.com.evil.example/longPolling/login?a=b",
            "https://evilaccount.xiaomi.com/longPolling/login?a=b", "https://account.xiaomi.com.evil/longPolling/login?a=b",
            "https://sgp.account.xiaomi.com:443/longPolling/login?a=b", "https://user:password@sgp.account.xiaomi.com/longPolling/login?a=b",
            "https://evil.example/longPolling/login?a=b", "https://account.xiaomi.com/other?a=b",
            "https://user:password@account.xiaomi.com/longPolling/login?a=b", "https://account.xiaomi.com:443/longPolling/login?a=b",
            "https://account.xiaomi.com/longPolling/login?a=b#secret", "https://account.xiaomi.com/longPolling/login",
            "https://account.xiaomi.com/longPolling/login?a= b", Fixture.loginURL + String(repeating: "a", count: 8192)
        ] { check(!MijiaConnection.validLoginURL(bad), "拒绝非标准登录地址 \(bad.prefix(80))") }
        do {
            let f = try Fixture(); let job = f.startLogin()
            job.emit(["event": "qr", "login_url": regionalLogin, "expires_in": 120])
            let status = f.flush(); let id = status["sessionId"] as? String ?? ""
            check(f.state() == "waiting" && f.connection.qr(session: id) == Data(("qr:" + regionalLogin).utf8), "地区子域二维码通过真实协调器事件路径")
        }
        do {
            let f = try Fixture(); let job = f.startLogin(); let id = f.waiting(job)
            let status = f.flush()
            check(f.state() == "waiting" && status["qrReady"] as? Bool == true, "有效二维码进入待扫码")
            check(f.connection.qr(session: id) == Data(("qr:" + Fixture.loginURL).utf8), "当前会话可读取二维码字节")
            check(f.connection.qr(session: "unrelated") == nil, "错误会话无法读取二维码")
            check(status["expiresAt"] as? TimeInterval == f.fake.now().timeIntervalSince1970 + 120, "二维码具有明确120秒期限")
            let publicText = String(data: try JSONSerialization.data(withJSONObject: status), encoding: .utf8)!
            check(!publicText.contains(Fixture.loginURL) && !publicText.contains("login_url") && !publicText.contains(f.root.path), "状态快照不公开登录网址或凭证路径")
            f.fake.advance(119)
            check(f.connection.qr(session: id) != nil, "期限前二维码有效")
            f.fake.advance(1)
            check(f.connection.qr(session: id) == nil && f.state() == "expired", "期限到达即停止提供旧二维码")
            check(job.cancelCount == 1 && f.flush()["qrReady"] as? Bool == false, "过期取消子进程并清空二维码")
            job.emit(["event": "complete"]); job.finish(0); f.flush()
            check(f.fake.checks.isEmpty && f.authData() == nil, "过期后的成功回调不能提交账号")
        }
        do {
            let f = try Fixture(); let job = f.startLogin()
            job.emit(["event": "qr", "login_url": "https://evil.example/longPolling/login?a=b"])
            check(f.state() == "failed" && job.cancelCount == 1 && f.flush()["qrReady"] as? Bool == false, "非小米网址在二维码生成前终止")
        }
        do {
            let f = try Fixture(); f.fake.qrWorks = false; let job = f.startLogin()
            job.emit(["event": "qr", "login_url": Fixture.loginURL])
            check(f.state() == "failed" && f.flush()["qrReady"] as? Bool == false, "图片生成失败不保留二维码状态")
        }

        // ---------- 刷新与取消使旧代际永久失效 ----------
        do {
            let f = try Fixture(credentials: true); f.authenticateExisting()
            let old = f.startLogin(); let oldID = f.waiting(old); let oldRevision = f.flush()["revision"] as! Int
            let fresh = f.connection.connect(); let newID = fresh["sessionId"] as! String
            check(old.cancelCount == 1 && newID != oldID, "刷新取消旧进程并签发新会话")
            check(f.connection.qr(session: oldID) == nil && fresh["qrReady"] as? Bool == false, "刷新立即废弃旧二维码")
            check(f.connection.cancel(session: oldID) == nil, "旧页面取消不能影响新会话")
            old.emit(["event": "qr", "login_url": Fixture.loginURL]); old.emit(["event": "complete"]); old.finish(0)
            check(f.state() == "starting" && f.fake.checks.count == 1, "旧事件和成功退出不能推进新代际")
            check((f.flush()["revision"] as! Int) > oldRevision && f.authData() == Fixture.oldAuth, "版本单调递增，刷新保留正式账号")
            let cancelled = f.connection.cancel(session: newID)
            check(cancelled?["state"] as? String == "connected" && cancelled?["sessionId"] == nil, "取消重连恢复已核验的现有连接")
            check(f.authData() == Fixture.oldAuth, "取消未改写旧凭证")
        }
        do {
            let f = try Fixture(credentials: true)
            _ = f.connection.status(); let staleCheck = f.fake.checks[0]
            let login = f.startLogin(); _ = f.waiting(login)
            staleCheck.finish(.success(["authenticated": true]))
            check(f.state() == "waiting", "初始检查迟到不能覆盖正在扫码的新状态")
        }
        do {
            let f = try Fixture(); let job = f.startLogin(); let id = f.waiting(job)
            check(f.connection.cancel(session: id)?["state"] as? String == "unconfigured", "首次扫码取消回到未配置")
            job.emit(["event": "complete"]); job.finish(0)
            check(f.state() == "unconfigured" && f.fake.checks.isEmpty, "取消后的旧成功事件无效")
        }

        // ---------- 完成必须等待退出与账号核验，再原子替换 ----------
        do {
            let f = try Fixture(credentials: true); f.authenticateExisting()
            let job = f.startLogin(); let id = f.waiting(job); try f.stage(job)
            job.emit(["event": "complete"]); f.flush()
            check(f.state() == "authorizing" && f.connection.qr(session: id) == nil, "扫码完成立即移除二维码，等待授权核验")
            check(f.fake.checks.count == 1 && f.authData() == Fixture.oldAuth, "子进程退出前不核验也不替换旧账号")
            job.finish(0); f.flush()
            check(f.fake.checks.count == 2 && f.fake.checks[1].path == job.authURL.path, "进程成功退出后核验隔离的新凭证")
            check(f.authData() == Fixture.oldAuth, "核验回调到达前正式账号保持完整")
            f.fake.checks[1].finish(.success(["authenticated": true])); f.flush()
            check(f.eventually { f.state() == "connected" } && f.authData() == Fixture.newAuth, "新账号核验成功后保存并显示已连接")
            let permissions = try FileManager.default.attributesOfItem(atPath: f.auth.path)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o600, "正式凭证保持0600")
            check(f.eventually { !FileManager.default.fileExists(atPath: job.authURL.deletingLastPathComponent().path) }, "提交成功清理暂存会话目录")
            check(f.flush()["sessionId"] == nil && f.flush()["qrReady"] as? Bool == false, "完成快照不残留扫码会话")
        }
        do {
            let f = try Fixture(credentials: true); let job = f.startLogin(); _ = f.waiting(job); try f.stage(job)
            f.complete(job)
            f.fake.checks.last!.finish(.failure(.init(kind: "network", message: "offline")))
            check(f.state() == "failed" && f.authData() == Fixture.oldAuth, "新账号核验失败保留旧凭证")
        }
        do {
            let f = try Fixture(credentials: true); f.authenticateExisting()
            let job = f.startLogin(); let id = f.waiting(job); try f.stage(job); f.complete(job)
            let verification = f.fake.checks.last!
            _ = f.connection.cancel(session: id)
            verification.finish(.success(["authenticated": true]))
            check(f.state() == "connected" && f.authData() == Fixture.oldAuth, "核验期间取消后迟到成功不能覆盖旧账号")
        }
        do {
            let f = try Fixture(credentials: true); f.authenticateExisting()
            let job = f.startLogin(); let id = f.waiting(job); try f.stage(job)
            job.emit(["event": "complete"]); f.flush(); _ = f.connection.cancel(session: id)
            check(FileManager.default.fileExists(atPath: job.authURL.deletingLastPathComponent().path), "子进程未退出的取消保留暂存目录，交给退出回调清理")
            job.finish(0); f.flush()
            check(f.state() == "connected" && f.authData() == Fixture.oldAuth && f.fake.checks.count == 1, "收到complete但未退出时取消，晚退出不能核验或覆盖旧账号")
            check(!FileManager.default.fileExists(atPath: job.authURL.deletingLastPathComponent().path), "已取消子进程退出后删除暂存目录")
        }
        do {
            let f = try Fixture(credentials: true); let old = f.startLogin(); _ = f.waiting(old); try f.stage(old); f.complete(old)
            let oldVerification = f.fake.checks.last!
            let fresh = f.startLogin(); let newID = f.waiting(fresh)
            oldVerification.finish(.success(["authenticated": true])); f.flush()
            check(f.state() == "waiting" && f.connection.qr(session: newID) != nil && f.authData() == Fixture.oldAuth, "刷新后的旧核验不能覆盖凭证或删除新二维码")
        }
        do {
            let f = try Fixture(credentials: true); f.authenticateExisting()
            let job = f.startLogin(); let id = f.waiting(job); try f.stage(job); f.complete(job)
            let lockEntered = DispatchSemaphore(value: 0), unlock = DispatchSemaphore(value: 0), lockFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                MijiaHomeScope.shared.withAccountReplacement { lockEntered.signal(); _ = unlock.wait(timeout: .now() + 5) }
                lockFinished.signal()
            }
            check(lockEntered.wait(timeout: .now() + 2) == .success, "模拟在途设备调用持有家庭锁")
            f.fake.checks.last!.finish(.success(["authenticated": true]))
            let cancelled = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = f.connection.status(); _ = f.connection.cancel(session: id); cancelled.signal()
            }
            let remainedResponsive = cancelled.wait(timeout: .now() + 0.5) == .success
            unlock.signal()
            check(remainedResponsive, "授权保存等待家庭锁时状态查询和取消保持响应")
            check(lockFinished.wait(timeout: .now() + 2) == .success, "模拟设备调用可释放家庭锁")
            check(f.eventually { !FileManager.default.fileExists(atPath: job.authURL.deletingLastPathComponent().path) }, "取消后迟到提交完成暂存清理")
            check(f.state() == "connected" && f.authData() == Fixture.oldAuth, "等待家庭锁期间取消，锁释放后不得提交旧会话账号")
        }
        for permissions in [0o644, 0o400] {
            let f = try Fixture(credentials: true); let job = f.startLogin(); _ = f.waiting(job); try f.stage(job, mode: permissions)
            f.complete(job); f.fake.checks.last!.finish(.success(["authenticated": true]))
            check(f.eventually { f.state() == "failed" } && f.authData() == Fixture.oldAuth, "拒绝非0600的新凭证权限 \(String(permissions, radix: 8))")
        }
        do {
            let f = try Fixture(credentials: true); let job = f.startLogin(); _ = f.waiting(job); try f.stage(job, data: Data())
            f.complete(job); f.fake.checks.last!.finish(.success(["authenticated": true]))
            check(f.eventually { f.state() == "failed" } && f.authData() == Fixture.oldAuth, "空暂存凭证不能替换旧账号")
        }
        do {
            let f = try Fixture(credentials: true); let job = f.startLogin(); _ = f.waiting(job); try f.stage(job)
            job.finish(0)
            check(f.state() == "failed" && f.fake.checks.isEmpty && f.authData() == Fixture.oldAuth, "缺少complete事件的正常退出不构成成功")
        }
        do {
            let f = try Fixture(credentials: true); let job = f.startLogin(); _ = f.waiting(job); try f.stage(job)
            job.emit(["event": "complete"]); job.finish(1)
            check(f.state() == "failed" && f.fake.checks.isEmpty && f.authData() == Fixture.oldAuth, "complete后异常退出不能提交凭证")
        }
        do {
            let f = try Fixture(); let job = f.startLogin()
            job.emit(["event": "complete"])
            check(f.state() == "failed" && f.fake.checks.isEmpty, "未生成二维码就complete属于异常协议")
        }
        do {
            let f = try Fixture(); let job = f.startLogin(); _ = f.waiting(job)
            job.emit(["event": "error", "kind": "expired", "message": "ignored external text"])
            check(f.state() == "expired" && f.flush()["qrReady"] as? Bool == false, "SDK过期事件清除二维码并显示过期")
        }

        // ---------- HTTP 边界；同源授权由 Server 共用入口负责 ----------
        do {
            let f = try Fixture()
            func request(_ method: String, _ rawPath: String, _ body: String = "") -> (code: Int, data: Data, type: String) {
                var response = (code: -1, data: Data(), type: "")
                let handled = MijiaHTTP.handle(method: method, path: URLComponents(string: rawPath)!.path,
                    rawPath: rawPath, body: Data(body.utf8), connection: f.connection) { response = ($0, $1, $2) }
                precondition(handled); return response
            }
            let status = request("GET", "/api/console/mijia/status")
            check(status.code == 200 && status.type == "application/json; charset=utf-8", "HTTP状态提供JSON")
            let statusJSON = try JSONSerialization.jsonObject(with: status.data) as! [String: Any]
            check(statusJSON["state"] as? String == "unconfigured" && f.fake.jobs.isEmpty, "HTTP初访不触发安装或登录")
            for body in ["[]", "null", "{\"unexpected\":true}", "", "{", "{\"padding\":\"" + String(repeating: "a", count: 1024) + "\"}"] {
                check(request("POST", "/api/console/mijia/connect", body).code == 400, "connect拒绝非空对象或畸形JSON \(body.prefix(30))")
            }
            check(f.fake.jobs.isEmpty, "非法HTTP连接请求没有副作用")
            check(request("POST", "/api/console/mijia/check", "{\"sessionId\":\"bad\"}").code == 400, "check拒绝额外参数")
            check(request("POST", "/api/console/mijia/cancel", "{\"sessionId\":\"bad\"}").code == 400, "cancel拒绝非UUID会话")
            check(request("POST", "/api/console/mijia/cancel", "{\"sessionId\":\"\(UUID().uuidString)\",\"extra\":true}").code == 400, "cancel拒绝额外字段")
            check(request("POST", "/api/console/mijia/cancel", "{\"sessionId\":\"\(UUID().uuidString)\"}").code == 409, "旧会话cancel返回409")
            check(request("GET", "/api/console/mijia/qr?sessionId=bad").code == 404, "二维码拒绝无效会话")
            let job = f.startLogin(); let id = f.waiting(job)
            let qr = request("GET", "/api/console/mijia/qr?sessionId=\(id)")
            check(qr.code == 200 && qr.type == "image/png" && qr.data == f.connection.qr(session: id), "二维码HTTP仅返回当前会话PNG")
            check(request("GET", "/api/console/mijia/qr?sessionId=\(id)&sessionId=\(id)").code == 404, "二维码拒绝重复会话参数")
            f.fake.advance(120)
            check(request("GET", "/api/console/mijia/qr?sessionId=\(id)").code == 404, "HTTP读取时强制二维码到期失效")
            check(request("POST", "/api/console/mijia/cancel", "{\"sessionId\":\"\(id)\"}").code == 409, "已过期会话不能再次取消")
            check(request("POST", "/api/console/mijia/unknown", "{}").code == 404, "未知米家操作返回404")
            var replied = false
            let handled = MijiaHTTP.handle(method: "GET", path: "/api/console/unrelated", rawPath: "/api/console/unrelated",
                body: Data(), connection: f.connection) { _, _, _ in replied = true }
            check(!handled && !replied, "不截获其他控制台路由")
        }
        for failure in failures { print("FAIL: \(failure)") }
        print("Mijia connection: \(checks - failures.count)/\(checks) checks passed")
        if !failures.isEmpty { exit(1) }
    }
}
