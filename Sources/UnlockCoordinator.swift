/**
 * [INPUT]: 依赖 CryptoKit 的 P256/SHA256、Foundation；消费 UnlockConfig/UnlockStateFile、UnlockCredentialStore、LockStateProviding、UnlockInputExecuting（LockScreenInput 适配）与 UnlockWebAuthn 验签。
 * [OUTPUT]: 验签通过后通过 onBeforeInput 请求亮屏，确认解锁后调用 onUnlocked；提供解锁挑战、配对、撤销与签名结果，保留输入边界的具体失败原因。
 * [POS]: Sources 的快捷解锁状态机；UnlockNativeHTTP 消费原生签名入口，UnlockPanel 消费配对与撤销入口；授权字段绑定本机挑战记录，保留旧 WebAuthn 协议实现但生产不启动 relay。
 * [NATIVE]: 原生签名使用独立协议域与凭据类型，共用一次性挑战、撤销和逐键授权执行。
 * [REVIEW]: 授权代际覆盖撤销、断线和密码删除；逐键核验凭据/用户/锁屏，签名封套保留原始字节，配对决定单独回执。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import CryptoKit
import Foundation

/// 锁屏输入执行器协议：生产实现是 LockScreenInput.shared（复用其串行/租约/布局校验边界，
/// 禁止另建普通键盘执行器），测试注入 mock。
protocol UnlockInputExecuting {
    func prepare(session: String) -> [String: Any]
    func submit(password: String, id: String, session: String, authorized: @escaping () -> Bool,
                completion: @escaping ([String: Any]) -> Void)
}

extension LockScreenInput: UnlockInputExecuting {}

/// 验证失败的机器可读分类（人话文案由调用方映射，避免测试断言字符串）。
enum UnlockVerificationFailure: String, Equatable {
    case disabled = "disabled"           // 功能未开启
    case unconfigured = "unconfigured"   // 未完成部署配置
    case noPassword = "no-password"      // 未保存系统密码
    case noCredential = "no-credential"  // 未配对任何凭据
    case notLocked = "not-locked"        // 电脑未锁屏
    case unknownState = "unknown-state"  // 锁屏状态未知，保守拒绝
    case noPendingChallenge = "no-challenge"
    case consumed = "consumed"           // 已消费（并发/重放）
    case expired = "expired"
    case epochChanged = "epoch-changed"  // 锁屏代际变化
    case sessionChanged = "session-changed"
    case generationChanged = "generation-changed"
    case unknownCredential = "unknown-credential"
    case unconfirmedCredential = "unconfirmed-credential"
    case revoked = "revoked"
    case verificationFailed = "verification-failed" // WebAuthn 验签（类型/挑战/origin/RP/UV/签名等）
    case prepareRejected = "prepare-rejected"        // 锁屏输入门禁拒绝（焦点/权限/布局）
    case submitFailed = "submit-failed"
}

struct UnlockPendingChallenge {
    let requestId: String
    let challenge: String       // base64url（32 字节随机）
    let lockEpoch: UInt64
    let sessionUserID: Int64?
    let authorizationEpoch: UInt64
    let generation: UInt64      // 出站连接代际
    let expiresAt: DispatchTime
    var nativeCredential: String? = nil
    var consumed: Bool = false
}

struct UnlockPairingSession {
    let pairId: String
    let challenge: String       // base64url（注册 challenge）
    let deviceKeyPoint: Data
    let expiresAt: DispatchTime
    var credentialId: String?   // 注册响应验证通过后填入
}

final class UnlockCoordinator {
    // 可注入依赖（测试用 mock；生产用默认值）
    let credentials: UnlockCredentialStore
    let lockState: LockStateProviding
    private let executor: UnlockInputExecuting
    private let clock: () -> DispatchTime

    private let configProvider: () -> UnlockConfig?
    private let mutex = NSLock()
    private var pending: [String: UnlockPendingChallenge] = [:]   // requestId -> challenge
    private var pairingSession: UnlockPairingSession?
    private var currentGeneration: UInt64 = 0
    private var authorizationEpoch: UInt64 = 0
    var onUnlocked: (() -> Void)?
    var onBeforeInput: (() -> Void)?
    var onPairingDecision: ((String, String, Bool) -> Void)?
    private var seq: UInt64 = 0
    private var bootID = UUID().uuidString
    private var lastUptime: TimeInterval = 0
    /// 单次输入互斥；撤销通过授权代际让执行器在下一键停止。
    private var executing = false
    /// 提交后轮询锁屏状态的节奏。
    static let postSubmitPollInterval: TimeInterval = 0.5
    static let postSubmitBudget: TimeInterval = 6

    init(credentials: UnlockCredentialStore, configProvider: @escaping () -> UnlockConfig?,
         lockState: LockStateProviding = LockStateMonitor.shared,
         executor: UnlockInputExecuting = LockScreenInput.shared,
         clock: @escaping () -> DispatchTime = DispatchTime.now) {
        self.credentials = credentials
        self.configProvider = configProvider
        self.lockState = lockState
        self.executor = executor
        self.clock = clock
    }

    // MARK: - 前置检查

    /// 功能可用性检查；返回失败原因（nil 表示可发起）。
    func readiness(native: Bool = false) -> UnlockVerificationFailure? {
        guard native || configProvider() != nil else { return .unconfigured }
        guard credentials.enabled else { return .disabled }
        guard credentials.hasPassword else { return .noPassword }
        guard credentials.credentials.contains(where: { $0.confirmed }) else { return .noCredential }
        return nil
    }

    /// relay 连接代际登记：断线重连推进代际，旧连接上的挑战授权闭包即失效。
    func setGeneration(_ generation: UInt64) {
        mutex.lock(); currentGeneration = generation; authorizationEpoch &+= 1; pending.removeAll(); mutex.unlock()
    }

    private func generation() -> UInt64 {
        mutex.lock(); defer { mutex.unlock() }
        return currentGeneration
    }

    private func currentAuthorizationEpoch() -> UInt64 {
        mutex.lock(); defer { mutex.unlock() }; return authorizationEpoch
    }

    func cancelAuthorization() { invalidatePending() }

    private func checkBoot() {
        // systemUptime 变小 ⇒ 经历了重启：boot 身份重生成，旧的状态签名自然不可信。
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime < lastUptime { bootID = UUID().uuidString }
        lastUptime = uptime
    }

    // MARK: - 解锁请求

    /// 收到解锁请求：登记挑战。挑战字段全部在此绑定，relay 只能携带 requestId。
    func handleUnlockRequest(requestId: String, nativeCredential: String? = nil) -> [String: Any] {
        if let failure = readiness(native: nativeCredential != nil) { return ["error": failure.rawValue] }
        let state = lockState.state
        guard state != "unknown" else { return ["error": UnlockVerificationFailure.unknownState.rawValue] }
        guard state == "locked" else { return ["error": UnlockVerificationFailure.notLocked.rawValue] }
        let challenge = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let encoded = Base64URL.encode(challenge)
        let record = UnlockPendingChallenge(requestId: requestId, challenge: encoded,
                                            lockEpoch: lockState.epoch,
                                            sessionUserID: lockState.sessionUserID,
                                            authorizationEpoch: currentAuthorizationEpoch(),
                                            generation: generation(),
                                            expiresAt: clock() + DispatchTimeInterval.seconds(30), nativeCredential: nativeCredential)
        mutex.lock()
        pending = pending.filter { !$0.value.consumed && $0.value.expiresAt >= clock() }
        guard pending.count < 64 else { mutex.unlock(); return ["error": "too-many-requests"] }
        // 同 requestId 的旧挑战（无论活没活）一律覆盖：新请求永远拿新挑战。
        pending[requestId] = record
        mutex.unlock()
        let config = configProvider() ?? UnlockConfig(origin: "", rpId: "", relayWSS: "")
        return ["challenge": encoded, "rpId": config.rpId, "expiresIn": 30]
    }

    /// 收到断言：验证 → 原子消费 → 执行输入 → 回报结果（带签名）。任何分支输入执行次数为零。
    func handleUnlockAssertion(requestId: String, credentialId: String, clientDataJSON: Data,
                               authenticatorData: Data, signature: Data,
                               completion: @escaping ([String: Any]) -> Void) {
        guard let config = configProvider() else { completion(["error": UnlockVerificationFailure.unconfigured.rawValue]); return }
        guard let record = credentials.credential(id: credentialId) else {
            completion(["error": UnlockVerificationFailure.unknownCredential.rawValue]); return
        }
        guard record.transport != "native-v1" else { completion(["error": "wrong-protocol"]); return }
        guard record.confirmed else { completion(["error": UnlockVerificationFailure.unconfirmedCredential.rawValue]); return }

        let challenge: String
        mutex.lock()
        guard var pendingRecord = pending[requestId] else {
            mutex.unlock(); completion(["error": UnlockVerificationFailure.noPendingChallenge.rawValue]); return
        }
        guard pendingRecord.nativeCredential == nil else { mutex.unlock(); completion(["error": "wrong-protocol"]); return }
        guard !pendingRecord.consumed else {
            mutex.unlock(); completion(["error": UnlockVerificationFailure.consumed.rawValue]); return
        }
        guard clock() <= pendingRecord.expiresAt else {
            pending[requestId] = nil; mutex.unlock()
            completion(["error": UnlockVerificationFailure.expired.rawValue]); return
        }
        // 消费即占用：后续并发/重放到不了输入层。
        pendingRecord.consumed = true
        pending[requestId] = pendingRecord
        challenge = pendingRecord.challenge
        mutex.unlock()

        let signCount: UInt32
        do {
            signCount = try UnlockWebAuthn.verifyAssertion(clientDataJSON: clientDataJSON,
                                                           authenticatorData: authenticatorData,
                                                           signature: signature,
                                                           challenge: challenge,
                                                           origin: config.origin, rpId: config.rpId,
                                                           credential: record)
        } catch let error as UnlockAuthError {
            completion(["error": UnlockVerificationFailure.verificationFailed.rawValue,
                        "reason": String(describing: error)])
            return
        } catch {
            completion(["error": UnlockVerificationFailure.verificationFailed.rawValue]); return
        }

        // 挑战被消费时锁屏代际已被绑定；此刻再核一次：代际变了（锁过又解）立即作废。
        guard lockState.epoch == pendingRecord.lockEpoch else {
            completion(["error": UnlockVerificationFailure.epochChanged.rawValue]); return
        }
        guard let userID = pendingRecord.sessionUserID, lockState.sessionUserID == userID else {
            completion(["error": UnlockVerificationFailure.sessionChanged.rawValue]); return
        }
        guard lockState.state == "locked" else {
            completion(["error": UnlockVerificationFailure.notLocked.rawValue]); return
        }

        // 凭据使用记录（公钥数据，可写）。
        credentials.state.mutate { s in
            if let i = s.credentials.firstIndex(where: { $0.credentialId == credentialId }) {
                s.credentials[i].lastUsedAt = Date().timeIntervalSince1970
                if s.credentials[i].signCount > 0 || signCount > 0 { s.credentials[i].signCount = signCount }
            }
        }

        executeInput(requestId: requestId, record: pendingRecord, credentialId: credentialId, completion: completion)
    }

    /// 验签通过后的执行段。密码在此处解出并立刻交给执行器，提交收尾即弃，不得记录或暂存。
    private func executeInput(requestId: String, record: UnlockPendingChallenge, credentialId: String,
                              connected: @escaping () -> Bool = { true }, completion: @escaping ([String: Any]) -> Void) {
        mutex.lock()
        guard !executing else { mutex.unlock(); completion(["error": UnlockVerificationFailure.consumed.rawValue]); return }
        executing = true
        mutex.unlock()
        defer { mutex.lock(); executing = false; mutex.unlock() }
        onBeforeInput?()
        var inputFailure: String?

        // ① 取密码 → prepare → submit（同步等待执行器收尾）。授权闭包在每次按键前被复查：
        //   连接代际、功能开关任一变化立即停手。密码字符串只在本闭包存活。
        //   外层 nil = 没有密码；内层 nil = prepare 门禁拒绝；Bool = submit 的 sent 标志。
        let submitOutcome: Bool?? = credentials.withPassword { password -> Bool? in
            let session = UUID().uuidString
            let prepared = self.executor.prepare(session: session)
            guard let challengeId = prepared["challenge"] as? String else {
                inputFailure = prepared["error"] as? String; return nil
            }
            var result: [String: Any]?
            let done = DispatchSemaphore(value: 0)
            self.executor.submit(password: password, id: challengeId, session: session,
                                 authorized: { [weak self] in
                                    guard let self else { return false }
                                    return connected() && self.generation() == record.generation && self.credentials.enabled
                                        && self.currentAuthorizationEpoch() == record.authorizationEpoch
                                        && self.credentials.credential(id: credentialId)?.confirmed == true
                                        && self.lockState.epoch == record.lockEpoch
                                        && self.lockState.sessionUserID == record.sessionUserID
                                        && self.lockState.state == "locked"
                                        && self.clock() <= record.expiresAt
                                 }) { outcome in
                result = outcome
                done.signal()
            }
            done.wait()
            inputFailure = result?["error"] as? String
            return result?["sent"] as? Bool ?? false
        }
        switch submitOutcome {
        case .none:
            completion(signResult(requestId: requestId, payload: ["outcome": "failed",
                        "detail": "无法读取钥匙串中的登录密码。请在电脑网页点击“检查并授权钥匙串”，完成系统授权后重试。", "error": "keychain-unavailable"]))
            return
        case .some(.none):
            completion(signResult(requestId: requestId, payload: ["outcome": "failed",
                        "detail": inputFailure ?? "电脑端输入门禁未通过，未输入任何字符。",
                        "error": UnlockVerificationFailure.prepareRejected.rawValue]))
            return
        case .some(.some(true)):
            break
        case .some(.some(false)):
            completion(signResult(requestId: requestId, payload: ["outcome": "failed",
                        "detail": inputFailure ?? "输入执行未完成，已停止；不会自动重试。",
                        "error": UnlockVerificationFailure.submitFailed.rawValue]))
            return
        }
        // ② sent 只是"发出去了"；解锁与否以提交后的锁屏状态为准（超时只说未确认）。
        let outcome = postSubmitOutcome(after: true)
        if outcome == "unlocked" { onUnlocked?() }
        let detail: String
        switch outcome {
        case "unlocked": detail = onUnlocked == nil ? "电脑已解锁。" : "电脑已解锁，已请求点亮屏幕。"
        case "unconfirmed": detail = "已提交密码但未确认解锁，请检查电脑。"
        default: detail = "已提交密码，无法确认电脑状态。"
        }
        completion(signResult(requestId: requestId, payload: ["outcome": outcome, "detail": detail]))
    }

    /// sent 之后轮询锁屏状态：立刻解锁 → unlocked；超时仍锁 → unconfirmed（不武断说密码错）。
    func postSubmitOutcome(after submitted: Bool) -> String {
        guard submitted else { return "unconfirmed" }
        let deadline = Date().addingTimeInterval(Self.postSubmitBudget)
        while Date() < deadline {
            let state = lockState.state
            if state == "unlocked" { return "unlocked" }
            Thread.sleep(forTimeInterval: Self.postSubmitPollInterval)
        }
        return lockState.state == "unlocked" ? "unlocked" : "unconfirmed"
    }

    // MARK: - 配对

    /// 面板发起配对：同一时刻最多一个会话。
    func beginPairing(native: Bool = false) -> [String: Any] {
        guard native || configProvider() != nil else { return ["error": UnlockVerificationFailure.unconfigured.rawValue] }
        guard let keyPoint = credentials.devicePublicKeyPoint, credentials.deviceKey() != nil else {
            return ["error": "device-key-unavailable"]
        }
        mutex.lock()
        defer { mutex.unlock() }
        if !native, let existing = pairingSession, clock() <= existing.expiresAt {
            return ["pairId": existing.pairId, "challenge": existing.challenge]
        }
        if let old = pairingSession?.credentialId, credentials.credential(id: old)?.confirmed == false {
            credentials.revokeCredential(id: old)
        }
        let session = UnlockPairingSession(pairId: Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) })),
                                           challenge: Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) })),
                                           deviceKeyPoint: keyPoint,
                                           expiresAt: clock() + DispatchTimeInterval.seconds(300),
                                           credentialId: nil)
        pairingSession = session
        return ["pairId": session.pairId, "challenge": session.challenge]
    }

    /// 注册响应验证：Mac 独立验签并登记未确认凭据，返回核对码（面板显示）。
    func handlePairingRegister(pairId: String, clientDataJSON: Data, attestationObject: Data) -> [String: Any] {
        guard let config = configProvider() else { return ["error": UnlockVerificationFailure.unconfigured.rawValue] }
        mutex.lock()
        defer { mutex.unlock() }
        let session = pairingSession
        guard let session, session.pairId == pairId, session.credentialId == nil, clock() <= session.expiresAt else {
            return ["error": "pairing-session-invalid"]
        }
        do {
            let result = try UnlockWebAuthn.verifyRegistration(clientDataJSON: clientDataJSON,
                                                               attestationObject: attestationObject,
                                                               challenge: session.challenge,
                                                               origin: config.origin, rpId: config.rpId)
            let label = "解锁设备 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            let record = UnlockCredentialRecord(credentialId: result.credentialId,
                                                publicKey: Base64URL.encode(result.publicKeyPoint),
                                                label: label, createdAt: Date().timeIntervalSince1970,
                                                lastUsedAt: nil, signCount: result.signCount,
                                                confirmed: false, transport: "synced")
            credentials.upsertCredential(record)
            // credentialId 绑回配对会话：确认/拒绝动作据此处置这条凭据。
            pairingSession?.credentialId = result.credentialId
            let code = Self.pairingCode(devicePoint: session.deviceKeyPoint,
                                        credentialPoint: result.publicKeyPoint,
                                        challenge: Base64URL.decode(session.challenge) ?? Data())
            return ["code": code, "credentialId": result.credentialId]
        } catch let error as UnlockAuthError {
            return ["error": "registration-\(error)"]
        } catch {
            return ["error": "registration-failed"]
        }
    }

    /// 配对核对码：由双方实际登记的公钥、设备身份与会话 challenge 推导（非 relay 生成）。
    /// SHA-256 前 4 字节 mod 1e7 → 7 位十进制。
    static func pairingCode(devicePoint: Data, credentialPoint: Data, challenge: Data) -> String {
        var material = Data("PocketDesk-QuickUnlock-Pair-v1".utf8)
        material.append(devicePoint)
        material.append(credentialPoint)
        material.append(challenge)
        let digest = SHA256.hash(data: material)
        var value: UInt32 = 0
        for b in digest.prefix(4) { value = (value << 8) | UInt32(b) }
        return String(format: "%07d", value % 10_000_000)
    }

    /// 用户在面板确认：登记的凭据转正。
    func confirmPairing(pairId: String) -> Bool {
        mutex.lock()
        guard let session = pairingSession, session.pairId == pairId,
              clock() <= session.expiresAt, let credentialId = session.credentialId else {
            mutex.unlock(); return false
        }
        pairingSession = nil
        let confirmed = credentials.confirmCredential(id: credentialId)
        mutex.unlock()
        onPairingDecision?(pairId, credentialId, confirmed)
        return confirmed
    }

    /// 拒绝/放弃：未确认凭据直接删除。
    func denyPairing(pairId: String) {
        mutex.lock()
        let session = pairingSession
        guard session?.pairId == pairId else { mutex.unlock(); return }
        pairingSession = nil
        mutex.unlock()
        if let credentialId = session?.credentialId {
            credentials.revokeCredential(id: credentialId)
            onPairingDecision?(pairId, credentialId, false)
        }
    }

    /// relay 转发的注册（带配对 token 换来的浏览器会话）最终落到这里。
    func attachRegistration(pairId: String, credentialId: String) {
        mutex.lock()
        defer { mutex.unlock() }
        guard let session = pairingSession, session.pairId == pairId else { return }
        pairingSession = UnlockPairingSession(pairId: session.pairId, challenge: session.challenge,
                                              deviceKeyPoint: session.deviceKeyPoint,
                                              expiresAt: session.expiresAt,
                                              credentialId: credentialId)
    }

    // MARK: - 撤销与关闭

    func revokeCredential(id: String) {
        credentials.revokeCredential(id: id)
        invalidatePending()
    }

    func revokeAll() {
        credentials.revokeAllCredentials()
        invalidatePending()
    }

    func disable() {
        credentials.enabled = false
        invalidatePending()
    }

    private func invalidatePending() {
        mutex.lock(); authorizationEpoch &+= 1; pending.removeAll(); mutex.unlock()
    }

    // MARK: - 签名状态与结果

    private func canonical(_ payload: [String: Any]) -> Data? {
        (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    }

    func signPayload(_ payload: [String: Any]) -> (payload: [String: Any], signature: String?)? {
        guard let key = credentials.deviceKey() else { return nil }
        mutex.lock()
        checkBoot()
        seq &+= 1
        let withSeq = payload.merging(["v": 1, "seq": Int(seq), "boot": bootID,
                                       "ts": Date().timeIntervalSince1970]) { _, new in new }
        mutex.unlock()
        guard let bytes = canonical(withSeq), let sig = try? key.signature(for: bytes) else { return nil }
        var envelope = withSeq
        envelope["signedData"] = Base64URL.encode(bytes)
        return (envelope, Base64URL.encode(Data(sig.derRepresentation)))
    }

    /// 锁屏状态广播：payload 由手机端用配对确认的设备公钥验签。
    func statusBroadcast(nonce: String = "") -> (payload: [String: Any], signature: String)? {
        guard let signed = signPayload(["kind": "state", "state": lockState.state,
                                        "epoch": Int(lockState.epoch), "nonce": nonce]) else { return nil }
        guard signed.signature != nil else { return nil }
        return (signed.payload, signed.signature!)
    }

    /// 解锁结果签名（requestId 绑定）。
    func signResult(requestId: String, payload: [String: Any]) -> [String: Any] {
        let base = payload.merging(["kind": "unlock-result", "requestId": requestId]) { _, new in new }
        guard let signed = signPayload(base), let sig = signed.signature else { return base }
        var out = signed.payload
        out["sig"] = sig
        out["deviceKey"] = Base64URL.encode(credentials.devicePublicKeyPoint ?? Data())
        return out
    }
}

// MARK: - 原生直连协议（不伪装 WebAuthn；只共享本机输入边界）
extension UnlockCoordinator {
    static func nativeMessage(action: String, request: String, challenge: String, credential: String) -> Data {
        Data("PocketDesk-Native-v1\n\(action)\n\(request)\n\(challenge)\n\(credential)".utf8)
    }

    func registerNative(pairId: String, publicKey: Data, signature: Data, label: String) -> [String: Any] {
        mutex.lock(); defer { mutex.unlock() }
        guard credentials.enabled, let session = pairingSession, session.pairId == pairId,
              session.credentialId == nil, clock() <= session.expiresAt,
              let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let proof = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              key.isValidSignature(proof, for: Self.nativeMessage(action: "pair", request: pairId,
                  challenge: session.challenge, credential: Base64URL.encode(publicKey))) else {
            return ["error": "pairing-session-invalid"]
        }
        let id = Base64URL.encode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        credentials.upsertCredential(UnlockCredentialRecord(credentialId: id, publicKey: Base64URL.encode(publicKey),
            label: String(label.prefix(60)), createdAt: Date().timeIntervalSince1970, lastUsedAt: nil,
            signCount: 0, confirmed: false, transport: "native-v1"))
        pairingSession?.credentialId = id
        let code = Self.pairingCode(devicePoint: session.deviceKeyPoint, credentialPoint: publicKey,
                                   challenge: Base64URL.decode(session.challenge) ?? Data())
        return ["credentialId": id, "code": code]
    }

    func handleNativeAssertion(requestId: String, credentialId: String, signature: Data,
                               connected: @escaping () -> Bool = { true },
                               completion: @escaping ([String: Any]) -> Void) {
        guard readiness(native: true) == nil,
              let credential = credentials.credential(id: credentialId), credential.confirmed,
              credential.transport == "native-v1" else { completion(["error": "unauthorized"]); return }
        mutex.lock()
        guard var record = pending[requestId], record.nativeCredential == credentialId,
              !record.consumed, clock() <= record.expiresAt else {
            mutex.unlock(); completion(["error": "no-challenge"]); return
        }
        record.consumed = true; pending[requestId] = record
        mutex.unlock()
        guard let point = Base64URL.decode(credential.publicKey),
              let key = try? P256.Signing.PublicKey(x963Representation: point),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature),
              key.isValidSignature(sig, for: Self.nativeMessage(action: "unlock", request: requestId,
                  challenge: record.challenge, credential: credentialId)),
              let uid = record.sessionUserID, lockState.sessionUserID == uid,
              lockState.epoch == record.lockEpoch, lockState.state == "locked",
              currentAuthorizationEpoch() == record.authorizationEpoch,
              generation() == record.generation, connected() else {
            completion(["error": "verification-failed"]); return
        }
        executeInput(requestId: requestId, record: record, credentialId: credentialId,
                     connected: connected, completion: completion)
    }
}
