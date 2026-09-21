/**
 * [INPUT]: 全量 Sources（除 main.swift）；注入 PhoneFileAgent 的暂存库与访达替身、ComputerFileSearch 的 locate 替身、AgentRunner.canControl。
 * [OUTPUT]: 验证 send_files_to_phone 的参数校验、租约失效拒绝、访达多选空选/授权失败与成功回执，以及
 *           search_computer_files 的参数校验、截断与同名提示；全部走临时暂存目录，不触发 Finder 自动化、不读真实文件。
 * [POS]: tests 的文件发送工具替身回归；与 agent-runner.test.swift 同一编译方式。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct PhoneFileAgentTests {
    static var failures = 0
    static func check(_ condition: Bool, _ label: String) {
        if condition { print("  ok - \(label)") } else { failures += 1; print("  FAIL - \(label)") }
    }
    static func tempRoot(_ label: String) -> URL {
        URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("pd-pf-agent-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    static func main() {
        let root = tempRoot("root")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = PhoneFileStore(directory: root)
        PhoneFileAgent.store = store
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("交接单.txt")
        try! Data("正文".utf8).write(to: file)

        print("phone file agent: 参数与租约")
        do {
            AgentRunner.canControl = { _ in false }
            var outcome: AgentRunner.ToolOutcome?
            let done = DispatchSemaphore(value: 0)
            PhoneFileAgent.send(arguments: "{\"paths\":[\"\(file.path)\"]}", taskId: "t1") { outcome = $0; done.signal() }
            done.wait()
            if case .failed(let message)? = outcome, message.contains("控制权") {
                check(true, "租约失效拒绝发送")
            } else { check(false, "租约失效拒绝发送（实际 \(String(describing: outcome))）") }

            AgentRunner.canControl = { _ in true }
            var invalid: AgentRunner.ToolOutcome?
            let done2 = DispatchSemaphore(value: 0)
            PhoneFileAgent.send(arguments: "not-json", taskId: "t1") { invalid = $0; done2.signal() }
            done2.wait()
            if case .failed? = invalid { check(true, "无效参数回失败") } else { check(false, "无效参数回失败") }

            var missing: AgentRunner.ToolOutcome?
            let done3 = DispatchSemaphore(value: 0)
            PhoneFileAgent.send(arguments: "{}", taskId: "t1") { missing = $0; done3.signal() }
            done3.wait()
            if case .failed? = missing { check(true, "缺 paths 回失败") } else { check(false, "缺 paths 回失败") }
        }

        print("phone file agent: 访达多选替身")
        do {
            var outcomes: [AgentRunner.ToolOutcome] = []
            let lock = NSLock()
            func send(_ arguments: String, selection: [String]?, taskId: String) {
                PhoneFileAgent.finderSelection = { selection }
                let done = DispatchSemaphore(value: 0)
                PhoneFileAgent.send(arguments: arguments, taskId: taskId) { value in
                    lock.lock(); outcomes.append(value); lock.unlock(); done.signal()
                }
                done.wait()
            }
            send("{\"paths\":[]}", selection: nil, taskId: "f1")
            if case .needsInput(let message)? = outcomes.last, message.contains("访达") {
                check(true, "自动化读取失败如实提示")
            } else { check(false, "自动化读取失败如实提示") }

            send("{\"paths\":[]}", selection: [], taskId: "f2")
            if case .needsInput? = outcomes.last { check(true, "空选择要求用户先选中文件") } else { check(false, "空选择要求用户先选中文件") }

            send("{\"paths\":[]}", selection: [file.path], taskId: "f3")
            if case .sent(let message)? = outcomes.last, message.contains("接收"), message.contains("24 小时") {
                check(true, "多选成功回执说明等待手机确认")
            } else { check(false, "多选成功回执说明等待手机确认（实际 \(String(describing: outcomes.last))）") }

            check(store.list(subject: PhoneFileStore.subject).count == 1, "访达路径进入暂存")
        }

        print("phone file agent: 指定路径批次")
        do {
            var outcome: AgentRunner.ToolOutcome?
            let done = DispatchSemaphore(value: 0)
            let second = root.appendingPathComponent("说明.md")
            try! Data("# 说明".utf8).write(to: second)
            PhoneFileAgent.send(arguments: "{\"paths\":[\"\(file.path)\",\"\(second.path)\"]}", taskId: "p1") { outcome = $0; done.signal() }
            done.wait()
            if case .sent(let message)? = outcome, message.contains("2 个文件"), message.contains("ZIP") {
                check(true, "多文件回执说明打包 ZIP")
            } else { check(false, "多文件回执说明打包 ZIP（实际 \(String(describing: outcome))）") }

            check(PhoneFileAgent.tool["type"] as? String == "function", "工具声明暴露给模型")
            let description = (PhoneFileAgent.tool["function"] as? [String: Any])?["description"] as? String ?? ""
            check(!description.contains("已下载"), "工具描述不声称已下载")
        }

        print("phone file agent: 文件搜索替身")
        do {
            // 过滤按真实文件系统资源值判断，替身路径必须真实存在。
            let searchRoot = tempRoot("search")
            try! FileManager.default.createDirectory(at: searchRoot, withIntermediateDirectories: true)
            let pdf = searchRoot.appendingPathComponent("合同.pdf")
            let bak = searchRoot.appendingPathComponent("合同.pdf.bak")
            let folder = searchRoot.appendingPathComponent("合同", isDirectory: true)
            try! Data("pdf".utf8).write(to: pdf)
            try! Data("bak".utf8).write(to: bak)
            try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var reply = ""
            let done = DispatchSemaphore(value: 0)
            ComputerFileSearch.locate = { query, _ in
                if query == "合同" { return [pdf.path, bak.path, folder.path] }
                return []
            }
            ComputerFileSearch.search(arguments: "{\"query\":\"合同\"}") { reply = $0; done.signal() }
            done.wait()
            let data = reply.data(using: .utf8) ?? Data()
            let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let files = values["files"] as? [String] ?? []
            check(files == [pdf.path, bak.path], "只返回普通文件路径（目录过滤）")
            check(values["truncated"] as? Bool == false, "少量结果不标记截断")
            check((values["note"] as? String)?.contains("同名") == true, "提醒同名候选需用户选择")

            var empty = ""
            let done2 = DispatchSemaphore(value: 0)
            ComputerFileSearch.search(arguments: "{\"query\":\"不存在的文件名xyz\"}") { empty = $0; done2.signal() }
            done2.wait()
            check(empty.contains("\"files\":[]"), "无匹配返回空列表不猜路径")

            var bad = ""
            let done3 = DispatchSemaphore(value: 0)
            ComputerFileSearch.search(arguments: "{\"query\":\"-rm\"}") { bad = $0; done3.signal() }
            done3.wait()
            check(bad.contains("无效"), "选项样关键词拒绝")
        }

        print(failures == 0 ? "phone file agent: 全部通过" : "phone file agent: \(failures) 项失败")
        exit(failures == 0 ? 0 : 1)
    }
}
