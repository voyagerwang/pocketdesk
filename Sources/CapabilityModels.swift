/**
 * [INPUT]: 冻结包 A-protocol-v1-r2 的 protocols/unified-assistant/v1/unified-assistant-v1.schema.json
 *         （唯一 wire contract，schema SHA-256 f057f017…31910）与 fixtures/manifest.json（66 case，
 *         与 TS 校验器共用）；运行时模型不读取磁盘文件或环境变量。
 * [OUTPUT]: 统一小精灵能力协议 v1 的 Swift 落点：JSON 值层（自有属性语义、布尔/数字区分）、五类 wire
 *         对象（CapabilityDefinition/AdapterBinding/ReadinessObservation/CapabilityInvocation/
 *         CapabilityReceipt）与 Evidence/Artifact/ReceiptError 的 Codable 词汇表、严格语义校验
 *         （validateCapability* 系列，错误带 schema 关键字：type/const/enum/required/
 *         additionalProperties/minItems/minimum/format/contains/not）、agentTaskId/attempt 轮次配对、
 *         回执与调用的归属核验 validateReceipt(_:againstInvocation:)、readiness 局部可用性检查
 *         isReadinessObservationUsable、schema 漂移守卫 driftAgainstSchemaDocument（Swift 字段/枚举/
 *         版本表与冻结 schema 文档不一致即报）。测试设施另见 tests/CapabilityFixtureSupport.swift。
 * [POS]: Sources 的统一小精灵能力协议层（G0 纯协议）。只做 Codable/语义校验与共享 fixtures 验证：
 *        不接生产调用、不注册 HTTP 路由、不改 AgentRunner/TaskStore/Server/现有控制通道、不实现
 *        Bridge 写入。Codable 默认忽略未知字段，wire 入口必须使用 decodeWire；schema 演进必须
 *        先更新并重新冻结 A 合约，Swift 表跟随，不修改既有冻结包。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreFoundation

// MARK: - JSON 值层（自有属性语义）

/// 与 JSONSerialization/JSONDecoder 解出的自有键一一对应；Swift 字典没有原型继承链，
/// `__proto__`/`constructor`/`toString` 只是普通键，按额外字段拒绝（与 A1 修正后的 TS 判定一致）。
enum JSONValue: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    static func parse(_ data: Data) throws -> JSONValue {
        convert(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private static func convert(_ raw: Any) -> JSONValue {
        switch raw {
        case is NSNull: return .null
        case let n as NSNumber:
            // JSONSerialization 的 true/false 也是 NSNumber，须按 CFBoolean 区分，否则 true 会变 1。
            return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map(convert))
        case let d as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (key, value) in d { out[key] = convert(value) }
            return .object(out)
        default: return .null
        }
    }

    var isObject: Bool { if case .object = self { return true }; return false }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var number: Double? { if case .number(let d) = self { return d }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    /// TS Number.isInteger 语义：1 与 1.0 都是整数，1.5 不是。
    var isInteger: Bool {
        guard case .number(let d) = self, d.isFinite else { return false }
        return d == d.rounded(.towardZero)
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "无法识别的 JSON 值") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - 协议常量（与冻结 schema 的 $defs 一一对应；漂移守卫负责核对）

enum UnifiedAssistantV1 {
    static let protocolVersion = 1.0
    static let capabilityVersion = "1"
    static let capabilityIds: [String] = [
        "note.create", "note.append", "checklist.create", "checklist.add_item",
        "agent.project.execute", "agent.text.generate", "document.generate",
        "browser.current.read", "desktop.app.open", "agent.gui.submit",
        "desktop.window.list", "desktop.window.arrange", "desktop.menu.invoke", "desktop.lock",
    ]
    static let effects: [String] = ["read", "write", "external_send", "desktop_control"]
    static let idempotencyModes: [String] = ["transactional", "provider_key", "reserve_only", "none"]
    static let cancellationModes: [String] = ["before_start", "local_process", "remote_confirmed", "none"]
    static let availabilityLevels: [String] = ["unknown", "available", "blocked"]
    static let verificationLevels: [String] = ["unverified", "probe_passed", "scenario_passed"]
    static let receiptStates: [String] = [
        "accepted", "running", "succeeded", "failed", "uncertain", "submitted_untracked", "cancelled",
    ]
    static let recoveryHints: [String] = ["query", "retry_safe", "user_action", "none"]
    /// checkedAt 允许领先调用方时钟的幅度；超出视为疑似未来时间不采信（与 TS READINESS_CLOCK_SKEW_MS 一致）。
    static let readinessClockSkewSeconds = 60.0
    /// 不存在 production_ready 层级：探针/未验证结果不冒充生产可用。
    static let statesWithoutError: Set<String> = ["accepted", "running", "succeeded", "submitted_untracked", "cancelled"]
    static let guiSubmissionEvidenceKind = "gui_submission"
    static let guiSubmitCapabilityId = "agent.gui.submit"
}

// MARK: - 校验错误与结果

struct CapabilityProtocolError: Error, Equatable {
    let path: String
    let keyword: String
    let message: String
    /// manifest 的 errorContains 按「关键字+消息」拼接匹配，与 TS 校验器口径一致。
    var matchText: String { "\(keyword) \(path): \(message)" }
}

struct CapabilityValidationResult: Equatable {
    let ok: Bool
    let errors: [CapabilityProtocolError]
    static let ok = CapabilityValidationResult(ok: true, errors: [])
    static func failed(_ errors: [CapabilityProtocolError]) -> CapabilityValidationResult {
        CapabilityValidationResult(ok: errors.isEmpty, errors: errors)
    }
}

// MARK: - 五类 wire 对象的字段表

enum CapabilityObjectKind: String, CaseIterable {
    case capabilityDefinition = "CapabilityDefinition"
    case adapterBinding = "AdapterBinding"
    case readinessObservation = "ReadinessObservation"
    case capabilityInvocation = "CapabilityInvocation"
    case capabilityReceipt = "CapabilityReceipt"

    var requiredFields: [String] {
        switch self {
        case .capabilityDefinition:
            return ["id", "version", "inputSchema", "outputSchema", "effect", "requiredEvidence"]
        case .adapterBinding:
            return ["id", "capabilityId", "capabilityVersion", "providerId", "providerVersion",
                    "transport", "scopeRefs", "idempotency", "cancellation", "resume", "undo"]
        case .readinessObservation:
            return ["bindingId", "availability", "checkedAt", "expiresAt", "environmentFingerprint",
                    "verification", "verifiedScope", "evidenceRefs"]
        case .capabilityInvocation:
            return ["protocolVersion", "requestId", "invocationId", "operationId", "bindingId",
                    "capabilityId", "capabilityVersion", "arguments", "argumentHash", "contextRefs",
                    "deadlineAt", "authorizationRef"]
        case .capabilityReceipt:
            return ["protocolVersion", "requestId", "invocationId", "operationId", "bindingId",
                    "capabilityId", "capabilityVersion", "revision", "state", "evidence", "artifacts",
                    "occurredAt"]
        }
    }

    var optionalFields: [String] {
        switch self {
        case .capabilityDefinition: return []
        case .adapterBinding: return ["deviceId"]
        case .readinessObservation: return ["reason"]
        case .capabilityInvocation: return ["agentTaskId", "attempt", "expectedResourceRevision"]
        case .capabilityReceipt: return ["agentTaskId", "attempt", "externalRunId", "error"]
        }
    }
}

// MARK: - 严格语义校验器

enum CapabilityProtocol {
    /// wire 入口先保留原始字段并验证，再解码，避免 Codable 静默丢弃额外字段。
    static func decodeWire<T: CapabilityWireObject>(_ type: T.Type, from data: Data) throws -> T {
        let result = validate(kind: T.wireKind, value: try JSONValue.parse(data))
        if let error = result.errors.first { throw error }
        return try JSONDecoder().decode(type, from: data)
    }

    static func validate(kind: CapabilityObjectKind, value: JSONValue) -> CapabilityValidationResult {
        switch kind {
        case .capabilityDefinition: return validateCapabilityDefinition(value)
        case .adapterBinding: return validateAdapterBinding(value)
        case .readinessObservation: return validateReadinessObservation(value)
        case .capabilityInvocation: return validateCapabilityInvocation(value)
        case .capabilityReceipt: return validateCapabilityReceipt(value)
        }
    }

    static func validateCapabilityDefinition(_ value: JSONValue) -> CapabilityValidationResult {
        var errors: [CapabilityProtocolError] = []
        guard let obj = takeObject(.capabilityDefinition, value, &errors) else { return .failed(errors) }
        checkEnum(obj, "id", UnifiedAssistantV1.capabilityIds, &errors)
        checkConstString(obj, "version", UnifiedAssistantV1.capabilityVersion, &errors)
        checkObjectField(obj, "inputSchema", &errors)
        checkObjectField(obj, "outputSchema", &errors)
        checkEnum(obj, "effect", UnifiedAssistantV1.effects, &errors)
        checkStringArray(obj, "requiredEvidence", minItems: 1, itemsMinLength: nil, &errors)
        return .failed(errors)
    }

    static func validateAdapterBinding(_ value: JSONValue) -> CapabilityValidationResult {
        var errors: [CapabilityProtocolError] = []
        guard let obj = takeObject(.adapterBinding, value, &errors) else { return .failed(errors) }
        checkString(obj, "id", minLength: 1, &errors)
        checkEnum(obj, "capabilityId", UnifiedAssistantV1.capabilityIds, &errors)
        checkConstString(obj, "capabilityVersion", UnifiedAssistantV1.capabilityVersion, &errors)
        checkString(obj, "providerId", minLength: 1, &errors)
        checkString(obj, "providerVersion", minLength: 1, &errors)
        checkString(obj, "deviceId", minLength: 1, &errors)
        checkString(obj, "transport", minLength: 1, &errors)
        checkStringArray(obj, "scopeRefs", minItems: 1, itemsMinLength: nil, &errors)
        checkEnum(obj, "idempotency", UnifiedAssistantV1.idempotencyModes, &errors)
        checkEnum(obj, "cancellation", UnifiedAssistantV1.cancellationModes, &errors)
        checkBoolean(obj, "resume", &errors)
        checkBoolean(obj, "undo", &errors)
        return .failed(errors)
    }

    static func validateReadinessObservation(_ value: JSONValue) -> CapabilityValidationResult {
        var errors: [CapabilityProtocolError] = []
        guard let obj = takeObject(.readinessObservation, value, &errors) else { return .failed(errors) }
        checkString(obj, "bindingId", minLength: 1, &errors)
        checkEnum(obj, "availability", UnifiedAssistantV1.availabilityLevels, &errors)
        checkDateTime(obj, "checkedAt", &errors)
        checkDateTime(obj, "expiresAt", &errors)
        checkString(obj, "environmentFingerprint", minLength: 1, &errors)
        checkEnum(obj, "verification", UnifiedAssistantV1.verificationLevels, &errors)
        checkStringArray(obj, "verifiedScope", minItems: nil, itemsMinLength: nil, &errors)
        checkStringArray(obj, "evidenceRefs", minItems: nil, itemsMinLength: nil, &errors)
        checkString(obj, "reason", minLength: 0, &errors)
        // schema allOf：scenario_passed 必须声明已验证范围与证据；probe_passed 必须可回溯证据。
        if obj["verification"]?.string == "scenario_passed" {
            if (obj["verifiedScope"]?.array ?? []).isEmpty {
                fail(&errors, "/verifiedScope", "minItems", "scenario_passed 必须声明非空 verifiedScope")
            }
            if (obj["evidenceRefs"]?.array ?? []).isEmpty {
                fail(&errors, "/evidenceRefs", "minItems", "scenario_passed 必须携带证据引用")
            }
        }
        if obj["verification"]?.string == "probe_passed", (obj["evidenceRefs"]?.array ?? []).isEmpty {
            fail(&errors, "/evidenceRefs", "minItems", "probe_passed 必须携带证据引用")
        }
        return .failed(errors)
    }

    static func validateCapabilityInvocation(_ value: JSONValue) -> CapabilityValidationResult {
        var errors: [CapabilityProtocolError] = []
        guard let obj = takeObject(.capabilityInvocation, value, &errors) else { return .failed(errors) }
        checkConstNumber(obj, "protocolVersion", UnifiedAssistantV1.protocolVersion, &errors)
        checkString(obj, "requestId", minLength: 1, &errors)
        checkString(obj, "invocationId", minLength: 1, &errors)
        checkString(obj, "operationId", minLength: 1, &errors)
        checkString(obj, "bindingId", minLength: 1, &errors)
        checkEnum(obj, "capabilityId", UnifiedAssistantV1.capabilityIds, &errors)
        checkConstString(obj, "capabilityVersion", UnifiedAssistantV1.capabilityVersion, &errors)
        checkObjectField(obj, "arguments", &errors)
        checkString(obj, "argumentHash", minLength: 1, &errors)
        checkStringArray(obj, "contextRefs", minItems: nil, itemsMinLength: 1, &errors)
        checkString(obj, "expectedResourceRevision", minLength: 1, &errors)
        checkDateTime(obj, "deadlineAt", &errors)
        checkString(obj, "authorizationRef", minLength: 1, &errors)
        checkAgentTaskPairing(obj, &errors)
        return .failed(errors)
    }

    static func validateCapabilityReceipt(_ value: JSONValue) -> CapabilityValidationResult {
        var errors: [CapabilityProtocolError] = []
        guard let obj = takeObject(.capabilityReceipt, value, &errors) else { return .failed(errors) }
        checkConstNumber(obj, "protocolVersion", UnifiedAssistantV1.protocolVersion, &errors)
        checkString(obj, "requestId", minLength: 1, &errors)
        checkString(obj, "invocationId", minLength: 1, &errors)
        checkString(obj, "operationId", minLength: 1, &errors)
        checkString(obj, "bindingId", minLength: 1, &errors)
        checkEnum(obj, "capabilityId", UnifiedAssistantV1.capabilityIds, &errors)
        checkConstString(obj, "capabilityVersion", UnifiedAssistantV1.capabilityVersion, &errors)
        if let revision = obj["revision"] {
            if revision.isInteger, case .number(let d) = revision {
                if d < 0 { fail(&errors, "/revision", "minimum", "修订号不得小于 0") }
            } else {
                fail(&errors, "/revision", "type", "修订号必须为整数，实际为 \(describe(revision))")
            }
        }
        checkEnum(obj, "state", UnifiedAssistantV1.receiptStates, &errors)
        checkString(obj, "externalRunId", minLength: 1, &errors)
        for key in ["evidence", "artifacts"] {
            if let value = obj[key], value.array == nil {
                fail(&errors, "/\(key)", "type", "必须是数组")
            }
        }
        if let items = obj["evidence"]?.array {
            for (index, item) in items.enumerated() { validateEvidenceEntry(item, "/evidence[\(index)]", &errors) }
        }
        if let items = obj["artifacts"]?.array {
            for (index, item) in items.enumerated() { validateArtifactEntry(item, "/artifacts[\(index)]", &errors) }
        }
        validateReceiptError(obj["error"], "/error", &errors)
        checkDateTime(obj, "occurredAt", &errors)
        checkAgentTaskPairing(obj, &errors)

        let state = obj["state"]?.string
        // failed 必须带 error；其余可追踪状态禁止 error。
        if state == "failed", obj["error"] == nil {
            fail(&errors, "/error", "required", "失败回执必须携带 error（code/recovery）")
        }
        if let state, UnifiedAssistantV1.statesWithoutError.contains(state), obj["error"] != nil {
            fail(&errors, "/error", "not", "\(state) 回执不得携带 error")
        }
        // succeeded 必须至少一条完成证据：只回执文字不构成成功。
        if state == "succeeded", (obj["evidence"]?.array ?? []).isEmpty {
            fail(&errors, "/evidence", "minItems", "succeeded 必须至少一条完成证据")
        }
        // submitted_untracked：必须有 gui_submission 提交证据，且绝不推断 externalRunId。
        if state == "submitted_untracked" {
            if obj["externalRunId"] != nil {
                fail(&errors, "/externalRunId", "not", "submitted_untracked 不得携带 externalRunId")
            }
            let hasGuiEvidence = (obj["evidence"]?.array ?? []).contains {
                $0["kind"]?.string == UnifiedAssistantV1.guiSubmissionEvidenceKind
            }
            if !hasGuiEvidence {
                fail(&errors, "/evidence", "contains", "submitted_untracked 必须含 kind=gui_submission 证据")
            }
        }
        // agent.gui.submit 永不 succeeded（投递不等于执行/完成），且任何状态不得携带 externalRunId。
        if obj["capabilityId"]?.string == UnifiedAssistantV1.guiSubmitCapabilityId {
            if state == "succeeded" {
                fail(&errors, "/state", "not", "agent.gui.submit 永不 succeeded：投递不等于对端执行或完成")
            }
            if obj["externalRunId"] != nil {
                fail(&errors, "/externalRunId", "not", "agent.gui.submit 一律不得携带 externalRunId（凭空推断禁止）")
            }
        }
        return .failed(errors)
    }

    /// 回执归属核验（超出纯 schema 的上下文一致性）：关联字段必须与调用一致，agentTaskId/attempt
    /// 同有同无且值相等，不让回执自报归属。不做授权判定，也不提供 exactly-once。
    static func validateReceipt(_ receipt: JSONValue, againstInvocation invocation: JSONValue) -> CapabilityValidationResult {
        var errors = validateCapabilityReceipt(receipt).errors + validateCapabilityInvocation(invocation).errors
        let stringPairs: [(String, JSONValue?, JSONValue?)] = [
            ("requestId", invocation["requestId"], receipt["requestId"]),
            ("invocationId", invocation["invocationId"], receipt["invocationId"]),
            ("operationId", invocation["operationId"], receipt["operationId"]),
            ("bindingId", invocation["bindingId"], receipt["bindingId"]),
            ("capabilityId", invocation["capabilityId"], receipt["capabilityId"]),
            ("capabilityVersion", invocation["capabilityVersion"], receipt["capabilityVersion"]),
        ]
        for (field, expected, actual) in stringPairs where actual != expected {
            fail(&errors, "/\(field)", "correlation",
                 "回执 \(field) 与调用不符：期望 \(describeAny(expected))，实际 \(describeAny(actual))")
        }
        let taskInvocation = invocation["agentTaskId"], taskReceipt = receipt["agentTaskId"]
        if (taskInvocation == nil) != (taskReceipt == nil) {
            fail(&errors, "/agentTaskId", "correlation", "agentTaskId 在调用与回执中必须同有同无")
        } else if let expected = taskInvocation, taskReceipt != expected {
            fail(&errors, "/agentTaskId", "correlation",
                 "回执 agentTaskId 与调用不符：期望 \(describeAny(expected))，实际 \(describeAny(taskReceipt))")
        }
        let attemptInvocation = invocation["attempt"], attemptReceipt = receipt["attempt"]
        if (attemptInvocation == nil) != (attemptReceipt == nil) {
            fail(&errors, "/attempt", "correlation", "attempt 在调用与回执中必须同有同无")
        } else if let expected = attemptInvocation, attemptReceipt != expected {
            fail(&errors, "/attempt", "correlation",
                 "回执 attempt 与调用不符：期望 \(describeAny(expected))，实际 \(describeAny(attemptReceipt))")
        }
        return .failed(errors)
    }

    /// readiness 观察的**局部条件检查**，不是完整生产可用判定：仅核对观察自身。binding 是否匹配当前
    /// 请求、环境指纹是否与当前设备一致、请求 scope 是否落在 verifiedScope 内，由调用方在执行点核验。
    static func isReadinessObservationUsable(_ obs: ReadinessObservation, now: Date = Date()) -> (usable: Bool, reasons: [String]) {
        var reasons: [String] = []
        if obs.verification != "scenario_passed" {
            reasons.append("verification=\(obs.verification)，探针/未验证结果不冒充生产可用")
        }
        if obs.availability != "available" { reasons.append("availability=\(obs.availability)") }
        let checked = rfc3339Date(obs.checkedAt)
        let expires = rfc3339Date(obs.expiresAt)
        if checked == nil {
            reasons.append("checkedAt 非法")
        } else if checked!.timeIntervalSince(now) > UnifiedAssistantV1.readinessClockSkewSeconds {
            reasons.append("checkedAt 为未来时间（超出时钟偏差容限 \(Int(UnifiedAssistantV1.readinessClockSkewSeconds * 1000))ms），不采信")
        }
        if expires == nil {
            reasons.append("expiresAt 非法")
        } else {
            if expires! <= now { reasons.append("观察已过期") }
            if let checked, expires! <= checked { reasons.append("expiresAt 必须晚于 checkedAt") }
        }
        if obs.evidenceRefs.isEmpty { reasons.append("evidenceRefs 为空") }
        if obs.bindingId.isEmpty { reasons.append("bindingId 为空") }
        if obs.verifiedScope.isEmpty { reasons.append("verifiedScope 为空") }
        if obs.environmentFingerprint.isEmpty { reasons.append("environmentFingerprint 为空") }
        return (reasons.isEmpty, reasons)
    }

    static func isValidRFC3339DateTime(_ s: String) -> Bool { RFC3339.isValidDateTime(s) }
    static func rfc3339Date(_ s: String) -> Date? { RFC3339.rfc3339Date(s) }

    // MARK: 字段级检查

    private static func takeObject(_ kind: CapabilityObjectKind, _ value: JSONValue,
                                   _ errors: inout [CapabilityProtocolError]) -> [String: JSONValue]? {
        guard let obj = value.object else {
            fail(&errors, "", "type", "类型应为 object，实际为 \(describe(value))")
            return nil
        }
        let allowed = Set(kind.requiredFields + kind.optionalFields)
        for key in kind.requiredFields where obj[key] == nil {
            fail(&errors, "/\(key)", "required", "缺少必填字段 \(key)")
        }
        for key in obj.keys.sorted() where !allowed.contains(key) {
            fail(&errors, "/\(key)", "additionalProperties", "不允许的额外字段 \(key)")
        }
        return obj
    }

    /// agentTaskId/attempt 同有同无，attempt 为正整数；不为短操作强建长任务。
    private static func checkAgentTaskPairing(_ obj: [String: JSONValue], _ errors: inout [CapabilityProtocolError]) {
        let hasTaskId = obj["agentTaskId"] != nil, hasAttempt = obj["attempt"] != nil
        if hasTaskId != hasAttempt {
            if !hasTaskId { fail(&errors, "/agentTaskId", "required", "agentTaskId 与 attempt 必须同有同无") }
            if !hasAttempt { fail(&errors, "/attempt", "required", "agentTaskId 与 attempt 必须同有同无") }
            return
        }
        checkString(obj, "agentTaskId", minLength: 1, &errors)
        checkPositiveInteger(obj, "attempt", minimum: 1, &errors)
    }

    private static func checkString(_ obj: [String: JSONValue], _ key: String, minLength: Int,
                                    _ errors: inout [CapabilityProtocolError]) {
        guard let value = obj[key] else { return }
        guard let s = value.string else {
            fail(&errors, "/\(key)", "type", "类型应为 string，实际为 \(describe(value))")
            return
        }
        if s.count < minLength { fail(&errors, "/\(key)", "minLength", "字符串长度不得小于 \(minLength)") }
    }

    private static func checkEnum(_ obj: [String: JSONValue], _ key: String, _ options: [String],
                                  _ errors: inout [CapabilityProtocolError]) {
        guard let value = obj[key] else { return }
        if let s = value.string, options.contains(s) { return }
        fail(&errors, "/\(key)", "enum", "值不在允许的枚举内：\(describe(value))")
    }

    private static func checkConstString(_ obj: [String: JSONValue], _ key: String, _ expected: String,
                                         _ errors: inout [CapabilityProtocolError]) {
        guard let value = obj[key] else { return }
        if value != .string(expected) {
            fail(&errors, "/\(key)", "const", "值必须是 \(expected)，实际为 \(describe(value))")
        }
    }

    private static func checkConstNumber(_ obj: [String: JSONValue], _ key: String, _ expected: Double,
                                         _ errors: inout [CapabilityProtocolError]) {
        guard let value = obj[key] else { return }
        if value.number != expected {
            fail(&errors, "/\(key)", "const", "值必须是 \(Int(expected))，实际为 \(describe(value))")
        }
    }

    private static func checkBoolean(_ obj: [String: JSONValue], _ key: String,
                                     _ errors: inout [CapabilityProtocolError]) {
        guard let value = obj[key] else { return }
        if value.bool == nil { fail(&errors, "/\(key)", "type", "类型应为 boolean，实际为 \(describe(value))") }
    }

    private static func checkObjectField(_ obj: [String: JSONValue], _ key: String,
                                         _ errors: inout [CapabilityProtocolError]) {
        guard let value = obj[key] else { return }
        if !value.isObject { fail(&errors, "/\(key)", "type", "类型应为 object，实际为 \(describe(value))") }
    }

    private static func checkPositiveInteger(_ obj: [String: JSONValue], _ key: String, minimum: Int,
                                             _ errors: inout [CapabilityProtocolError]) {
        guard let value = obj[key] else { return }
        if value.isInteger, let d = value.number {
            if d < Double(minimum) { fail(&errors, "/\(key)", "minimum", "数值不得小于 \(minimum)") }
        } else {
            fail(&errors, "/\(key)", "type", "类型应为 integer，实际为 \(describe(value))")
        }
    }

    private static func checkStringArray(_ obj: [String: JSONValue], _ key: String, minItems: Int?,
                                         itemsMinLength: Int?, _ errors: inout [CapabilityProtocolError]) {
        guard let value = obj[key] else { return }
        guard let items = value.array else {
            fail(&errors, "/\(key)", "type", "类型应为 array，实际为 \(describe(value))")
            return
        }
        if let minItems, items.count < minItems {
            fail(&errors, "/\(key)", "minItems", "数组长度不得小于 \(minItems)")
        }
        for (index, item) in items.enumerated() {
            guard let s = item.string else {
                fail(&errors, "/\(key)[\(index)]", "type", "数组元素应为 string，实际为 \(describe(item))")
                continue
            }
            if let itemsMinLength, s.count < itemsMinLength {
                fail(&errors, "/\(key)[\(index)]", "minLength", "字符串长度不得小于 \(itemsMinLength)")
            }
        }
    }

    private static func checkDateTime(_ obj: [String: JSONValue], _ key: String,
                                      _ errors: inout [CapabilityProtocolError]) {
        guard let value = obj[key] else { return }
        guard let s = value.string else {
            fail(&errors, "/\(key)", "type", "类型应为 string，实际为 \(describe(value))")
            return
        }
        if !RFC3339.isValidDateTime(s) {
            fail(&errors, "/\(key)", "format",
                 "必须是带时区的 RFC 3339 date-time，且为真实存在的日历日期（拒绝 2026-02-30 类归一化）")
        }
    }

    /// 冻结 schema 要求每条证据、产物和错误都是严格对象。
    private static func validateEvidenceEntry(_ item: JSONValue, _ path: String,
                                              _ errors: inout [CapabilityProtocolError]) {
        guard let obj = item.object else { fail(&errors, path, "type", "必须是对象"); return }
        let firstError = errors.count
        defer {
            for index in firstError..<errors.count {
                let error = errors[index]
                errors[index] = CapabilityProtocolError(path: path + error.path, keyword: error.keyword, message: error.message)
            }
        }
        checkEntryFields(obj, required: ["kind", "ref", "verifiedAt"], optional: [], path: path, &errors)
        checkString(obj, "kind", minLength: 1, &errors)
        checkString(obj, "ref", minLength: 1, &errors)
        checkDateTime(obj, "verifiedAt", &errors)
    }

    private static func validateArtifactEntry(_ item: JSONValue, _ path: String,
                                              _ errors: inout [CapabilityProtocolError]) {
        guard let obj = item.object else { fail(&errors, path, "type", "必须是对象"); return }
        let firstError = errors.count
        defer {
            for index in firstError..<errors.count {
                let error = errors[index]
                errors[index] = CapabilityProtocolError(path: path + error.path, keyword: error.keyword, message: error.message)
            }
        }
        checkEntryFields(obj, required: ["type", "id"], optional: ["revision", "accessRef"], path: path, &errors)
        checkString(obj, "type", minLength: 1, &errors)
        checkString(obj, "id", minLength: 1, &errors)
        checkString(obj, "revision", minLength: 1, &errors)
        checkString(obj, "accessRef", minLength: 1, &errors)
    }

    private static func validateReceiptError(_ item: JSONValue?, _ path: String,
                                             _ errors: inout [CapabilityProtocolError]) {
        guard let item else { return }
        guard let obj = item.object else { fail(&errors, path, "type", "必须是对象"); return }
        let firstError = errors.count
        defer {
            for index in firstError..<errors.count {
                let error = errors[index]
                errors[index] = CapabilityProtocolError(path: path + error.path, keyword: error.keyword, message: error.message)
            }
        }
        checkEntryFields(obj, required: ["code", "message", "recovery"], optional: [], path: path, &errors)
        checkString(obj, "code", minLength: 1, &errors)
        checkString(obj, "message", minLength: 0, &errors)
        checkEnum(obj, "recovery", UnifiedAssistantV1.recoveryHints, &errors)
    }

    /// 嵌套条目（evidence/artifacts/error）的 required + additionalProperties 检查；path 仅用于定位。
    private static func checkEntryFields(_ obj: [String: JSONValue], required: [String], optional: [String],
                                         path: String, _ errors: inout [CapabilityProtocolError]) {
        _ = path
        for key in required where obj[key] == nil {
            fail(&errors, "/\(key)", "required", "缺少必填字段 \(key)")
        }
        let allowed = Set(required + optional)
        for key in obj.keys.sorted() where !allowed.contains(key) {
            fail(&errors, "/\(key)", "additionalProperties", "不允许的额外字段 \(key)")
        }
    }

    private static func fail(_ errors: inout [CapabilityProtocolError], _ path: String,
                             _ keyword: String, _ message: String) {
        errors.append(CapabilityProtocolError(path: path.isEmpty ? "/" : path, keyword: keyword, message: message))
    }

    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool: return "boolean"
        case .number(let d):
            return d.isFinite && d == d.rounded(.towardZero) && abs(d) < 1e15
                ? "integer(\(Int(d)))" : "number(\(d))"
        case .string(let s): return "string(\(s.count) 字符)"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func describeAny(_ value: JSONValue?) -> String {
        guard let value else { return "（缺失）" }
        if let s = value.string { return s }
        if let d = value.number { return String(d) }
        return describe(value)
    }
}

// MARK: - schema 漂移守卫

extension CapabilityProtocol {
    /// Swift 字段/枚举/版本表与冻结 schema 文档逐项核对；schema 演进而 Swift 未跟随时测试即失败，
    /// 不允许两端各自猜测兼容。
    static func driftAgainstSchemaDocument(_ doc: JSONValue) -> [String] {
        var drift: [String] = []
        guard let defs = doc["$defs"]?.object else { return ["schema 文档缺少 $defs"] }
        if doc["$schema"]?.string != "https://json-schema.org/draft/2020-12/schema" {
            drift.append("$schema 不是 draft 2020-12")
        }
        for kind in CapabilityObjectKind.allCases {
            guard let def = defs[kind.rawValue]?.object else {
                drift.append("缺少 $defs.\(kind.rawValue)")
                continue
            }
            let schemaProperties = Set((def["properties"]?.object ?? [:]).keys)
            let swiftProperties = Set(kind.requiredFields + kind.optionalFields)
            for missing in swiftProperties.subtracting(schemaProperties).sorted() {
                drift.append("\(kind.rawValue)：schema 缺少 Swift 已登记字段 \(missing)")
            }
            for extra in schemaProperties.subtracting(swiftProperties).sorted() {
                drift.append("\(kind.rawValue)：schema 新增字段 \(extra) 未登记到 Swift（不得自行猜测兼容）")
            }
            let schemaRequired = (def["required"]?.array ?? []).compactMap(\.string).sorted()
            if schemaRequired != kind.requiredFields.sorted() {
                drift.append("\(kind.rawValue)：required 列表与 Swift 不一致（schema=\(schemaRequired)）")
            }
        }
        func enumDrift(_ defName: String, _ expected: [String]) {
            let actual = (defs[defName]?["enum"]?.array ?? []).compactMap(\.string)
            if actual != expected { drift.append("$defs.\(defName).enum 与 Swift 不一致（schema=\(actual)）") }
        }
        enumDrift("CapabilityId", UnifiedAssistantV1.capabilityIds)
        enumDrift("Effect", UnifiedAssistantV1.effects)
        enumDrift("Idempotency", UnifiedAssistantV1.idempotencyModes)
        enumDrift("Cancellation", UnifiedAssistantV1.cancellationModes)
        enumDrift("Availability", UnifiedAssistantV1.availabilityLevels)
        enumDrift("Verification", UnifiedAssistantV1.verificationLevels)
        enumDrift("ReceiptState", UnifiedAssistantV1.receiptStates)
        enumDrift("Recovery", UnifiedAssistantV1.recoveryHints)
        if defs["ProtocolVersion"]?["const"]?.number != UnifiedAssistantV1.protocolVersion {
            drift.append("$defs.ProtocolVersion.const 与 Swift 不一致")
        }
        if defs["CapabilityVersion"]?["const"]?.string != UnifiedAssistantV1.capabilityVersion {
            drift.append("$defs.CapabilityVersion.const 与 Swift 不一致")
        }
        return drift
    }
}

// MARK: - Codable 词汇表（生产消费用；wire 判定仍以校验器为准）

struct CapabilityEvidence: Codable, Equatable {
    let kind: String
    let ref: String
    let verifiedAt: String
}

struct CapabilityArtifact: Codable, Equatable {
    let type: String
    let id: String
    let revision: String?
    let accessRef: String?
}

enum ReceiptRecovery: String, Codable, Equatable {
    case query
    case retrySafe = "retry_safe"
    case userAction = "user_action"
    case none
}

struct CapabilityReceiptError: Codable, Equatable {
    let code: String
    let message: String
    let recovery: ReceiptRecovery
}

struct CapabilityDefinition: Codable, Equatable {
    let id: String
    let version: String
    let inputSchema: JSONValue
    let outputSchema: JSONValue
    let effect: String
    let requiredEvidence: [String]
}

struct AdapterBinding: Codable, Equatable {
    let id: String
    let capabilityId: String
    let capabilityVersion: String
    let providerId: String
    let providerVersion: String
    let deviceId: String?
    let transport: String
    let scopeRefs: [String]
    let idempotency: String
    let cancellation: String
    let resume: Bool
    let undo: Bool
}

struct ReadinessObservation: Codable, Equatable {
    let bindingId: String
    let availability: String
    let checkedAt: String
    let expiresAt: String
    let environmentFingerprint: String
    let verification: String
    let verifiedScope: [String]
    let evidenceRefs: [String]
    let reason: String?
}

struct CapabilityInvocation: Codable, Equatable {
    let protocolVersion: Int
    let requestId: String
    let invocationId: String
    let operationId: String
    let agentTaskId: String?
    let attempt: Int?
    let bindingId: String
    let capabilityId: String
    let capabilityVersion: String
    let arguments: JSONValue
    let argumentHash: String
    let contextRefs: [String]
    let expectedResourceRevision: String?
    let deadlineAt: String
    let authorizationRef: String
}

struct CapabilityReceipt: Codable, Equatable {
    let protocolVersion: Int
    let requestId: String
    let invocationId: String
    let operationId: String
    let agentTaskId: String?
    let attempt: Int?
    let bindingId: String
    let capabilityId: String
    let capabilityVersion: String
    let revision: Int
    let state: String
    let externalRunId: String?
    let evidence: [CapabilityEvidence]
    let artifacts: [CapabilityArtifact]
    let error: CapabilityReceiptError?
    let occurredAt: String
}


// MARK: - 类型绑定（避免调用者把模型与另一种校验器配错）
protocol CapabilityWireObject: Codable { static var wireKind: CapabilityObjectKind { get } }
extension CapabilityDefinition: CapabilityWireObject { static var wireKind: CapabilityObjectKind { .capabilityDefinition } }
extension AdapterBinding: CapabilityWireObject { static var wireKind: CapabilityObjectKind { .adapterBinding } }
extension ReadinessObservation: CapabilityWireObject { static var wireKind: CapabilityObjectKind { .readinessObservation } }
extension CapabilityInvocation: CapabilityWireObject { static var wireKind: CapabilityObjectKind { .capabilityInvocation } }
extension CapabilityReceipt: CapabilityWireObject { static var wireKind: CapabilityObjectKind { .capabilityReceipt } }
