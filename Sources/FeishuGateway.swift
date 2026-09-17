/**
 * [INPUT]: FeishuCLI 的实时命令帮助/授权范围/用户身份业务调用，TaskStore 的操作记录。
 * [OUTPUT]: CLI 全业务域发现与执行；按真实命令风险处理幂等记录、高风险补充确认及缺权限错误。
 * [POS]: PocketDesk 飞书通用适配，不复制 Workbench 业务代码；模型不能更换身份、读取凭证或执行 shell。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CryptoKit
import CoreFoundation

enum FeishuGateway {
    static let domains = Set(["application", "approval", "apps", "attendance", "base", "calendar", "contact", "docs", "drive", "event", "im", "mail", "markdown", "mindnotes", "minutes", "note", "okr", "sheets", "slides", "task", "vc", "whiteboard", "wiki"])
    static var help = FeishuCLI.help
    static var invoke = FeishuCLI.run
    static var authorization = FeishuCLI.capabilities
    private static let queue = DispatchQueue(label: "PocketDesk.feishu.gateway")
    static func encode(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
    static func valid(_ command: [String]) -> Bool {
        guard (1...4).contains(command.count), domains.contains(command[0]) else { return false }
        return command.allSatisfy { $0.range(of: "^[a-z+][a-z0-9_+.-]*$", options: .regularExpression) != nil }
    }
    static func discover(_ command: [String]) -> String {
        if command.isEmpty {
            switch authorization() {
            case .failure(let error): return "未执行：" + error.message
            case .success(let data): return encode(["authorization": data, "domains": domains.sorted(), "instruction": "先按 domain 查看帮助，再查看具体命令帮助；以实际 scopes 和 CLI 权限检查为准，不承诺整域全部可用。"])
            }
        }
        if command.count == 2, command[0] == "schema",
           let domain = command[1].split(separator: ".").first, domains.contains(String(domain)),
           command[1].range(of: "^[a-z][a-z0-9_.]+$", options: .regularExpression) != nil {
            switch FeishuCLI.reference(command + ["--format", "json"]) {
            case .success(let data): return encode(data)
            case .failure(let error): return "未执行：" + error.message
            }
        }
        if command.count == 3, command[0] == "skills", command[1] == "read",
           command[2].hasPrefix("lark-"), !command[2].contains(".."),
           command[2].range(of: "^[a-zA-Z0-9_./-]+$", options: .regularExpression) != nil {
            switch FeishuCLI.reference(command) {
            case .success(let data): return encode(data)
            case .failure(let error): return "未执行：" + error.message
            }
        }
        guard valid(command) else { return "未执行：请选择飞书业务域，不支持凭证或 CLI 配置管理。" }
        switch help(command) {
        case .success(let data): return encode(data)
        case .failure(let error): return "未执行：" + error.message
        }
    }
    static func execute(command: [String], options: [String: Any], confirmed: Bool, taskId: String,
                        authorized: @escaping () -> Bool, completion: @escaping (FeishuMessaging.Outcome) -> Void) {
        queue.async { completion(perform(command: command, options: options, confirmed: confirmed, taskId: taskId, authorized: authorized)) }
    }
    static func perform(command: [String], options: [String: Any], confirmed: Bool, taskId: String,
                        authorized: () -> Bool) -> FeishuMessaging.Outcome {
        guard valid(command), command.count >= 2 else { return .failed("请选择具体飞书业务命令。") }
        guard authorized(), let initial = TaskStore.task(id: taskId), initial.status == .running else { return .failed("控制权失效或任务已结束。") }
        guard case .success(let documentation) = help(command), let usage = documentation["help"] as? String else { return .failed("无法核对命令用法，未执行。") }
        let risk: String
        if usage.contains("Risk: high-risk-write") { risk = "high-risk-write" }
        else if usage.contains("Risk: write") { risk = "write" }
        else if usage.contains("Risk: read") { risk = "read" }
        else { return .failed("未能核对命令风险，请先选择帮助中列出的具体命令。") }
        // 身份和确认只能由本地适配层决定，禁止通过 options 更换 profile 或隐藏回执。
        let reserved: Set<String> = ["as", "profile", "format", "json", "jq", "yes", "help", "dry-run"]
        var args = command
        for key in options.keys.sorted() {
            guard key.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil,
                  !reserved.contains(key), usage.contains("--" + key + " ") else { return .failed("命令不接受参数：" + key) }
            let values = (options[key] as? [Any]) ?? [options[key]!]
            for value in values {
                let string: String
                if let value = value as? String { string = value }
                else if let value = value as? NSNumber { string = CFGetTypeID(value) == CFBooleanGetTypeID() ? (value.boolValue ? "true" : "false") : value.stringValue }
                else { return .failed("参数需使用文本、数字或布尔值；JSON 正文作为字符串传递。") }
                guard string.utf8.count <= 32000 else { return .failed("参数内容过长，请缩小范围。") }
                // 等号传值，消息正文即使以 -- 开头也不能成为 CLI 参数。
                args.append("--" + key + "=" + string)
            }
        }
        let key = SHA256.hash(data: Data(encode(args).utf8)).map { String(format: "%02x", $0) }.joined()
        guard var task = TaskStore.task(id: taskId), task.status == .running, authorized() else { return .failed("控制权失效或任务已结束。") }
        if risk != "read", let previous = task.feishuOperations?[key] {
            return previous == "pending" ? .failed("此前操作结果待核对，不会自动重试。") : .sent(previous)
        }
        if risk == "high-risk-write" {
            if !confirmed || task.feishuConfirmation?.key != key || task.supplementCount <= (task.feishuConfirmation?.supplement ?? task.supplementCount) {
                task.feishuConfirmation = FeishuConfirmation(key: key, supplement: task.supplementCount)
                do { try TaskStore.save(task) } catch { return .failed("无法保存待确认操作，未执行。") }
                return .needsInput("飞书将此操作标为高风险，请确认是否执行：\n" + command.joined(separator: " ") + "\n" + encode(options))
            }
            guard usage.contains("--yes") else { return .failed("该命令的确认方式尚未识别，未执行。") }
            args.append("--yes")
        }
        if risk != "read" {
            task.feishuOperations = task.feishuOperations ?? [:]
            task.feishuOperations?[key] = "pending"
            do { try TaskStore.save(task) } catch { return .failed("无法保存操作记录，未执行。") }
        }
        args += ["--as", "user", "--format", "json"]
        switch invoke(args) {
        case .failure(let failure): return .failed(failure.message + (risk == "read" ? "" : " 操作未确认，不会自动重试。"))
        case .success(let data):
            let result = encode(data)
            let content = String(result.prefix(20000)) + (result.count > 20000 ? "\n结果过长，已截断，请缩小查询范围。" : "")
            if risk != "read" {
                guard var current = TaskStore.task(id: taskId) else { return .failed("操作已返回，但无法保存记录，请核对飞书。") }
                current.feishuOperations = current.feishuOperations ?? [:]
                current.feishuOperations?[key] = content
                do { try TaskStore.save(current) } catch { return .failed("操作已返回，但记录保存失败，请核对飞书。") }
            }
            return .sent(content)
        }
    }
}
