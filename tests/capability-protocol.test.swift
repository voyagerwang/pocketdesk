/**
 * [INPUT]: 冻结包 A-protocol-v1-r2 的共享 fixtures/manifest.json（66 case）与
 *         unified-assistant-v1.schema.json（SHA-256 f057f017…31910），经
 *         CapabilityProtocolPaths.defaultProtocolDirectory() 读取（默认冻结包路径，可用
 *         PD_UNIFIED_ASSISTANT_PROTOCOL_DIR 覆盖）；Sources/CapabilityModels.swift 的校验器、
 *         schema 漂移守卫与 Codable 词汇表。
 * [OUTPUT]: 隔离验证：① manifest 完整性（66 case，22 pass + 44 reject）；② 全部共享 fixtures 逐 case
 *          判定与 TS 一致（pass 通过、reject 失败且错误命中 errorContains）；③ schema 漂移守卫为空且
 *          对被篡改的 schema 能真实报警；④ 严格字段/版本/枚举/date-time/轮次配对/回执硬规则的合成
 *          反例与正例（含「note.create succeeded 保留真实 externalRunId」放行）；⑤ 回执与调用的归属
 *          核验逐字段篡改拒绝；⑥ Codable 词汇表对 pass fixtures 解码→再编码→再校验往返成立，并锁定
 *          「Codable 默认忽略未知字段 ≠ wire 合法」；⑦ RFC 3339 边界与 readiness 局部可用性检查。
 * [POS]: tests 的统一小精灵协议回归。纯本地 JSON 读写临时目录之外只读冻结包；无网络、无桌面副作用、
 *        无真实模型/外发调用；fixtures 是协议样例，非真实业务数据；校验通过不代表授权有效、恰好一次
 *        或能力对某入口开放。运行：swiftc -parse-as-library 编译本文件与 Sources/CapabilityModels.swift
 *        后执行（见 tests/run-capability-protocol-test.sh）。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct CapabilityProtocolTests {
    static var failures: [String] = []
    static var total = 0

    static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        total += 1
        if condition {
            print("PASS \(label)")
        } else {
            failures.append(detail.isEmpty ? label : "\(label)：\(detail)")
            print("FAIL \(label)\(detail.isEmpty ? "" : " —— \(detail)")")
        }
    }

    static func main() {
        let dir = CapabilityProtocolPaths.defaultProtocolDirectory()
        print("协议目录：\(dir.path)")

        // 1) 冻结包可读。
        let schemaURL = CapabilityProtocolPaths.schemaURL(in: dir)
        let manifestURL = CapabilityProtocolPaths.manifestURL(in: dir)
        let schemaData = try? Data(contentsOf: schemaURL)
        let manifestData = try? Data(contentsOf: manifestURL)
        check("冻结包 schema 可读", schemaData != nil, schemaURL.path)
        check("冻结包 manifest 可读", manifestData != nil, manifestURL.path)
        guard schemaData != nil, manifestData != nil else {
            finish(); return
        }

        guard let changed = try? FixtureRunner.verifyFrozenFiles(protocolDir: dir) else {
            check("冻结包摘要清单可读", false); finish(); return
        }
        check("冻结 schema 与全部共享 fixtures 摘要一致", changed.isEmpty, changed.joined(separator: ", "))
        guard changed.isEmpty else { finish(); return }

        // 2) manifest 完整性：66 case、22 pass + 44 reject、reject 均带 errorContains、文件齐全可解析。
        guard let manifest = try? FixtureRunner.loadManifest(protocolDir: dir) else {
            check("manifest 可解析", false); finish(); return
        }
        check("manifest 66 case", manifest.cases.count == 66, "实际 \(manifest.cases.count)")
        check("manifest 22 合法", manifest.cases.filter { $0.expect == "pass" }.count == 22)
        check("manifest 44 拒绝", manifest.cases.filter { $0.expect == "reject" }.count == 44)
        check("reject 均带 errorContains",
              manifest.cases.filter { $0.expect == "reject" }.allSatisfy { !($0.errorContains ?? "").isEmpty })
        check("defs 均为五类协议对象",
              manifest.cases.allSatisfy { CapabilityObjectKind(rawValue: $0.defs) != nil })
        var unreadable: [String] = []
        for item in manifest.cases {
            let url = CapabilityProtocolPaths.fixtureURL(in: dir, relativeToFixtures: item.file)
            if let data = try? Data(contentsOf: url), (try? JSONValue.parse(data)) != nil {
                continue
            }
            unreadable.append(item.file)
        }
        check("全部 fixture 文件存在且可解析", unreadable.isEmpty, unreadable.joined(separator: ", "))

        // 3) 共享 fixtures 全量判定（与 TS 校验器同一组输入）。
        let outcomes = (try? FixtureRunner.runAll(protocolDir: dir)) ?? []
        let mismatched = outcomes.filter { !$0.matched }
        check("共享 fixtures 66 case 全部按预期（pass/reject 且拒绝原因命中）",
              outcomes.count == manifest.cases.count && mismatched.isEmpty,
              mismatched.map { "\($0.file)：\($0.detail ?? "")" }.joined(separator: " | "))
        let rejectedAsExpected = outcomes.filter { $0.expect == "reject" && $0.matched }.count
        print("INFO fixtures：pass \(outcomes.filter { $0.expect == "pass" && $0.matched }.count)/22，reject \(rejectedAsExpected)/44")

        // 4) schema 漂移守卫：Swift 表与冻结 schema 文档一致；对被篡改 schema 能真实报警。
        guard let schemaValue = try? JSONValue.parse(schemaData!) else {
            check("schema 可解析", false); finish(); return
        }
        check("schema 漂移守卫为空", CapabilityProtocol.driftAgainstSchemaDocument(schemaValue).isEmpty,
              CapabilityProtocol.driftAgainstSchemaDocument(schemaValue).joined(separator: " | "))
        if case .object(var tampered) = schemaValue {
            if case .object(var defs) = tampered["$defs"] ?? .null,
               case .object(var definition) = defs["CapabilityDefinition"] ?? .null,
               case .object(var properties) = definition["properties"] ?? .null {
                properties["risk"] = .object(["type": .string("string")])
                definition["properties"] = .object(properties)
                defs["CapabilityDefinition"] = .object(definition)
                tampered["$defs"] = .object(defs)
                let drift = CapabilityProtocol.driftAgainstSchemaDocument(.object(tampered))
                check("漂移守卫对 schema 新增字段能报警",
                      drift.contains { $0.contains("CapabilityDefinition") && $0.contains("risk") },
                      drift.joined(separator: " | "))
            } else {
                check("漂移守卫负例构造", false, "schema 结构与预期不符")
            }
        }

        // 5) 调用语义合成反例（基于 invocation/ok-note-create）。
        let okInvocation = try! fixture("invocation/ok-note-create.json")
        checkMutation(okInvocation, .capabilityInvocation, fields: ["protocolVersion": .number(2)],
                      keyword: "const", label: "protocolVersion=2 拒绝（const）")
        checkMutation(okInvocation, .capabilityInvocation, fields: ["capabilityVersion": .string("2")],
                      keyword: "const", label: "capabilityVersion=\"2\" 拒绝（const）")
        checkMutation(okInvocation, .capabilityInvocation, remove: ["authorizationRef"],
                      keyword: "required", label: "缺 authorizationRef 拒绝（required）")
        checkMutation(okInvocation, .capabilityInvocation, fields: ["confirmedAt": .string("now")],
                      keyword: "additionalProperties", label: "confirmedAt 自报拒绝（additionalProperties）")
        // attempt 边界反例须与 agentTaskId 成对（否则配对校验先以 required 报错，与真实 fixtures 构造一致）。
        checkMutation(okInvocation, .capabilityInvocation,
                      fields: ["agentTaskId": .string("t-1"), "attempt": .number(0)],
                      keyword: "minimum", label: "attempt=0 拒绝（minimum）")
        checkMutation(okInvocation, .capabilityInvocation,
                      fields: ["agentTaskId": .string("t-1"), "attempt": .string("1")],
                      keyword: "type", label: "attempt 字符串拒绝（type）")
        checkMutation(okInvocation, .capabilityInvocation,
                      fields: ["agentTaskId": .string("t-1"), "attempt": .number(1.5)],
                      keyword: "type", label: "attempt=1.5 拒绝（type）")
        checkMutation(okInvocation, .capabilityInvocation, fields: ["arguments": .string("{}")],
                      keyword: "type", label: "arguments 非对象拒绝（type）")
        checkMutation(okInvocation, .capabilityInvocation, fields: ["deadlineAt": .string("2026-02-30T00:00:00Z")],
                      keyword: "format", label: "不存在的日历日期拒绝（format）")
        checkMutation(okInvocation, .capabilityInvocation, fields: ["agentTaskId": .string("t-1")],
                      keyword: "required", label: "agentTaskId 单独出现拒绝（required）")
        // 正例：短操作补齐成对轮次字段后合法。
        checkMutation(okInvocation, .capabilityInvocation,
                      fields: ["agentTaskId": .string("t-1"), "attempt": .number(1)],
                      keyword: nil, label: "agentTaskId/attempt 成对出现合法")

        // 6) 回执硬规则（基于 receipt/ok-succeeded-note-create）。
        let okReceipt = try! fixture("receipt/ok-succeeded-note-create.json")
        checkMutation(okReceipt, .capabilityReceipt, fields: ["evidence": .array([])],
                      keyword: "minItems", label: "succeeded 无证据拒绝（minItems）")
        checkMutation(okReceipt, .capabilityReceipt,
                      fields: ["error": .object(["code": .string("E_X"), "message": .string("x"), "recovery": .string("none")])],
                      keyword: "not", label: "succeeded 带 error 拒绝（not）")
        checkMutation(okReceipt, .capabilityReceipt, fields: ["state": .string("failed")],
                      keyword: "required", label: "failed 无 error 拒绝（required）")
        checkMutation(okReceipt, .capabilityReceipt, fields: ["state": .string("accepted"), "evidence": .array([])],
                      keyword: nil, label: "accepted 无证据无错误合法")
        checkMutation(okReceipt, .capabilityReceipt, remove: ["revision"],
                      keyword: "required", label: "缺修订号拒绝（required）")
        checkMutation(okReceipt, .capabilityReceipt, fields: ["revision": .number(1.5)],
                      keyword: "type", label: "修订号非整数拒绝（type）")
        // 正例控制：非 GUI 能力 succeeded 保留真实取得的 externalRunId 不被误禁（unknown outcome ≠ unknown identity 的姊妹场景）。
        checkMutation(okReceipt, .capabilityReceipt, fields: ["externalRunId": .string("run-known-2")],
                      keyword: nil, label: "note.create succeeded 携带真实 externalRunId 合法")

        // 7) GUI 投递回执：永不 succeeded、任何状态禁 externalRunId（基于 receipt/ok-gui-untracked-with-agent-task）。
        let guiReceipt = try! fixture("receipt/ok-gui-untracked-with-agent-task.json")
        checkMutation(guiReceipt, .capabilityReceipt, fields: ["state": .string("succeeded")],
                      keyword: "not", label: "GUI 投递冒充 succeeded 拒绝（not）")
        checkMutation(guiReceipt, .capabilityReceipt, fields: ["externalRunId": .string("run-9")],
                      keyword: "not", label: "GUI 投递携带 externalRunId 拒绝（not）")
        checkMutation(guiReceipt, .capabilityReceipt,
                      fields: ["evidence": .array([.object(["kind": .string("model_text"),
                                                            "ref": .string("x"),
                                                            "verifiedAt": .string("2026-09-19T08:31:00+08:00")])])],
                      keyword: "contains", label: "submitted_untracked 缺 gui_submission 证据拒绝（contains）")

        // 8) 归属核验：回执关联字段必须与调用一致，轮次字段同有同无且值相等。
        let invocation = try! fixture("invocation/ok-note-create.json")
        var receipt = try! fixture("receipt/ok-succeeded-note-create.json")
        // 让回执与该调用共享全部关联字段。
        receipt = mutate(receipt, set: [
            "requestId": invocation["requestId"]!,
            "invocationId": invocation["invocationId"]!,
            "operationId": invocation["operationId"]!,
            "bindingId": invocation["bindingId"]!,
            "capabilityId": invocation["capabilityId"]!,
            "capabilityVersion": invocation["capabilityVersion"]!,
        ])
        check("构造归属一致的调用/回执对",
              CapabilityProtocol.validateReceipt(receipt, againstInvocation: invocation).ok,
              CapabilityProtocol.validateReceipt(receipt, againstInvocation: invocation)
                  .errors.map(\.matchText).joined(separator: "; "))
        for field in ["requestId", "invocationId", "operationId", "bindingId", "capabilityId", "capabilityVersion"] {
            let tampered = mutate(receipt, set: [field: .string("spoofed-value")])
            let result = CapabilityProtocol.validateReceipt(tampered, againstInvocation: invocation)
            check("篡改回执 \(field) 被归属核验拒绝",
                  !result.ok && result.errors.contains { $0.keyword == "correlation" && $0.path == "/\(field)" },
                  result.errors.map(\.matchText).joined(separator: "; "))
        }
        let withTaskOnlyReceipt = mutate(receipt, set: ["agentTaskId": .string("t-1"), "attempt": .number(1)])
        let taskOnlyResult = CapabilityProtocol.validateReceipt(withTaskOnlyReceipt, againstInvocation: invocation)
        check("回执凭空新增轮次字段被归属核验拒绝",
              !taskOnlyResult.ok && taskOnlyResult.errors.contains { $0.path == "/agentTaskId" || $0.path == "/attempt" },
              taskOnlyResult.errors.map(\.matchText).joined(separator: "; "))
        let withTaskBoth = mutate(invocation, set: ["agentTaskId": .string("t-1"), "attempt": .number(2)])
        let taskReceiptBoth = mutate(receipt, set: ["agentTaskId": .string("t-1"), "attempt": .number(2)])
        check("轮次字段成对且值相等时归属核验通过",
              CapabilityProtocol.validateReceipt(taskReceiptBoth, againstInvocation: withTaskBoth).ok)
        let attemptMismatch = mutate(taskReceiptBoth, set: ["attempt": .number(3)])
        let attemptResult = CapabilityProtocol.validateReceipt(attemptMismatch, againstInvocation: withTaskBoth)
        check("回执 attempt 值与调用不符被归属核验拒绝",
              !attemptResult.ok && attemptResult.errors.contains { $0.path == "/attempt" },
              attemptResult.errors.map(\.matchText).joined(separator: "; "))

        // 9) Codable 词汇表：pass fixtures 解码→再编码→再校验往返成立。
        let encoder = JSONEncoder()
        for item in manifest.cases where item.expect == "pass" {
            let rel = item.file
            let (ok, detail) = decodeAndRoundTrip(rel: rel, dir: dir, encoder: encoder)
            check("Codable 往返再校验：\(rel)", ok, detail)
        }
        // Codable 默认忽略未知字段：额外字段 fixture 能解码却必须被严格校验拒绝——wire 判定以校验器为准。
        let extraFieldData = try! Data(contentsOf: CapabilityProtocolPaths.fixtureURL(
            in: dir, relativeToFixtures: "invocation/reject-extra-field.json"))
        let decodesDespiteExtra = (try? JSONDecoder().decode(CapabilityInvocation.self, from: extraFieldData)) != nil
        let extraValidation = CapabilityProtocol.validate(
            kind: .capabilityInvocation,
            value: try! JSONValue.parse(extraFieldData))
        check("额外字段经 Codable 解码不报错但严格校验拒绝", decodesDespiteExtra && !extraValidation.ok)
        // Codable 类型严格性：attempt 为字符串时类型化解码失败。
        let attemptStringData = try! Data(contentsOf: CapabilityProtocolPaths.fixtureURL(
            in: dir, relativeToFixtures: "invocation/reject-attempt-as-string.json"))
        check("attempt 字符串无法经 Codable 解码",
              (try? JSONDecoder().decode(CapabilityInvocation.self, from: attemptStringData)) == nil)

        check("wire 解码拒绝未知字段", (try? CapabilityProtocol.decodeWire(CapabilityInvocation.self, from: extraFieldData)) == nil)
        check("空对象不得通过回执归属核验", !CapabilityProtocol.validateReceipt(.object([:]), againstInvocation: .object([:])).ok)
        for field in ["evidence", "artifacts"] {
            for bad: JSONValue in [.null, .string("fake"), .bool(true), .object([:]), .number(1)] {
                let invalidArray = mutate(receipt, set: [field: bad])
                check("\(field) 数组类型拒绝 \(bad)", !CapabilityProtocol.validateCapabilityReceipt(invalidArray).ok)
                let invalidEntry = mutate(receipt, set: [field: .array([bad])])
                check("\(field) 条目类型拒绝 \(bad)", !CapabilityProtocol.validateCapabilityReceipt(invalidEntry).ok)
            }
        }
        for bad: JSONValue in [.null, .string("fake"), .array([]), .bool(false)] {
            check("failed 非对象 error 拒绝 \(bad)", !CapabilityProtocol.validateCapabilityReceipt(
                mutate(receipt, set: ["state": .string("failed"), "error": bad])).ok)
        }
        let fractional = CapabilityProtocol.rfc3339Date("2026-09-19T00:00:00.750Z")!
        let whole = CapabilityProtocol.rfc3339Date("2026-09-19T00:00:00Z")!
        check("小数秒不得丢失", abs(fractional.timeIntervalSince(whole) - 0.75) < 0.00001)
        let extremeOffset = CapabilityProtocol.rfc3339Date("2026-09-19T00:00:00+23:59")!
        check("大时区偏移不得回退 UTC", abs(extremeOffset.timeIntervalSince(whole) + 86340) < 0.00001)

        // 10) RFC 3339 边界。
        let validTimes = ["2026-09-19T08:35:00+08:00", "2028-02-29T00:00:00Z", "2026-09-19T08:35:00.123+05:45"]
        let invalidTimes = ["2027-02-29T00:00:00Z", "2026-02-30T00:00:00Z", "2026-13-01T00:00:00Z",
                            "2026-09-19 08:35:00", "2026-09-19T08:35:60Z", "2026-09-19T08:35:00+24:00",
                            "2026-09-19T25:00:00Z"]
        for sample in validTimes {
            check("date-time 合法：\(sample)", CapabilityProtocol.isValidRFC3339DateTime(sample))
        }
        for sample in invalidTimes {
            check("date-time 非法：\(sample)", !CapabilityProtocol.isValidRFC3339DateTime(sample))
        }

        // 11) readiness 局部可用性检查（局部条件，不构成生产可用判定）。
        let scenario = try! JSONDecoder().decode(ReadinessObservation.self, from:
            Data(contentsOf: CapabilityProtocolPaths.fixtureURL(in: dir, relativeToFixtures: "readiness/ok-scenario-passed.json")))
        let probe = try! JSONDecoder().decode(ReadinessObservation.self, from:
            Data(contentsOf: CapabilityProtocolPaths.fixtureURL(in: dir, relativeToFixtures: "readiness/ok-probe-passed.json")))
        let nowInWindow = CapabilityProtocol.rfc3339Date("2026-09-19T08:32:00+08:00")!
        let scenarioUsable = CapabilityProtocol.isReadinessObservationUsable(scenario, now: nowInWindow)
        check("scenario_passed 且未过期可用", scenarioUsable.usable, scenarioUsable.reasons.joined(separator: "; "))
        let probeUsable = CapabilityProtocol.isReadinessObservationUsable(probe, now: nowInWindow)
        check("probe_passed 永不合格（探针不冒充生产可用）",
              !probeUsable.usable && probeUsable.reasons.contains { $0.contains("probe_passed") },
              probeUsable.reasons.joined(separator: "; "))
        let expiredUsable = CapabilityProtocol.isReadinessObservationUsable(
            scenario, now: CapabilityProtocol.rfc3339Date("2026-09-19T08:36:00+08:00")!)
        check("过期观察不可用", !expiredUsable.usable, expiredUsable.reasons.joined(separator: "; "))
        let future = ReadinessObservation(bindingId: scenario.bindingId, availability: "available",
                                          checkedAt: "2030-01-01T00:00:00Z", expiresAt: scenario.expiresAt,
                                          environmentFingerprint: scenario.environmentFingerprint,
                                          verification: "scenario_passed",
                                          verifiedScope: scenario.verifiedScope,
                                          evidenceRefs: scenario.evidenceRefs, reason: nil)
        let futureUsable = CapabilityProtocol.isReadinessObservationUsable(future, now: nowInWindow)
        check("checkedAt 疑似未来时间不采信", !futureUsable.usable, futureUsable.reasons.joined(separator: "; "))
        let skewedButTolerated = ReadinessObservation(bindingId: scenario.bindingId, availability: "available",
                                                      checkedAt: "2026-09-19T08:32:30+08:00",
                                                      expiresAt: scenario.expiresAt,
                                                      environmentFingerprint: scenario.environmentFingerprint,
                                                      verification: "scenario_passed",
                                                      verifiedScope: scenario.verifiedScope,
                                                      evidenceRefs: scenario.evidenceRefs, reason: nil)
        let toleratedUsable = CapabilityProtocol.isReadinessObservationUsable(skewedButTolerated, now: nowInWindow)
        check("容限内轻微领先仍可采信", toleratedUsable.usable, toleratedUsable.reasons.joined(separator: "; "))
        let inverted = ReadinessObservation(bindingId: scenario.bindingId, availability: "available",
                                            checkedAt: scenario.expiresAt, expiresAt: scenario.checkedAt,
                                            environmentFingerprint: scenario.environmentFingerprint,
                                            verification: "scenario_passed",
                                            verifiedScope: scenario.verifiedScope,
                                            evidenceRefs: scenario.evidenceRefs, reason: nil)
        let invertedUsable = CapabilityProtocol.isReadinessObservationUsable(inverted, now: nowInWindow)
        check("expiresAt 必须晚于 checkedAt", !invertedUsable.usable, invertedUsable.reasons.joined(separator: "; "))

        finish()
    }

    // MARK: 辅助

    static func fixture(_ rel: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: CapabilityProtocolPaths.fixtureURL(
            in: CapabilityProtocolPaths.defaultProtocolDirectory(), relativeToFixtures: rel)))
    }

    static func mutate(_ base: JSONValue, set fields: [String: JSONValue] = [:], remove: [String] = []) -> JSONValue {
        guard case .object(var obj) = base else { return base }
        for (key, value) in fields { obj[key] = value }
        for key in remove { obj.removeValue(forKey: key) }
        return .object(obj)
    }

    /// 按目标类型套用同一份合成变更：先按 wire 严格校验，再按需断言错误关键字。
    static func checkMutation(_ base: JSONValue, _ kind: CapabilityObjectKind,
                              fields: [String: JSONValue] = [:], remove: [String] = [],
                              keyword: String?, label: String) {
        let value = mutate(base, set: fields, remove: remove)
        let result = CapabilityProtocol.validate(kind: kind, value: value)
        if let keyword {
            check(label, !result.ok && result.errors.contains { $0.keyword == keyword },
                  result.errors.map(\.matchText).joined(separator: "; "))
        } else {
            check(label, result.ok, result.errors.map(\.matchText).joined(separator: "; "))
        }
    }

    /// 类型化解码 → 再编码 → 再解析 → 严格校验，证明 Codable 词汇表与冻结 wire 兼容。
    static func decodeAndRoundTrip(rel: String, dir: URL, encoder: JSONEncoder) -> (Bool, String) {
        func revalidate(_ reencoded: Data, kind: CapabilityObjectKind) -> (Bool, String) {
            guard let value = try? JSONValue.parse(reencoded) else { return (false, "再编码结果无法解析") }
            let result = CapabilityProtocol.validate(kind: kind, value: value)
            return result.ok ? (true, "") : (false, result.errors.map(\.matchText).joined(separator: "; "))
        }
        let data: Data
        do {
            data = try Data(contentsOf: CapabilityProtocolPaths.fixtureURL(in: dir, relativeToFixtures: rel))
        } catch {
            return (false, "\(error)")
        }
        func roundTrip<T: CapabilityWireObject>(_ type: T.Type, _ kind: CapabilityObjectKind,
                                     encode: (T) throws -> Data) -> (Bool, String) {
            guard let model = try? CapabilityProtocol.decodeWire(type, from: data),
                  let out = try? encode(model) else {
                return (false, "类型化解码或编码失败")
            }
            return revalidate(out, kind: kind)
        }
        switch rel.components(separatedBy: "/")[0] {
        case "capability-definition":
            return roundTrip(CapabilityDefinition.self, .capabilityDefinition) { try encoder.encode($0) }
        case "adapter-binding":
            return roundTrip(AdapterBinding.self, .adapterBinding) { try encoder.encode($0) }
        case "readiness":
            return roundTrip(ReadinessObservation.self, .readinessObservation) { try encoder.encode($0) }
        case "invocation":
            return roundTrip(CapabilityInvocation.self, .capabilityInvocation) { try encoder.encode($0) }
        case "receipt":
            return roundTrip(CapabilityReceipt.self, .capabilityReceipt) { try encoder.encode($0) }
        default:
            return (false, "未知往返目标：\(rel)")
        }
    }

    static func finish() {
        if failures.isEmpty {
            print("ALL PASS（\(total) 项断言）")
            exit(0)
        }
        print("FAILED \(failures.count)/\(total)：")
        for item in failures { print("  - \(item)") }
        exit(1)
    }
}
