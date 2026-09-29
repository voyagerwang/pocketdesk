/**
 * [INPUT]: Chrome 原生 scripting.sdef 的窗口/标签 ID、URL 与 loading；小精灵控制租约。
 * [OUTPUT]: 按窗口和完整网址清理重复 HTTP(S) 标签；关闭只发一次，异步轮询新快照核实结果。
 * [POS]: 本机固定能力；不执行模型脚本、不读取网页正文、不跨窗口/无痕去重。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md。
 */
import AppKit

enum ChromeTabCleanup {
    struct Tab: Equatable {
        let window: Int
        let id: Int
        let url: String
        let active: Bool
        let loading: Bool
    }
    struct Duplicate: Equatable { let keep: Tab; let close: Tab }
    enum Verification { case closed, pending, unknown }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static let tool: [String: Any] = ["type": "function", "function": [
        "name": "close_duplicate_chrome_tabs",
        "description": "用户明确要求清理 Chrome 重复标签页时直接调用。对每个普通窗口单独按完整 HTTP(S) 网址去重，优先保留当前选中页，否则保留最左边一页；不按标题判断，不跨窗口或无痕窗口合并，跳过加载中的页面。仅本次清理，不开启后台监控。结果不明立即停止，不重试，不代确认未保存提示。",
        "parameters": ["type": "object", "properties": [:], "required": [], "additionalProperties": false]
    ] as [String: Any]]

    // 不归一化 query/hash/path，避免后台的不同记录和 SPA 页面被视为重复。
    static func plan(_ tabs: [Tab]) -> [Duplicate] {
        var groups: [String: [Tab]] = [:]
        for tab in tabs where !tab.loading {
            guard let url = URL(string: tab.url), ["http", "https"].contains(url.scheme ?? ""),
                  url.host != nil, !tab.url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            groups["\(tab.window)\n\(tab.url)", default: []].append(tab)
        }
        var result: [Duplicate] = []
        for group in groups.values where group.count > 1 {
            let keep = group.first(where: \.active) ?? group[0]
            result += group.filter { $0.id != keep.id }.map { Duplicate(keep: keep, close: $0) }
        }
        return result.sorted { ($0.close.window, $0.close.id) < ($1.close.window, $1.close.id) }
    }

    static var snapshot: () throws -> [Tab] = readTabs
    /// true 只代表关闭指令已发出，不是关闭成功；必须单独 verify。
    static var close: (Duplicate) throws -> Bool = requestClose
    static var verify: (Duplicate) throws -> Verification = verifyClose
    static var available: () -> Bool = {
        LockScreenInput.state == "unlocked" && !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }

    static func run(taskId: String, completion: @escaping (AgentRunner.ToolOutcome) -> Void) {
        DispatchQueue.main.async {
            var closed = 0
            do {
                guard AgentRunner.canControl(taskId), available() else {
                    throw Failure(message: "请确认 Chrome 正在运行、电脑已解锁且控制连接有效。")
                }
                let candidates = plan(try snapshot())
                var skipped = 0
                let deadline = Date().addingTimeInterval(30)
                func next(_ index: Int) {
                    guard index < min(candidates.count, 100), Date() < deadline else {
                        let suffix = skipped + candidates.count - index
                        let message = candidates.isEmpty ? "Chrome 普通窗口内没有可清理的重复网址标签页。"
                            : "已关闭 \(closed) 个 Chrome 重复标签页。" + (suffix > 0 ? "另有 \(suffix) 个因状态变化或本次上限而保留。" : "")
                        completion(.sent(message)); return
                    }
                    do {
                        guard AgentRunner.canControl(taskId), available() else {
                            throw Failure(message: "控制连接或电脑状态已变化，已停止。")
                        }
                        let pair = candidates[index]
                        guard try close(pair) else {
                            skipped += 1
                            DispatchQueue.main.async { next(index + 1) }
                            return
                        }
                        let verificationDeadline = Date().addingTimeInterval(2)
                        func check() {
                            do {
                                guard AgentRunner.canControl(taskId), available() else {
                                    throw Failure(message: "控制连接或电脑状态已变化，本次关闭结果尚未核实，已停止。")
                                }
                                switch try verify(pair) {
                                case .closed:
                                    closed += 1
                                    DispatchQueue.main.async { next(index + 1) }
                                case .pending where Date() < verificationDeadline:
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
                                default:
                                    throw Failure(message: "等待后仍未能核实标签页关闭结果，请检查 Chrome 是否有未保存提示；不会重复关闭或确认提示。")
                                }
                            } catch {
                                completion(.failed("已确认关闭 \(closed) 个；清理已停止：" + error.localizedDescription))
                            }
                        }
                        // Chrome 的 close 返回时标签仍可能存在；让浏览器处理关闭，再发独立读事件。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
                    } catch {
                        completion(.failed("已确认关闭 \(closed) 个；清理已停止：" + error.localizedDescription))
                    }
                }
                next(0)
            } catch {
                completion(.failed("已确认关闭 \(closed) 个；清理已停止：" + error.localizedDescription))
            }
        }
    }

