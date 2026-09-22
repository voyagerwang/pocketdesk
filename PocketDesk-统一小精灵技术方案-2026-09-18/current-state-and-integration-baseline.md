<!--
[INPUT]: Workbench 既有总方案、愿景裁决、历史验收及 2026-09-22 实施/部署清单；保留 2026-09-19 历史基线
[OUTPUT]: 两端当前关系、S01–S22 进度校准、调用图、证据边界和实施前门禁
[POS]: 统一方案的事实基线；产品解释先读本文，实施契约由同目录统一架构和专项规格承接
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
-->
# 小精灵现在是什么、已经做到哪里、两端如何统一

版本：v0.3 · 2026-09-19。结论依据：源码、历史交付记录和本轮隔离测试；不等于当前部署全部验收。

## 2026-09-22 实施增量（以下旧日期章节保留为历史基线）

本轮已在未提交源码增加默认关闭的同机 G1 笔记 Bridge、手机显式保存与原请求查账；G2 增加工作台任务、当前轮成果、显式记忆/执行规则的授权只读投影。原手机发送仍走 TaskService，未切到统一模型循环；它另外补齐原子去重台账、执行领取与手机持久恢复。G2 写入/续办、G3 Provider、G4 旧循环退役未完成。

G1/G2 的 Swift → 隔离 Workbench HTTP 和完整手机页面模拟测试通过，不等于已安装或真机通过。S15 的旧“无共享记忆 Bridge”现只在原安装包/默认路径成立：新增源码已有机主精确授权的只读记忆投影，不包含统一所有入口身份或记忆编辑。

当前 Mac 安装包内缺少 G1/G2 两个入口，原 agent-client.js 摘要也与修复版不同；本机 8787 未见监听，正式 Workbench 位置未确认。详见 [部署清单](deployment-manifest.md) 与 [实施交付证据](../../workbench/docs/assistant-reliability-delivery-2026-09-22.md)。本增量只更新事实，不降低原架构及切流门禁。

## 1. 先回答用户的四个问题

**现在是一体的吗？还不是。** Workbench 网页、微信（经 OpenClaw）、飞书接同一个 Workbench 助手入口；PocketDesk 仍有自己的模型循环、任务状态与本机工具。球体形象或名称相同，不代表共享会话、任务和记忆。

**以后是一体的吗？产品上是同一个助手，程序上保留两个协作进程。** Workbench 继续负责理解与业务调度，PocketDesk 负责手机入口、桌面展示和 Mac 执行能力。不会把 Swift 应用搬进 Node，也不会新建第三个总调度器。

**谁调用谁？** 手机的办事请求由 PocketDesk 转给 Workbench；Workbench 遇到需要操作这台 Mac 的步骤，再调用 PocketDesk 本机 Provider。CLI 执行器由 Workbench 现有 runtime 调用。返回回执沿原任务回到发起入口。

**是不是所有操作都绕 Workbench？不是。** 手动鼠标、键盘、屏幕画面、草稿同步和专用解锁继续走 PocketDesk 原通道。普通聊天与业务短操作复用 Workbench 现有助手/业务服务，不强制创建 Agent 长任务或额外审核模型。

## 2. 当前与目标调用图

当前：
```text
Workbench 网页 ───────────┐
微信 → OpenClaw 兼容入口 ─┼→ Workbench chatWithAssistant
飞书机器人 ──────────────┘     ├→ 现有业务工具：笔记/清单/日程/知识/Skill
                              ├→ 项目任务 runtime → Codex CLI
                              └→ 内容任务 runtime → Codex/WorkBuddy/Cola 文本适配

手机 → PocketDesk TaskService → AgentRunner → 本机工具/飞书 CLI/桌面 Agent GUI
         （目前没有正式 Bridge 连到上面的 Workbench 助手）
```

目标（尚未实施）：
```text
手机 → PocketDesk Bridge ─┐
Workbench / 微信 / 飞书 ──┴→ 同一个 Workbench 助手入口与现有服务
                            ├→ 笔记/清单/知识/Skill：直接复用业务服务
                            ├→ 项目任务：现有 runtime → Codex CLI
                            ├→ 内容任务：现有 runtime → 文本适配器
                            └→ Mac 操作：结构化调用 → PocketDesk Provider
                                                       → 原执行器与控制租约
                            ← 真实回执/成果 ←───────────┘
                            → 原入口展示；通知失败仅重试通知

手动看屏/鼠标/键盘/草稿/解锁 → PocketDesk 原通道
```

