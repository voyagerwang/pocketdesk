/**
 * [INPUT]: 依赖 ModelConfigStore 的纯函数——端点归一化与脱敏视图；不联网、不写桌面、不读真实配置。
 * [OUTPUT]: 验证 ①Base URL 只接受 http/https（file/ftp/无 scheme 一律拒绝）②尾缀补全且不重复拼接
 *           ③脱敏视图绝不回传完整 Key，只给 hint ④isConfigured 要求三项齐全。
 * [POS]: tests 的模型服务配置回归；真实 HTTP 往返由 tests/m0-model-probe.cjs 与控制台「测试连接」覆盖。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct ModelConfigTests {
    static func main() {
        // 尾缀补全：填到 /v1 就自动补 /chat/completions。
        assert(ModelConfigStore.endpoint(for: "https://api.openai.com/v1")?.absoluteString
               == "https://api.openai.com/v1/chat/completions", "v1 应自动补全尾缀")
        // 已经带完整尾缀时不能拼成 /chat/completions/chat/completions。
        assert(ModelConfigStore.endpoint(for: "https://api.openai.com/v1/chat/completions")?.absoluteString
               == "https://api.openai.com/v1/chat/completions", "尾缀已存在时不应重复拼接")
        // 尾部斜杠不能拼出双斜杠空段。
        assert(ModelConfigStore.endpoint(for: "http://127.0.0.1:8080/v1/")?.absoluteString
               == "http://127.0.0.1:8080/v1//chat/completions", "尾部斜杠按原样拼接，交由服务端判定")

        // 协议白名单：不给 SSRF 留口子。
        assert(ModelConfigStore.endpoint(for: "file:///etc") == nil, "file 协议必须拒绝")
        assert(ModelConfigStore.endpoint(for: "ftp://host/v1") == nil, "ftp 协议必须拒绝")
        assert(ModelConfigStore.endpoint(for: "api.openai.com/v1") == nil, "缺 scheme 必须拒绝")
        assert(ModelConfigStore.endpoint(for: "") == nil, "空串必须拒绝")

        // 脱敏：hint 只暴露首尾，完整 Key 不得出现在视图里的任何字段。
        let secret = "sk-abcdefghij1234"
        let view = ModelConfigStore.view(ModelConfig(baseURL: "https://x/v1", model: "m", apiKey: secret, updatedAt: 0))
        let hint = view["keyHint"] as? String ?? ""
        assert(hint == "sk-…1234", "hint 应为 sk-…1234，实际 \(hint)")
        assert(view["hasKey"] as? Bool == true, "有 Key 时 hasKey 为真")
        for (key, value) in view {
            assert(!String(describing: value).contains("abcdefghij"), "视图字段 \(key) 泄漏了 Key 主体")
        }
        // 短 Key 不截断出无意义 hint，只说「已保存」。
        let shortView = ModelConfigStore.view(ModelConfig(baseURL: "https://x/v1", model: "m", apiKey: "short", updatedAt: 0))
        assert(shortView["keyHint"] as? String == "已保存", "短 Key 应只回「已保存」")
        assert(ModelConfigStore.view(ModelConfig())["hasKey"] as? Bool == false, "空配置 hasKey 为假")

        // isConfigured 要求三项齐全：缺 Key 不算配好，避免探针拿到空凭证还去发请求。
        assert(ModelConfig(baseURL: "https://x/v1", model: "m", apiKey: "").isConfigured == false, "缺 Key 不算已配置")
        assert(ModelConfig(baseURL: "", model: "m", apiKey: "k").isConfigured == false, "缺 Base URL 不算已配置")
        assert(ModelConfig(baseURL: "https://x/v1", model: "m", apiKey: "k").isConfigured == true, "三项齐全才算已配置")

        print("model config: 端点归一化/协议白名单/脱敏视图/配置完整性 全部通过")
    }
}
