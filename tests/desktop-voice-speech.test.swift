/**
 * [INPUT]: 真实DesktopVoiceSpeech与隔离设置目录；合成/播放替身，不访问网络或扬声器。
 * [OUTPUT]: 验证冷合成不阻塞主线程、打断后迟到音频不播放、缓存命中及超限逐项淘汰而非整批清空。
 * [POS]: 真人音色生命周期回归；用-D DESKTOP_VOICE_TEST编译，固定硬件与云端副作用边界。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
@main struct Tests {
    static func pump(until ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        precondition(ready(), "异步回调应收敛")
    }
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DesktopVoiceSettings.directory = directory
        defer { try? FileManager.default.removeItem(at: directory) }
        try DesktopVoiceSettings().save()
        let voice = DesktopVoiceSpeech()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        voice.testReady = true
        voice.testAudio = { _,_,_,_ in
            started.signal(); _ = release.wait(timeout: .now()+3)
            return Data(repeating: 1, count: 1024)
        }
        var played = 0
        voice.testPlay = { _ in played += 1; return 0.5 }
        let began = ProcessInfo.processInfo.systemUptime
        _ = voice.say("我在")
        precondition(ProcessInfo.processInfo.systemUptime-began < 0.1, "合成不能锁住主线程")
        precondition(started.wait(timeout:.now()+1) == .success && voice.isSpeaking)
        voice.stop(); release.signal()
        pump { voice.rendered("我在") != nil }
        precondition(played==0 && !voice.isSpeaking, "新唤醒取消后旧音频不能迟到播放")
        _ = voice.say("我在");precondition(played==1, "相同音色缓存立即播放")
        voice.stop()
        voice.testAudio = { text,_,_,_ in Data(("fixture:"+text).utf8) }
        for i in 0..<70 { voice.prewarm("固定短句\(i)") }
        pump { voice.diagnostics["pending"] as? Int == 0 }
        precondition(voice.diagnostics["cached"] as? Int == 64, "缓存到上限只淘汰最旧条目")
        precondition(voice.rendered("固定短句69") != nil && voice.rendered("固定短句0") == nil)
        precondition(played==1, "预渲染不播报")
        print("Desktop voice speech: nonblocking synthesis, cancellation, cache hit and bounded eviction passed")
    }
}
