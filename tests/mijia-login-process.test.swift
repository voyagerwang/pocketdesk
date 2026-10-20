/**
 * [INPUT]: MijiaLoginProcess 与临时 Python 程序；使用真实管道、进程退出和本机信号，不读取授权或访问网络。
 * [OUTPUT]: 验证逐行事件与退出顺序、stderr 隔离、输出上限、超时取消，以及后代持有管道时的有界结束。
 * [POS]: tests 的米家登录进程边界回归；会话与凭据提交由 mijia-connection.test.swift 覆盖。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin

private final class Observation {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var order: [String] = []
    private var status: Int32?
    private var duration: TimeInterval?
    private let started = ProcessInfo.processInfo.systemUptime
    let done = DispatchSemaphore(value: 0)
    let ready = DispatchSemaphore(value: 0)
    func receive(_ event: [String: Any]) {
        lock.lock()
        events.append(event); order.append(event["event"] as? String ?? "other")
        lock.unlock()
        if event["event"] as? String == "ready" { ready.signal() }
    }
    func complete(_ code: Int32) {
        lock.lock()
        status = code; duration = ProcessInfo.processInfo.systemUptime - started
        order.append("completion")
        lock.unlock(); done.signal()
    }
    var result: (events: [[String: Any]], order: [String], status: Int32?, duration: TimeInterval?) {
        lock.lock(); defer { lock.unlock() }; return (events, order, status, duration)
    }
}

private final class Fixture {
    let directory: URL
    private var counter = 0
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pd-mijia-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func start(_ source: String, timeout: TimeInterval = 3, arguments: [String] = []) throws -> (MijiaCancellable, Observation) {
        counter += 1
        let script = directory.appendingPathComponent("child-\(counter).py")
        try source.write(to: script, atomically: true, encoding: .utf8)
        let observation = Observation()
        let job = MijiaLoginProcess.start(executable: "/usr/bin/env", arguments: ["python3", "-I", "-B", script.path] + arguments,
                                          timeout: timeout, event: observation.receive, completion: observation.complete)
        return (job, observation)
    }
}

@main struct MijiaLoginProcessTests {
    private static var checks = 0
    private static var failures: [String] = []
    private static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }
    private static func finish(_ job: MijiaCancellable, _ observation: Observation, timeout: TimeInterval = 5) {
        let arrived = observation.done.wait(timeout: .now() + timeout) == .success
        check(arrived, "进程必须在测试期限内完成")
        if !arrived {
            job.cancel()
            _ = observation.done.wait(timeout: .now() + 3)
        }
    }
    private static func processExited(_ pid: Int32) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    static func main() throws {
        let fixture = try Fixture()
        try orderedEvents(fixture)
        try stderrIsPrivate(fixture)
        try outputIsBounded(fixture)
        try longLineIsRejected(fixture)
        try deadlineKillsStubbornProcess(fixture)
        try cancelImmediately(fixture)
        try cancelAfterStart(fixture)
        try descendantCannotHoldCompletion(fixture)
        invalidExecutableFinishes()
        if failures.isEmpty { print("mijia-login-process: \(checks) checks passed") }
        else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
    }

    private static func orderedEvents(_ fixture: Fixture) throws {
        let (job, observation) = try fixture.start("""
        import os, time
        os.write(1, b'{"event":"qr",')
        time.sleep(0.03)
        os.write(1, b'"number":1}\\n{"event":"complete"}\\n')
        """)
        finish(job, observation)
        let result = observation.result
        check(result.status == 0, "正常子进程必须成功退出")
        check(result.order == ["qr", "complete", "completion"], "分块 NDJSON 必须按顺序交付，排空后才能完成")
        check(result.events.first?["number"] as? Int == 1, "拆开的 JSON 行必须完整组装")
    }

    private static func stderrIsPrivate(_ fixture: Fixture) throws {
        let log = fixture.directory.appendingPathComponent("parent-stderr.txt")
        let sink = open(log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard sink >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let original = dup(STDERR_FILENO)
        guard original >= 0 else { close(sink); throw CocoaError(.fileReadUnknown) }
        dup2(sink, STDERR_FILENO); close(sink)
        do {
            defer { dup2(original, STDERR_FILENO); close(original) }
            let (job, observation) = try fixture.start("""
            import os
            os.write(2, b'PRIVATE_TEST_STDERR_DO_NOT_EXPOSE\\n')
            os.write(1, b'{"event":"complete"}\\n')
            """)
            finish(job, observation)
            check(observation.result.order == ["complete", "completion"], "stderr 不得成为事件")
        }
        let captured = try Data(contentsOf: log)
        check(captured.isEmpty, "第三方 stderr 不得转发到宿主 stderr")
    }

    private static func outputIsBounded(_ fixture: Fixture) throws {
        let (job, observation) = try fixture.start("""
        import json, os, time
        print(json.dumps({"event":"ready", "pid":os.getpid()}), flush=True)
        for i in range(2000):
            print(json.dumps({"event":"row", "text":"x" * 200}), flush=True)
        time.sleep(20)
        """, timeout: 10)
        finish(job, observation)
        let result = observation.result
        check(result.status == -1, "超过 64 KiB 总输出必须取消")
        check((result.duration ?? 99) < 3, "输出超限必须主动终止，不能等普通截止时间")
        check(result.events.count < 2000, "超限后的事件不得继续交付")
        if let pid = result.events.first?["pid"] as? Int32 { check(processExited(pid), "超限子进程必须退出并回收") }
        else { check(false, "超限测试必须观察到实际子进程") }
    }

    private static func longLineIsRejected(_ fixture: Fixture) throws {
        let (job, observation) = try fixture.start("""
        import json, time
        print(json.dumps({"event":"too-long", "text":"x" * 20000}), flush=True)
        time.sleep(20)
        """, timeout: 10)
        finish(job, observation)
        check(observation.result.status == -1, "超过 16 KiB 的单行必须拒绝")
        check(observation.result.events.isEmpty, "过长单行不得送入事件处理")
    }

    private static func deadlineKillsStubbornProcess(_ fixture: Fixture) throws {
        let (job, observation) = try fixture.start("""
        import json, os, signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print(json.dumps({"event":"ready", "pid":os.getpid()}), flush=True)
        time.sleep(20)
        """, timeout: 0.4)
        finish(job, observation)
        let result = observation.result
        check(result.status == -1, "到期必须返回取消状态")
        check((result.duration ?? 99) < 3, "忽略 TERM 的程序必须在期限后有界升级终止")
        if let pid = result.events.first?["pid"] as? Int32 { check(processExited(pid), "超时子进程必须退出并回收") }
        else { check(false, "超时测试必须观察到实际子进程") }
    }

    private static func cancelImmediately(_ fixture: Fixture) throws {
        // 直接构造覆盖尚未启动的幂等取消；公开异步入口随后验证调度后立即取消。
        let unscheduled = MijiaLoginProcess()
        unscheduled.cancel(); unscheduled.cancel()
        let (job, observation) = try fixture.start("""
        import time
        time.sleep(1)
        print('{"event":"late"}', flush=True)
        """)
        job.cancel(); job.cancel()
        finish(job, observation)
        check(observation.result.status == -1, "启动前或调度后立即取消必须收尾")
        check(observation.result.events.isEmpty, "立即取消后不得执行迟到事件")
    }

    private static func cancelAfterStart(_ fixture: Fixture) throws {
        let (job, observation) = try fixture.start("""
        import json, os, time
        print(json.dumps({"event":"ready", "pid":os.getpid()}), flush=True)
        time.sleep(20)
        """, timeout: 10)
        check(observation.ready.wait(timeout: .now() + 3) == .success, "取消前必须确认子进程实际已启动")
        job.cancel(); job.cancel()
        finish(job, observation)
        let result = observation.result
        check(result.status == -1, "启动后取消必须返回取消状态")
        check(result.order == ["ready", "completion"], "取消不得伪造额外登录事件")
        if let pid = result.events.first?["pid"] as? Int32 { check(processExited(pid), "主动取消的子进程必须退出并回收") }
    }

    private static func descendantCannotHoldCompletion(_ fixture: Fixture) throws {
        let marker = fixture.directory.appendingPathComponent("descendant-exited")
        let (job, observation) = try fixture.start("""
        import json, os, sys, time
        child = os.fork()
        if child == 0:
            time.sleep(2)
            with open(sys.argv[1], 'w') as marker:
                marker.write('finished')
            os._exit(0)
        print(json.dumps({"event":"ready", "pid":child}), flush=True)
        os._exit(0)
        """, timeout: 5, arguments: [marker.path])
        finish(job, observation)
        let result = observation.result
        check(result.status == 0, "父进程成功退出必须保留其退出结果")
        check((result.duration ?? 99) < 1.5, "后代持有 stdout 不得把父进程完成拖到后代退出")
        guard let pid = result.events.first?["pid"] as? Int32 else { check(false, "必须观察到后代 PID"); return }
        defer { if !processExited(pid) { kill(pid, SIGKILL) } }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !processExited(pid) && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
        check(FileManager.default.fileExists(atPath: marker.path), "短命后代必须按预期结束")
        check(processExited(pid), "后代必须已退出并由系统回收，测试不得遗留进程")
    }

    private static func invalidExecutableFinishes() {
        let observation = Observation()
        let job = MijiaLoginProcess.start(executable: "/nonexistent/pocketdesk-mijia-test", arguments: [], timeout: 1,
                                          event: observation.receive, completion: observation.complete)
        finish(job, observation)
        check(observation.result.status == -1, "无法启动必须明确失败并结束")
        check(observation.result.events.isEmpty, "无法启动不得生成事件")
    }
}
