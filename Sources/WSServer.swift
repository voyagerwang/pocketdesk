/**
 * [INPUT]: 依赖 Network 的 NWListener/NWConnection 与 NWProtocolWebSocket；消费 PointerExecutor 的手势执行、CursorMonitor 的光标采样与 Auth 的 token 校验。
 * [OUTPUT]: 对外提供 WSServer（触控板 WebSocket 通道 :46388 的监听、首帧 token 鉴权与 auth_ok 回执、已鉴权连接表、鼠标位置广播、会话重置与消息转发）。
 * [POS]: Sources 的触控板传输层；只管连接与转发，与 Server（HTTP）平行为一对传输兄弟。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Network

// MARK: - 触控板 WebSocket 服务

// 这一层是双向的：上行是手机手势 → PointerExecutor，下行是 Mac 光标位置 → 手机叠加层。
// 下行走 latest-only：同一连接最多一个在途帧 + 一个待发帧，过期的中间状态直接丢弃。
// TCP 没有应用层背压，不这样限流的话网络一拥塞，延迟会单调变大且再也回不来。

final class WSServer {
    private let port: UInt16
    private let pointer: PointerExecutor
    private let cursor: CursorMonitor
    private let queue = DispatchQueue(label: "dev.voicedeck.ws")
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]   // 只在 queue 上读写

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var authenticated = false
        var cursorSubscribed = false
        var sending = false
        var pending: String?        // latest-only：在途时最多留一个最新状态
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(port: UInt16, pointer: PointerExecutor, cursor: CursorMonitor) {
        self.port = port
        self.pointer = pointer
        self.cursor = cursor
        cursor.onSample = { [weak self] seq, display, rx, ry in
            self?.broadcastCursor(seq: seq, display: display, rx: rx, ry: ry)
        }
        pointer.onError = { [weak self] message in self?.broadcastError(message) }
    }

    func start() throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { fputs("触控板通道失败：\(error)\n", stderr) }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        // 局域网写通道必须鉴权：浏览器 WS 不能带自定义头，用首帧 auth 握手。
        // 回环（控制台本机调试）豁免；非回环首帧必须是 {"t":"auth","token":"…"}，否则关闭连接。
        let loopback = isLoopback(connection)
        let client = Client(connection)
        queue.async {
            self.clients[client.id] = client
            client.authenticated = loopback
            if loopback {
                self.pointer.resetSession()
                // 回环豁免也回执：前端因此只有一条"我通过了"的判定路径，
                // 不必再区分"本机调试不发 auth"和"局域网发了 auth"两种情形。
                self.enqueue(client, "{\"t\":\"auth_ok\"}")
            }
        }
        connection.start(queue: queue)
        receive(client)
    }

    private func isLoopback(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return false }
        switch host {
        case .ipv4(let address): return address.rawValue.withUnsafeBytes { $0.first == 127 }
        case .ipv6(let address): return address.rawValue.withUnsafeBytes { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }
        default: return false
        }
    }

    private func receive(_ client: Client) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, let context,
               context.protocolMetadata(definition: NWProtocolWebSocket.definition) is NWProtocolWebSocket.Metadata,
               let text = String(data: data, encoding: .utf8) {
                self.handle(text, from: client)
            }
            if error != nil {
                self.drop(client.id)
            } else if self.clients[client.id] != nil {
                self.receive(client)
            }
        }
    }

    private func handle(_ text: String, from client: Client) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["t"] as? String else { return }

        if type == "auth" {
            guard let token = object["token"] as? String, Auth.verify(token: token) else {
                drop(client.id); return
            }
            client.authenticated = true
            pointer.resetSession()
            // 手机此前只能靠 wsReady 猜自己通没通过鉴权；现在有明确回执，
            // 之后才知道该不该订阅鼠标、该不该把"已发送"说成"已生效"。
            enqueue(client, "{\"t\":\"auth_ok\"}")
            return
        }

        guard client.authenticated else { drop(client.id); return }

        if type == "cursor-subscribe" {
            client.cursorSubscribed = object["enabled"] as? Bool ?? false
            syncCursorSubscribers()
            return
        }

        pointer.handle(text)
    }

    // MARK: - 下行广播

    private func broadcastCursor(seq: UInt64, display: UInt32?, rx: Double, ry: Double) {
        let id = display.map { String($0) } ?? "null"
        let payload = String(format: "{\"t\":\"cursor\",\"seq\":%llu,\"displayId\":%@,\"rx\":%.4f,\"ry\":%.4f}",
                             seq, id, rx, ry)
        queue.async {
            for client in self.clients.values where client.authenticated && client.cursorSubscribed {
                self.enqueue(client, payload)
            }
        }
    }

    private func broadcastError(_ message: String) {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        let payload = "{\"t\":\"error\",\"message\":\"\(escaped)\"}"
        queue.async {
            for client in self.clients.values where client.authenticated { self.enqueue(client, payload) }
        }
    }

    private func enqueue(_ client: Client, _ text: String) {
        if client.sending {
            client.pending = text     // 旧状态直接覆盖：鼠标位置看最新一帧才有意义
            return
        }
        client.sending = true
        send(client, text)
    }

    private func send(_ client: Client, _ text: String) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "pocketdesk-send", metadata: [metadata])
        client.connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                               completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.clients[client.id] != nil else { return }
                guard error == nil else { self.drop(client.id); return }
                if let next = client.pending {
                    client.pending = nil
                    self.send(client, next)
                } else {
                    client.sending = false
                }
            }
        })
    }

    private func drop(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        // 断线必须释放该会话的拖动状态：否则左键卡在按下态，重连后一点就变成拖拽。
        pointer.resetSession()
        syncCursorSubscribers()
    }

    private func syncCursorSubscribers() {
        let count = clients.values.filter { $0.authenticated && $0.cursorSubscribed }.count
        cursor.setSubscribers(count)
    }
}
