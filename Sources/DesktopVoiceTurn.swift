/**
 * [INPUT]: 配置唤醒词、单轮转写、单调时间和声学活动；不访问设备或任务。
 * [OUTPUT]: 追问/失败原因/长回答要点的口语挑句与闲聊就地回应（招呼按时段、自我介绍、夸奖、应一声不回）；唤醒分段/同段重复识别去重、转写入口的唤醒名剥离、自适应停顿、麦克风兜底时机与文案策略；仅新唤醒片段可重开输入，不把转写修订当作再次呼叫。
 * [POS]: 自动语音的纯判定层；麦克风只供样本、识别只供转写，发声、提交与锁屏授权由 DesktopVoice 管理。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

enum DesktopVoiceTurn {
    struct WakePart { let before: String; let body: String }
    static func wakeParts(_ text: String, wake: String) -> [WakePart] {
        let names = wake.lowercased() == "小e" ? ["小e", "小易", "小伊", "小艺"] : [wake.lowercased()]
        let target = names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(?:^|(?<=[\\s，,。！!？?；;]))(?:" + target + ")[\\s，,。！!？?：:]*", options: .caseInsensitive) else { return [] }
        let ranges = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
        return ranges.enumerated().map { index, range in
            let start = index == 0 ? text.startIndex : ranges[index - 1].upperBound
            return WakePart(before: String(text[start..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                            body: String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    /// 键盘链路断了先给一点宽限再换电脑麦克风，键盘一回来立刻切回；两路不同时收音。
    static let systemFallbackGrace: TimeInterval = 2
    static func wantsSystemFallback(linked: Bool, usingSystem: Bool, silentFor: TimeInterval) -> Bool {
        !linked && !usingSystem && silentFor >= systemFallbackGrace
    }
    /// 播报不包含唤醒名，避免扬声器回采主动召回助手；完整原文仍留在屏幕。
    static func feedback(_ text: String, wake: String) -> String {
        let names = wake.lowercased() == "小e" ? ["小e", "小易", "小伊", "小艺"] : [wake.lowercased()]
        return names.contains(where: { text.lowercased().contains($0) }) ? "结果在屏幕上，你看一下" : text
    }
    // 只开放固定设备短口令；问句、否定、复合动作和自由指令继续等待最终识别。
    static func stableQuick(_ text: String, stableFor: TimeInterval, quietFor: TimeInterval, bound: Bool) -> Bool {
        guard bound, stableFor >= 2, quietFor >= 2 else { return false }
        return text.range(of: "^(?:开灯|关灯|亮灯|熄灯|打开灯|关闭灯|打开开灯|打开空调|关闭空调|开启空调|关掉空调)[。！!]*$", options: .regularExpression) != nil
    }
    /// 空最终结果：没内容就回待唤醒，已收尾就按已听内容提交，其它情况继续听——任何一支都不许停在保留态。
    enum EmptyFinal: Equatable { case wake, commit, resume }
    static func emptyFinal(body: String, finishing: Bool) -> EmptyFinal {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .wake }
        return finishing ? .commit : .resume
    }
    /// 识别把“小E”听成小艺/小易/小伊是常态；展示和派单统一写回用户设定的名字。
    /// 只在唤醒词确实是“小E”时替换，别的名字不做猜测。
    static func normalize(_ text: String, wake: String) -> String {
        guard wake.lowercased() == "小e" else { return text }
        return text.replacingOccurrences(of: "小\\s*[eEｅ艺易伊]", with: wake, options: .regularExpression)
    }
    /// 豆包与本地兜底这两条转入正文的入口不经过唤醒分段：名字落在句首就当场剥掉。
    /// 名字留在正文里，“小E开灯”就认不出是固定设备短口令，固定快路径落空只能退回模型跑多轮。
    static func dictated(_ text: String, wake: String) -> String {
        let normalized = normalize(text, wake: wake)
        return body(normalized, wake: wake) ?? normalized
    }
    static func body(_ text: String, wake: String) -> String? {
        // 识别引擎几乎每次都把“小E”写成“小艺”，这几种写法都得算唤醒名，否则正文里会留着名字，指令就对不上了。
        let aliases = wake.lowercased() == "小e" ? ["小e", "小易", "小伊", "小艺"] : [wake.lowercased()]
        let target = aliases.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "^\\s*(?:" + target + ")[\\s，,。！!：:]*", options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// 一段新的识别文本又用唤醒词开头，说明用户重喊了一次，而不是接着说。
    static func rewoke(_ text: String, wake: String) -> String? { body(text, wake: wake) }
    /// 唤醒应答：短、有回应感，可关掉；文案由控制台配置，多句用「|」隔开轮换。
    /// roll 由调用方给（测试可固定，运行时取随机数）；重复上一句时在池里顺延一句，避免连着两次一模一样。
    static func ack(_ configured: String, avoiding previous: String? = nil, roll: Int = 0) -> String {
        let items = DesktopVoiceSettings.pool(String(configured.prefix(120))).map { String($0.prefix(16)) }
        return pick(items, avoiding: previous, roll: roll)
    }
    /// 任务收尾的一句话反馈：同样轮换，不和上一次重。
    enum Outcome { case succeeded, answered, receipt, needsInput, unconfirmed, failed }
    static let outcomes: [Outcome: [String]] = [
        .succeeded: ["办好了", "嗯，搞定了", "好了"],
        // 已经答完、只是末尾又追问了一句的，不能报成“还没做”。
        .answered: ["查到了", "有了，你看一眼"],
        // 事情没那么快办完时先说这一句，别让人干等着。
        .receipt: ["好的，这就去办", "行，这就办", "好，稍等我一下"],
        .needsInput: ["有个地方要你定一下", "还得你确认一下"],
        // 动作发出去了但没核对上，既不是成功也不是没做。
        .unconfirmed: ["已经发出去了，还没确认上", "发出去了，回执还没回来"],
        .failed: ["抱歉，这个没弄成，原因在屏幕上", "这次没办成，你看一眼屏幕"],
    ]
    static func outcome(_ outcome: Outcome, avoiding previous: String? = nil, roll: Int = 0) -> String {
        pick(outcomes[outcome] ?? [], avoiding: previous, roll: roll)
    }
    /// 查到的结论要念出来，而不是一律“搞定了”。
    /// 屏幕上的那句话是写给人看的（设备全名、云端术语、括号补注），直接念又长又隔应；
    /// 这里只做“能念出口”的瘦身：去设备全名、去括号、短句、把“为”说成“是”。
    /// 动作回执（已设置/已打开/已发送…）没有可念的事实，返回 nil 交给通用反馈。
    /// 动作回执的标志词：这些句子说的是“做了什么”，不是可以念给人听的结论。
    static let actionMarks = ["已执行", "已打开", "已保存", "已发送", "已创建", "已提交", "已派", "已添加", "已关闭", "已启动", "已尝试", "已把", "已让", "已交给"]
    static let spokenProperties = ["湿度", "温度", "电量", "开关", "状态", "亮度", "余额", "进度"]
    static let countWords: [(String, Int)] = [("一", 1), ("二", 2), ("两", 2), ("三", 3), ("四", 4),
                                              ("五", 5), ("六", 6), ("七", 7), ("八", 8), ("九", 9), ("十", 10)]
    /// 时间念成口语：一分钟后 / 今天下午三点 / 明天上午十点。屏幕上写 00:28 是一回事，
    /// 张嘴念“零点二十八分”是另一回事——人不会这么说话。
    static let cnDigits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    static func cnNumber(_ value: Int) -> String {
        if value < 10 { return cnDigits[max(0, min(9, value))] }
        if value < 20 { return "十" + (value % 10 == 0 ? "" : cnDigits[value % 10]) }
        if value < 60 { return cnDigits[value / 10] + "十" + (value % 10 == 0 ? "" : cnDigits[value % 10]) }
        return String(value)
    }
    static func clockPhrase(hour: Int, minute: Int, now: Date, timeZone: TimeZone, context: String = "") -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour; parts.minute = minute; parts.second = 0
        guard let target = calendar.date(from: parts) else { return "\(hour)点\(minute)分" }
        // 前面已经说了“明天上午”，就别再拼一遍，也别把它当“75 分钟后”。
        let spokenPrefix = ["明天", "后天", "今天", "上午", "下午", "晚上", "凌晨", "中午"].contains { context.contains($0) }
        if spokenPrefix {
            let display = hour % 12 == 0 ? (hour == 0 ? 0 : 12) : hour % 12
            return cnNumber(display) + "点" + (minute == 0 ? "" : cnNumber(minute) + "分")
        }
        let ahead = target.timeIntervalSince(now)
        if ahead >= -60, ahead <= 5400 {
            let minutes = max(1, Int((ahead / 60).rounded()))
            return minutes == 1 ? "一分钟后" : cnNumber(minutes) + "分钟后"
        }
        let day: String
        if calendar.isDate(target, inSameDayAs: now) { day = "今天" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(target, inSameDayAs: tomorrow) { day = "明天" }
        else if let after = calendar.date(byAdding: .day, value: 2, to: now), calendar.isDate(target, inSameDayAs: after) { day = "后天" }
        else { day = "\(calendar.component(.month, from: target))月\(calendar.component(.day, from: target))日" }
        let period = hour < 6 ? "凌晨" : (hour < 12 ? "上午" : (hour == 12 ? "中午" : (hour < 18 ? "下午" : "晚上")))
        let display = hour % 12 == 0 ? (hour == 0 ? 0 : 12) : hour % 12
        return day + period + cnNumber(display) + "点" + (minute == 0 ? "" : cnNumber(minute) + "分")
    }
    static func spokenTime(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])([01]?[0-9]|2[0-3])[:：]([0-5][0-9])(?![0-9])") else { return text }
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let hour = Int(source.substring(with: match.range(at: 1))) ?? 0
            let minute = Int(source.substring(with: match.range(at: 2))) ?? 0
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let before = source.substring(to: max(0, match.range.location))
            let context = String(before.suffix(8))
            output += clockPhrase(hour: hour, minute: minute, now: now, timeZone: timeZone, context: context)
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
            .replacingOccurrences(of: "\\s+([，,。；;])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "(?<=[\\u4e00-\\u9fa5])\\s+(?=[\\u4e00-\\u9fa5])", with: "", options: .regularExpression)
    }
    static func speakable(_ result: String?, now: Date = Date()) -> String? {
        guard var text = result?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // 灯/插座这种确定性的开关，直接报状态：“灯 · 开关 已设置为 true” → “灯开了”。
        if let hit = text.range(of: "^(.*?)[\\s·]*开关\\s*已设置为\\s*(true|false)", options: .regularExpression) {
            let line = String(text[hit])
            var name = line.replacingOccurrences(of: "[·]?\\s*开关.*$", with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ·"))
            if name.contains("·") { name = String(name.split(separator: "·").last ?? "").trimmingCharacters(in: .whitespaces) }
            guard !name.isEmpty else { return nil }
            // 带品牌的插座名不用念全：“电小酷插座开了” → “插座开了”。
            if name.hasSuffix("插座") { name = "插座" }
            return name + (line.hasSuffix("true") ? "开了" : "关了")
        }
        // 动作类回执一句话就够，念原文反而像机器报表。
        if actionMarks.contains(where: { text.contains($0) }) { return nil }
        // 括号里多半是设备型号、时间戳这类念不出意义的补注。
        for pattern in ["（[^）]*）", "\\([^)]*\\)", "\\[[^\\]]*\\]"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "[「」“”\"`*>#]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        // 时间先说成人话，再决定念哪一句。
        text = spokenTime(text, now: now)
        text = text.replacingOccurrences(of: "\\s*·\\s*", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // “个人工作台”是内部叫法，念出来像报表字段。
        for (from, to) in [("个人工作台只有", "只有"), ("工作台只有", "只有"),
                           ("个人工作台待办", "待办"), ("工作台待办", "待办"),
                           ("个人工作台日程", "日程")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        // 从设备全名后面那个属性词开始说：“米家智能温湿度计 3 2 的湿度为 58%” → “现在湿度是 58%”。
        let headRange = text.startIndex..<text.index(text.startIndex, offsetBy: min(20, text.count))
        let head = text[headRange]
        var picked: String?
        var pickedAt = text.endIndex
        for property in spokenProperties {
            // 必须真在报数值：“温湿度计”里的“湿度”不算。
            guard let r = head.range(of: property + "[为是：:] ?[0-9]", options: .regularExpression),
                  r.lowerBound < pickedAt else { continue }
            picked = property; pickedAt = r.lowerBound
        }
        if let property = picked {
            text = String(text[pickedAt...])
            text = text.replacingOccurrences(of: "^" + property + "为", with: property + "是", options: .regularExpression)
            text = text.replacingOccurrences(of: "^" + property + "都是", with: property + "是", options: .regularExpression)
        }
        // 列举要念全：说“两条待办”就得两条都念，只念一条等于没说全。
        if let speech = enumeration(text) { return speech }
        // 念哪一句：默认第一句（带着动词和结论）；第一句若是“读不到”这类声明，
        // 才去挑后面带数值的那句——否则会出现只念了一个“11月3日”这种半句话。
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "，,；;。！!\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let caveats = ["读不到", "暂时", "无法", "没拿到", "拿不到", "不可用", "稍后"]
        // “好的”“已经设好提醒”这种只有客套没有信息的开头，念出来只占时间。
        let fillers = ["好的", "好呀", "好的，", "好，", "嗯", "已经设好提醒", "提醒已设置", "已经设置好", "已设置提醒", "好的，已经设好提醒"]
        var remaining = parts
        while let head = remaining.first, head.count <= 10, fillers.contains(where: { head == $0 }) {
            remaining.removeFirst()
        }
        guard var sentence = remaining.first else { return nil }
        let clauses = remaining
        if caveats.contains(where: { sentence.contains($0) }) {
            if let numbered = clauses.dropFirst().first(where: {
                $0.rangeOfCharacter(from: .decimalDigits) != nil && $0.count <= 30 }) {
                sentence = numbered
            }
        } else if sentence.count < 10, clauses.count > 1,
                  sentence.rangeOfCharacter(from: .decimalDigits) == nil,
                  !["但", "不过", "可是", "而且", "另外", "这是", "然后", "其中", "备注", "计划"].contains(where: { clauses[1].hasPrefix($0) }),
                  sentence.count + clauses[1].count <= 28 {
            // 头一句太短就接上后半句，别把“已经记好了”单独甩出来。
            sentence += "，" + clauses[1]
        }
        // 句中残留的指代说明念出来很别扭：“会前评审产品文档这个待办”。
        for filler in ["这个待办", "这条待办", "这个日程", "这条日程", "这个笔记", "这条笔记", "这个任务"] {
            sentence = sentence.replacingOccurrences(of: filler, with: "")
        }
        text = sentence
        guard text.count <= 40 else { return nil }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ，,；;。！!、：: \t\n"))
        // 念不短就不念，宁可报一句“办好了”。
        guard !text.isEmpty, text.count <= 40 else { return nil }
        if spokenProperties.contains(where: { text.hasPrefix($0) }), text.contains("是") { return "现在" + text }
        return text
    }
    // MARK: - 对话感：追问念出来、失败说原因、长回答念要点
    //
    // 真人助理不会说“有个地方要你定一下”然后让你自己去看屏幕——他会直接问；
    // 也不会只说“没弄成”——他会顺口说一句卡在哪。下面三个函数都只从结果原文里挑一句
    // 能张口说的话，挑不出就返回 nil，由调用方退回固定短句：宁可少说，不念半句或报表。

    /// 屏幕文字转口语前的统一清洗：去括号补注、Markdown 记号、机器时间与字段分隔符。
    static func spokenClean(_ raw: String, now: Date = Date()) -> String {
        var text = raw
        for pattern in ["（[^）]*）", "\\([^)]*\\)", "\\[[^\\]]*\\]"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "[「」“”\"`*>#]", with: "", options: .regularExpression)
        text = spokenTime(text, now: now)
        text = text.replacingOccurrences(of: "\\s*·\\s*", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// 逐行清洗再拼回：spokenTime 会吞掉中文之间的空白（含换行），整段一起洗会把两行粘成一句。
    static func spokenLines(_ raw: String, now: Date = Date()) -> String {
        raw.components(separatedBy: .newlines).map { spokenClean($0, now: now) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    /// 按中文句读切句，标点留在句尾（问号要留着，才知道哪句是在问）。
    static func sentences(_ text: String) -> [String] {
        var output: [String] = [], current = ""
        for character in text {
            current.append(character)
            if "。！!；;？?\n".contains(character) {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { output.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { output.append(tail) }
        return output
    }
    static let candidateBullet = "^(?:[-•*＊]|[0-9]{1,2}[.、)）]|[①②③④⑤⑥⑦⑧⑨])\\s*"
    /// 追问念出来：取第一句问句；候选两三个且都短就直接念进去，多了就指一下屏幕。
    static func spokenQuestion(_ result: String?, now: Date = Date()) -> String? {
        guard let raw = result?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        var prose: [String] = [], options: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let bullet = trimmed.range(of: candidateBullet, options: .regularExpression) {
                let item = spokenClean(String(trimmed[bullet.upperBound...]), now: now)
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ，,。；;"))
                if !item.isEmpty { options.append(item) }
            } else {
                prose.append(spokenClean(trimmed, now: now))
            }
        }
        guard var question = sentences(prose.joined(separator: "\n"))
            .first(where: { $0.hasSuffix("？") || $0.hasSuffix("?") }) else { return nil }
        if question.hasSuffix("?") { question = String(question.dropLast()) + "？" }
        question = question.trimmingCharacters(in: CharacterSet(charactersIn: " ，,：:"))
        // 问句太长就只留最后那个分句——真正在问的就是它。
        if question.count > 40, let comma = question.dropLast().lastIndex(where: { $0 == "，" || $0 == "," }) {
            question = String(question[question.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        }
        guard question.count >= 2, question.count <= 40 else { return nil }
        guard !options.isEmpty else { return question }
        if (2...3).contains(options.count), Set(options).count == options.count, options.allSatisfy({ $0.count <= 10 }) {
            return question + options.dropLast().joined(separator: "、") + "，还是" + options[options.count - 1] + "？"
        }
        return question + "选项在屏幕上"
    }
    /// 没办成的原因：第一句人话。错误码、英文异常念出来只会更像机器，宁可不念。
    static func spokenReason(_ result: String?, now: Date = Date()) -> String? {
        guard let raw = result?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard var sentence = sentences(spokenLines(raw, now: now)).first else { return nil }
        sentence = sentence.trimmingCharacters(in: CharacterSet(charactersIn: " ，,：:。！!；;"))
        if sentence.count > 40, let comma = sentence.firstIndex(where: { $0 == "，" || $0 == "," }),
           sentence.distance(from: sentence.startIndex, to: comma) >= 4 {
            sentence = String(sentence[..<comma])
        }
        guard sentence.count >= 4, sentence.count <= 40 else { return nil }
        guard sentence.range(of: "(?i)error|exception|errno|错误码|状态码|未知错误|http ?[0-9]{3}", options: .regularExpression) == nil else { return nil }
        return sentence
    }
    /// 这句话本身已经在说“没成”，就不必再垫一句“没办成”。
    static func soundsNegative(_ text: String) -> Bool {
        ["没", "未", "无法", "不能", "不了", "找不到", "打不开", "失败", "读不到", "连不上", "不支持", "抱歉", "暂时", "需要", "得先", "要先"]
            .contains { text.contains($0) }
    }
    /// 回答太长念不完：念第一句结论，再告诉他细节在屏幕上——而不是只说一句“查到了”。
    static func spokenGist(_ result: String?, now: Date = Date()) -> String? {
        guard let raw = result?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !actionMarks.contains(where: { raw.contains($0) }) else { return nil }
        let cleaned = spokenLines(raw, now: now)
        guard var first = sentences(cleaned).first else { return nil }
        // 以冒号收尾的是列表开头：“明天有这些安排：”——说一半，剩下的指给他看。
        let intro = first.hasSuffix("：") || first.hasSuffix(":")
        first = first.trimmingCharacters(in: CharacterSet(charactersIn: " ，,：:。！!；;"))
        // 问句不当结论念；数字结论交给 speakable，这里只管长的文字回答。
        guard first.count >= 4, first.count <= 48, !first.hasSuffix("？"), !first.hasSuffix("?") else { return nil }
        if intro { return first + "，我列在屏幕上了" }
        let more = cleaned.count - first.count > 12
        return more ? first + "，细节在屏幕上" : first
    }
    /// 没有现成可念的结论时，按收尾类型挑一句：追问念问题，失败念原因，长回答念要点。
    /// 已发出未核实（unconfirmed 且不是执行失败）不在这里编话，那一句必须由固定措辞说清。
    static func conversational(_ outcome: Outcome, recovery: String?, result: String?, now: Date = Date()) -> String? {
        let text = result ?? ""
        switch outcome {
        case .needsInput:
            if recovery == nil || recovery == "clarification" {
                return spokenQuestion(result, now: now) ?? spokenReason(result, now: now)
            }
            return spokenReason(result, now: now)
        case .failed:
            guard let reason = spokenReason(result, now: now) else { return nil }
            return soundsNegative(reason) ? reason : "没办成，" + reason
        case .unconfirmed:
            let sent = ["已尝试", "已发出", "发出去", "待核实", "待核对", "接收"].contains { text.contains($0) }
            guard recovery == "executionFailure", !awaiting(text), !sent, let reason = spokenReason(result, now: now) else { return nil }
            return soundsNegative(reason) ? reason : "没办成，" + reason
        case .succeeded, .answered:
            return spokenGist(result, now: now)
        case .receipt:
            return nil
        }
    }
    /// 模型写的口播总括：先总后分的一句话，洗掉括号与机器时间后照念；空的或过长的不念，交回挑句规则。
    static func summary(_ raw: String?, now: Date = Date()) -> String? {
        guard let raw else { return nil }
        let text = spokenClean(raw, now: now).trimmingCharacters(in: CharacterSet(charactersIn: " 。.；;"))
        return text.isEmpty || text.count > SpokenSummary.maxLength ? nil : text
    }
    /// 念完一个问题后，给多久不用喊名字就能直接回答。
    static let replyWindow: TimeInterval = 8

    /// 把结果当列举念：头一句说“几条”，后面逐条念，时间要贴着标题念，别只报个钟点。
    static func enumeration(_ text: String) -> String? {
        guard let colon = text.firstIndex(where: { $0 == "：" || $0 == ":" }) else { return nil }
        let head = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else { return nil }
        var counted: Int?
        for (word, value) in countWords {
            if head.contains(word + "条") || head.contains(word + "个") || head.contains(word + "项") {
                counted = value; break
            }
        }
        if counted == nil { counted = head.split(separator: " ").compactMap { Int($0) }.first }
        let tail = String(text[text.index(after: colon)...])
        let raw = tail.replacingOccurrences(of: "，以及", with: "、")
            .replacingOccurrences(of: "以及", with: "")
            .components(separatedBy: CharacterSet(charactersIn: "、，,；;"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " 。.、\n")) }
            .filter { !$0.isEmpty }
        // 纯时间的一条（“下午两点到三点”）只是下一条的附属，并进去一起念。
        var items: [String] = []
        var pendingTime: String?
        for piece in raw {
            var item = piece
            for prefix in ["还有", "另外一个", "另外", "然后", "以及", "其中"] where item.hasPrefix(prefix) {
                item = String(item.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            for suffix in ["这两个安排重叠了", "两个安排重叠了", "这两个时间重叠", "时间重叠了", "有重叠", "这两个撞了"] {
                item = item.replacingOccurrences(of: suffix, with: "")
            }
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: " 。，,、"))
            guard !item.isEmpty else { continue }
            if item.range(of: "^(上午|下午|中午|晚上|凌晨)?[0-9一二两三四五六七八九十]+点(半|[0-9一二三四五六七八九十]+分)?(到|至|-|~|—)(上午|下午|中午|晚上)?[0-9一二两三四五六七八九十]+点(半|[0-9一二三四五六七八九十]+分)?$", options: .regularExpression) != nil {
                pendingTime = item; continue
            }
            // “在5层休息区有『…』”只留标题。
            if let mark = item.range(of: "有"), item.distance(from: item.startIndex, to: mark.lowerBound) <= 12 {
                let after = String(item[mark.upperBound...]).trimmingCharacters(in: .whitespaces)
                if after.count >= 3 { item = after }
            }
            // 标题先压到 20 字，再贴上时间，免得把标题尾巴截掉。
            if item.count > 20 { item = String(item.prefix(20)) }
            item = item.replacingOccurrences(of: "&", with: "和")
            if let time = pendingTime { item = time + "的" + item; pendingTime = nil }
            items.append(item)
        }
        if let time = pendingTime, let last = items.last { items[items.count - 1] = last + "，" + time }
        guard items.count >= 2 else { return nil }
        guard counted.map({ $0 == items.count }) ?? true else { return items.count > 4 ? nil : nil }
        let kept = items.count > 4 ? Array(items.prefix(4)) : items
        let overlap = ["重叠", "撞了"].contains { text.contains($0) } ? "，时间撞了" : ""
        let speech = head + "：" + kept.joined(separator: "、") + (items.count > 4 ? "等 \(items.count) 条" : "") + overlap
        return speech.count <= 90 ? speech : nil
    }
    /// 结果里带数字的多半是真查到了东西（读数、条数、时间），那就值得念出来。
    static func hasNumber(_ text: String) -> Bool {
        !text.isEmpty && text.rangeOfCharacter(from: .decimalDigits) != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("？")
    }
    /// 用户当场就能看见结果的操作用得上的动词：打开、退出、开关、锁屏、摆窗口。
    /// 这类事办成了不用报——他眼睛已经收到了；只有失败或要他拿主意才开口。
    /// 反过来，记待办、发消息、派单这类他看不见，必须给回执。
    static let perceivableVerbs = ["打开", "关闭", "关掉", "关上", "退出", "隐藏", "锁屏", "锁定屏幕",
                                   "开灯", "关灯", "亮灯", "熄灯", "开空调", "关空调", "开插座", "关插座",
                                   "最小化", "最大化", "全屏", "分屏", "左半", "右半", "切到", "切回"]
    static func perceivable(_ text: String) -> Bool {
        let body = bare(text)
        return perceivableVerbs.contains { body.contains($0) }
    }
    /// “已请求但没确认”不是失败：关掉飞书却听到“没办成”，比不说还糟。
    static func awaiting(_ text: String) -> Bool {
        ["待核对", "尚未确认", "还没确认", "未确认", "没看到它"].contains { text.contains($0) }
    }
    /// 把任务终态翻译成该说哪句话：已经答完又追问的，不能报成“还没做”。
    enum Verdict { case succeeded, needsInput, failed }
    static func outcome(_ verdict: Verdict, answered: Bool, recovery: String?) -> Outcome {
        switch verdict {
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .needsInput:
            switch recovery {
            case "clarification": return answered ? .answered : .needsInput
            case "executionFailure", "unconfirmed": return .unconfirmed
            default: return .needsInput
            }
        }
    }
    /// 回答是否真的说完了：以问号收尾的就不算，那是反过来在问你，这时说“查到了”就是胡说。
    static func answered(_ result: String?) -> Bool {
        let text = (result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return !text.hasSuffix("？") && !text.hasSuffix("?")
    }

    /// 接着上一句说的短追问：把这句接到上一件任务上，模型才看得到“多少”“那后天呢”到底在问什么。
    /// 宁窄不宽：只认明显指代上文的短句，宁可多开一条任务，也不把新指令误接成补充。
    static let followUpLead = ["那", "那如果", "还有", "还有呢", "再", "然后", "接着", "继续", "改", "换成", "改成", "别的", "其他", "是不是", "是多少", "几点", "呢"]
    static func followUp(_ text: String) -> Bool {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "，。！？!?、"))
        guard !cleaned.isEmpty, cleaned.count <= 12 else { return false }
        if followUpLead.contains(where: { cleaned.hasPrefix($0) }) { return true }
        // 自带动词或“帮我”的是完整指令，就算短也不接上文。
        let verbs = ["帮我", "请", "查", "记", "开", "关", "设", "打", "放", "发", "搜", "找", "删"]
        if verbs.contains(where: { cleaned.hasPrefix($0) }) { return false }
        guard cleaned.count <= 6 else { return false }
        return cleaned.hasSuffix("呢") || cleaned.hasSuffix("多少") || cleaned.hasSuffix("几点")
    }
    /// 上一件任务多久之内还算“刚说的”，超过就当成新话题。
    static let followUpWindow: TimeInterval = 180
    /// 同一句里已经带了指令时不必先应答：人不会先说一声“我在”再干活。
    /// 只喊了名字就等一小会儿，确认没有下文再回一句，避免踩在用户的话上。
    static let ackDelay: TimeInterval = 0.35
    /// 事情没这么快办完时，多久之后先说一句“这就去办”。
    /// 1.2 秒太早：零模型快路与流式口播常在一两秒内就到，先说“这就去办”紧接着又报结果，听起来像连珠炮。
    static let receiptDelay: TimeInterval = 2.5
    /// 豆包接管正文的硬闸：这么久没有任何结果就交回本地已经并行听到的那份。
    /// 真正的“它没起来”由接收框那层几秒内就判定，这里只防一条链路卡死。
    static let dictationBudget: TimeInterval = 60

    /// 对助手本人说的话，不是任务：说一句就回，不派单、不走模型。
    /// “退下”派给任务，收回来的当然是“搞定了”——这种回复很诡异。
    enum Local { case dismiss, hush, thanks, remember, forget, greet, identity, praise, okay }
    /// 闲聊类：只在没有待回答的问题时就地回应；正在等他回答时，“好的”“嗯”就是答案，必须交给任务。
    static let casualKinds: Set<Local> = [.greet, .identity, .praise, .okay]
    static func casual(_ kind: Local) -> Bool { casualKinds.contains(kind) }
    static let literals: [(Local, Set<String>)] = [
        (.dismiss, ["退下", "退下吧", "退下退下", "退下吧退下", "你退下", "下去吧", "你下去吧", "你走吧", "走吧", "你可以走了", "没事了", "没事了退下", "没你事了", "你可以退下了"]),
        (.hush, ["别说了", "不要说了", "闭嘴", "安静", "安静点", "别吵", "别念了", "停一下", "停下来"]),
        (.thanks, ["谢谢", "谢谢你", "谢谢啦", "多谢", "好的谢谢", "好谢谢"]),
        // 声纹注册与取消：锁屏放开之后，这两句是机主守住“只认我”的闸门，必须能直接用嘴说。
        (.remember, ["记住我的声音", "记一下我的声音", "记下我的声音", "记住这个声音", "记住我的声纹", "注册我的声音", "认识我的声音"]),
        (.forget, ["忘掉我的声音", "忘掉这个声音", "忘掉我的声纹", "清掉我的声音", "取消声纹", "别认我的声音", "忘了我"]),
        // 打个招呼、问它是谁、夸一句、应一声：真人不会把这些当成“任务”去办，回一句就好。
        (.greet, ["你好", "您好", "你好呀", "在吗", "在不在", "早", "早上好", "早安", "中午好", "下午好", "晚上好", "哈喽", "哈啰"]),
        (.identity, ["你是谁", "你叫什么", "你叫什么名字", "你是干嘛的", "你能干什么", "你会什么", "你能做什么", "你会干什么", "你都会什么"]),
        (.praise, ["真棒", "真厉害", "厉害", "好样的", "辛苦了", "辛苦", "干得好", "干得漂亮", "不错", "做得好", "太棒了"]),
        (.okay, ["好的", "好", "知道了", "嗯", "嗯嗯", "行", "收到", "明白", "明白了", "好嘞", "ok", "OK", "okay"]),
    ]
    /// 正文里常常还带着唤醒名（“小艺退下”“小艺小艺，退下吧”），句尾还挂着语气词。
    /// 不先剥干净，这几句就会被当成活儿派出去——“退下”上一版就被理解成“退出名叫小艺的应用”。
    static let wakeNames = ["小艺", "小E", "小e", "小易", "小伊", "嗨", "嘿"]
    static let particles: Set<Character> = ["吧", "嘛", "啊", "呀", "呢", "了", "哦", "喔", "哈", "啦", "嘛"]
    static func bare(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<3 {
            let before = cleaned
            // 语音转写会把唤醒名拆开：“小 E 退下”。短句里的空格对意思没有影响，一并抹掉。
            cleaned = cleaned.filter { !$0.isWhitespace }
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "，。！？!?、~～"))
            for name in wakeNames where cleaned.hasPrefix(name) {
                cleaned.removeFirst(name.count)
                cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "，。！？!?、~～"))
            }
            if cleaned == before { break }
        }
        return cleaned
    }
    static func local(_ text: String) -> Local? {
        let body = bare(text)
        guard !body.isEmpty, body.count <= 8 else { return nil }
        // 逐层去掉句尾语气词再比对：“退下吧”“谢谢啦”都要能命中。
        var candidate = body
        for _ in 0..<3 {
            for (kind, phrases) in literals where phrases.contains(candidate) { return kind }
            guard let last = candidate.last, particles.contains(last) else { break }
            candidate.removeLast()
        }
        for (kind, phrases) in literals where phrases.contains(candidate) { return kind }
        return nil
    }
    /// 对助手本人的回应：只说一句，不报进度、不说“搞定”。
    static let replies: [Local: [String]] = [
        .dismiss: ["好，我退下了", "嗯，有需要再叫我", "行，我先退下"],
        .hush: [],
        .thanks: ["不客气", "嗯，有事叫我"],
        // 注册/取消由 DesktopVoice 自己说（要先等对方开口再收音），这里留空避免抢话。
        .remember: [],
        .forget: [],
        .greet: [],
        .identity: [],
        .praise: ["嘿嘿，应该的", "能帮上就好", "不辛苦，还有事就叫我"],
        // 应一声“好的”不需要回话；再回一句“嗯”只会变成两个人互相客气。
        .okay: [],
    ]
    /// 打招呼按时段回，后面顺口问一句要办什么，不念时间也不自我介绍一长串。
    static func greeting(hour: Int, roll: Int = 0) -> String {
        let pool: [String]
        switch hour {
        case 5..<11: pool = ["早呀，今天先办点什么？", "早，有什么要我做的吗？"]
        case 11..<14: pool = ["中午好，要我帮你做点什么？", "在呢，中午好"]
        case 14..<18: pool = ["在呢，要办点什么？", "下午好，有事你说"]
        case 18..<23: pool = ["晚上好，要我帮你做点什么？", "在呢，晚上好"]
        default: pool = ["这么晚还没睡呀，要我做点什么？", "在呢，夜深了，有事你说"]
        }
        return pool[abs(roll) % pool.count]
    }
    /// “你是谁 / 你能干什么”：一句话说清名字和三五样常用本事，不背功能清单。
    static func introduction(wake: String) -> String {
        "我是" + wake + "，能帮你开关灯、记待办、查日程、发飞书、开应用，直接跟我说就行"
    }
    /// 记声纹时收多久：够人磎慢念两三句并停顿，又不至于让人干站着。
    static let enrollSeconds: TimeInterval = 20
    static let enrollMinimumSampleCount = 32000
    static let enrollMaxSamples = 320_000
    /// 一口气念完没有停顿时按 2 秒机械切，至少也能得到几段。
    static let enrollChunkSamples = 32000
    static let enrollMaxSegments = 8
    /// 分数明显高于阈值才把这一句并进画像；不是每次通过都学，免得一次误收把陌生人越学越像。
    static let adaptScoreFloor = 0.86
    static let adaptEvery = 10
    /// 把注册音频按“句子”切段：中间停顿就算一句，短于 1.2 秒的丢掉，长于 6 秒的截开。
    /// 一句话一个样本，比固定 2 秒机械切更接近人的音素分布。
    static func enrollmentSegments(_ samples: [Float], rate: Double = 16000) -> [[Float]] {
        let frame = 320
        guard samples.count >= Int(rate) else { return [] }
        let minSamples = Int(1.2 * rate), maxSamples = Int(6 * rate)
        let silenceFrames = max(1, Int(0.35 * rate / Double(frame)))
        var spans: [(Int, Int)] = []
        var start: Int? = nil, quiet = 0, index = 0
        while index + frame <= samples.count {
            let energy = samples[index..<(index + frame)].reduce(Float(0)) { $0 + $1 * $1 } / Float(frame)
            if energy > 0.000225 { if start == nil { start = index }; quiet = 0 }
            else if start != nil { quiet += 1 }
            if let begin = start, quiet >= silenceFrames {
                let end = index - quiet * frame
                if end - begin >= minSamples { spans.append((begin, end)) }
                start = nil; quiet = 0
            }
            index += frame
        }
        if let begin = start, samples.count - begin >= minSamples { spans.append((begin, samples.count)) }
        var segments: [[Float]] = []
        for (begin, end) in spans {
            var offset = begin
            while offset < end, segments.count < enrollMaxSegments {
                let stop = min(offset + maxSamples, end)
                if stop - offset >= minSamples { segments.append(Array(samples[offset..<stop])) }
                offset = stop
            }
        }
        if segments.count >= 2 { return Array(segments.prefix(enrollMaxSegments)) }
        // 一口气念完没有停顿：固定切，至少给两段，总比一段窄画像强。
        let chunks = stride(from: 0, to: samples.count, by: enrollChunkSamples)
            .map { Array(samples[$0..<min($0 + enrollChunkSamples, samples.count)]) }
            .filter { $0.count >= enrollMinimumSampleCount }
        return Array(chunks.prefix(enrollMaxSegments))
    }
    static func reply(_ kind: Local, avoiding previous: String? = nil, roll: Int = 0,
                      hour: Int = Calendar.current.component(.hour, from: Date()), wake: String = "小E") -> String {
        switch kind {
        case .greet: return greeting(hour: hour, roll: roll)
        case .identity: return introduction(wake: wake)
        default: return pick(replies[kind] ?? [], avoiding: previous, roll: roll)
        }
    }
    /// 固定池里挑一句：优先不重复上一句，池里只有一句时就一直是它。
    static func pick(_ items: [String], avoiding previous: String?, roll: Int) -> String {
        guard !items.isEmpty else { return "" }
        guard items.count > 1 else { return items[0] }
        var index = abs(roll) % items.count
        if items[index] == previous { index = (index + 1) % items.count }
        return items[index]
    }
    /// 说完后的停顿容忍：句子越长越宽容，避免长口述中途被当成说完。
    static func silence(_ body: String) -> TimeInterval {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["等一下", "等一等", "先别执行", "稍等一下"].contains(text) { return 30 }
        if text.hasSuffix("执行吧") || text.hasSuffix("开始执行") { return 0.8 }
        if ["然后", "还有", "以及", "帮我", "把", "和", "给"].contains(where: text.hasSuffix) { return 8 }
        return min(3.5, 2.0 + Double(max(0, text.count - 16)) / 40)
    }
    /// 收尾等待：识别服务迟迟不给最终结果时的兜底上界，到点按已听内容处理。
    static let finalizeTimeout: TimeInterval = 2.5
    static func command(_ body: String) -> String {
        var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["等一下", "等一等", "先别执行", "稍等一下"].contains(text) { return "" }
        for ending in ["，开始执行", "，执行吧", "开始执行", "执行吧"] where text.hasSuffix(ending) {
            text.removeLast(ending.count); break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
