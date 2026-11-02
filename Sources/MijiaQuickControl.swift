/**
 * [INPUT]: 用户完整灯光/空调插座开关单句、私有不可变目标绑定、MijiaHomeScope 票据与 Gateway 的规格/去重/租约边界。
 * [OUTPUT]: 已确认单设备的零模型控制；仅精确别名与开关布尔值，完成后直接使用真实回执，不拿云缓存跳过写入。
 * [POS]: AgentRunner 的轻量控制入口；绑定只定义用户已确认目标，实际调用仍由 Gateway 和 Python 实时核对家庭及规格。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin

enum MijiaQuickControl {
    struct Binding: Codable {
        let version: Int
        let account: String
        let homeID: String
        let revision: String
        let deviceID: String
        let propertyID: String
        let name: String
        let aliases: [String]
    }
    struct Request: Equatable { let value: Bool }
    static var bindingURL = MijiaBridge.directory.appendingPathComponent("quick-light.json")

    static func load() throws -> Binding { try load(at: bindingURL) }

    static func load(at url: URL) throws -> Binding {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              info.st_flags & UInt32(UF_IMMUTABLE) != 0, info.st_size > 0, info.st_size < 8192 else {
            throw CocoaError(.fileReadNoPermission)
        }
        let binding = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: url))
        guard binding.version == 1, binding.account.count == 64, !binding.homeID.isEmpty,
              UUID(uuidString: binding.revision) != nil, !binding.deviceID.isEmpty,
              binding.propertyID.range(of: "^[1-9][0-9]*\\.[1-9][0-9]*$", options: .regularExpression) != nil,
              !binding.name.isEmpty, binding.name.count <= 40,
              !binding.aliases.isEmpty, binding.aliases.count <= 12,
              Set(binding.aliases).count == binding.aliases.count,
              binding.aliases.allSatisfy({ !$0.isEmpty && $0.count <= 40 && !$0.contains("\n") }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return binding
    }

    // 两个绑定分别封存；歧义或损坏不靠文件顺序决定控制对象。
    static func resolve(_ text: String) -> (Binding, Request)? {
        let urls = [bindingURL, bindingURL.deletingLastPathComponent().appendingPathComponent("quick-ac.json")]
        var matches: [(Binding, Request)] = []
        for url in urls {
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { continue }
                return nil
            }
            guard let binding = try? load(at: url) else { return nil }
            if let request = request(in: text, aliases: binding.aliases) { matches.append((binding, request)) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func request(in text: String, aliases: [String]) -> Request? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count <= 80, !input.contains("\n"), !input.contains("\r") else { return nil }
        let target = aliases.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard !target.isEmpty else { return nil }
        let light = aliases.contains("灯")
        let action = "打开|开启|开|关闭|关掉|关|熄灭|熄" + (light ? "|亮" : "")
        let prefix = "^(?:请)?(?:帮我|请你|麻烦你)?\\s*"
        let suffix = "(?:一下)?[。！!]*$"
        if light, input.range(of: prefix + "打开开灯" + suffix, options: .regularExpression) != nil {
            return Request(value: true)
        }
        let patterns = [prefix + "(" + action + ")\\s*(?:" + target + ")" + suffix,
                        prefix + "(?:把)?(?:" + target + ")\\s*(" + action + ")" + suffix]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
                  let range = Range(match.range(at: 1), in: input) else { continue }
            return Request(value: ["打开", "开启", "开", "亮"].contains(String(input[range])))
        }
        return nil
    }

    static func matches(_ binding: Binding, _ ticket: MijiaHomeScope.Ticket) -> Bool {
        binding.account == ticket.account && binding.homeID == ticket.homeID && binding.revision == ticket.revision
    }
}

extension AgentRunner {
    static func tryQuickControl(task: AgentTask, completion: @escaping (Outcome) -> Void) -> Bool {
        guard task.attempt == 1, task.supplementCount == 0, task.context == nil,
              task.transcript?.isEmpty != false,
              let (binding, request) = MijiaQuickControl.resolve(task.text) else { return false }
        let ticket: MijiaHomeScope.Ticket
        do {
            ticket = try MijiaGateway.scope.authorize()
            guard MijiaQuickControl.matches(binding, ticket) else { return false }
        } catch { return false }
        let write = MijiaGateway.BoundWrite(ticket: ticket, device: binding.deviceID,
                                           property: binding.propertyID, value: request.value)
        MijiaGateway.executeBound(write, taskId: task.id, authorized: { canControl(task.id) }) { result in
            guard let current = TaskStore.task(id: task.id), current.status == .running,
                  current.attempt == task.attempt else {
                completion(Outcome(content: nil, usage: .zero, error: "任务已结束，控制结果请核对。", pages: [], rounds: 0, drifted: false)); return
            }
            var content: String?, failureText: String?, needsInput = false
            switch result {
            case .sent(let message): content = message
            case .needsInput(let message): content = message; needsInput = true
            case .failed(let message): failureText = message
            }
            let callID = "mijia-light-" + UUID().uuidString
            var saved = current
            saved.transcript = [
                ["role": "user", "content": task.text],
                ["role": "assistant", "tool_calls": [["id": callID, "type": "function", "function": ["name": "mijia", "arguments": MijiaGateway.encode(write.arguments)]]]],
                ["role": "tool", "tool_call_id": callID, "content": content ?? failureText ?? "结果未确认。"],
                ["role": "assistant", "content": content ?? failureText ?? "结果未确认。"]
            ]
            do { try TaskStore.save(saved) }
            catch { content = nil; failureText = "控制回执保存失败，请核对设备状态；不会重复发送。" }
            completion(Outcome(content: content, usage: .zero, error: failureText, pages: [], rounds: 0, drifted: false,
                               needsInput: needsInput, recovery: failureText != nil || needsInput ? .init(kind: .executionFailure) : nil))
        }
        return true
    }
}
