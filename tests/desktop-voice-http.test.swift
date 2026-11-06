/**
 * [INPUT]: 真实语音HTTP处理器与纯运行时替身；主线程RunLoop处理回调。
 * [OUTPUT]: 验证读取零启用、严格布尔/唤醒词/应答/音色/字段/体积门禁、试听与当前及较早未发送输入的明确动作；不申请权限、不收音。
 * [POS]: 本机语音配置契约回归；来源门禁仍由ConsoleManagementHTTP/ConsoleActions统一处理。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
final class DesktopVoice {
    static let shared = DesktopVoice()
    var writes = 0; var wake = "小E"; var enabled = false; var sent = 0; var dropped = 0; var retries = 0
    var previews = 0; var parkedSent = 0; var parkedDropped = 0
    var settings = DesktopVoiceSettings()
    func snapshot() -> [String:Any] { ["wakeWord":wake,"enabled":enabled,"ackPhrase":settings.ackPhrase] }
    func configure(enabled:Bool,wake:String,allowLocked:Bool,ack:String,ackEnabled:Bool,voice:String?,
                   engine:String? = nil,ttsVoice:String? = nil,rate:Int? = nil,dictation:Bool? = nil,followUp:Bool? = nil) throws {
        writes += 1; self.wake = wake; self.enabled = enabled
        settings.ackPhrase = ack; settings.ackEnabled = ackEnabled; settings.voiceIdentifier = voice
        if let engine { settings.ttsEngine = engine }
        if let ttsVoice { settings.ttsVoice = ttsVoice.isEmpty ? nil : ttsVoice }
        if let rate { settings.ttsRate = rate }
        if let dictation { settings.dictationEnabled = dictation }
        if let followUp { settings.followUpEnabled = followUp }
    }
    func retry() { retries += 1 }; func sendDraft() throws { sent += 1 }; func discardDraft() throws { dropped += 1 }
    func sendParked() throws { parkedSent += 1 }; func discardParked() throws { parkedDropped += 1 }
    func preview() { previews += 1 }
}
@main struct Tests {
    static var count = 0
    static func check(_ yes:Bool,_ label:String) { count += 1; if !yes { fatalError(label) } }
    static func call(_ method:String,_ value:[String:Any]? = nil,raw:Data? = nil)->Int {
        var status:Int?
        let handled = DesktopVoiceHTTP.handle(method:method,path:"/api/console/voice",body:raw ?? (try! JSONSerialization.data(withJSONObject:value ?? [:]))) { code,_ in status=code }
        check(handled,"路由接管")
        let deadline = Date().addingTimeInterval(2)
        while status == nil && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.001)) }
        return status ?? -1
    }
    static func main() {
        let runtime=DesktopVoice.shared
        check(call("GET")==200 && runtime.writes==0,"GET不启用收音")
        let save:[String:Any] = ["action":"save","enabled":true,"wakeWord":"小E","allowLocked":true]
        check(call("POST",save)==200 && runtime.enabled,"显式保存")
        check(runtime.settings.ackPhrase.hasPrefix("嗯，我在") && runtime.settings.ackEnabled,"缺省不改唤醒应答")
        var bad=save;bad["enabled"]=1
        check(call("POST",bad)==400 && runtime.writes==1,"数字不冒充布尔")
        bad=save;bad["allowLocked"]="true"
        check(call("POST",bad)==400,"字符串不冒充锁屏授权")
        bad=save;bad["wakeWord"]="小E\n执行"
        check(call("POST",bad)==400,"换行拒绝")
        bad=save;bad["audio"]="injected"
        check(call("POST",bad)==400,"拒绝音频注入")
        bad=save;bad["ackEnabled"]=1
        check(call("POST",bad)==400 && runtime.writes==1,"应答开关不接受数字")
        bad=save;bad["ackPhrase"]="我在\n执行"
        check(call("POST",bad)==400 && runtime.writes==1,"应答文案不接受换行")
        bad=save;bad["ackPhrase"]=String(repeating:"长",count:17)
        check(call("POST",bad)==400,"应答文案限长")
        bad=save;bad["voice"]="com.apple.voice;rm"
        check(call("POST",bad)==400 && runtime.writes==1,"音色标识拒绝注入")
        var tuned=save;tuned["ackPhrase"]="诶";tuned["ackEnabled"]=false;tuned["voice"]="com.apple.voice.compact.zh-CN.Tingting"
        check(call("POST",tuned)==200 && runtime.settings.ackPhrase=="诶" && !runtime.settings.ackEnabled
              && runtime.settings.voiceIdentifier=="com.apple.voice.compact.zh-CN.Tingting","显式保存应答与音色")
        var empty=tuned;empty["voice"]=""
        check(call("POST",empty)==200 && runtime.settings.voiceIdentifier == nil,"空音色回到自动选择")
        var neural=save;neural["ttsEngine"]="neural";neural["ttsVoice"]="zh-CN-XiaoxiaoNeural";neural["ttsRate"]=6
        check(call("POST",neural)==200 && runtime.settings.ttsVoice=="zh-CN-XiaoxiaoNeural" && runtime.settings.ttsRate==6
              && runtime.settings.usesNeural,"显式保存神经音色与语速")
        var engine=save;engine["ttsEngine"]="cloud"
        check(call("POST",engine)==400,"音色来源只接受neural或system")
        var rate=save;rate["ttsRate"]=40
        check(call("POST",rate)==400,"语速越界拒绝")
        var numeric=save;numeric["ttsRate"]=true
        check(call("POST",numeric)==400,"布尔不冒充语速")
        var follow=save;follow["followUp"]=false
        check(call("POST",follow)==200 && !runtime.settings.followUpEnabled,"连续对话可显式关闭")
        var followNumber=save;followNumber["followUp"]=0
        check(call("POST",followNumber)==400,"数字不冒充连续对话开关")
        var system=save;system["ttsEngine"]="system";system["voice"]="com.apple.voice.compact.zh-CN.Tingting"
        check(call("POST",system)==200 && !runtime.settings.usesNeural,"可切回本机音色")
        check(call("POST",["action":"preview"])==200 && runtime.previews==1,"试听只朗读应答")
        check(call("POST",["action":"sendDraft"])==200 && runtime.sent==1,"草稿仅明确发送")
        check(call("POST",["action":"discardDraft"])==200 && runtime.dropped==1,"草稿仅明确丢弃")
        check(call("POST",["action":"sendParked"])==200 && runtime.parkedSent==1,"较早输入仅明确发送")
        check(call("POST",["action":"discardParked"])==200 && runtime.parkedDropped==1,"较早输入仅明确丢弃")
        check(call("POST",["action":"retry"])==200 && runtime.retries==1,"显式重连")
        check(call("POST",["action":"sendDraft","text":"替换原文"])==400 && runtime.sent==1,"不得偷偷替换草稿")
        check(call("POST",["action":"preview","text":"我插一句"])==400 && runtime.previews==1,"不得注入朗读正文")
        check(call("POST",raw:Data(repeating:32,count:4097))==413,"体积限制")
        print("Desktop voice HTTP: \(count) checks passed")
    }
}