“同一个助手”意味着共享可信主体、策略与经授权的记忆，不意味着所有入口合并成同一个聊天窗口。会话、项目、附件访问和外发授权仍保留隔离。

## 3. 原规划在哪，如何承接

| 文档 | 地位 | 新方案的处理 |
|---|---|---|
| [Workbench 总方案](../../workbench/docs/assistant-overall-plan.md) | 九环节产品链与整体执行评审入口 | 保留，不用 PocketDesk 接入方案替代它 |
| [终态愿景及附录裁决](../../workbench/docs/workbench-vision-v1.md) | 长期目标；附录限定近期技术选择 | 保留 Fastify/SQLite/Vite，不新增 workbenchd/Temporal，不强推向量库 |
| [场景验收](../../workbench/docs/assistant-scenario-acceptance-2026-09-13.md) | S01–S22 的 9/13 历史快照 | 用下表补充后续源码进展，不把旧日期改成今日 |
| [续办交接](../../workbench/docs/assistant-next-stage-handoff-2026-09-13.md) | 边界批次与后续顺序 | 本轮复跑部分专项；不代替整批发布验收 |
| [能力×通道盘点](../../workbench/docs/stage2-pkg1-inventory-2026-09-13.md) | 登记、事实关联、换执行器缺口 | 包装现有代码；内容换手与事件记录已有后续实现 |
| 本目录统一架构 | PocketDesk 接入与跨端边界 | 只增接入契约，复用上述业务与执行底座 |

底座 B/C（Workbench 原生 / 外部编排）在旧总方案仍是待决项。本次采用“接入现有 Workbench 运行链”作为增量实施边界，不擅自宣告完成 B/C 对照，也不把外部框架迁移作为接入前置。

## 4. S01–S22 推进到了哪里

“历史通过”仅指原记录限定范围；“本轮通过”仅指隔离测试，不含真实模型、真实微信/飞书外发或运行服务器部署。

| 场景 | 本轮校准后的状态 | 保留的边界 |
|---|---|---|
| S01 笔记创建编辑 | 有现有业务链和历史通过记录 | 自然语言归类质量不由接口存在保证 |
| S02 视频→转写→总结→笔记 | 专用内容链已有历史交付 | 音频转写不等于画面理解，不能覆盖任意网站 |
| S03 公开文章导入 | 历史限定范围通过 | 登录/反爬/验证码不保证 |
| S04 内容→本地 Skill | 当前源码已自动提炼安装；本轮隔离通过 | 原任务必须要求 Skill；不执行来源脚本，不代表内容质量全通过 |
| S05 Skill 发现挂载 | 现有能力，本轮随 S04 验证发现/挂载 | 助手读方法正文不等于所有外部 Agent 自动安装执行 |
| S06 笔记→知识快照 | 已有历史通过记录 | 原笔记与知识快照不自动双向覆盖 |
| S07 定期关联笔记 | 未取得完整实现/验收证据 | 不能用普通搜索或 scheduler 存在代替 |
| S08 笔记资料→主题候选 | 后端已推进，本轮专项通过 | 真实模型归属质量及当前部署另验 |
| S09 跨主题支持/矛盾关系 | 部分基础，完整推荐闭环未验收 | 关系记录不等于自动正确发现 |
| S10 知识检索与原文引用 | 已有源码和历史通过记录 | 大规模云端资料和问答质量另验 |
| S11 主题简报与回存 | 本轮专项通过覆盖口径、幂等与冲突边界 | 不代表定期主动整理或真实业务总结质量通过 |
| S12 定期/睡眠整理 | 未取得闭环证据 | 留在后续工作，不因两端统一自动获得 |
| S13 知识→记忆→复用 | 未取得完整闭环证据 | 当前显式记忆不能冒充自动学习 |
| S14 显式记忆管理 | 已有条目增删停用和会话项目绑定 | 当前按入口身份隔离 |
| S15 跨入口记忆与领域隔离 | 部分基础；可信主体合并未接完 | PocketDesk 无共享记忆 Bridge |
| S16 Codex 项目执行 | 当前源码已支持授权开关下项目写入；本轮替身闭环通过 | 不再概括为“仅只读”；真实部署开关及项目白名单未核实 |
| S17 原任务返工/续接 | 绑定会话的 Codex 路径已有历史证据 | 不能外推到任意入口或 WorkBuddy/Cola |
| S18 WorkBuddy 联网/安装/改代码 | 正式项目路径仍阻断非 Codex | CLI 文本/文档探针和 GUI 投递不是通用项目执行 |
| S19 长期执行偏好 | 后端/API/登记消费已接线，本轮专项通过 | `global` 单条偏好；不是项目/能力范围路由全实现 |
| S20 逐轮用量与预算 | 本轮专项通过，未知不记零、已知超额前置拒绝 | 动态选模、供应商调用金额硬上限未证明 |
| S21 任务复盘与经验进化 | 未取得完整闭环证据 | Skill 自动保存不能代替试用、纠错与效果对照 |
| S22 清单详情互斥 | 已有历史通过记录 | 本轮未复跑页面 |