    static func execute(_ source: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { throw Failure(message: "无法创建 Chrome 自动化指令。") }
        let value = script.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                throw Failure(message: "需要在系统设置 → 隐私与安全性 → 自动化中允许 PocketDesk 控制 Google Chrome。")
            }
            // 不把可能含网址/查询参数的原始错误写入任务或交给模型。
            throw Failure(message: "Chrome 自动化调用未返回确定结果（错误码 \(error[NSAppleScript.errorNumber] ?? "未知")）；可能正在等待授权或浏览器响应，不会自动重试关闭。")
        }
        return value
    }

    static let readSource = """
    with timeout of 15 seconds
        tell application id "com.google.Chrome"
            set rows to {}
            repeat with w in windows
                if mode of w is "normal" then
                    set activeID to id of active tab of w
                    repeat with t in tabs of w
                        set end of rows to {id of w as text, id of t as text, URL of t, (id of t is activeID), loading of t}
                    end repeat
                end if
            end repeat
            return rows
        end tell
    end timeout
    """

    private static func readTabs() throws -> [Tab] {
        let rows = try execute(readSource)
        guard rows.descriptorType == typeAEList else { throw Failure(message: "Chrome 返回的标签页列表格式无效，未继续清理。") }
        guard rows.numberOfItems > 0 else { return [] }
        return try (1...rows.numberOfItems).map { index in
            guard let row = rows.atIndex(index), row.numberOfItems == 5,
                  let window = Int(row.atIndex(1)?.stringValue ?? ""),
                  let id = Int(row.atIndex(2)?.stringValue ?? ""), window > 0, id > 0,
                  let url = row.atIndex(3)?.stringValue else { throw Failure(message: "无法核对 Chrome 标签页身份，未继续清理。") }
            return Tab(window: window, id: id, url: url, active: row.atIndex(4)!.booleanValue, loading: row.atIndex(5)!.booleanValue)
        }
    }

    static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func closeSource(_ pair: Duplicate) -> String {
        // 参数仅来自本机读取；ID 为整数，URL 作为转义字符串，不接受模型提供代码。
        """
        with timeout of 5 seconds
            tell application id "com.google.Chrome"
                if not (exists window id \(pair.close.window)) then return "skipped"
                set w to window id \(pair.close.window)
                if mode of w is not "normal" then return "skipped"
                if not (exists tab id \(pair.keep.id) of w) then return "skipped"
                if not (exists tab id \(pair.close.id) of w) then return "skipped"
                set kept to tab id \(pair.keep.id) of w
                set targetTab to tab id \(pair.close.id) of w
                if id of active tab of w is \(pair.close.id) then return "skipped"
                if loading of kept or loading of targetTab then return "skipped"
                considering case
                    if URL of kept is not \(literal(pair.keep.url)) then return "skipped"
                    if URL of targetTab is not \(literal(pair.close.url)) then return "skipped"
                end considering
                close targetTab
                return "requested"
            end tell
        end timeout
        """
    }

    static func verifySource(_ pair: Duplicate) -> String {
        """
        with timeout of 5 seconds
            tell application id "com.google.Chrome"
                if not (exists window id \(pair.close.window)) then return "unknown"
                set w to window id \(pair.close.window)
                -- 重新读取实际 ID 列表，不复用关闭前的 targetTab 对象引用。
                set currentIDs to {}
                repeat with t in tabs of w
                    set end of currentIDs to (id of t as text)
                end repeat
                if currentIDs does not contain "\(pair.keep.id)" then return "unknown"
                if currentIDs contains "\(pair.close.id)" then return "pending"
                return "closed"
            end tell
        end timeout
        """
    }

    private static func verifyClose(_ pair: Duplicate) throws -> Verification {
        switch try execute(verifySource(pair)).stringValue {
        case "closed": return .closed
        case "pending": return .pending
        default: return .unknown
        }
    }

    private static func requestClose(_ pair: Duplicate) throws -> Bool {
        switch try execute(closeSource(pair)).stringValue {
        case "requested": return true
        case "skipped": return false
        default: throw Failure(message: "未能核实标签页关闭结果，请检查 Chrome；不会继续关闭或确认提示。")
        }
    }
}
