/**
 * [INPUT]: 依赖 NWConnection 已建立路径的远端地址。
 * [OUTPUT]: 提供 isLocalPeer，供控制/画面连接保持本机调试豁免，非回环仍需 token。
 * [POS]: Sources 的网络地址判定，不接受客户端自报主机名。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Network
func isLocalPeer(_ connection: NWConnection) -> Bool {
    guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint else { return false }
    switch host {
    case .ipv4(let address): return address.rawValue.first == 127
    case .ipv6(let address): return address.rawValue.dropLast().allSatisfy { $0 == 0 } && address.rawValue.last == 1
    default: return false
    }
}