新增校准：内容任务已支持同一任务编号换执行者、attempt 增长、同一笔记交接及内容事件入账；本轮 `verify-content-switch` 通过。仅限视频/文章内容，执行中拒绝换手；项目任意换执行器不支持。当前实现仍需单独补换手与领取并发、事务中断、迟到回执的全链路验收，不能把现有专项扩写成全保障。

## 5. 各家 Agent 到底能做什么

| 执行者/路径 | 当前可确认范围 | 不应承诺 |
|---|---|---|
| Workbench 自己的助手工具 | 笔记、清单、提醒、日程、知识、Skill 等现有业务接口；按各自授权/配置执行 | 无条件访问所有外部账号；所有操作都有统一新协议 |
| Codex 项目 CLI | 授权项目、执行与独立验收；可按配置选择 workspace-write；绑定会话续接 | 任意项目写入、所有入口续接、任意多 Agent 编排 |
| WorkBuddy CLI | 内容纯文本总结；固定文件受限文档探针 | 通用网页研究/安装/项目改码；原生持久 resume；远端停止已验证 |
| Cola CLI | 内容文本总结/文档返回；已在 registry 登记 | 项目目录控制、原生续接和任意模型选择 |
| ZCode 飞书路径 | 登记和历史通信探针 | 正式项目 runtime 接入 |
| PocketDesk 桌面 GUI | 向配置支持的 Agent 应用提交正文 | 获取正式 session、持续进度、成果与验收闭环 |
| PocketDesk 本机工具 | 当前网页、受控应用/窗口/菜单/输入、锁屏及飞书 CLI 等现有工具 | 已被 Workbench 自动共享；解锁密码进入助手 |

“在 PocketDesk 里能发给 WorkBuddy”与“Workbench 能让 WorkBuddy 完成项目任务”是两种能力，界面必须用“桌面投递 / 文本处理 / 项目执行”分别说明。

## 6. 本轮证据与部署限制

源码基准：Workbench HEAD `2d2f357`（2026-09-18）；审阅前工作区干净。PocketDesk 有用户既有未提交代码，本轮只修改方案文档，不改运行代码。

现状代码定位：
- [入站来源](../../workbench/server/src/services/inbound-context.ts)：仅 workbench/weixin/feishu；[三入口助手](../../workbench/server/src/services/assistant-entry.ts)。
- [派发装配](../../workbench/server/src/services/agent-dispatch.ts)：项目仅 Codex、内容分流、Stage A 绑定、内容换手。
- [项目沙箱](../../workbench/server/src/services/agent-execution.ts)、[Agent 登记](../../workbench/server/src/services/agent-registry.ts)。
- [普通记忆](../../workbench/server/src/services/assistant-memory.ts)、[执行偏好](../../workbench/server/src/services/agent-preferences.ts)、[登记消费](../../workbench/server/src/services/agent-orchestrator.ts)。
- [Skill 自动安装](../../workbench/server/src/services/skill-capture.ts)、[用量聚合](../../workbench/server/src/services/agent-task-usage.ts)。
- [PocketDesk 任务服务](../Sources/TaskService.swift)、[持久占用](../Sources/TaskStore.swift)、[配对鉴权](../Sources/Auth.swift)。

本轮执行命令：工作目录 `/Users/yz/Documents/workbench`，统一前缀 `./node_modules/.bin/tsx server/`，以下七项均 exit 0：

