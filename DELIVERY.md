# C Swift G0 交付与审核记录

2026-09-19。ZCode 提供初始三个文件；用户说明任务中途停止并授权继续后，由 Codex 审核并完成下述修复、测试和文档。不是 ZCode 独立完成，也不是上线验收。

## 结论
C 的纯协议包验收通过，保留在隔离 worktree，未提交、合并或部署。A 冻结包未修改；B 的多观测取值问题仍按 REVIEW-AB-R2-20260919.md 待修，不能据 C 完成宣称整体 G0 已通过。

## 审核发现与处理
1. 初始 66 共享样例及 65 项断言全过，但证据/产物数组类型、嵌套证据/产物/错误对象类型未严格验证。原代码误称冻结 EvidenceEntry 无 type，实际 schema 明确 type=object。现已拒绝错误类型并补反例，嵌套错误保留完整路径。
2. 时间解析丢弃小数秒，大时区偏移可能因 Foundation TimeZone 限制而回退 UTC。现显式换算偏移并保留小数秒，测试精确差值。
3. 原归属检查只比较字段，两个空对象可通过。现先校验调用与回执结构再核对关联字段，并修复原测试用 invocation 冒充 receipt 的无效正例。
4. 原生 Codable 忽略未知字段。增加类型绑定的 decodeWire 入口，先校验原始 JSON 再转模型。未来业务接入必须使用此入口，直接 JSONDecoder 不是 wire 验证。
5. readiness 局部检查补齐证据引用与 bindingId 非空检查。仍不代替执行点的设备、环境指纹、scope、权限核验。
6. 原文件 871 行且混入机器绝对路径、测试设施。现产品只保留模型/校验及独立日期文件；冻结路径、fixture 与哈希检查仅在测试层；每个新增 Swift 文件小于 800 行。

## 文件
- Sources/CapabilityModels.swift：五类 Codable 模型、严格 wire 校验、归属与 readiness 局部核验。
- Sources/CapabilityDateTime.swift：无副作用协议日期解析。
- tests/CapabilityFixtureSupport.swift：共享样例与冻结摘要验证，不编入产品。
- tests/capability-protocol.test.swift：全部共享样例、22 个合法样例严格解码往返和额外反例。
- tests/run-capability-protocol-test.sh：临时编译/执行，退出自动清理。
- CLAUDE.md、Sources/CLAUDE.md、tests/CLAUDE.md：GEB 地图同步。

## 验证
- `bash tests/run-capability-protocol-test.sh`：退出 0，111 项断言通过，其中共享 fixtures 66/66（22 合法、44 拒绝且命中原因）。
- 在临时拷贝篡改 schema 的 EvidenceEntry.type，再通过 PD_UNIFIED_ASSISTANT_PROTOCOL_DIR 运行：预期退出 1，摘要检查拒绝，未修改冻结包。
- 原冻结 SHA256SUMS.json 共 76 个文件逐个 SHA-256 复核：无差异；schema 摘要 f057f01713070ccf8d256a7e8637cede903bd1e0f5d35d31a246be57dd831910。
- 对比 C-pre-dispatch-sha256.json：已有文件仅三份 CLAUDE.md 改动；AgentRunner、TaskStore、Server 和用户既有修改均保持派发前内容。
- `git diff --check`：退出 0。

## 边界与后续
未接 Bridge、网络、生产数据库、桌面执行或任何模型调用；没有验证真实部署拓扑，也没有新增书签 capability。沿用冻结 14 个 ID，无底层架构改造。

Swift Int 解码有平台整数范围，JSONValue 数值采用 Double（与 TS number 同等级精度）；超过 Swift Int 的轮次/修订号安全拒绝，不代表支持任意精度整数。字段表漂移检查只是诊断，完整冻结文件摘要负责发现语义变更。测试使用本机冻结包路径，可通过环境变量指向同内容拷贝，移机需连同冻结包/摘要清单迁移。

原始 C 工作区附带的 v0.2 方案副本保持历史快照；产品方案以主工作区 v0.3 为准。下一步先解决 B 已登记问题及部署门禁，再安排集成，不能直接开放写能力。
