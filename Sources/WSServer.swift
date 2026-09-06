/**
 * [INPUT]: 依赖 Network 的 NWListener/NWConnection 与 NWProtocolWebSocket；消费 PointerExecutor 的手势执行。
 * [OUTPUT]: 对外提供 WSServer（触控板 WebSocket 通道 :46388 的监听、会话重置与消息转发）。
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
        pointer.resetSession() // 新会话：抬起可能残留的左键，防止点击失灵
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, let context,
               context.protocolMetadata(definition: NWProtocolWebSocket.definition) is NWProtocolWebSocket.Metadata,
               let text = String(data: data, encoding: .utf8) {
                self.pointer.handle(text)
            }
            if error == nil { self.receive(connection) } else { connection.cancel() }
        }
    }
}
