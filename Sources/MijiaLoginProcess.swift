/**
 * [INPUT]: Foundation Process 的固定程序/参数、限时约束与桥接脚本 NDJSON 事件。
 * [OUTPUT]: 可取消的异步子进程；逐行限制事件大小，隐藏 stderr，退出前排空事件，超时升级终止。
 * [POS]: 米家连接的进程边界；MijiaConnection 管理会话与凭证，本文件不解释账号或保存数据。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin

protocol MijiaCancellable: AnyObject { func cancel() }

final class MijiaLoginProcess: MijiaCancellable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    private var started = false
    private var finished = false

    static func start(executable: String, arguments: [String], timeout: TimeInterval,
                      event: @escaping ([String: Any]) -> Void, completion: @escaping (Int32) -> Void) -> MijiaCancellable {
        let job = MijiaLoginProcess()
        DispatchQueue.global(qos: .utility).async { job.run(executable, arguments, timeout, event, completion) }
        return job
    }

    func cancel() {
        lock.lock(); cancelled = true
        let running = started && !finished && process.isRunning
        if running { process.terminate() }
        lock.unlock()
        if running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock(); defer { lock.unlock() }
                if !finished && process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval,
                     _ event: @escaping ([String: Any]) -> Void, _ completion: @escaping (Int32) -> Void) {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        lock.lock()
        guard !cancelled else { lock.unlock(); completion(-1); return }
        do { try process.run(); started = true; lock.unlock() }
        catch { finished = true; lock.unlock(); completion(-1); return }
        let deadline = DispatchWorkItem { [weak self] in self?.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let descriptor = output.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var bytes = [UInt8](repeating: 0, count: 4096)
        var buffer = Data(), total = 0, invalid = false
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count <= 0 {
                if count == 0 || !process.isRunning { break }
                if errno != EAGAIN && errno != EINTR { invalid = true; cancel(); break }
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptorState, 1, 100)
                continue
            }
            let chunk = Data(bytes.prefix(count))
            total += chunk.count
            if total > 65536 { invalid = true; cancel(); continue }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                if line.count > 16384 { invalid = true; cancel(); break }
                if let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { event(value) }
            }
            if buffer.count > 16384 { invalid = true; cancel(); buffer.removeAll() }
        }
        process.waitUntilExit(); deadline.cancel()
        lock.lock(); finished = true; let status = cancelled || invalid ? -1 : process.terminationStatus; lock.unlock()
        try? output.fileHandleForReading.close()
        completion(status)
    }
}
