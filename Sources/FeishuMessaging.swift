/**
 * [INPUT]: FeishuCLI 的用户身份收件者/群成员查询与发送，TaskStore 的持久候选、发送占用和控制租约，CoreFoundation 的 JSON 布尔/数值类型核验。
 * [OUTPUT]: 联系人/群聊/机器人收件者文字与群内真实 @；原名称查无结果才对机器人/群做一次边界类型词查询，补查唯一准确同名才自动外发，其他候选等待用户选择。发送者固定本人，同名补充冻结正文及提及计划，发送前原子占用、回执落库，未知结果不自动重试。
 * [POS]: 小精灵飞书消息的确定性业务边界；模型只描述收件者、正文与提及者，不能指定 argv、身份或凭证。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreFoundation

enum FeishuMessaging {
    enum Outcome { case sent(String), needsInput(String), failed(String) }
    static var invoke = FeishuCLI.run
    private static let queue = DispatchQueue(label: "PocketDesk.feishu")
    private static let maximumMentions = 20
    private static let maximumTextBytes = 16000

    static func execute(recipient: String, text: String, choice: String?, taskId: String, kind: String = "person",
                        mentions: [String] = [], authorized: @escaping () -> Bool, completion: @escaping (Outcome) -> Void) {
        queue.async { completion(perform(recipient: recipient, text: text, choice: choice, taskId: taskId,
                                         kind: kind, mentions: mentions, authorized: authorized)) }
    }

    static func perform(recipient: String, text: String, choice: String?, taskId: String, kind: String = "person",
                        mentions: [String] = [], authorized: () -> Bool) -> Outcome {
        guard let task = TaskStore.task(id: taskId), task.status == .running, authorized() else {
            return .failed("控制权已失效，请重新连接。")
        }
        if let delivery = task.feishuDelivery { return receipt(delivery) }
        guard ["person", "group", "bot"].contains(kind) else { return .failed("请说明发给联系人、群聊还是机器人。") }
        var messageText = text
        var names = mentions
        var resolved: [FeishuContact] = []
        var target: FeishuContact?
        if let choice, !choice.isEmpty {
            guard let pending = task.feishuChoice, task.supplementCount > pending.supplement,
                  (pending.kind ?? "person") == kind, let index = Int(choice), pending.contacts.indices.contains(index - 1) else {
                return .failed("候选选择无效，请补充目标姓名或群名重新查找。")
            }
            // 用户只回答序号时，本地保存的正文与提及计划才是权威，不依赖模型重传。
            messageText = pending.text
            names = pending.mentions ?? []
            resolved = pending.resolvedMentions ?? []
            if let group = pending.recipient {
                target = group
                resolved.append(pending.contacts[index - 1])
            } else { target = pending.contacts[index - 1] }
        }
        guard !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              messageText.utf8.count <= maximumTextBytes else { return .failed("消息为空或超过 16000 字节。") }
        // CLI 支持正文中的提及标记；所有真实提及必须先经过群成员核验。
        guard messageText.range(of: "<\\s*at\\b", options: [.regularExpression, .caseInsensitive]) == nil else {
            return .failed("正文含未核对的飞书艾特标记，请明确指定要艾特的群成员。")
        }
        guard names.count <= maximumMentions,
              names.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 50 }) else {
            return .failed("请提供完整的艾特姓名，一条消息最多艾特 20 位群成员。")
        }
        guard names.isEmpty || kind == "group" else { return .failed("艾特成员需要指定飞书群聊。") }
        if target == nil {
            guard !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  recipient.count <= (kind == "group" ? 64 : 50) else { return .failed("请提供联系人姓名、邮箱或完整群名。") }
            let queries = [recipient] + (fallbackRecipient(recipient, kind: kind).map { [$0] } ?? [])
            var contacts: [FeishuContact] = []
            var confirmFallback = false
            querySearch: for (index, query) in queries.enumerated() {
                // 原始查询期间也可能失权；第二次只读查询不能沿用过期任务。
                if index > 0 {
                    guard authorized(), TaskStore.task(id: taskId)?.status == .running else {
                        return .failed("任务已结束或控制权已失效，未发送。")
                    }
                }
                let args = kind == "group"
                    ? ["im", "+chat-search", "--query", query, "--disable-search-by-user", "--search-types", "private,public_joined,external", "--page-size", "100", "--as", "user", "--format", "json"]
                    : ["contact", kind == "bot" ? "+search-bot" : "+search-user", "--query", query, "--page-size", "30", "--as", "user", "--format", "json"]
                switch invoke(args) {
                case .failure(let failure): return .failed(failure.message)
                case .success(let data):
                    guard data["has_more"] as? Bool == false, (data["truncations"] as? [Any] ?? []).isEmpty else {
                        return .needsInput(kind == "group" ? "匹配群较多，请补充完整群名。" : "匹配范围较大，请补充完整姓名或邮箱。")
                    }
                    let raw = data[kind == "group" ? "chats" : kind == "bot" ? "bots" : "users"]
                    contacts = parse(raw, id: kind == "group" ? "chat_id" : "open_id",
                                     name: kind == "person" ? "localized_name" : "name", detail: kind == "person" ? "department" : "description",
                                     prefix: kind == "group" ? "oc_" : "ou_")
                    // 只接受已证明的空结果；字段缺失或非空结果无法解析，不是改名重查的依据。
                    if index == 0, isEmptyResult(raw, kind: kind, data: data), queries.count > 1 { continue querySearch }
                    if index > 0 {
                        guard isCompleteResult(data), (raw as? [[String: Any]]).map({ $0.count == contacts.count })
                                ?? isEmptyResult(raw, kind: kind, data: data) else {
                            return .needsInput("无法完整核对查询返回的收件者，请补充完整名称，未发送。")
                        }
                        confirmFallback = contacts.count != 1 || normalize(contacts[0].name) != normalize(query)
                    }
                    break querySearch
                }
            }
            guard !contacts.isEmpty else { return .needsInput("没有找到目标，请补充完整姓名、邮箱、群名或机器人名称，并说明接收者类型。") }
            if contacts.count != 1 || confirmFallback {
                return requestChoice(contacts, text: messageText, names: names, resolved: [], group: nil,
                                     kind: kind, taskId: taskId, authorized: authorized,
                                     question: contacts.count == 1 ? "找到相近名称，请确认是否发送给：" : kind == "group" ? "找到多个群，请选择：" : kind == "bot" ? "找到多个机器人，请选择：" : "找到多个联系人，请选择：")
            }
            target = contacts[0]
        }
        guard let contact = target else { return .failed("未能确定收件者。") }
        if !names.isEmpty {
            let result = invoke(["im", "+chat-members-list", "--chat-id", contact.id, "--member-types", "user",
                                 "--member-id-type", "open_id", "--page-all", "--page-limit", "10", "--as", "user", "--format", "json"])
            guard case .success(let data) = result else {
                if case .failure(let failure) = result { return .failed(failure.message) }
                return .failed("无法查询群成员，未发送。")
            }
            guard data["has_more"] as? Bool == false,
                  (data["truncations"] as? [Any] ?? []).isEmpty else {
                return .needsInput("群成员列表不完整，无法确认艾特对象；请先核对群成员可见权限。")
            }
            let members = parse(data["users"], id: "member_id", name: "name", detail: "department", prefix: "ou_")
            guard resolved.count <= names.count, resolved.allSatisfy({ selected in members.contains { $0.id == selected.id } }) else {
                return .needsInput("之前选择的成员已不在可核对的群成员列表中，请重新指定艾特对象。")
            }
            for name in names.dropFirst(resolved.count) {
                let matches = members.filter { name.hasPrefix("ou_") ? $0.id == name : normalize($0.name) == normalize(name) }
                guard !matches.isEmpty else { return .needsInput("在“" + contact.name + "”中没有找到“" + name + "”，请补充该成员的完整飞书姓名。") }
                if matches.count > 1 {
                    return requestChoice(enrich(matches), text: messageText, names: names, resolved: resolved, group: contact,
                                         kind: kind, taskId: taskId, authorized: authorized,
                                         question: "“" + contact.name + "”里有多位“" + name + "”，请选择要艾特的人：")
                }
                resolved.append(matches[0])
            }
        }
        // 查询期间用户可能离开或放弃；本地存储原子占用是任何外发的最后门禁。
        guard authorized(), let latest = TaskStore.task(id: taskId), latest.status == .running else {
            return .failed("任务已结束或控制权已失效，未发送。")
        }
        do {
            guard try TaskStore.reserveFeishuDelivery(id: taskId, recipient: contact.name) else {
                if let delivery = TaskStore.task(id: taskId)?.feishuDelivery { return receipt(delivery) }
                return .failed("任务已结束，未发送。")
            }
        } catch { return .failed("无法保存发送记录，未发送。") }
        var args = ["im", "+messages-send", kind == "group" ? "--chat-id" : "--user-id", contact.id]
        if resolved.isEmpty { args += ["--text", messageText] }
        else { args += ["--msg-type", "post", "--content", post(text: messageText, mentions: resolved)] }
        args += ["--idempotency-key", task.id, "--as", "user", "--format", "json"]
        let result = invoke(args)
        guard case .success(let data) = result else {
            if case .failure(let failure) = result { return .failed("发送未确认：" + failure.message + " 请查看飞书，不会自动重发。") }
            return .failed("发送待核对。")
        }
        guard let messageId = data["message_id"] as? String, !messageId.isEmpty else {
            return .failed("发送待核对：未取得消息回执。")
        }
        guard var current = TaskStore.task(id: taskId) else { return .failed("已取得发送回执，但任务记录不可用。") }
        current.feishuDelivery = FeishuDelivery(recipient: contact.name, messageId: messageId)
        current.feishuChoice = nil
        do { try TaskStore.save(current) } catch { return .failed("已取得发送回执，但保存失败；请查看飞书。") }
        return .sent("已发送给" + contact.name + (resolved.isEmpty ? "" : "，并艾特了" + resolved.map(\.name).joined(separator: "、")))
    }

    private static func receipt(_ delivery: FeishuDelivery) -> Outcome {
        delivery.messageId != nil ? .sent("已发送给" + delivery.recipient) : .failed("发送待核对，请查看飞书；不会重复发送。")
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    // ==================== 收件者名称与类型词 ====================
    private static func isCompleteResult(_ data: [String: Any]) -> Bool {
        guard let hasMore = data["has_more"] as? NSNumber,
              CFGetTypeID(hasMore) == CFBooleanGetTypeID(), !hasMore.boolValue else { return false }
        if let truncations = data["truncations"], (truncations as? [Any])?.isEmpty != true { return false }
        return true
    }

    private static func isEmptyResult(_ raw: Any?, kind: String, data: [String: Any]) -> Bool {
        guard isCompleteResult(data) else { return false }
        if (raw as? [Any])?.isEmpty == true { return true }
        // CLI 的群搜索在 total=0 时返回 chats:null；缺字段或布尔 false 不证明空结果。
        guard kind == "group", raw is NSNull, let total = data["total"] as? NSNumber,
              CFGetTypeID(total) != CFBooleanGetTypeID() else { return false }
        return total.doubleValue == 0
    }

    private static func fallbackRecipient(_ recipient: String, kind: String) -> String? {
        guard kind == "bot" || kind == "group" else { return nil }
        let original = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = original
        for prefix in ["飞书的", "飞书"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        if kind == "bot" {
            if name.hasPrefix("机器人") {
                name = String(name.dropFirst("机器人".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if name.hasSuffix("机器人") {
                name = String(name.dropLast("机器人".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            for suffix in ["群聊", "群"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        guard !name.isEmpty, normalize(name) != normalize(original) else { return nil }
        return name
    }

    private static func parse(_ raw: Any?, id: String, name: String, detail: String, prefix: String) -> [FeishuContact] {
        var seen = Set<String>()
        return (raw as? [[String: Any]] ?? []).compactMap { item in
            guard let value = item[id] as? String, value.hasPrefix(prefix), seen.insert(value).inserted,
                  let label = item[name] as? String, !label.isEmpty else { return nil }
            return FeishuContact(id: value, name: label, department: item[detail] as? String ?? "")
        }
    }

    private static func enrich(_ contacts: [FeishuContact]) -> [FeishuContact] {
        // 群成员列表没有部门；只读补充候选标签失败时仍等用户选择，绝不降低匹配标准。
        guard contacts.count <= 100 else { return contacts }
        guard case .success(let data) = invoke(["contact", "+search-user", "--user-ids", contacts.map(\.id).joined(separator: ","),
                                               "--as", "user", "--format", "json"]) else { return contacts }
        let users = data["users"] as? [[String: Any]] ?? []
        return contacts.map { contact in
            guard let user = users.first(where: { $0["open_id"] as? String == contact.id }) else { return contact }
            let detail = [user["department"] as? String, user["enterprise_email"] as? String, user["email"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return FeishuContact(id: contact.id, name: contact.name, department: detail)
        }
    }

    private static func requestChoice(_ contacts: [FeishuContact], text: String, names: [String], resolved: [FeishuContact],
                                      group: FeishuContact?, kind: String, taskId: String, authorized: () -> Bool, question: String) -> Outcome {
        guard var task = TaskStore.task(id: taskId), task.status == .running, authorized() else { return .failed("任务已结束，未发送。") }
        task.feishuChoice = FeishuChoice(contacts: contacts, text: text, supplement: task.supplementCount, kind: kind,
                                         recipient: group, mentions: names, resolvedMentions: resolved)
        do { try TaskStore.save(task) } catch { return .failed("无法保存候选，请重试查询。") }
        let labels = contacts.enumerated().map { "\($0.offset + 1). \($0.element.name) · \($0.element.department.isEmpty ? "暂无补充信息" : $0.element.department)" }
        return .needsInput(question + "\n" + labels.joined(separator: "\n"))
    }

    private static func post(text: String, mentions: [FeishuContact]) -> String {
        var seen = Set<String>()
        var firstLine: [[String: String]] = []
        for member in mentions where seen.insert(member.id).inserted {
            firstLine.append(["tag": "at", "user_id": member.id, "user_name": member.name])
            firstLine.append(["tag": "text", "text": " "])
        }
        var lines = text.components(separatedBy: "\n").map { [["tag": "text", "text": $0]] }
        firstLine += lines.removeFirst()
        lines.insert(firstLine, at: 0)
        let data = try! JSONSerialization.data(withJSONObject: ["zh_cn": ["content": lines]], options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
