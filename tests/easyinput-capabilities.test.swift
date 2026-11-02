/**
 * [INPUT]: EasyInputAudio的纯状态过滤器和合成固件状态JSON；不启动蓝牙。
 * [OUTPUT]: 验证只披露版本与已知布尔能力，配置、凭据、设备身份及畸形/超长数据不能进入诊断。
 * [POS]: 键盘扬声器接入排查的隐私边界回归，不发送硬件命令。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
@main struct Tests {
    static func main() throws {
        let fixture: [String: Any] = ["firmware":"v2.1.3-beta", "wifi_password":"fixture", "device_id":"fixture",
            "audio":["host":"private"], "capabilities":["speaker_playback":true, "speaker_stream":false,
            "host_action_v1":true, "speaker_assets_v1":1, "secret":"fixture", "device_id":"fixture"]]
        let result = EasyInputAudio.safeDeviceStatus(try JSONSerialization.data(withJSONObject: fixture))
        precondition(Set(result.keys) == Set(["firmware","capabilities"]))
        precondition(result["firmware"] as? String == "v2.1.3-beta")
        let capabilities = result["capabilities"] as! [String: Bool]
        precondition(capabilities == ["speaker_playback":true,"speaker_stream":false,"host_action_v1":true])
        precondition(EasyInputAudio.safeDeviceStatus(Data("broken".utf8)).isEmpty)
        precondition(EasyInputAudio.safeDeviceStatus(Data(repeating:32,count:4097)).isEmpty)
        precondition(EasyInputAudio.safeDeviceStatus(Data("{\"firmware\":\"bad\\nversion\"}".utf8)).isEmpty)
        print("EasyInput capabilities: version/boolean allowlist and private data rejection passed")
    }
}
