/**
 * [INPUT]: 依赖 Network 的 NWListener/NWConnection 与 NWProtocolWebSocket；消费 PointerExecutor 的手势执行与 Auth 的 token 校验。
 * [OUTPUT]: 对外提供 WSServer（触控板 WebSocket 通道 :46388 的监听、首帧 token 鉴权、会话重置与消息转发）。
 * [POS]: Sources 的触控板传输层；只管连接与转发，与 Server（HTTP）平行为一对传输兄弟。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Network

// MARK: - 触控板 WebSocket 服务

final class WSServer {
    private let port: UInt16
    private let pointer: PointerExecutor
    private let queue = DispatchQueue(label: "dev.voicedeck.ws")
    private var listener: NWListener?

    init(port: UInt16, pointer: PointerExecutor) {
        self.port = port
        self.pointer = pointer
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
        if loopback { pointer.resetSession() }
        connection.start(queue: queue)
        receive(connection, authenticated: loopback)
    }

    private func isLoopback(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return false }
        switch host {
        case .ipv4(let address): return address.rawValue.withUnsafeBytes { $0.first == 127 }
        case .ipv6(let address): return address.rawValue.withUnsafeBytes { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }
        default: return false
        }
    }

    private func receive(_ connection: NWConnection, authenticated: Bool) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, let context,
               context.protocolMetadata(definition: NWProtocolWebSocket.definition) is NWProtocolWebSocket.Metadata,
               let text = String(data: data, encoding: .utf8) {
                if authenticated {
                    self.pointer.handle(text)
                } else if let token = self.extractAuth(from: text) {
                    if Auth.verify(token: token) {
                        pointer.resetSession()
                        self.receive(connection, authenticated: true)
                        return
                    } else {
                        connection.cancel(); return
                    }
                } else {
                    connection.cancel(); return
                }
            }
            if error == nil { self.receive(connection, authenticated: authenticated) } else { connection.cancel() }
        }
    }

    private func extractAuth(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["t"] as? String == "auth" else { return nil }
        return object["token"] as? String
    }
}
