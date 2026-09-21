/**
 * [INPUT]: 小精灵明确发送指令、控制租约与访达选择；注入的 PhoneFileStore 提供快照与幂等。
 * [OUTPUT]: send_files_to_phone：完整路径或访达多选文件，准备后等待手机确认；发送回执结束本轮，
 *           不把文件内容传给模型；AgentRunner.ToolOutcome 通用回执，不耦合具体消息业务。
 * [POS]: AgentRunner 与文件资源之间的适配器；不执行 shell、不推断同名文件，控制租约失效时拒绝新发送。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import Foundation

enum PhoneFileAgent {
    private static let queue = DispatchQueue(label: "dev.voicedeck.phone-files.prepare")
    static let tool: [String: Any] = ["type": "function", "function": [
        "name": "send_files_to_phone",
        "description": "用户明确要求把电脑文件发到当前配对手机时使用。paths 填用户提供或 search_computer_files 查到的绝对路径数组（最多20个）；用户说选中的文件时传空数组，读取访达多选。按文件名发送时先搜索，同名先问用户。不得猜路径；文件夹需先压缩。不上传文件内容给模型。成功只表示准备好待手机接收，不能说已保存到手机。",
        "parameters": ["type": "object", "properties": ["paths": ["type": "array", "items": ["type": "string"], "maxItems": 20]], "required": ["paths"], "additionalProperties": false]
    ] as [String: Any]]

    /// 测试接缝：真实实现分别走共享暂存库与 Finder AppleScript；替身测试注入，不触碰真实文件与自动化授权。
    static var store = PhoneFileStore.shared
    static var finderSelection: () -> [String]? = {
        // 固定脚本只读 Finder selection；用户输入不参与 AppleScript 拼接。
        let source = """
        tell application "Finder"
            set picked to selection
            set paths to {}
            repeat with itemRef in picked
                set end of paths to POSIX path of (itemRef as alias)
            end repeat
            return paths
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        let selected = (1...max(1, result?.numberOfItems ?? 0)).compactMap { result?.atIndex($0)?.stringValue }
        return error == nil ? selected : nil
    }

    static func send(arguments: String, taskId: String, completion: @escaping (AgentRunner.ToolOutcome) -> Void) {
        guard let data = arguments.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = values["paths"] as? [String] else { completion(.failed("文件发送参数无效。")); return }
        func prepare(_ paths: [String]) {
            queue.async {
                guard AgentRunner.canControl(taskId) else { completion(.failed("手机控制权已失效，请重新连接后发送。")); return }
                do {
                    // 复制/打包可能耗时较长；发布临界点再次核验控制权与任务状态，失权即整批丢弃。
                    let offer = try store.prepare(paths: paths, subject: PhoneFileStore.subject, taskId: taskId,
                                                  authorized: { AgentRunner.canControl(taskId) })
                    let count = offer.fileNames?.count ?? 1
                    let summary = count > 1 ? "\(count) 个文件（打包为 ZIP）" : "「\(offer.name)」"
                    completion(.sent("\(summary)已准备好，请在手机收件区点“接收”。文件保留 24 小时。"))
                } catch { completion(.failed(error.localizedDescription)) }
            }
        }
        if !paths.isEmpty { prepare(paths); return }
        guard AgentRunner.canControl(taskId) else { completion(.failed("手机控制权已失效。")); return }
        guard let selected = readFinderSelection() else {
            completion(.needsInput("无法读取访达选择。请提供完整文件路径，或在 Mac 系统设置中允许 PocketDesk 自动化访问访达。")); return
        }
        guard !selected.isEmpty else {
            completion(.needsInput("请在电脑访达选中文件，再说“把这个文件发到手机”；也可以直接告诉我完整文件路径。")); return
        }
        prepare(selected)
    }

    /// NSAppleScript 要求主线程执行；生产调用在后台线程，跳到主线程同步读取；
    /// 测试替身通常直接在主线程运行，零开销返回。
    private static func readFinderSelection() -> [String]? {
        if Thread.isMainThread { return finderSelection() }
        var value: [String]?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            value = finderSelection()
            done.signal()
        }
        done.wait()
        return value
    }
}
