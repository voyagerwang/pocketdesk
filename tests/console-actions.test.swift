/**
 * [INPUT]: 本机操作适配器、原生协议与内存凭据，所有文件/二维码依赖为隔离替身。
 * [OUTPUT]: 回环/Host/Origin/CSRF边界，密码不回传、开关/删除、二维码注册确认与过期请求拒绝。
 * [POS]: 不读真实密码、不执行输入、不打开系统选择器。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CryptoKit
final class UnreadableSecrets: UnlockSecretStore {
    var writes = 0
    func save(_ data: Data, service: String) throws { writes += 1 }
    func load(service: String) -> Data? { nil }
    func contains(service: String) -> Bool { true }
    func authorize(service: String) -> Bool { true }
    func delete(service: String) {}
}
enum Util { static func primaryLANAddress() -> String? { "192.168.1.2" }; static func qrPNG(_ text: String) -> Data? { Data([1,2,3]) } }
enum SecureTransport { static let port: UInt16 = 46487; static var directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
final class PhoneFileStore {
    struct Offer { var json: [String: Any] { [:] } }
    static let shared = PhoneFileStore(); static let subject = "fixture"
    func list(subject: String) -> [Offer] { [] }
}
final class PhoneFilePicker { static let shared = PhoneFilePicker(); func presentPicker(completion: @escaping ([String: Any]) -> Void) { completion(["cancelled": true]) } }
final class ConsoleLock: LockStateProviding { var state = "locked"; var epoch: UInt64 = 1; var sessionUserID: Int64? = 501 }
final class ConsoleNoInput: UnlockInputExecuting {
    func prepare(session: String) -> [String: Any] { fatalError("must never input") }
    func submit(password: String, id: String, session: String, authorized: @escaping () -> Bool, completion: @escaping ([String: Any]) -> Void) { fatalError("must never input") }
}
@main enum ConsoleActionsTest {
 static func main() throws {
    var failures = 0
    func check(_ ok: Bool, _ label: String) { print("\(ok ? "PASS" : "FAIL") \(label)"); if !ok { failures += 1 } }
    func allowed(_ loopback: Bool = true, _ method: String = "POST", _ host: String = "127.0.0.1:46387", _ origin: String? = "http://127.0.0.1:46387", _ marker: String? = "1") -> Bool {
        ConsoleActions.allowed(loopback: loopback, method: method, host: host, origin: origin, marker: marker, contentType: "application/json", port: 46387, secure: false)
    }
    check(allowed(), "same-origin local write")
    check(!allowed(false) && !allowed(true,"POST","evil.example:46387"), "reject LAN and DNS rebind")
    check(!allowed(true,"POST","127.0.0.1:46387","https://evil.example") && !allowed(true,"POST","127.0.0.1:46387",nil), "reject foreign or missing Origin")
    check(!allowed(true,"POST","127.0.0.1:46387","http://127.0.0.1:46387",nil), "require console marker")
    check(!allowed(true,"OPTIONS") && allowed(true,"GET","127.0.0.1:46387",nil), "GET local and no CORS preflight")
    let directory = SecureTransport.directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([1,2]).write(to: directory.appendingPathComponent("server-cert.der"))
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UnlockCredentialStore(secrets: MemorySecretStore(), state: UnlockStateFile(directory: directory))
    let unreadable = UnreadableSecrets()
    let blockedStore = UnlockCredentialStore(secrets: unreadable, state: UnlockStateFile(directory: directory))
    check(!blockedStore.authorizeKeychain(), "one-time interactive approval is insufficient without background read")
    check(blockedStore.deviceKey() == nil && unreadable.writes == 0, "unreadable identity never replaced")
    let coordinator = UnlockCoordinator(credentials: store, configProvider: { nil }, lockState: ConsoleLock(), executor: ConsoleNoInput())
    let native = UnlockNativeHTTP(coordinator: coordinator)
    let actions = ConsoleActions(coordinator: coordinator, native: native, configured: { true }, isLocked: { false })
    func request(_ action: String, _ body: [String: Any] = [:], method: String = "POST") throws -> (Int,[String: Any]) {
        let done = DispatchSemaphore(value: 0); var result = (0, [String: Any]())
        actions.handle(method: method, path: "/api/console/unlock" + action, body: try JSONSerialization.data(withJSONObject: body)) { result = ($0,$1); done.signal() }
        guard done.wait(timeout: .now()+5) == .success else { fatalError("timeout") }; return result
    }
    check(try request("/enabled",["enabled":true]).0 == 422, "cannot enable before password")
    let saved = try request("/password",["password":"fixture-secret"])
    check(saved.0 == 200 && store.hasPassword && !String(describing: saved.1).contains("fixture-secret"), "password saves without echo")
    check(try request("/enabled",["enabled":true]).1["enabled"] as? Bool == true, "enable")
    let pairing = try request("/pair").1["pair"] as! [String: Any]
    let access = try request("/keychain-authorize")
    check(access.0 == 200 && !String(describing: access.1).contains("fixture-secret"), "keychain authorization returns no secrets")
    let link = pairing["link"] as! String
    let offer = try JSONSerialization.jsonObject(with: Base64URL.decode(String(link.split(separator:"#")[1]))!) as! [String: Any]
    let phone = P256.Signing.PrivateKey(), id = offer["pairId"] as! String
    let point = phone.publicKey.x963Representation
    let sig = try phone.signature(for: UnlockCoordinator.nativeMessage(action:"pair",request:id,challenge:offer["challenge"] as! String,credential:Base64URL.encode(point))).derRepresentation
    let registered = coordinator.registerNative(pairId:id,publicKey:point,signature:sig,label:"Test phone")
    native.onPairingCode?(registered["code"] as! String,id)
    check(try request("",method:"GET").1["pair"] != nil, "pairing state visible")
    check(try request("/confirm",["pairId":id]).0 == 200 && store.credentials.first?.confirmed == true, "web confirmation authorizes exact pending phone")
    check(try request("/confirm",["pairId":id]).0 == 409, "confirmation cannot replay")
    _ = try request("/revoke",["id":registered["credentialId"] as! String])
    check(store.credentials.isEmpty, "revoke")
    _ = try request("/password/delete")
    check(!store.hasPassword && !store.enabled, "delete disables and removes password")
    exit(failures == 0 ? 0 : 1)
 }
}
