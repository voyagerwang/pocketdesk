/**
 * [INPUT]: Server已核实的本机同源控制台请求、DesktopVoice运行时；仅主线程访问语音状态。
 * [OUTPUT]: 读取状态与音色清单、严格配置唤醒词/应答/音色/连续对话、显式重试/试听/处理当前与较早未发送输入；不接受音频注入或文本代替声学唤醒。
 * [POS]: 唤醒配置的HTTP适配层；复用ConsoleActions来源门禁，不开放局域网或跨站修改。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import CoreFoundation

enum DesktopVoiceHTTP {
    private static let required: Set<String> = ["action", "enabled", "wakeWord", "allowLocked"]
    private static let accepted: Set<String> = required.union(["ackEnabled", "ackPhrase", "voice", "ttsEngine", "ttsVoice", "ttsRate", "dictation", "followUp"])

    private static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func handle(method: String, path: String, body: Data, reply: @escaping (Int, [String: Any]) -> Void) -> Bool {
        guard path == "/api/console/voice" else { return false }
        guard body.count <= 4096 else { reply(413, ["error": "请求过大。"]); return true }
        DispatchQueue.main.async {
            let voice = DesktopVoice.shared
            if method == "GET" { reply(200, voice.snapshot()); return }
            guard method == "POST", let v = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let action = v["action"] as? String else {
                reply(400, ["error": "请求无效。"]); return
            }
            do {
                switch action {
                case "save":
                    guard required.isSubset(of: Set(v.keys)), Set(v.keys).isSubset(of: accepted),
                          let enabled = flag(v["enabled"]), let locked = flag(v["allowLocked"]),
                          let wake = v["wakeWord"] as? String, DesktopVoiceSettings.valid(wake: wake) else {
                        reply(400, ["error": "唤醒词请填写1至8个汉字、字母或数字。"]); return
                    }
                    var ackEnabled = voice.settings.ackEnabled, ack = voice.settings.ackPhrase
                    var identifier = voice.settings.voiceIdentifier
                    var engine = voice.settings.ttsEngine
                    var ttsVoice = voice.settings.ttsVoice
                    var ttsRate = voice.settings.ttsRate
                    var dictation: Bool? = nil
                    var followUp: Bool? = nil
                    if v.keys.contains("ackEnabled") {
                        guard let value = flag(v["ackEnabled"]) else { reply(400, ["error": "唤醒应答开关无效。"]); return }
                        ackEnabled = value
                    }
                    if let value = v["ackPhrase"] {
                        guard let text = value as? String, DesktopVoiceSettings.valid(ack: text) else {
                            reply(400, ["error": "唤醒应答请填写120个字以内、每句不超过16个字，多句用竖线分隔。"]); return
                        }
                        ack = text
                    }
                    if let value = v["voice"] {
                        guard let text = value as? String, DesktopVoiceSettings.valid(voice: text) else {
                            reply(400, ["error": "音色标识无效。"]); return
                        }
                        identifier = text.isEmpty ? nil : text
                    }
                    if let value = v["ttsEngine"] {
                        guard let text = value as? String, ["neural", "system"].contains(text) else {
                            reply(400, ["error": "音色来源无效。"]); return
                        }
                        engine = text
                    }
                    if let value = v["ttsVoice"] {
                        guard let text = value as? String, DesktopVoiceSettings.valid(voice: text) else {
                            reply(400, ["error": "音色标识无效。"]); return
                        }
                        ttsVoice = text.isEmpty ? nil : text
                    }
                    if let value = v["ttsRate"] {
                        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                              (-25...25).contains(number.intValue) else { reply(400, ["error": "语速请设在 -25 到 25 之间。"]); return }
                        ttsRate = number.intValue
                    }
                    if let value = v["dictation"] {
                        guard let text = flag(value) else { reply(400, ["error": "转写方式开关无效。"]); return }
                        dictation = text
                    }
                    if let value = v["followUp"] {
                        guard let on = flag(value) else { reply(400, ["error": "连续对话开关无效。"]); return }
                        followUp = on
                    }
                    try voice.configure(enabled: enabled, wake: wake, allowLocked: locked,
                                        ack: ack, ackEnabled: ackEnabled, voice: identifier,
                                        engine: engine, ttsVoice: ttsVoice, rate: ttsRate, dictation: dictation, followUp: followUp)
                case "retry", "sendDraft", "discardDraft", "sendParked", "discardParked", "preview":
                    guard Set(v.keys) == Set(["action"]) else { reply(400, ["error": "请求无效。"]); return }
                    switch action {
                    case "retry": voice.retry()
                    case "sendDraft": try voice.sendDraft()
                    case "discardDraft": try voice.discardDraft()
                    case "sendParked": try voice.sendParked()
                    case "discardParked": try voice.discardParked()
                    default: voice.preview()
                    }
                default: reply(400, ["error": "操作无效。"]); return
                }
                reply(200, voice.snapshot())
            } catch { reply(422, ["error": "未完成操作，配置或输入已保留；请检查锁屏状态与文件权限。"] ) }
        }
        return true
    }
}
