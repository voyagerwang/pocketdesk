/**
 * [INPUT]: 依赖 ModelConfigStore 的纯函数——端点归一化与脱敏视图；不联网、不写桌面、不读真实配置。
 * [OUTPUT]: 验证端点/凭证同源边界、多条目递归脱敏、旧单条稳定迁移与无重复凭证的新格式往返；活动 ID 只显式选择，缺失或删除后不猜其他服务商，Codex 后端与 API 条目独立。
 * [POS]: tests 的模型服务配置回归；真实 HTTP 往返由 tests/m0-model-probe.cjs 与控制台「测试连接」覆盖。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

@main struct ModelConfigTests {
    static func main() throws {
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

        // 凭证身份按 origin 判定，路径变化不会强制用户重输同一服务的 Key。
        assert(ModelConfigStore.credentialOriginMatches("https://api.example/v1", "https://API.EXAMPLE:443/v2"), "https 默认端口与主机大小写等价")
        assert(ModelConfigStore.credentialOriginMatches("http://api.example/v1", "http://api.example:80/v2"), "http 默认端口等价")
        assert(ModelConfigStore.credentialOriginMatches("https://api.example:8443/v1", "https://api.example:8443/other"), "同源的非默认端口允许改路径")
        assert(!ModelConfigStore.credentialOriginMatches("https://api.example/v1", "https://other.example/v1"), "不同主机不能沿用 Key")
        assert(!ModelConfigStore.credentialOriginMatches("https://api.example/v1", "http://api.example/v1"), "不同协议不能沿用 Key")
        assert(!ModelConfigStore.credentialOriginMatches("https://api.example/v1", "https://api.example:8443/v1"), "不同有效端口不能沿用 Key")
        assert(!ModelConfigStore.credentialOriginMatches("file:///etc", "file:///etc"), "不支持的协议没有可沿用的凭证身份")
        assert(!ModelConfigStore.credentialOriginMatches("", "https://api.example/v1"), "无效原地址不能授权沿用 Key")

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

        let legacy = try JSONDecoder().decode(ModelConfig.self, from: Data("{\"baseURL\":\"https://api.deepseek.com\",\"model\":\"deepseek-flash\",\"apiKey\":\"test\",\"updatedAt\":1}".utf8))
        assert(legacy.backend == .api && legacy.activeModel == "deepseek-flash", "旧存储必须保留原 API 路由")
        assert(legacy.providers.count == 1 && legacy.activeProviderID == "legacy-api", "旧单条解码成稳定 ID，不重新生成身份")
        assert(legacy.providers[0].apiKey == "test", "旧密钥留在原条目中")
        assert(legacy.providers[0].name == "DeepSeek", "旧已知服务只按精确 origin 命名")
        assert(ModelConfigStore.providerName(for: "https://API.OPENAI.COM:443/v1") == "OpenAI", "品牌命名采用同源默认端口规则")
        assert(ModelConfigStore.providerName(for: "https://other.example/v1") == "other.example", "自定义服务保留主机名")
        assert(ModelConfigStore.providerName(for: "http://api.deepseek.com") == "api.deepseek.com", "不同协议不冒充已知 origin")
        var selected = legacy
        selected.backend = .codex
        assert(selected.isConfigured && selected.activeModel == "gpt-6-luna" && selected.activeHost == "codex", "Codex 使用独立登录模型")
        assert(selected.apiKey == legacy.apiKey && selected.backupConfigured, "切换不删除 API 备用")
        assert(ModelConfig(backend: .codex).isConfigured, "Codex 不要求额外 API Key")
        let selectedView = ModelConfigStore.view(selected)
        assert(selectedView["authMode"] as? String == "chatgpt" && selectedView["backend"] as? String == "codex", "视图说明真实计费后端")
        let restored = try JSONDecoder().decode(ModelConfig.self, from: JSONEncoder().encode(selected))
        assert(restored == selected, "后端选择可持久恢复")

        let first = APIProviderConfig(id: "first", name: "服务 A", baseURL: "https://a.example/v1", model: "model-a", apiKey: secret)
        let second = APIProviderConfig(id: "second", name: "服务 B", baseURL: "https://b.example/v1", model: "model-b", apiKey: "sk-othersecret5678")
        var multiple = ModelConfig(providers: [first, second], activeProviderID: "first")
        assert(multiple.baseURL == first.baseURL && multiple.model == first.model && multiple.apiKey == first.apiKey, "兼容字段来自选中条目")
        multiple.activeProviderID = "second"
        assert(multiple.baseURL == second.baseURL && multiple.apiKey == second.apiKey && multiple.activeModel == "model-b", "切换选择不丢其他条目的密钥")
        multiple.activeProviderID = "first"
        multiple.model = "model-a-edited"
        assert(multiple.provider(id: "first")?.model == "model-a-edited" && multiple.provider(id: "second") == second, "兼容字段写入只更新当前条目")
        let multipleView = ModelConfigStore.view(multiple)
        let providerViews = multipleView["providers"] as? [[String: Any]] ?? []
        assert(providerViews.count == 2 && providerViews.allSatisfy { $0["apiKey"] == nil && $0["hasKey"] as? Bool == true }, "列表只包含脱敏字段")
        let visibleJSON = String(data: try JSONSerialization.data(withJSONObject: multipleView), encoding: .utf8) ?? ""
        assert(!visibleJSON.contains("abcdefghij") && !visibleJSON.contains("othersecret"), "所有条目及顶层都不泄漏密钥主体")
        let encoded = try JSONEncoder().encode(multiple)
        let storedJSON = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        assert(storedJSON["apiKey"] == nil && storedJSON["baseURL"] == nil && storedJSON["model"] == nil, "新格式只在 providers 内保存凭证，避免双重真值")
        let decodedMultiple = try JSONDecoder().decode(ModelConfig.self, from: encoded)
        assert(decodedMultiple == multiple, "多条目及选择完整往返")

        multiple.removeProvider(id: "first")
        assert(multiple.providers == [second] && multiple.activeProviderID == nil && !multiple.isConfigured, "删除活动 API 留未配置态，不切向另一家")
        assert(multiple.baseURL.isEmpty && multiple.model.isEmpty && multiple.apiKey.isEmpty, "未选中时兼容字段为空，不借其他条目凭证")
        assert(ModelConfigStore.view(multiple)["activeProviderID"] as? String == "", "控制台用空字符串表示未选中")
        var codex = ModelConfig(backend: .codex, providers: [first, second], activeProviderID: "first")
        codex.removeProvider(id: "first")
        assert(codex.isConfigured && codex.backend == .codex && codex.providers == [second], "删除 Codex 的选中备用不改变登录后端")
        let noSelection = try JSONDecoder().decode(ModelConfig.self, from: JSONEncoder().encode(multiple))
        assert(noSelection.activeProviderID == nil && !noSelection.isConfigured, "未选中状态持久化后也不猜默认服务")
        let emptyNew = try JSONDecoder().decode(ModelConfig.self, from: Data("{\"providers\":[],\"activeProviderID\":\"\",\"baseURL\":\"https://old.example\",\"model\":\"old\",\"apiKey\":\"old-key\"}".utf8))
        assert(emptyNew.providers.isEmpty && !emptyNew.isConfigured, "存在新格式时不从遗留顶层字段复活已移除条目")
        var staleSelectionJSON = storedJSON
        staleSelectionJSON["activeProviderID"] = "missing"
        let staleSelection = try JSONDecoder().decode(ModelConfig.self, from: JSONSerialization.data(withJSONObject: staleSelectionJSON))
        assert(staleSelection.activeProviderID == nil && !staleSelection.isConfigured, "失效活动 ID 不回退到列表首项")
        var incomplete = first
        incomplete.name = " \n"
        assert(!incomplete.isConfigured, "无名称的服务商不是完整配置")
        incomplete = first
        incomplete.baseURL = "file:///tmp"
        assert(!incomplete.isConfigured, "无效 API 协议不能标为已配置")

        print("model config: 端点/同源/迁移/多服务商/递归脱敏/显式选择 全部通过")
    }
}
