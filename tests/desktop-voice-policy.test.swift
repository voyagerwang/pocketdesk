/**
 * [INPUT]: EasyInput纯音频协议、唤醒/稳定短口令规则及临时配置目录。
 * [OUTPUT]: 验证畸形帧/会话/序号/ADPCM界限、精确唤醒同句提取、重喊唤醒词、自适应停顿、空结果收尾策略与配置私有持久性；追问/候选/原因/要点的口语挑句与闲聊就地回应。
 * [POS]: 自动语音协议回归；不连接蓝牙、不启动麦克风/识别、不执行用户任务。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Darwin
@main struct Tests {
    static var count = 0
    static func check(_ yes: @autoclosure () -> Bool, _ label: String) { count += 1; if !yes() { fatalError(label) } }
    static func main() throws {
        check(DesktopVoiceTurn.wakeParts("小E，小E，关灯",wake:"小E").count == 2,"相邻唤醒正确分段")
        let parts=DesktopVoiceTurn.wakeParts("小E，帮我记明天开会，小艺，关灯",wake:"小E")
        check(parts.count==2 && parts.last?.before=="帮我记明天开会，" && parts.last?.body=="关灯","新旧正文分离")
        check(DesktopVoiceTurn.wakeParts("这是陈小艺的作品",wake:"小E").isEmpty,"正文人名不误重唤醒")
        check(DesktopVoiceTurn.feedback("小E有结果了",wake:"小E")=="结果在屏幕上，你看一下","播报不自带唤醒名")
        check(DesktopVoiceTurn.stableQuick("关灯",stableFor:2,quietFor:2,bound:true), "固定短口令稳定和停顿后放行")
        check(!DesktopVoiceTurn.stableQuick("关灯",stableFor:1.99,quietFor:2,bound:true), "刚修改文字不放行")
        check(!DesktopVoiceTurn.stableQuick("关灯",stableFor:2,quietFor:1.99,bound:true), "仍有声音不放行")
        check(!DesktopVoiceTurn.stableQuick("关灯",stableFor:2,quietFor:2,bound:false), "没有封存绑定拒绝")
        for text in ["不要关灯", "关灯了吗", "关灯然后开空调", "帮我记录待办", "开灯？", "关闭空调\n开灯"] {
            check(!DesktopVoiceTurn.stableQuick(text,stableFor:3,quietFor:3,bound:true), "非固定短口令拒绝："+text)
        }
        check(DesktopVoiceTurn.stableQuick("打开空调。",stableFor:2,quietFor:2,bound:true), "固定插座短口令放行")
        check(DesktopVoiceTurn.emptyFinal(body:"",finishing:true) == .wake,"空final继续等待唤醒")
        check(DesktopVoiceTurn.emptyFinal(body:"开灯",finishing:true) == .commit,"收尾空结果按已听内容提交，不再停在保留态")
        check(DesktopVoiceTurn.emptyFinal(body:"开灯",finishing:false) == .resume,"未收尾的空结果继续听")
        check(DesktopVoiceTurn.ack("我在") == "我在" && DesktopVoiceTurn.ack("   ").isEmpty,"唤醒应答可配置可关闭")
        check(DesktopVoiceTurn.ack(String(repeating:"长",count:20)).count == 16,"应答文案限长")
        // 多句应答轮流说：不连着两次同一句，池里只有一句时保持不变。
        let pool = "嗯，我在|在呢|哎，听着呢"
        let first = DesktopVoiceTurn.ack(pool, avoiding: nil, roll: 0)
        let second = DesktopVoiceTurn.ack(pool, avoiding: first, roll: 0)
        check(first == "嗯，我在" && second == "在呢","应答轮换不重复上一句")
        check(DesktopVoiceTurn.ack(pool, avoiding: nil, roll: 7) == "在呢","应答轮换按存活数取模")
        check(DesktopVoiceTurn.ack("就一句") == "就一句","单句应答复原样")
        check(DesktopVoiceTurn.outcome(.succeeded, avoiding: "办好了", roll: 0) == "嗯，搞定了","收尾反馈也轮换")
        check(DesktopVoiceTurn.outcome(.failed).isEmpty == false,"失败收尾一定有话说")
        check(DesktopVoiceTurn.outcome(.answered, avoiding: "查到了", roll: 0) == "有了，你看一眼","答完又追问只报查到，不再让人确认")
        check(DesktopVoiceTurn.outcome(.answered).count <= 16,"已答完的反馈也是短句")
        // 查到了但末尾追问一句：说“查到了”，不说“要你定一下”。
        check(DesktopVoiceTurn.outcome(.needsInput, answered: true, recovery: "clarification") == .answered,"答完再追问按已答处理")
        check(DesktopVoiceTurn.outcome(.needsInput, answered: false, recovery: "clarification") == .needsInput,"没答只问仍然待确认")
        check(DesktopVoiceTurn.outcome(.needsInput, answered: true, recovery: "executionFailure") == .unconfirmed,"执行没核对上不报成功")
        check(DesktopVoiceTurn.outcome(.needsInput, answered: true, recovery: "capabilityLimit") == .needsInput,"能力不足仍待确认")
        check(DesktopVoiceTurn.outcome(.succeeded, answered: false, recovery: nil) == .succeeded,"正常完成就说完成")
        check(DesktopVoiceTurn.outcome(.failed, answered: true, recovery: nil) == .failed,"失败不因为带文字就说成功")
        check(DesktopVoiceTurn.outcome(.receipt).isEmpty == false,"办理中一定有回执话",)
        check(DesktopVoiceTurn.outcomes.values.allSatisfy { $0.allSatisfy { !$0.isEmpty } },"每个池子都有话可说")
        // 对助手本人说的话不派任务：“退下”不能被当成一个活儿去执行。
        for text in ["退下", "退下吧", "你走吧", "没事了", "你可以退下了"] {
            check(DesktopVoiceTurn.local(text) == .dismiss, "退下类话语就地回应：" + text)
        }
        for text in ["别说了", "闭嘴", "安静点"] { check(DesktopVoiceTurn.local(text) == .hush, "止声就地回应：" + text) }
        check(DesktopVoiceTurn.local("谢谢") == .thanks, "道谢就地回应")
        // 声纹注册/取消必须能用嘴说：锁屏放开之后，这是机主守住“只认我”的闸门。
        for text in ["记住我的声音", "记住我的声音吧", "小艺记住我的声音", "记一下我的声音", "注册我的声音"] {
            check(DesktopVoiceTurn.local(text) == .remember, "声纹注册就地识别：" + text)
        }
        for text in ["忘掉我的声音", "忘掉我的声音吧", "小E忘掉我的声音", "取消声纹", "别认我的声音"] {
            check(DesktopVoiceTurn.local(text) == .forget, "声纹取消就地识别：" + text)
        }
        for text in ["帮我记一个待办", "开灯", "退下以后再说", "把灯关掉然后退下"] {
            check(DesktopVoiceTurn.local(text) == nil, "不是当面话的不劫持：" + text)
        }
        check(DesktopVoiceTurn.reply(.hush).isEmpty, "止声不再多说一句话")
        check(!DesktopVoiceTurn.reply(.dismiss).isEmpty && DesktopVoiceTurn.reply(.dismiss).count <= 10, "退下的回应很短")
        // 屏幕上看到的那句话得能念出来：设备全名、括号补注和云端术语都要剔到剩下人话。
        check(DesktopVoiceTurn.speakable("米家智能温湿度计 3 2 的湿度为 58%；这是云端本次上报值，上报时间约为今天 22:29。") == "现在湿度是 58%", "湿度换成能念的一句")
        check(DesktopVoiceTurn.speakable("湿度为 58%，来自云端上一次上报（2026-11-01 22:28），目前读不到实时值。") == "现在湿度是 58%", "带括号与术语的湿度")
        check(DesktopVoiceTurn.speakable("明天（11月2日）工作台只有一条待办：「示例任务」，备注是明天示例任务；没找到和示例联系人相关的记录。") == "明天只有一条待办：示例任务", "待办只念主句")
        // 开关就直接报状态，别再让用户“看一眼”。
        check(DesktopVoiceTurn.speakable("灯 · 开关 已设置为 true，并已读回核实。") == "灯开了", "开灯念“灯开了”")
        check(DesktopVoiceTurn.speakable("灯 · 开关 已设置为 false，并已读回核实。") == "灯关了", "关灯念“灯关了”")
        check(DesktopVoiceTurn.speakable("电小酷插座 · 开关 已设置为 true，并已读回核实。") == "插座开了", "插座不带品牌名")
        // 列举必须念全：说两条就得两条都念出来。
        check(DesktopVoiceTurn.speakable("明天有两条待办：录制示例任务，以及示例文档评审。") == "明天有两条待办：录制示例任务、示例文档评审", "两条待办都念")
        check(DesktopVoiceTurn.speakable("你还有 4 个待办：1 分钟后提醒、示例任务、录制示例任务、示例文档评审。")?.contains("示例文档评审") == true, "四个待办一个不漏")
        // 日程要念标题，不能只报个钟点。
        let schedule = "明天有两个日程，都从下午两点开始：\n\n下午两点到三点，在示例会议室有「示例项目&体验讨论」；下午两点到四点，还有「示例需求评审」这两个安排重叠了。"
        let spokenSchedule = DesktopVoiceTurn.speakable(schedule) ?? ""
        check(spokenSchedule.contains("示例项目和体验讨论"), "日程标题要念全")
        check(spokenSchedule.contains("示例需求评审"), "第二条日程也要念")
        check(spokenSchedule.contains("时间撞了"), "重叠要提醒")
        let many = "共六条：甲、乙、丙、丁、戊、己。"
        check(DesktopVoiceTurn.speakable(many)?.contains("等 6 条") == true, "太多就报条数")
        // 时间念人话：说不出“零点二十八分”，也不说“75 分钟后”。
        let clock = Date(timeIntervalSince1970: 1_791_854_100)
        let zone = TimeZone(secondsFromGMT: 8 * 3600)!
        check(DesktopVoiceTurn.spokenTime("00:28 会提醒你", now: clock, timeZone: zone) == "今天凌晨零点二十八分会提醒你", "夜里零点说成凌晨零点")
        check(DesktopVoiceTurn.spokenTime("15:07 提醒你开会", now: clock, timeZone: zone) == "今天下午三点七分提醒你开会", "下午三点七分")
        check(DesktopVoiceTurn.spokenTime("明天上午10:30 有个会", now: clock, timeZone: zone) == "明天上午十点三十分有个会", "已带明天上午就不重复")
        // 一小时以内说成“几分钟后”，才是人说话的方式。
        let ninetyLater = Date(timeIntervalSince1970: 1_791_854_100)
        check(DesktopVoiceTurn.spokenTime("09:20 叫你", now: ninetyLater, timeZone: zone) == "五分钟后叫你", "五分钟后就别报点钟")
        check(DesktopVoiceTurn.spokenTime("09:21 叫你", now: ninetyLater, timeZone: zone) == "六分钟后叫你", "六分钟")
        // 记待办这类回执不能只念一个日期——“11月3日”这种半句话是最伤人的。
        check(DesktopVoiceTurn.speakable("已经记好了，“示例文档评审”这个待办，计划日期是明天，11月3日，备注里写明用 Claude Code。") == "已经记好了，示例文档评审", "待办回执念成一句人话")
        // 屏幕上的话也变成人话后，念出来仍是一句正常的回执。
        check(DesktopVoiceTurn.speakable("灯开好了。") == "灯开好了", "新回执照念")
        check(DesktopVoiceTurn.speakable("灯关好了，但没读到回读值；这次不会自动重发。") == "灯关好了", "没回读也只念前半句")
        // 缺实时值时念带数值的那一句，不念“读不到”。
        check(DesktopVoiceTurn.speakable("湿度当前值暂时读不到；最近记录 60%（今天22:40）。") == "最近记录 60%", "念带数值的那句")
        // 其它动作回执没有可念的事实，交给“办好了”。
        for text in ["已打开微信。", "已把更新检查交给 Codex。"] {
            check(DesktopVoiceTurn.speakable(text) == nil, "动作回执不逐字念：" + text)
        }
        check(DesktopVoiceTurn.speakable("") == nil && DesktopVoiceTurn.speakable(nil) == nil, "空结果不念")
        check(DesktopVoiceTurn.speakable(String(repeating: "这是一个很长很长的说明", count: 6)) == nil, "长句不逐字念")
        // 只有历史读数时也念数字，别念“还没确认上”。
        check(DesktopVoiceTurn.hasNumber("房间温度现在读不到实时值，最近一次是 25.2℃（昨天22:47）。"), "带数字的结论值得念")
        check(!DesktopVoiceTurn.hasNumber("我没找到叫小艺的设备，你想问的是哪个？"), "反问句不念")
        check(!DesktopVoiceTurn.hasNumber(""), "空结果不念")
        // 看得见的事办成了不必报；看不见的（记待办、发消息、派单）必须给回执。
        for text in ["打开飞书", "关闭飞书", "小E，退出微信", "关灯", "开灯", "锁屏", "把窗口最大化", "隐藏飞书"] {
            check(DesktopVoiceTurn.perceivable(text), "看得见的操作：" + text)
        }
        for text in ["帮我记一个明天的待办", "给张三发个消息", "让 Codex 去改 bug", "房间湿度是多少",
                     "明天有什么日程", "把这个文件发到手机"] {
            check(!DesktopVoiceTurn.perceivable(text), "看不见的操作要给回执：" + text)
        }
        // “已请求但没确认”不是失败：关掉飞书却听到“没办成”。
        for text in ["结果待核对：已请求退出飞书，尚未确认；如有保存提示，请在电脑处理。",
                     "已请求退出飞书，但没看到它关掉；如果弹了保存提示，请在电脑上处理。"] {
            check(DesktopVoiceTurn.awaiting(text), "待核对不报没办成：" + text)
        }
        check(!DesktopVoiceTurn.awaiting("未找到唯一且正在运行的目标应用，请明确应用名称。"), "真失败的仍报失败")
        // 带唤醒名和语气词也得认出来：“小艺退下”上一版被派成了“退出名叫小艺的应用”。
        for text in ["小艺退下", "小艺小艺退下", "小艺，退下吧", "小 E 退下", "退下吧", "小艺退下吧退下"] {
            check(DesktopVoiceTurn.local(text) == .dismiss, "带唤醒名也认成退下：" + text)
        }
        for text in ["谢谢啦", "小艺谢谢你"] {
            check(DesktopVoiceTurn.local(text) == .thanks, "带唤醒名也认成道谢：" + text)
        }
        for text in ["小艺别说了", "小艺，安静点"] {
            check(DesktopVoiceTurn.local(text) == .hush, "带唤醒名也认成静默：" + text)
        }
        // 剥名字不能剥出误判：真指令一个都不能被接走。
        for text in ["小艺开灯", "小艺帮我记个待办", "把灯关掉然后退下", "小艺明天什么待办", "退下以后再说"] {
            check(DesktopVoiceTurn.local(text) == nil, "剥名字后不误接：" + text)
        }
        // ---------- 对话感：追问念出来、失败说原因、长回答念要点、闲聊就地回 ----------
        check(DesktopVoiceTurn.spokenQuestion("找到两个叫张三的联系人，要发给哪一个？\n- 张三（产品部）\n- 张三（研发部）\n直接说名称就行。") == "找到两个叫张三的联系人，要发给哪一个？选项在屏幕上", "同名候选念不清就指屏幕")
        check(DesktopVoiceTurn.spokenQuestion("要发到哪个群？\n1. 产品群\n2. 研发群\n3. 周会群") == "要发到哪个群？产品群、研发群，还是周会群？", "两三个短候选直接念进问句")
        check(DesktopVoiceTurn.spokenQuestion("日程几点开始？") == "日程几点开始？", "单句问题原样念")
        check(DesktopVoiceTurn.spokenQuestion("已记下。") == nil && DesktopVoiceTurn.spokenQuestion(nil) == nil, "不是问题不硬念")
        let longQuestion = "我在你家里找到了好几个名字里都带着灯字的设备，它们分别在不同的房间里面，你想控制的是哪一个房间的？"
        check(DesktopVoiceTurn.spokenQuestion(longQuestion) == "你想控制的是哪一个房间的？", "长问句只念真正在问的分句")
        check(DesktopVoiceTurn.spokenReason("飞书登录过期了，发不出去。请在电脑上重新登录。") == "飞书登录过期了，发不出去", "失败只念第一句原因")
        check(DesktopVoiceTurn.spokenReason("Error Domain=NSURLErrorDomain Code=-1001") == nil, "英文报错不念")
        check(DesktopVoiceTurn.spokenReason("未知错误。") == nil, "空洞错误不念")
        check(DesktopVoiceTurn.conversational(.failed, recovery: nil, result: "网页服务没响应。") == "网页服务没响应", "自带否定的原因不再垫话")
        check(DesktopVoiceTurn.conversational(.failed, recovery: nil, result: "工作台服务在重启中。") == "没办成，工作台服务在重启中", "中性原因前面补一句没办成")
        check(DesktopVoiceTurn.conversational(.unconfirmed, recovery: "unconfirmed", result: "已尝试发送，接收待核实。") == nil, "已发出未核实不编话，用固定措辞")
        check(DesktopVoiceTurn.conversational(.unconfirmed, recovery: "executionFailure", result: "已尝试发送，接收待核实。") == nil, "带发送事实的执行失败也不说成没办成")
        check(DesktopVoiceTurn.conversational(.unconfirmed, recovery: "executionFailure", result: "米家服务暂时连不上。") == "米家服务暂时连不上", "真正的执行失败念原因")
        check(DesktopVoiceTurn.conversational(.needsInput, recovery: "prerequisite", result: "需要先在电脑控制台选一个家庭。") == "需要先在电脑控制台选一个家庭", "前置条件念出要做什么")
        let essay = "北京明天多云转晴，最高气温十八度。早晚温差比较大，出门记得带件外套，另外空气质量良好适合户外活动。"
        check(DesktopVoiceTurn.spokenGist(essay) == "北京明天多云转晴，最高气温十八度，细节在屏幕上", "长回答念第一句结论再指屏幕")
        check(DesktopVoiceTurn.spokenGist("明天有这些安排：\n- 评审\n- 周会") == "明天有这些安排，我列在屏幕上了", "列表开头不念半截")
        check(DesktopVoiceTurn.spokenGist("已打开微信。") == nil, "动作回执不当成回答念")
        let casualCases: [(String, DesktopVoiceTurn.Local)] = [("你好", .greet), ("小E，早上好", .greet), ("你叫什么名字", .identity),
                                                               ("你能干什么", .identity), ("辛苦了", .praise), ("好的", .okay), ("嗯", .okay)]
        for (text, kind) in casualCases {
            check(DesktopVoiceTurn.local(text) == kind, "闲聊就地回应：" + text)
            check(DesktopVoiceTurn.casual(kind), "闲聊在回答问题时让给任务：" + text)
        }
        check(!DesktopVoiceTurn.casual(.dismiss) && !DesktopVoiceTurn.casual(.hush), "退下与止声任何时候都就地处理")
        for text in ["你好帮我开灯", "你能帮我记个待办吗", "好的帮我发出去"] {
            check(DesktopVoiceTurn.local(text) == nil, "带正事的话不被闲聊吞掉：" + text)
        }
        check(DesktopVoiceTurn.reply(.greet, hour: 8).contains("早"), "早上问候按时段")
        check(DesktopVoiceTurn.reply(.greet, hour: 2).contains("晚") || DesktopVoiceTurn.reply(.greet, hour: 2).contains("夜"), "深夜问候按时段")
        check(DesktopVoiceTurn.reply(.identity, wake: "小E").hasPrefix("我是小E"), "自我介绍带上名字")
        check(DesktopVoiceTurn.reply(.okay).isEmpty, "应一声好的不再回话")
        check(DesktopVoiceTurn.outcome(.failed).contains("屏幕") , "兜底失败句告诉他去哪看原因")
        check(DesktopVoiceTurn.summary("明天两个日程（11月3日），下午的撞了。") == "明天两个日程，下午的撞了", "口播总括洗掉括号与句末标点照念")
        check(DesktopVoiceTurn.summary(String(repeating: "长", count: 90)) == nil && DesktopVoiceTurn.summary(nil) == nil && DesktopVoiceTurn.summary("  ") == nil, "空的或过长的总括不念")
        check(DesktopVoiceTurn.receiptDelay >= 2, "“这就去办”不抢在快速结果前面")
        for text in ["是多少", "那后天呢", "还有呢", "换成卧室", "几点", "那湿度呢"] {
            check(DesktopVoiceTurn.followUp(text), "短追问认出来：" + text)
        }
        for text in ["开灯", "帮我记一个明天的待办", "帮我查一下房间湿度是多少", "退下"] {
            check(!DesktopVoiceTurn.followUp(text), "不是追问的不劫持：" + text)
        }
        // 答完末尾还挂着问号的，不算答完——那是反过来在问用户。
        check(DesktopVoiceTurn.answered("湿度为 58%，来自云端上一次上报。"), "陈述句算答完")
        check(!DesktopVoiceTurn.answered("我没找到叫“小艺”的设备，你想问的是哪个？"), "反问句不算答完")
        check(!DesktopVoiceTurn.answered("") && !DesktopVoiceTurn.answered(nil), "空回答不算答完")
        check(DesktopVoiceTurn.outcomes.values.allSatisfy { $0.allSatisfy { phrase in phrase.count <= 16 } },"收尾反馈都是短句")
        check(DesktopVoiceTurn.rewoke("小E，打开灯",wake:"小E") == "打开灯","重喊唤醒词识别新内容")
        check(DesktopVoiceTurn.rewoke("帮我打开灯",wake:"小E") == nil,"普通接话不算重唤醒")
        let session: UInt64 = 0x1020304050607080
        let control = EasyInputAudioWire.control(action: 1, session: session, sequence: 42)!
        check(control.count == 20 && control.prefix(8) == Data([69,73,66,67,1,1,1,0]), "精确控制头")
        check(EasyInputAudioWire.number([UInt8](control),8,8) == session, "小端会话")
        check(EasyInputAudioWire.number([UInt8](control),16,4) == 42, "小端控制序号")
        check(EasyInputAudioWire.control(action: 0, session: session, sequence: 0) == nil, "未知动作拒绝")
        check(EasyInputAudioWire.control(action: 1, session: 0, sequence: 0) == nil, "零会话拒绝")
        var bytes = Array(repeating: UInt8(0), count: 112)
        bytes.replaceSubrange(0..<8, with: [69,73,66,65,1,28,1,1])
        bytes.replaceSubrange(8..<16, with: (0..<8).map { UInt8(truncatingIfNeeded: session >> ($0*8)) })
        bytes[24] = 160; bytes[26] = 84
        let zero = EasyInputAudioWire.decode(Data(bytes), session: session)!
        check(zero.samples.count == 160 && zero.samples.allSatisfy { $0 == 0 }, "静音ADPCM")
        check(EasyInputAudioWire.decode(Data(bytes), session: session+1) == nil, "错会话拒绝")
        for n in [0,27,32,111,113] { check(EasyInputAudioWire.decode(Data(bytes.prefix(n)), session: session) == nil || n == 113, "截断拒绝") }
        for offset in [0,4,5,6,7,24,26,31] {
            var bad = bytes; bad[offset] &+= 1
            check(EasyInputAudioWire.decode(Data(bad), session: session) == nil, "头部损坏拒绝")
        }
        var badIndex = bytes; badIndex[30] = 89
        check(EasyInputAudioWire.decode(Data(badIndex), session: session) == nil, "ADPCM索引越界")
        bytes[28] = 100; bytes[32] = 0x44; bytes[33] = 0x44
        let ramp = EasyInputAudioWire.decode(Data(bytes), session: session)!.samples
        check(ramp.prefix(4).map { Int(($0*32768).rounded()) } == [100,107,117,129], "独立IMA步进向量")
        bytes[30] = 88; bytes[28] = 255; bytes[29] = 127; bytes[32] = 0x77
        check(EasyInputAudioWire.decode(Data(bytes), session: session)!.samples.allSatisfy { $0 >= -1 && $0 <= 1 }, "PCM饱和不溢出")
        var gate = EasyInputAudioWire.SequenceGate()
        check(gate.accept(UInt32.max-1), "首帧")
        check(!gate.accept(UInt32.max-1), "重复拒绝")
        check(!gate.accept(UInt32.max-2), "倒序拒绝")
        check(gate.accept(UInt32.max) && gate.accept(0), "序号回绕")
        // 识别写成的“小艺”，展示和派单都要还原成“小E”。
        for text in ["小艺", "小艺，开灯", "小易开灯", "小伊 打开飞书", "小 e 关灯"] {
            check(DesktopVoiceTurn.normalize(text, wake: "小E").hasPrefix("小E"), "还原成小E：" + text)
        }
        check(DesktopVoiceTurn.normalize("小艺，开灯", wake: "小E") == "小E，开灯", "还原保留原句")
        check(DesktopVoiceTurn.normalize("帮我记个小艺的待办", wake: "小E") == "帮我记个小E的待办", "句中也还原")
        check(DesktopVoiceTurn.normalize("小艺开灯", wake: "小七") == "小艺开灯", "自定义唤醒词不改写")
        for (text, result) in [("小E，开灯", "开灯"), ("小e打开空调", "打开空调"), ("小易，关灯", "关灯"), ("小E", ""),
                                // 识别把“小E”写成“小艺”，正文里也不能留着名字。
                                ("小艺，开灯", "开灯"), ("小艺现在房间湿度是多少", "现在房间湿度是多少")] {
            check(DesktopVoiceTurn.body(text, wake: "小E") == result, "唤醒正文："+text)
        }
        for text in ["不要叫小E", "大小E", "小精灵开灯", "打开空调"] { check(DesktopVoiceTurn.body(text,wake:"小E") == nil, "不误唤醒") }
        check(DesktopVoiceTurn.body("零号，开灯",wake:"零号") == "开灯", "自定义唤醒词")
        check(DesktopVoiceTurn.silence("帮我") > DesktopVoiceTurn.silence("开灯"), "未完句留停顿")
        check(DesktopVoiceTurn.silence(String(repeating:"字",count:80)) <= 3.5 && DesktopVoiceTurn.silence(String(repeating:"字",count:80)) > 2.5, "长口述给更长的停顿容忍")
        check(DesktopVoiceTurn.silence("开灯") == 2, "短口令不被长停顿拖慢")
        check(DesktopVoiceTurn.silence("等一下") == 30 && DesktopVoiceTurn.command("等一下").isEmpty, "暂停不派单")
        check(DesktopVoiceTurn.command("开灯，执行吧") == "开灯", "显式收尾")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DesktopVoiceSettings.directory = dir
        defer { try? FileManager.default.removeItem(at: dir) }
        check(!DesktopVoiceSettings.load().enabled, "首次不自动收音")
        var settings = DesktopVoiceSettings(); settings.wakeWord = "小E"; settings.allowLocked = true; settings.peripheralID = UUID().uuidString
        try settings.save(); check(DesktopVoiceSettings.load().peripheralID == settings.peripheralID, "只绑定确切设备")
        let attributes = try FileManager.default.attributesOfItem(atPath: DesktopVoiceSettings.file.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "配置0600")
        for wake in ["", "a\nb", "x;rm", "123456789"] { check(!DesktopVoiceSettings.valid(wake:wake), "非法唤醒词") }
        for ack in ["a\nb", String(repeating:"长",count:17)] { check(!DesktopVoiceSettings.valid(ack:ack), "非法唤醒应答") }
        for voice in ["com.apple.voice.compact.zh-CN.Tingting", ""] { check(DesktopVoiceSettings.valid(voice:voice), "合法音色标识") }
        check(DesktopVoiceSettings.pool(" 嗯，我在 | 在呢 ||") == ["嗯，我在", "在呢"], "应答池拆句并丢空段")
        var neural = DesktopVoiceSettings()
        check(neural.usesNeural && neural.ttsVoice == "zh-CN-XiaoxiaoNeural", "缺省用神经音色")
        neural.ttsEngine = "system"; check(!neural.usesNeural && DesktopVoiceSettings.valid(tts: neural), "可切回本机音色")
        neural.ttsEngine = "xn--"; check(!DesktopVoiceSettings.valid(tts: neural), "未知音色来源拒绝")
        neural.ttsEngine = "neural"; neural.ttsRate = 99; check(!DesktopVoiceSettings.valid(tts: neural), "语速越界拒绝")
        neural.ttsRate = 4; neural.ttsVoice = "zh CN"; check(!DesktopVoiceSettings.valid(tts: neural), "神经音色标识拒绝空格")
        check(!DesktopVoiceSettings.valid(ack:String(repeating:"长|一",count:60)), "应答池总长有上限")
        for voice in ["a b", "音色", String(repeating:"a",count:129)] { check(!DesktopVoiceSettings.valid(voice:voice), "非法音色标识") }
        let legacy: [String:Any] = ["enabled":true,"wakeWord":"小E","allowLocked":true]
        try JSONSerialization.data(withJSONObject:legacy).write(to:DesktopVoiceSettings.file)
        let migrated = DesktopVoiceSettings.load()
        let escapedDefault = migrated.ackPhrase.contains("嗯，我在")
        check(migrated.enabled && migrated.ackEnabled && escapedDefault,"旧配置缺新字段按默认补齐且不静默关闭监听")
        try DesktopVoiceSettings.saveDraft("未说完的内容"); check(DesktopVoiceSettings.draft() == "未说完的内容", "草稿磁盘往返")
        let requestID = DesktopVoiceSettings.draftRequestID()
        try DesktopVoiceSettings.saveDraft("未说完的内容")
        check(DesktopVoiceSettings.draftRequestID() == requestID, "未知提交重试保留同一票据")
        try DesktopVoiceSettings.saveDraft(""); try DesktopVoiceSettings.saveDraft("未说完的内容")
        check(DesktopVoiceSettings.draftRequestID() != requestID, "下一条相同正文属于新意图")
        guard let record = DesktopVoiceSettings.draftRecord() else { fatalError("缺少草稿票据") }
        try DesktopVoiceSettings.saveParked(record)
        check(DesktopVoiceSettings.parked() == "未说完的内容" && DesktopVoiceSettings.parkedRecord()?.requestID == record.requestID, "较早未发送输入保留原文与票据")
        try DesktopVoiceSettings.saveParked(nil)
        check(DesktopVoiceSettings.parked().isEmpty && !FileManager.default.fileExists(atPath:DesktopVoiceSettings.parkedFile.path), "放弃较早输入后不留残缺文件")
        var corrupt = settings; corrupt.enabled = true; corrupt.wakeWord = ""
        try JSONEncoder().encode(corrupt).write(to: DesktopVoiceSettings.file)
        check(!DesktopVoiceSettings.load().enabled, "损坏唤醒配置不监听所有话语")
        try Data("corrupt".utf8).write(to: DesktopVoiceSettings.draftFile)
        check(DesktopVoiceSettings.draftIsCorrupt, "损坏草稿必须保留且停用")
        // 注册按“句子”切：中间停顿就断开，一句话一个样本。
        let burst = [Float](repeating: 0.3, count: 24000)
        let gap = [Float](repeating: 0, count: 9600)
        let read = DesktopVoiceTurn.enrollmentSegments(burst + gap + burst + gap + burst)
        check(read.count == 3, "念三句就得到三个样本")
        check(read.allSatisfy { $0.count >= 16000 }, "每段都不低于声纹桥的一秒下限")
        let continuous = DesktopVoiceTurn.enrollmentSegments([Float](repeating: 0.3, count: 96000))
        check(continuous.count >= 2 && continuous.count <= DesktopVoiceTurn.enrollMaxSegments, "一口气念完也切成多段")
        check(DesktopVoiceTurn.enrollmentSegments([Float](repeating: 0.3, count: 8000)).isEmpty, "半秒音频不冒充注册样本")
        check(DesktopVoiceTurn.enrollmentSegments([Float](repeating: 0.3, count: 16000 * 40)).count <= DesktopVoiceTurn.enrollMaxSegments, "念太久也不会堆样本")
        print("Desktop voice policy: \(count) checks passed")
    }
}