| 脚本 | 验证范围 |
|---|---|
| verify-agent-preferences.mts | 长期偏好、临时覆盖、任务消费、重启与撤销 |
| verify-agent-task-usage.mts | 阶段用量、缺失轮次、未知与预算前置拒绝 |
| verify-agent-project-write.mts | 替身项目文件写入、原生会话参数、独立只读审核 |
| verify-content-switch.mts | 内容同号换手、笔记复用、事件及轮次 |
| verify-note-topic-candidates.mts | 笔记资料候选、采纳/排除/去重 |
| verify-topic-brief-s11.mts | 简报覆盖、版本、回存冲突与幂等 |
| verify-skill-capture.mts | 隔离 Skill 自动落盘、读回、发现挂载与失败重试 |

没有调用真实模型、外发消息或修改生产数据库。没有找到本仓库 `data/workbench.db` 或 `server/data/workbench.db`。`/api/health` 返回正常，但 127.0.0.1:8787 的监听进程是 UURemote，不是本机 Node；这是部署拓扑需要核实的证据，不能据此确定远端主机、运行版本、配置或真实数据位置。

**因此可以确认源码进展和专项通过，不能宣称整个旧批次已发布，也不能照抄 9/18 方案中的数据库快照为当前事实。**

## 7. 接入前必须收口的门禁

| 门禁 | 必须产出 | 不通过时 |
|---|---|---|
| 部署定位 | 实际 Workbench 主机、监听地址、运行 commit、主库/附件目录、启动方式 | 只做协议/只读，不假定 loopback 同机调用成立 |
| 准入矩阵 | 能力×入口×执行通道×权限×配置×验证范围 | 不支持者明确阻塞，不靠换 taskType 绕过 |
| 旧能力保全 | S04/S08/S11/S16/S17/S19/S20 与内容换手的基线回归 | 不切换入口 |
| 身份与授权 | 单 owner 绑定、来源会话、凭证撤销、资源读取与动作确认 | 不开放写入 |
| 可靠性 | 回包丢失查账、重启、乱序、超时不双执行、通知不重跑任务 | 不开放默认统一模式 |
| 用户交付 | 手机能打开鉴权成果，原入口能追问/查看限制 | 不报告端到端交付完成 |

不承诺“绝无漏洞”或“永远不改底层”；通过稳定接口、证据门禁和小范围切换减少返工。任何数据库替换、运行时替换、同机改远端、通用 RunStep 引入都单独记架构决策，不能藏在接入实现里。

## 8. v0.3 覆盖补充与交付状态

PocketDesk 的书签检索/打开、自然名称解析、甩送复用普通发送、GUI 新任务/明确续接、桌面反馈只读投影已纳入 [接入与切流门禁](integration-gates-and-rollout.md)。桌面面板不是独立业务输入来源。HEAD 不包含全部当前修改，实施基线需同时保存 git status/diff 与被测文件摘要。

A/B 实现保存在隔离 worktree，未合并、未部署；第二轮验收：A 原缺陷反例通过、19/19 测试与 66 个样例的标准校验对照通过，可冻结首批契约供 C 对齐；B 11 组测试通过，但多观测先成功后失败仍误报 verified，暂不验收。C 的 Swift 纯协议包已由 Codex 接手补完并验收：111 项断言、共享 66 个样例全部通过，冻结包摘要未变；交付位于隔离 C worktree，未合并或部署。G0 整体仍未完成，B 与部署事实门禁尚待验收。详见 [C 验收记录](/Users/yz/.codex/zcode-night-20260919/REVIEW-C-20260919.md)。

新增产品解释见 [一套小精灵如何连接多个入口和执行能力](assistant-product-and-routing.md)：查用量工具、GUI 观察反馈及跨入口记忆均按目标设计与现有实现分开，新增能力不暗改冻结 14-ID 契约。

## 9. 2026-09-19 后续交付校准

B 已补修并验收：当前唯一观测契约、时间/范围/证据/环境校验，冲突或多条不选成功。A/B/C 均仅隔离包验收通过，部署拓扑与跨端 Bridge 尚未完成，G0 总门禁不自动通过。见 [B 最终验收](/Users/yz/.codex/zcode-night-20260919/REVIEW-B-FINAL-20260919.md)。

分层记忆管理首版在 D-memory 隔离 worktree：长期条目搜索/分类/编辑/停用/删除、现有 global 执行规则编辑/撤销、当前会话上下文说明；事务内版本冲突保护。没有跨 PocketDesk 共享、自动候选或打开目标规则，未合并/部署。见 [交付记录](/Users/yz/.codex/zcode-night-20260919/worktrees/D-memory/docs/memory-management-delivery-20260919.md)。
