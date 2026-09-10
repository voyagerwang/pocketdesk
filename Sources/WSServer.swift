/**
 * [INPUT]: 依赖 Network WebSocket、Auth、PointerExecutor 和 CursorMonitor。
 * [OUTPUT]: 提供控制所有权、心跳租约、能力握手、可靠回复和 latest-only 光标广播。
 * 安全边界：锁屏密码仅走 HTTPS 专用执行器，普通输入在锁屏时受阻；安全监听共享原控制租约。
 * [POS]: Sources 控制传输边界；观看者不重置控制者，断线只释放所属按键。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Network

final class WSServer {
    private let port: UInt16
    private let pointer: PointerExecutor
    private let cursor: CursorMonitor
    private let queue = DispatchQueue(label: "dev.voicedeck.ws")
    private var listener: NWListener?
    private var secureListener: NWListener?
    private var timer: DispatchSourceTimer?
    private var clients: [UUID: Client] = [:]
    private var owner: UUID?
    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var authenticated = false
        var subscribed = false
        var modern = false
        var sequence = -1
        var lastSeen = ProcessInfo.processInfo.systemUptime
        var sending = false
        var reliable: [String] = []
        var cursor: String?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    init(port: UInt16, pointer: PointerExecutor, cursor: CursorMonitor) {
        self.port = port; self.pointer = pointer; self.cursor = cursor
        cursor.onSample = { [weak self] seq, display, rx, ry in
            guard let self else { return }
            self.queue.async {
                let body: [String: Any] = ["t": "cursor", "seq": seq, "displayId": display as Any? ?? NSNull(), "rx": rx, "ry": ry]
                for c in self.clients.values where c.authenticated && c.subscribed { self.enqueue(c, body, latest: true) }
            }
        }
        pointer.onError = { [weak self] message in
            guard let self else { return }
            self.queue.async { if let id = self.owner, let c = self.clients[id] { self.enqueue(c, ["t": "error", "message": message]) } }
        }
    }
    // 供 HTTP 输入在执行队列落键前验证；调用者不能位于本服务队列。
    func isController(_ session: String) -> Bool {
        queue.sync {
            guard let id = UUID(uuidString: session), owner == id, let c = clients[id], c.authenticated else { return false }
            return !c.modern || ProcessInfo.processInfo.systemUptime - c.lastSeen < 2
        }
    }
    func start() throws {
        let p = NWParameters.tcp
        let options = NWProtocolWebSocket.Options(); options.autoReplyPing = true
        p.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let listener = try NWListener(using: p, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        self.listener = listener; listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            for c in Array(self.clients.values) where (!c.authenticated || c.modern) && now - c.lastSeen > 2 { self.drop(c.id) }
        }
        self.timer = timer; timer.resume()
    }
    func startSecure(_ transport: SecureTransport) throws {
        let parameters = transport.parameters()
        let options = NWProtocolWebSocket.Options(); options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let server = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: SecureTransport.port + 1)!)
        server.newConnectionHandler = listener?.newConnectionHandler
        secureListener = server; server.start(queue: queue)
    }
    private func accept(_ connection: NWConnection) {
        let c = Client(connection); clients[c.id] = c
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.drop(c.id) }
            if case .cancelled = state { self?.drop(c.id) }
        }
        connection.start(queue: queue); receive(c)
    }
    private func receive(_ c: Client) {
        c.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.clients[c.id] != nil else { return }
            if let data, data.count <= 16384, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { self.handle(body, c) }
            if error != nil { self.drop(c.id) }
            else if self.clients[c.id] != nil { self.receive(c) }
        }
    }
    private func handle(_ body: [String: Any], _ c: Client) {
        let type = body["t"] as? String ?? ""
        if type == "auth" {
            guard let token = body["token"] as? String, (Auth.verify(token: token) || isLocalPeer(c.connection)) else { drop(c.id); return }
            c.authenticated = true; c.modern = body["v"] as? Int == 1
            c.lastSeen = ProcessInfo.processInfo.systemUptime
            if owner == nil { owner = c.id; pointer.resetSession() }
            enqueue(c, ["t": "auth_ok", "session": c.id.uuidString, "controller": owner == c.id,
                        "absolutePointerV1": true, "doubleClickMs": NSEvent.doubleClickInterval * 1000])
            return
        }
        guard c.authenticated else { drop(c.id); return }
        c.lastSeen = ProcessInfo.processInfo.systemUptime
        if type == "heartbeat" { return }
        if type == "cursor-subscribe" { c.subscribed = body["enabled"] as? Bool == true; syncSubscribers(); return }
        if type == "take-control" {
            LockScreenInput.shared.cancel()
            pointer.resetSession(); owner = c.id
            for client in clients.values where client.authenticated { enqueue(client, ["t": "control", "controller": client.id == owner]) }
            return
        }
        guard owner == c.id else { enqueue(c, ["t": "error", "message": "另一台手机正在控制，请先接管。"]); return }
        if c.modern {
            guard body["session"] as? String == c.id.uuidString, let seq = body["seq"] as? Int, seq > c.sequence else { return }
            c.sequence = seq
        }
        if type == "cancel" { pointer.resetSession(); return }
        guard !LockScreenInput.locked else { enqueue(c, ["t": "error", "message": "电脑已锁屏，请使用解锁入口。"]); return }
        guard AXIsProcessTrusted() else { enqueue(c, ["t": "error", "message": "请在电脑上允许辅助功能后操作。"]); return }
        if let data = try? JSONSerialization.data(withJSONObject: body), let text = String(data: data, encoding: .utf8) { pointer.handle(text) }
    }
    private func enqueue(_ c: Client, _ body: [String: Any], latest: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: body), let text = String(data: data, encoding: .utf8) else { return }
        if latest { c.cursor = text }
        else {
            guard c.reliable.count < 64 else { drop(c.id); return }
            c.reliable.append(text)
        }
        drain(c)
    }
    private func drain(_ c: Client) {
        guard !c.sending else { return }
        let next: String?
        if !c.reliable.isEmpty { next = c.reliable.removeFirst() }
        else { next = c.cursor; c.cursor = nil }
        guard let next else { return }
        c.sending = true
        let context = NWConnection.ContentContext(identifier: "control", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        c.connection.send(content: Data(next.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.clients[c.id] != nil else { return }
                if error != nil { self.drop(c.id); return }
                c.sending = false; self.drain(c)
            }
        })
    }
    private func drop(_ id: UUID) {
        guard let c = clients.removeValue(forKey: id) else { return }
        c.connection.stateUpdateHandler = nil
        c.connection.cancel()
        if owner == id {
            LockScreenInput.shared.cancel()
            owner = nil; pointer.resetSession()
            for client in clients.values where client.authenticated { enqueue(client, ["t": "control", "controller": false]) }
        }
        syncSubscribers()
    }
    private func syncSubscribers() { cursor.setSubscribers(clients.values.filter { $0.authenticated && $0.subscribed }.count) }
}
