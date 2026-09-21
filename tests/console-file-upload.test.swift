/**
 * [INPUT]: ConsoleFileUpload 与隔离 PhoneFileStore/锁屏替身。
 * [OUTPUT]: 分块重组、Unicode 文件名、空文件、错序和总量边界回归。
 * [POS]: 不接触真实收件箱，只在系统临时目录写合成字节。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum LockScreenInput { static var locked = false }
final class PhoneFileStore {
    struct Offer { let name: String; var json: [String: Any] { ["name": name] } }
    static let shared = PhoneFileStore(), subject = "fixture"
    var captured: [(String, Data)] = []
    func prepare(paths: [String], subject: String, taskId: String, authorized: () -> Bool) throws -> Offer {
        guard authorized() else { throw ConsoleFileUpload.Failure(message: "blocked") }
        captured = try paths.map { ($0, try Data(contentsOf: URL(fileURLWithPath: $0))) }
        return Offer(name: paths.count == 1 ? URL(fileURLWithPath: paths[0]).lastPathComponent : "batch.zip")
    }
}

@main enum ConsoleFileUploadTest {
    static func main() throws {
        var failures = 0
        func check(_ ok: Bool, _ label: String) { print("\(ok ? "PASS" : "FAIL") \(label)"); if !ok { failures += 1 } }
        let upload = ConsoleFileUpload()
        let started = try upload.start(["files": [["name": "测试.txt", "size": 5], ["name": "空.txt", "size": 0]]])
        let id = started["uploadId"] as! String
        _ = try upload.append(["uploadId": id, "index": 0, "offset": 0, "data": Data("he".utf8).base64EncodedString()])
        _ = try upload.append(["uploadId": id, "index": 0, "offset": 2, "data": Data("llo".utf8).base64EncodedString()])
        _ = try upload.append(["uploadId": id, "index": 1, "offset": 0, "data": Data().base64EncodedString()])
        let done = DispatchSemaphore(value: 0); var result: [String: Any] = [:]
        upload.finish(["uploadId": id]) { result = $0; done.signal() }
        check(done.wait(timeout: .now() + 5) == .success && result["ok"] as? Bool == true, "finish publishes complete upload")
        check(PhoneFileStore.shared.captured.map { URL(fileURLWithPath: $0.0).lastPathComponent } == ["测试.txt", "空.txt"], "preserve unicode names")
        check(PhoneFileStore.shared.captured.map(\.1) == [Data("hello".utf8), Data()], "reassemble exact bytes and empty file")
        let other = try upload.start(["files": [["name": "a", "size": 2]]])
        do { _ = try upload.append(["uploadId": other["uploadId"]!, "index": 0, "offset": 1, "data": "YQ=="]); check(false, "reject wrong offset") }
        catch { check(error.localizedDescription.contains("顺序"), "reject wrong offset") }
        do { _ = try upload.start(["files": [["name": "../bad", "size": 1]]]); check(false, "reject path name") }
        catch { check(true, "reject path name") }
        exit(failures == 0 ? 0 : 1)
    }
}
