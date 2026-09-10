/**
 * [INPUT]: 依赖 Network WebSocket、Auth 与 ScreenStream 的独立 JPEG 帧。
 * [OUTPUT]: 提供鉴权画面服务；共享同屏同画质捕获器，每客户端仅一帧在途，呈现 ACK 后发送最新帧。
 * 安全边界：锁屏密码仅走 HTTPS 专用执行器，普通输入在锁屏时受阻；安全监听共享原控制租约。
 * [POS]: Sources 的画面传输边界；大包不经过控制连接，超时关闭而不堆积 TCP 旧画面。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Network
import CoreMedia

@available(macOS 14.0, *)
final class FrameServer: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "dev.voicedeck.frames")
    private var listener: NWListener?
    private var secureListener: NWListener?
    private var timer: DispatchSourceTimer?
    private var clients: [UUID: Client] = [:]
    private var streams: [String: ScreenStream] = [:]
    private var sequence: UInt64 = 0
    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var key: String?
        var display: UInt32 = 0
        var pending: ScreenStream.Frame?
        var inFlight: UInt64?
        var deadline = ProcessInfo.processInfo.systemUptime + 3
        init(_ connection: NWConnection) { self.connection = connection }
    }
    init(port: UInt16) { self.port = port }
    func start() throws {
        let p = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options(); ws.autoReplyPing = true
        p.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: p, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let c = Client(connection); self.clients[c.id] = c
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.drop(c.id) }
                if case .cancelled = state { self?.drop(c.id) }
            }
            connection.start(queue: self.queue); self.receive(c)
        }
        self.listener = listener; listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for c in Array(self.clients.values) where (c.key == nil || c.inFlight != nil) && ProcessInfo.processInfo.systemUptime > c.deadline { self.drop(c.id) }
        }
        self.timer = timer; timer.resume()
    }
    func startSecure(_ transport: SecureTransport) throws {
        let parameters = transport.parameters()
        let options = NWProtocolWebSocket.Options(); options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let server = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: SecureTransport.port + 2)!)
        server.newConnectionHandler = listener?.newConnectionHandler
        secureListener = server; server.start(queue: queue)
    }
    private func receive(_ c: Client) {
        c.connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.clients[c.id] != nil else { return }
            if let data, data.count < 4096, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if c.key == nil {
                    guard body["t"] as? String == "watch", let token = body["token"] as? String, (Auth.verify(token: token) || isLocalPeer(c.connection)),
                          let display = body["display"] as? UInt32 else { self.drop(c.id); return }
                    self.watch(c, display: display, width: body["width"] as? Int == 1920 ? 1920 : 1280)
                } else if body["t"] as? String == "presented", let seq = body["frameId"] as? UInt64, seq == c.inFlight {
                    c.inFlight = nil; self.drain(c)
                }
            }
            if error != nil { self.drop(c.id) } else if self.clients[c.id] != nil { self.receive(c) }
        }
    }
    private func watch(_ c: Client, display: UInt32, width: Int) {
        let key = "\(display):\(width)"
        c.key = key; c.display = display
        if streams[key] != nil { return }
        let stream = ScreenStream(); streams[key] = stream
        stream.onFrame = { [weak self, weak stream] frame in
            guard let self else { return }
            self.queue.async {
                guard let stream, self.streams[key] === stream else { return }
                for client in self.clients.values where client.key == key { client.pending = frame; self.drain(client) }
            }
        }
        stream.onFailure = { [weak self, weak stream] _ in
            guard let self else { return }
            self.queue.async {
                guard let stream, self.streams[key] === stream else { return }
                for client in Array(self.clients.values) where client.key == key { self.drop(client.id) }
            }
        }
        Task {
            do { try await stream.start(displayID: display, width: width) }
            catch { self.queue.async { guard self.streams[key] === stream else { return }; for client in Array(self.clients.values) where client.key == key { self.drop(client.id) } } }
        }
    }
    private func drain(_ c: Client) {
        guard c.inFlight == nil, let frame = c.pending else { return }
        c.pending = nil
        let age = max(0, CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - frame.captured)
        guard age < 1.5 else { return }
        sequence &+= 1; c.inFlight = sequence; c.deadline = ProcessInfo.processInfo.systemUptime + 2
        let header: [String: Any] = ["frameId": sequence, "epoch": c.id.uuidString, "display": c.display,
            "width": frame.width, "height": frame.height, "cursorIncluded": false, "ageMs": age * 1000]
        guard let json = try? JSONSerialization.data(withJSONObject: header) else { return }
        var length = UInt32(json.count).bigEndian
        var packet = Data(bytes: &length, count: 4); packet.append(json); packet.append(frame.jpeg)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        c.connection.send(content: packet, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.queue.async { self?.drop(c.id) } }
        })
    }
    private func drop(_ id: UUID) {
        guard let c = clients.removeValue(forKey: id) else { return }
        c.connection.stateUpdateHandler = nil
        c.connection.cancel()
        if let key = c.key, !clients.values.contains(where: { $0.key == key }) { streams.removeValue(forKey: key)?.stop() }
    }
}
