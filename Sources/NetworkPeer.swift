/**
 * [INPUT]: 依赖 NWConnection 已建立路径的远端地址。
 * [OUTPUT]: 提供纯连接地址判定 isLocalPeer；不能据此豁免配对凭证或授予控制/画面权限。
 * [POS]: Sources 的网络地址辅助函数；浏览器请求信任由 HTTPRequestSecurity 独立校验。
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
