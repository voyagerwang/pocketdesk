/**
 * [INPUT]: ModelConfig、AgentRunner 的完整消息与工具定义，以及本机已登录 ChatGPT 的 Codex CLI。
 * [OUTPUT]: 单次隔离规划的 ModelTurn 或 ModelFailure，以及不含正文/凭据的分段时序；不执行工具、不重试、不切回 API。
 * [POS]: Sources 的 Codex 推理后端；凭据留在原 CODEX_HOME，实际动作与去重回执仍归 AgentRunner。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin

enum CodexModelClient {
    private static let observationLock = NSLock()
    private static var observations: [[String: Any]] = []
    private static let loginLock = NSLock()
    private static var checkedLogins: [String: TimeInterval] = [:]

    static func diagnostics(limit: Int = 30) -> [[String: Any]] {
        observationLock.lock(); defer { observationLock.unlock() }
        return Array(observations.suffix(max(0, min(limit, 30))))
    }
    static func resetDiagnosticsForTesting() {
        observationLock.lock(); observations.removeAll(); observationLock.unlock()
        loginLock.lock(); checkedLogins.removeAll(); loginLock.unlock()
    }

    static func send(config: ModelConfig, messages: [[String: Any]], tools: [[String: Any]]?,
                     timeoutSeconds: Double = 60,
                     completion: @escaping (Result<ModelTurn, ModelFailure>) -> Void) {
        guard let binary = binaryURL() else {
            completion(.failure(.init(httpStatus: nil, message: "未找到 Codex CLI，请先安装或打开已登录的 Codex。")))
            return
        }
        perform(binary: binary, prefixArguments: [], messages: messages, tools: tools,
                timeoutSeconds: timeoutSeconds, completion: completion)
    }

    // 注入假进程验证协议；生产入口始终使用上方已解析的本机 CLI。
    static func sendForTesting(binary: URL, prefixArguments: [String], messages: [[String: Any]],
                               tools: [[String: Any]]?, catalog: [String: Any]? = nil, timeoutSeconds: Double,
                               completion: @escaping (Result<ModelTurn, ModelFailure>) -> Void) {
        perform(binary: binary, prefixArguments: prefixArguments, messages: messages, tools: tools,
                catalog: catalog, timeoutSeconds: timeoutSeconds, completion: completion)
    }

    static func binaryURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [env["POCKETDESK_CODEX_BINARY"],
                          "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex",
                          home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return candidates.compactMap { $0 }.first(where: {
            $0.hasPrefix("/") && !$0.contains("\0") && FileManager.default.isExecutableFile(atPath: $0)
        }).map { URL(fileURLWithPath: $0) }
    }

    static func environment(_ source: [String: String]) -> [String: String] {
        var result = source
        // 不读取、复制或重写 OAuth 凭据；清除能把子进程导向另一份 API 账单的环境覆盖。
        for key in source.keys where key.hasSuffix("_API_KEY") || key.hasSuffix("_ACCESS_TOKEN") ||
            ["CODEX_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE", "OPENAI_API_BASE_URL", "CODEX_API_BASE_URL",
             "CHATGPT_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID", "CODEX_MODEL_PROVIDER"].contains(key) {
            result.removeValue(forKey: key)
        }
        return result
    }

    // ---------- 一次完整规划 ----------
    private static func perform(binary: URL, prefixArguments: [String], messages: [[String: Any]],
                                tools: [[String: Any]]?, catalog: [String: Any]? = nil, timeoutSeconds: Double,
                                completion: @escaping (Result<ModelTurn, ModelFailure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var temporary: URL?
            let result: Result<ModelTurn, ModelFailure>
            let started = ProcessInfo.processInfo.systemUptime
            var metrics: [String: Any] = ["model": ModelConfig.codexModel, "startedAt": ISO8601DateFormatter().string(from: Date()),
                                          "toolCount": tools?.count ?? 0]
            var loginStamp: String?
            do {
                guard timeoutSeconds.isFinite, timeoutSeconds > 0 else {
                    throw CodexModelProtocol.Failure(message: "Codex 请求时限不合法。")
                }
                let definitions = try CodexModelProtocol.toolList(tools)
                let prompt = try CodexModelProtocol.prompt(messages: messages, tools: tools)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pocketdesk-codex-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                temporary = directory
                let schemaFile = directory.appendingPathComponent("output-schema.json")
                let schema = try JSONSerialization.data(withJSONObject: CodexModelProtocol.outputSchema(tools: definitions))
                try schema.write(to: schemaFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: schemaFile.path)
                let instructionsFile = directory.appendingPathComponent("planner-instructions.txt")
                try CodexModelProtocol.instructions.write(to: instructionsFile, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: instructionsFile.path)
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                let env = environment(ProcessInfo.processInfo.environment)
                let codexHome = env["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ??
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
                let cachedCatalog: [String: Any]
                if let catalog { cachedCatalog = catalog }
                else {
                    let cacheFile = codexHome.appendingPathComponent("models_cache.json")
                    guard let info = try? cacheFile.resourceValues(forKeys: [.fileSizeKey]),
                          let size = info.fileSize, size <= 16 * 1024 * 1024,
                          let data = try? Data(contentsOf: cacheFile),
                          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw CodexModelProtocol.Failure(message: "Codex 当前模型目录不可读，未请求模型。请先打开 Codex 并刷新模型。")
                    }
                    cachedCatalog = value
                }
                let plannerCatalog = try CodexModelProtocol.plannerCatalog(cachedCatalog)
                let catalogFile = directory.appendingPathComponent("planner-models.json")
                try JSONSerialization.data(withJSONObject: plannerCatalog).write(to: catalogFile, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: catalogFile.path)
                metrics["assemblyMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
                let loginStarted = ProcessInfo.processInfo.systemUptime
                loginStamp = loginFingerprint(binary: binary, prefix: prefixArguments, environment: env)
                let cached = hasCheckedLogin(loginStamp)
                metrics["loginCached"] = cached
                if !cached {
                    let login = try run(binary: binary, arguments: prefixArguments + ["login", "status"], cwd: directory,
                                        environment: env, input: nil, timeout: min(10, timeoutSeconds), jsonEvents: false)
                    guard !login.timedOut else { throw CodexModelProtocol.Failure(message: "Codex 登录状态检查超时，未请求模型。") }
                    let status = String(data: login.output, encoding: .utf8) ?? ""
                    // CLI login status 将状态写在 stderr；只匹配固定状态，不输出任意进程报文。
                    let loginStatus = status + "\n" + (String(data: login.diagnostics, encoding: .utf8) ?? "")
                    guard login.code == 0, loginStatus.contains("Logged in using ChatGPT") else {
                        throw ModelFailure(httpStatus: 401, message: "Codex 未使用 ChatGPT 登录。请先在 Codex 登录你的 ChatGPT 账号；未切换到 API Key。")
                    }
                    rememberLogin(loginStamp)
                }
                metrics["loginMs"] = (ProcessInfo.processInfo.systemUptime - loginStarted) * 1000
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw CodexModelProtocol.Failure(message: "Codex 请求超时，未请求模型。") }
                let arguments = prefixArguments + execArguments(schema: schemaFile, cwd: directory)
                // planner 指令已由 model_instructions_file 提供，不再放入用户输入重复计费。
                let payload = prompt
                metrics["payloadBytes"] = payload.utf8.count
                metrics["messageBytes"] = (try? JSONSerialization.data(withJSONObject: messages).count) ?? 0
                metrics["toolDefinitionBytes"] = (try? JSONSerialization.data(withJSONObject: tools ?? []).count) ?? 0
                let output = try run(binary: binary, arguments: arguments, cwd: directory, environment: env,
                                     input: Data(payload.utf8), timeout: remaining, jsonEvents: true)
                metrics.merge(output.metrics) { _, next in next }
                guard !output.timedOut else { throw CodexModelProtocol.Failure(message: "Codex 请求超时，已停止；没有重试或切换服务。") }
                if let failure = output.failure { throw CodexModelProtocol.Failure(message: failure) }
                guard output.code == 0 else { throw CodexModelProtocol.Failure(message: "Codex 进程未成功结束，请检查登录、套餐额度或网络；没有重试。") }
                guard output.turnCompleted, let final = output.finalText else {
                    throw CodexModelProtocol.Failure(message: "Codex 缺少完整的模型完成回执，未执行工具。")
                }
                let turn = try CodexModelProtocol.turn(text: final, tools: definitions, usage: output.usage)
                if let usage = turn.usage {
                    metrics["inputTokens"] = usage["prompt_tokens"]
                    metrics["outputTokens"] = usage["completion_tokens"]
                    metrics["cachedTokens"] = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"]
                }
                result = .success(turn)
            } catch let failure as ModelFailure {
                result = .failure(failure)
            } catch let failure as CodexModelProtocol.Failure {
                result = .failure(.init(httpStatus: nil, message: failure.message))
            } catch {
                // 不回传进程 stderr、请求正文、文件路径或系统错误中的凭据。
                result = .failure(.init(httpStatus: nil, message: "Codex 客户端无法启动或保存隔离请求，请检查 CLI 安装与本机权限。"))
            }
            // 完成回调前清理上下文与 schema，调用方不必等待另一条异步清理链。
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
            if case .failure = result { forgetLogin(loginStamp); metrics["status"] = "failed" }
            else { metrics["status"] = "completed" }
            metrics["totalMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            observationLock.lock(); observations.append(metrics)
            if observations.count > 30 { observations.removeFirst(observations.count - 30) }
            observationLock.unlock()
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]) {
                NSLog("[CodexModel] %@", String(decoding: data, as: UTF8.self))
            }
            completion(result)
        }
    }

    // ---------- 短时登录复用 ----------
    // 只读文件元数据，不打开 auth.json 内容；账号文件或程序变化即失效，缺少文件时不缓存。
    static func loginFingerprint(binary: URL, prefix: [String], environment: [String: String]) -> String? {
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let auth = home.appendingPathComponent("auth.json")
        guard let authInfo = try? FileManager.default.attributesOfItem(atPath: auth.path),
              let binaryInfo = try? FileManager.default.attributesOfItem(atPath: binary.resolvingSymlinksInPath().path),
              let authDate = authInfo[.modificationDate] as? Date,
              let binaryDate = binaryInfo[.modificationDate] as? Date else { return nil }
        let identity: [Any] = [binary.path, binaryDate.timeIntervalSince1970, binaryInfo[.size] ?? 0,
                              auth.path, authDate.timeIntervalSince1970, authInfo[.size] ?? 0,
                              authInfo[.systemFileNumber] ?? 0, prefix]
        return (try? JSONSerialization.data(withJSONObject: identity)).map { String(decoding: $0, as: UTF8.self) }
    }
    private static func hasCheckedLogin(_ stamp: String?) -> Bool {
        guard let stamp else { return false }
        loginLock.lock(); defer { loginLock.unlock() }
        return (checkedLogins[stamp] ?? 0) > ProcessInfo.processInfo.systemUptime
    }
    private static func rememberLogin(_ stamp: String?) {
        guard let stamp else { return }
        loginLock.lock(); defer { loginLock.unlock() }
        checkedLogins = checkedLogins.filter { $0.value > ProcessInfo.processInfo.systemUptime }
        checkedLogins[stamp] = ProcessInfo.processInfo.systemUptime + 60
    }
    private static func forgetLogin(_ stamp: String?) {
        guard let stamp else { return }
        loginLock.lock(); checkedLogins.removeValue(forKey: stamp); loginLock.unlock()
    }

    static func execArguments(schema: URL, cwd: URL) -> [String] {
        // 本机 0.159 协议的请求工具目录与恶意工具响应均已用本地假供应商核验。
        // code-mode 包装器仍可被供应商幻觉调用，但宿主已在任何执行前关闭。
        let disabledFeatures = ["shell_tool", "unified_exec", "apps", "plugins", "remote_plugin",
                                "multi_agent", "multi_agent_v2", "code_mode_host", "view_image", "image_generation",
                                "browser_use", "browser_use_external", "computer_use", "goals", "memories", "hooks",
                                "sleep_tool", "skill_search", "skill_mcp_dependency_install", "tool_suggest",
                                "workspace_dependencies", "enable_request_compression", "auth_elicitation",
                                "send_message_to_user_async", "standalone_web_search", "default_mode_request_user_input",
                                "current_time_reminder"]
        let instructionPath = cwd.appendingPathComponent("planner-instructions.txt").path
        let encoded = (try? JSONSerialization.data(withJSONObject: instructionPath, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        let config = ["model_provider=\"openai\"", "model_reasoning_effort=\"low\"", "model_reasoning_summary=\"none\"",
                      "service_tier=\"default\"", "analytics.enabled=false", "web_search=\"disabled\"", "mcp_servers={}", "project_doc_max_bytes=0",
                      "include_apps_instructions=false", "include_environment_context=false", "include_permissions_instructions=false",
                      "include_collaboration_mode_instructions=false", "skills.bundled.enabled=false", "skills.include_instructions=false",
                      "tools.update_plan.enabled=false", "tools.experimental_request_user_input.enabled=false",
                      "model_instructions_file=" + String(decoding: encoded, as: UTF8.self),
                      "model_catalog_json=" + String(decoding: (try? JSONSerialization.data(withJSONObject: cwd.appendingPathComponent("planner-models.json").path,
                                                   options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8), as: UTF8.self),
                      "features.skip_host_skill_discovery=true", "agents.enabled=false",
                      "features.code_mode.excluded_tool_namespaces=[\"functions\",\"apply_patch\",\"clock\"]"] +
            disabledFeatures.map { "features.\($0)=false" }
        var arguments = ["--no-daemon", "--strict-config", "-a", "never", "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--json",
                         "--color", "never", "--skip-git-repo-check", "--sandbox", "read-only", "--output-schema", schema.path,
                         "--cd", cwd.path, "--model", ModelConfig.codexModel]
        for value in config { arguments.append(contentsOf: ["-c", value]) }
        arguments.append("-")
        return arguments
    }

    // ---------- 进程、时限与输出 ----------
    private struct Output {
        var code: Int32 = -1
        var output = Data()
        var diagnostics = Data()
        var timedOut = false
        var failure: String?
        var finalText: String?
        var turnCompleted = false
        var usage: [String: Any]?
        var metrics: [String: Any] = [:]
    }

    private final class Capture {
        let lock = NSLock()
        var value = Output()
        var remainder = Data()
        var diagnosticRemainder = Data()
        let started = ProcessInfo.processInfo.systemUptime
        var turnStarted = false
        var warningItems = 0, reasoningItems = 0, agentMessages = 0, routerErrors = 0
        let jsonEvents: Bool
        init(jsonEvents: Bool) { self.jsonEvents = jsonEvents }

        func append(_ data: Data, diagnostics: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if diagnostics {
                if value.diagnostics.count < 16 * 1024 { value.diagnostics.append(data.prefix(16 * 1024 - value.diagnostics.count)) }
                if jsonEvents {
                    diagnosticRemainder.append(data)
                    while let newline = diagnosticRemainder.firstIndex(of: 10) {
                        receiveDiagnostic(Data(diagnosticRemainder[..<newline])); diagnosticRemainder.removeSubrange(...newline)
                    }
                    if diagnosticRemainder.count > 16 * 1024 { receiveDiagnostic(diagnosticRemainder); diagnosticRemainder.removeAll() }
                }
                return value.failure != nil
            }
            guard value.output.count + data.count <= 4 * 1024 * 1024 else {
                value.failure = "Codex 输出超过大小限制，已停止。"; return true
            }
            value.output.append(data)
            guard jsonEvents else { return false }
            remainder.append(data)
            while let newline = remainder.firstIndex(of: 10) {
                let line = Data(remainder[..<newline]); remainder.removeSubrange(...newline)
                if !line.isEmpty { receive(line) }
            }
            return value.failure != nil
        }
        func close(code: Int32) -> Output {
            lock.lock(); defer { lock.unlock() }
            if jsonEvents && !remainder.isEmpty { receive(remainder); remainder.removeAll() }
            if jsonEvents && !diagnosticRemainder.isEmpty { receiveDiagnostic(diagnosticRemainder); diagnosticRemainder.removeAll() }
            value.code = code
            value.metrics["processExitMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            value.metrics["startupWarningItems"] = warningItems
            value.metrics["reasoningItems"] = reasoningItems
            value.metrics["agentMessages"] = agentMessages
            value.metrics["nativeRouterErrors"] = routerErrors
            return value
        }
        func timeout() { lock.lock(); value.timedOut = true; lock.unlock() }
        func launched() { lock.lock(); value.metrics["processLaunchMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000; lock.unlock() }

        private func receiveDiagnostic(_ line: Data) {
            guard let text = String(data: line, encoding: .utf8), text.contains("ERROR"),
                  text.contains("codex_core::tools::router") else { return }
            routerErrors += 1
            // 原生工具失败只出现在 stderr；必须立即结束，不能放任 CLI 内部再向模型续轮。
            value.failure = "Codex 尝试调用被禁用的原生工具，已停止本轮；实际工具只由 PocketDesk 执行。"
        }

        private func receive(_ line: Data) {
            guard value.failure == nil else { return }
            guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = event["type"] as? String else {
                value.failure = "Codex 返回了无效协议事件，未执行工具。"; return
            }
            if type.hasPrefix("item.") {
                guard let item = event["item"] as? [String: Any], let kind = item["type"] as? String,
                      ["agent_message", "reasoning", "error"].contains(kind) else {
                    value.failure = "Codex 提出了原生工具操作，已停止；工具只能由 PocketDesk 执行。"; return
                }
                // CLI 启动时用 error item 报告被关闭的宿主能力；它不等于 turn.failed。
                // 不展示原始报文，是否完成仍以最终 turn.completed 与进程退出为准。
                if kind == "error" {
                    if !turnStarted { warningItems += 1 }
                    else { value.failure = "Codex 本轮出现原生错误，已停止；没有自动重试或切换服务。" }
                }
                if type == "item.completed", kind == "reasoning" { reasoningItems += 1 }
                if type == "item.completed", kind == "agent_message" {
                    guard !value.turnCompleted, let text = item["text"] as? String else {
                        value.failure = "Codex 最终消息与完成回执不一致，未执行工具。"; return
                    }
                    agentMessages += 1
                    if value.metrics["firstMessageMs"] == nil { value.metrics["firstMessageMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000 }
                    value.finalText = text
                }
            } else if type == "turn.completed" {
                guard !value.turnCompleted else { value.failure = "Codex 重复返回完成回执，未执行工具。"; return }
                value.turnCompleted = true
                value.metrics["turnCompletedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
                if let raw = event["usage"] as? [String: Any] { value.usage = CodexModelProtocol.usage(raw) }
            } else if type == "turn.started" {
                turnStarted = true
                value.metrics["turnStartedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            } else if type == "turn.failed" || type == "error" {
                value.failure = "Codex 本轮请求失败，请检查套餐额度、模型访问或网络；没有自动重试。"
            } else if type != "thread.started" {
                value.failure = "Codex 协议事件不受支持，未执行工具。"
            }
        }
    }

    private static func run(binary: URL, arguments: [String], cwd: URL, environment: [String: String],
                            input: Data?, timeout: Double, jsonEvents: Bool) throws -> Output {
        let process = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = binary; process.arguments = arguments
        process.currentDirectoryURL = cwd; process.environment = environment
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
        let capture = Capture(jsonEvents: jsonEvents), outRead = NSLock(), errRead = NSLock()
        func stop() {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            outRead.lock(); defer { outRead.unlock() }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if capture.append(data, diagnostics: false) { stop() }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            errRead.lock(); defer { errRead.unlock() }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if capture.append(data, diagnostics: true) { stop() }
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close(); try? stdin.fileHandleForWriting.close()
        }
        try process.run()
        capture.launched()
        let timer = DispatchWorkItem { capture.timeout(); stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        do { if let input { try stdin.fileHandleForWriting.write(contentsOf: input) } }
        catch { stop(); process.waitUntilExit(); timer.cancel(); throw error }
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit(); timer.cancel()
        stdout.fileHandleForReading.readabilityHandler = nil; stderr.fileHandleForReading.readabilityHandler = nil
        outRead.lock(); _ = capture.append(stdout.fileHandleForReading.readDataToEndOfFile(), diagnostics: false); outRead.unlock()
        errRead.lock(); _ = capture.append(stderr.fileHandleForReading.readDataToEndOfFile(), diagnostics: true); errRead.unlock()
        return capture.close(code: process.terminationStatus)
    }
}
