/**
 * [INPUT]: 生产 PhoneFileHTTP/PhoneFileStore；临时目录参数与固定假 Auth，不链接桌面应用。
 * [OUTPUT]: 仅监听 127.0.0.1 随机端口的 HTTP 测试服务，提供 Unicode/空/大文件夹具和两秒流超时。
 * [POS]: phone-file-http.test.py 的子进程；所有源文件与快照限定在调用方临时目录。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Network

enum Auth {
    static let token = "fixture-token"
    static func verify(authorizationHeader: String?) -> Bool { authorizationHeader == "Bearer " + token }
}
enum TargetStore { static let supportDirectory = URL(fileURLWithPath: CommandLine.arguments[1]) }

@main enum Fixture {
    static func main() throws {
        let root = TargetStore.supportDirectory
        let store = PhoneFileStore(directory: root.appendingPathComponent("store"), maintenance: false)
        let small = root.appendingPathComponent("测试 文件.txt")
        try Data("hello 手机\n".utf8).write(to: small)
        let empty = root.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        let large = root.appendingPathComponent("large.bin")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let file = try FileHandle(forWritingTo: large)
        try file.truncate(atOffset: 64 * 1024 * 1024); try file.close()
        for path in [small, empty, large] {
            _ = try store.prepare(path: path.path, subject: PhoneFileStore.subject, taskId: path.lastPathComponent)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "fixture")
        listener.stateUpdateHandler = { state in
            if case .ready = state { print(listener.port!.rawValue); fflush(stdout) }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            receive(connection, buffer: Data(), store: store)
        }
        listener.start(queue: queue)
        dispatchMain()
    }
    static func receive(_ connection: NWConnection, buffer: Data, store: PhoneFileStore) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, complete, error in
            var buffer = buffer; buffer.append(data ?? Data())
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete || error != nil || buffer.count > 32768 { connection.cancel() }
                else { receive(connection, buffer: buffer, store: store) }
                return
            }
            let lines = text.components(separatedBy: "\r\n")
            let request = lines[0].split(separator: " ")
            let auth = lines.first { $0.lowercased().hasPrefix("authorization:") }?.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
            guard request.count >= 2 else { connection.cancel(); return }
            let respond: (Int, [String: Any]) -> Void = { status, body in
                let json = try! JSONSerialization.data(withJSONObject: body)
                var response = Data("HTTP/1.1 \(status) Result\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
                response.append(json)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
            if !PhoneFileHTTP.handle(method: String(request[0]), path: String(request[1]), authorization: auth,
                                     connection: connection, store: store, streamTimeout: 2, respond: respond) {
                respond(404, [:])
            }
        }
    }
}
