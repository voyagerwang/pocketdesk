/**
 * [INPUT]: FeishuCLI 的用户身份搜索/发送，TaskStore 的持久任务与控制租约。
 * [OUTPUT]: 个人/群聊纯文本发送、同名补充选择、持久发送记录与幂等键；不自动重试结果未知的发送。
 * [POS]: 小精灵与飞书 CLI 的业务适配；后续可替换为共享服务，模型不能指定 argv 或凭证。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum FeishuMessaging {
    enum Outcome { case sent(String), needsInput(String), failed(String) }
    static var invoke = FeishuCLI.run
    private static let queue = DispatchQueue(label: "PocketDesk.feishu")

    static func execute(recipient: String, text: String, choice: String?, taskId: String, kind: String = "person",
                        authorized: @escaping () -> Bool, completion: @escaping (Outcome) -> Void) {
        queue.async { completion(perform(recipient: recipient, text: text, choice: choice, taskId: taskId, kind: kind, authorized: authorized)) }
    }

    static func perform(recipient: String, text: String, choice: String?, taskId: String, kind: String = "person",
                        authorized: () -> Bool) -> Outcome {
        guard var task = TaskStore.task(id: taskId), task.status == .running, authorized() else { return .failed("控制权已失效，请重新连接。") }
        if let delivery = task.feishuDelivery {
            return delivery.messageId != nil ? .sent("已发送给" + delivery.recipient) : .failed("发送待核对，请查看飞书；不会重复发送。")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16000 else { return .failed("消息为空或超过 16000 字节。") }
        guard ["person", "group"].contains(kind) else { return .failed("请说明发给联系人还是群聊。") }
        let contact: FeishuContact
        if let choice, !choice.isEmpty {
            guard let pending = task.feishuChoice, task.supplementCount > pending.supplement, (pending.kind ?? "person") == kind,
                  let index = Int(choice), pending.contacts.indices.contains(index - 1) else {
                return .failed("联系人选择无效，请补充姓名或邮箱重新查找。")
            }
            contact = pending.contacts[index - 1]
        } else {
            guard !recipient.isEmpty, recipient.count <= 50 else { return .failed("请提供联系人姓名或邮箱。") }
            let args = kind == "group"
                ? ["im", "+chat-search", "--query", recipient, "--disable-search-by-user", "--page-size", "100", "--as", "user", "--format", "json"]
                : ["contact", "+search-user", "--query", recipient, "--page-size", "30", "--as", "user", "--format", "json"]
            let result = invoke(args)
            guard case .success(let data) = result else {
                if case .failure(let failure) = result { return .failed(failure.message) }
                return .failed("联系人查询失败。")
            }
            let contacts = (data[kind == "group" ? "chats" : "users"] as? [[String: Any]] ?? []).compactMap { item -> FeishuContact? in
                guard let id = item[kind == "group" ? "chat_id" : "open_id"] as? String, id.hasPrefix(kind == "group" ? "oc_" : "ou_"), let name = item[kind == "group" ? "name" : "localized_name"] as? String else { return nil }
                return FeishuContact(id: id, name: name, department: item[kind == "group" ? "description" : "department"] as? String ?? "")
            }
            guard data["has_more"] as? Bool == false else { return .needsInput("匹配范围较大，请补充完整姓名或邮箱。") }
            guard !contacts.isEmpty else { return .needsInput("没有找到目标，请补充完整姓名、邮箱或群名。") }
            if contacts.count != 1 {
                guard let latest = TaskStore.task(id: taskId), latest.status == .running, authorized() else { return .failed("任务已结束，未发送。") }
                task = latest
                task.feishuChoice = FeishuChoice(contacts: contacts, text: text, supplement: task.supplementCount, kind: kind)
                do { try TaskStore.save(task) } catch { return .failed("无法保存联系人候选，请重试查询。") }
                let labels = contacts.enumerated().map { "\($0.offset + 1). \($0.element.name) · \($0.element.department.isEmpty ? "暂无补充信息" : $0.element.department)" }
                return .needsInput("找到多个匹配，请选择：\n" + labels.joined(separator: "\n"))
            }
            contact = contacts[0]
        }
        // 搜索期间用户可能离开或放弃任务，发送前重新核验。
        guard authorized(), let latest = TaskStore.task(id: taskId), latest.status == .running else { return .failed("任务已结束或控制权已失效，未发送。") }
        task = latest
        task.feishuDelivery = FeishuDelivery(recipient: contact.name, messageId: nil)
        do { try TaskStore.save(task) } catch { return .failed("无法保存发送记录，未发送。") }
        let result = invoke(["im", "+messages-send", kind == "group" ? "--chat-id" : "--user-id", contact.id, "--text", text,
                             "--idempotency-key", task.id, "--as", "user", "--format", "json"])
        guard case .success(let data) = result else {
            if case .failure(let failure) = result { return .failed("发送未确认：" + failure.message + " 请查看飞书，不会自动重发。") }
            return .failed("发送待核对。")
        }
        guard let messageId = data["message_id"] as? String, !messageId.isEmpty else { return .failed("发送待核对：未取得消息回执。") }
        guard var current = TaskStore.task(id: taskId) else { return .failed("已取得发送回执，但任务记录不可用。") }
        current.feishuDelivery = FeishuDelivery(recipient: contact.name, messageId: messageId)
        do { try TaskStore.save(current) } catch { return .failed("已取得发送回执，但保存失败；请查看飞书。") }
        return .sent("已发送给" + contact.name)
    }
}
