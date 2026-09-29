# PocketDesk × Workbench 统一小精灵技术架构

- 版本：v0.1
- 日期：2026-09-18
- 状态：技术基线与实施方案，可持续修订
- 范围：入口、身份、记忆、能力、路由、执行器、任务、回执、产物、权限与迁移；不在本版直接改造生产执行链

## 0. 本文要解决的问题

目前 PocketDesk 和 Workbench 都有“小精灵”，但它们不是同一个运行系统：

- PocketDesk 小精灵有自己的模型循环、本机工具和任务存储，可以通过桌面 GUI 向 WorkBuddy、Codex、Cola、ZCode、ChatGPT 等应用提交文字。
- Workbench 小精灵有自己的模型、工具、长期记忆、任务编排、执行台账和产物管理；正式项目执行主要接到了 Codex。
- Workbench 虽然已有 WorkBuddy CLI adapter，也有 WorkBuddy 已完成记录，但当前只在受限文档探针或无工具的内容总结路径中成立。正式项目派发路径仍明确拒绝非 Codex。

用户看到的表象都是“小精灵给 Agent 下命令”，技术上却处于不同证据等级。本文先统一术语和事实，再给出可以分阶段实施的架构。

## 1. 结论

最终应只有一个逻辑小精灵：**Workbench Assistant Core**。PocketDesk 不再长期维护第二套人格、记忆、业务工具和开放任务规划，而作为三个角色存在：

1. 手机输入与结果展示渠道。
2. Mac 本机能力提供者，例如当前网页、应用打开、窗口操作、输入和桌面 Agent GUI 投递。
3. Workbench 不可用时的有限本机降级执行器。

统一架构不是把两套代码直接合并，而是建立以下边界：

```text
手机 / Workbench / 微信 / 飞书
              │
        Inbound Gateway
              │
      Workbench Assistant Core
    身份 · 任务 · 记忆 · 路由 · 策略
              │
       Capability Orchestrator
      ┌───────┼────────┐
 Workbench    PocketDesk      外部 Adapter
 笔记/清单    本机桌面能力      Codex/WorkBuddy/Cola
      └───────┼────────┘
       Receipt / Artifact Ledger
```

核心原则：

- 一个长期记忆事实源：Workbench。
- 一个跨入口任务编号和 attempt 体系：Workbench。
- 一个统一能力目录；能力和执行者分开建模。
- PocketDesk 的桌面 GUI 派单是一种能力，但成功边界只到 `submitted_untracked`，不能冒充正式 Agent 执行。
- WorkBuddy CLI 文本总结、受限文档写入、项目执行和桌面 GUI 投递是四种不同 adapter 状态，不能合并成一个“WorkBuddy 可用”。

## 2. 证据分级

本文所有“可用”结论按以下等级表达：

| 等级 | 含义 | 能否称为完成 |
| --- | --- | --- |
| E0 注册 | 名称出现在 registry 或工具列表 | 否 |
| E1 配置 | 找到应用、CLI、模型或目标目录 | 否 |
| E2 传输 | 命令/文字已经发出 | 只能称已投递 |
| E3 接收 | 对端返回 session/task ID 或 accepted 事件 | 不能称完成 |
| E4 执行 | 有 started/progress，且归属无歧义 | 只能称执行中 |
| E5 产物 | 返回可定位的文件、记录或 external ID | 待验收 |
| E6 验收 | 产物按任务验收条件通过 | 可以称完成 |

这套分级同时适用于 UI、CLI、API 和 MCP。不能因入口不同降低完成标准。

## 3. 现状核查

### 3.1 PocketDesk：桌面 Agent GUI 投递

真实流程：

```text
手机提交任务
→ PocketDesk TaskService 持久接收
→ AgentRunner 选择 dispatch_to_app
→ AgentAppProfile 按 bundle ID 识别目标
→ 激活目标应用
→ 新建任务页并核验输入框
→ 写入正文并点击发送
→ 保存 handoffTarget
```

已具备：

- 支持 WorkBuddy、Codex、Cola、ZCode、ChatGPT 的已配置应用身份。
- WorkBuddy 使用 `com.tencent.workbuddy.mac`，新任务页需要同时看到选中的新任务入口和 `WorkBuddy, 我帮你` 页面证据。
- 副作用前通过 `TaskStore.reserveAppDispatch` 持久占用，避免超时后自动重复提交。
- 提交后明确返回“不代表该 Agent 已接收或完成”。
- 控制权、焦点、输入框、正文和发送按钮均有阶段性核验。

实际能力等级：**E2 传输**。它不能持续获得 WorkBuddy 的 session ID、执行状态、产物、用量和完成回调。

证据：

- `Sources/AgentAppProfile.swift`
- `Sources/AgentAppDispatch.swift`
- `Sources/AgentTaskComposer.swift`
- `Sources/AgentRunner.swift`

置信度：高，来自当前代码。

### 3.2 PocketDesk：本机 Agent 核心

PocketDesk 当前不是纯渠道，它有完整的第二套 Agent 核心：

- 独立模型配置和 OpenAI-compatible tool loop。
- 独立 `TaskStore`、状态、事件、追问和历史。
- 独立系统提示词和工具目录。
- 本机桌面、浏览器、飞书 CLI 和 Agent GUI 派单工具。

优势是离线于 Workbench 也可运行；代价是会形成两套人格、记忆、工具选择和任务事实源。

证据：`Sources/AgentRunner.swift`、`Sources/TaskService.swift`、`Sources/TaskStore.swift`、`Sources/ModelConfig.swift`。

置信度：高。

### 3.3 Workbench：助手与业务工具

Workbench 小精灵已有较完整的业务工具层：

- 清单创建/更新/删除。
- 随手记搜索、读取、更新、删除；普通 `/api/notes` 可创建笔记。
- 项目、提醒、知识资料、Skill、日历、钉钉等工具。
- 任务登记、长期执行者偏好和 Agent 切换。
- 助手记忆条目的增删、停用、查看和提示词注入。

但工具名、业务服务和执行器 capability 目前属于不同体系。例如 `workbench_create_task` 是模型工具，`agent-registry.capabilities` 使用 `code/document/research`，executor adapter 又声明 `projectDirectory/progressEvents/resume`。三者没有共同的 canonical capability ID。

证据：

- `server/src/services/assistant-tools.ts`
- `server/src/services/assistant-memory.ts`
- `server/src/services/agent-registry.ts`
- `server/src/services/executor-contract.ts`

置信度：高。

### 3.4 Workbench：为什么正式项目任务只有 Codex

这是明确的策略和装配结果，不是偶发现象：

1. `executionPolicy()` 将 `allowedExecutors` 固定为 `['codex']`。
2. `prepareAgentDispatch()` 对指定且非 Codex 的项目任务直接报错：“正式执行通道尚未接通；没有改派给其他 Agent”。
3. 正式项目 runtime 的 adapter 固定构造 `codexCliAdapter`。
4. 项目任务还要求项目白名单、sandbox、执行/审核模型、attempt、成果和审核流程；其他 adapter 没有接入完整链路。

证据：`server/src/services/agent-dispatch.ts`、`server/src/services/agent-execution.ts`。

置信度：高。

### 3.5 Workbench：WorkBuddy 到底通了什么

WorkBuddy 当前有三种相互独立的证据：

| 路径 | 当前能力 | 证据等级 | 限制 |
| --- | --- | --- | --- |
| registry | 登记 `workbuddy`，标注 `document` | E0 | `enabled` 只允许登记 drafted 意图 |
| CLI 文档探针 | 指定验收目录，只允许读 `probe-input.json`、写 `acceptance.md` | E5/E6 探针 | 不代表生产项目执行 |
| 内容总结 | `textOnly=true`，禁用工具，只返回 Markdown | E5 | 只适合视频/文章总结 |
| 正式项目任务 | 尚未接通 | E0/E1 | 当前明确阻断 |

`workbuddy-cli-adapter` 当前的重要能力边界：

- `projectDirectory: true`
- `progressEvents: true`
- `cancellation: local-process`
- `resume: false`
- 文档模式工具只允许固定 Read/Write 文件。
- 文本模式不允许任何工具。
- CLI 认证来自独立配置目录，桌面 WorkBuddy 已登录不等于 CLI 已认证。

运行态快照（2026-09-18）：

- Workbench 执行配置启用、未暂停、允许 workspace writes，配置两个项目。
- WorkBuddy v2 文档探针为 `verified`，声明只证明验收目录中的文件与内容检查。
- 最新 WorkBuddy 项目任务 `20260918-003`、`20260916-006` 仍为 `drafted`，错误均为正式执行通道未接通。
- 数据库中的 WorkBuddy `completed` 包含 document/research/other 类型，来自内容窄通道，不能外推为项目执行可用。

证据：当前 `data/workbench.db`、`data/executor-probes/*/result.json` 和上述代码。

置信度：高；运行状态会随配置和后续任务变化。

### 3.6 Workbench 与 PocketDesk 当前没有正式 Bridge

Workbench 默认监听 `127.0.0.1:8787`；设 `HOST` 后可通过访问令牌对外提供 UI/API。现有 OpenAI-compatible 入口只允许 loopback，并专用于 OpenClaw/微信渠道。当前代码未找到 PocketDesk channel adapter、PocketDesk capability provider 或共享 task ID 协议。

PocketDesk 和 Workbench 目前只是能在同一台 Mac 上分别运行，不是已连接的两个模块。

证据：Workbench `server/src/index.ts`、`routes/openai-compat.ts`；两仓库全局检索。

置信度：高。

## 4. 根因分析

### 4.1 同一个词描述了四种不同能力

“让 WorkBuddy 做事”至少可能指：

1. 打开 WorkBuddy 桌面应用。
2. 往 WorkBuddy 输入框提交一段文字。
3. 通过 WorkBuddy CLI 获取一段文本或文件。
4. 让 WorkBuddy 在指定项目中持续执行、续接并返回可验收成果。

当前 PocketDesk 覆盖 1–2，Workbench 内容线覆盖部分 3，正式项目线只允许 Codex 完成 4。UI 或文案如果只显示“WorkBuddy 已启用”，用户无法知道是哪一种。

### 4.2 Agent、Capability、Transport 混在一起

当前 Workbench registry 将 `workbuddy` 同时当作执行者、transport 和 capability 容器；PocketDesk 的 `dispatch_to_app` 又把应用名作为工具参数。这会造成：

- 记住“默认 WorkBuddy”后，系统不知道是 GUI 还是 CLI。
- WorkBuddy 支持 document 不代表支持 `note.create`。
- CLI 工具目录存在不代表本次运行获得调用权限。
- GUI 投递成功无法推进正式任务状态机。

### 4.3 两套 Assistant Core

PocketDesk 和 Workbench 各自决定：

- 模型和系统提示词。
- 哪些工具可见。
- 什么时候创建任务。
- 怎样解释结果。
- 保存哪些上下文。

如果只共享“能力清单”，仍会出现不同入口对同一句话做出不同规划。统一能力层必须和统一任务/记忆/策略一起设计。

### 4.4 WorkBuddy adapter 没有进入正式 runtime

现有 WorkBuddy adapter 是为受限探针和内容总结设计的。要直接把 `allowedExecutors` 改为 `['codex','workbuddy']` 会留下这些问题：

- 正式 runtime 仍固定创建 Codex adapter。
- WorkBuddy `resume=false`，不能满足现有续接方案。
- cancellation 只证明本地进程停止，不证明远端停止。
- 当前文件权限只允许固定探针文件，不能执行一般项目任务。
- 独立审核链目前依赖 Codex 模型/adapter 组合。
- 没有 WorkBuddy 正式任务的 sandbox、allowed tools、artifact contract 和 late-event 验收。

因此不能用一行白名单修改把它“接通”。

## 5. 目标模块划分

### 5.1 Channel Gateway

职责：接收来自 Workbench UI、PocketDesk、微信、飞书的消息，统一生成 `InboundRequest`。

必须字段：

```typescript
type InboundRequest = {
  requestId: string;
  channel: 'workbench' | 'pocketdesk' | 'weixin' | 'feishu';
  principalId: string;
  conversationId: string;
  messageId: string;
  text: string;
  attachments: ContextRef[];
  deviceId?: string;
  controlSession?: string;
};
```

方案：新增 PocketDesk channel adapter，沿用 Workbench 单一 `chatWithAssistant`。手机仍连接 PocketDesk，PocketDesk helper 通过 loopback/scoped token 调用 Workbench，避免把 Workbench 主访问令牌下发到手机。

### 5.2 Identity & Trust

职责：把不同入口映射到一个用户主体，同时保留入口和设备边界。

目标模型：

```text
principal: owner
channel identity: pocketdesk:<paired-device>
conversation: pocketdesk:<task-thread>
device: mac:<device-id>
```

迁移规则：

- Workbench 当前 `workbench:owner` 作为首个 canonical principal。
- PocketDesk 配对 token 不能直接当跨产品 principal；由 Bridge 交换成范围受限的服务身份。
- 微信/飞书旧记忆不自动合并；管理页提供逐条迁移预览。

### 5.3 Task Core

职责：统一任务、attempt、step、artifact 和事件。

Workbench `agent_tasks` 成为跨端开放任务事实源。PocketDesk `TaskStore` 在迁移期承担：

- 本机提交 outbox。
- Workbench task ID 映射。
- 本机能力调用账本。
- 离线/断线恢复。

不能让两个 TaskStore 都自由推进同一个业务任务。跨端任务字段建议：

```text
taskId
originChannel
originRequestId
revision
objective
taskType
status
currentAttempt
capabilityPlan
memoryRefs
artifactRefs
```

### 5.4 Capability Registry

职责：描述业务能力，不负责执行。

示例：

```text
note.create
checklist.create
knowledge.search
desktop.open_app
desktop.window.arrange
agent.gui.submit
agent.text.generate
agent.project.execute
```

每条 descriptor 包含：版本、输入 schema、副作用、风险、幂等、撤销、所需证据、适用 scope。

### 5.5 Provider/Adapter Registry

职责：声明哪个 adapter 能实现哪些 capability，以及当前 readiness。

WorkBuddy 必须拆成三个 adapter：

| Adapter | Capability | 成功边界 |
| --- | --- | --- |
| `workbuddy-desktop-ui` | `agent.gui.submit` | UI 提交确认，`submitted_untracked` |
| `workbuddy-cli-text` | `agent.text.generate` | 完整 protocol result + Markdown artifact |
| `workbuddy-cli-project` | `agent.project.execute` | 任务/session、事件、项目产物与验收 |

当前状态：前两者分别由 PocketDesk 和 Workbench 内容线部分具备；第三者未完成。

### 5.6 Policy Engine

职责：判断谁能在什么范围调用哪个能力。

Policy 输入：principal、channel、device、project、capability、adapter、risk、memory suggestion、current readiness。

输出：

```text
allow / deny / needs_confirmation / needs_clarification
allowed adapter list
required evidence
budget and timeout
```

记忆只作为 adapter/destination 建议，不进入授权判断。例如“默认交给 WorkBuddy”不能让 `workbuddy-desktop-ui` 自动获得项目写权限。

### 5.7 Router & Planner

职责：把任务拆成 capability plan，再按 policy 和 readiness 选择 adapter。

选择顺序：

1. 本次明确指定的 capability/目标。
2. 项目规则。
3. 用户偏好。
4. 已验证、成本和风险可接受的默认 adapter。

无法满足指定 adapter 时明确失败或提供选项，不能静默换成 Codex。

### 5.8 Execution Runtime

职责：执行 capability invocation，维护 attempt 和状态。

统一状态：

```text
planned
→ accepted
→ submitted
→ acknowledged
→ running
→ artifact_ready
→ pending_review
→ succeeded

任一阶段 → needs_input / failed / uncertain / cancelled
```

Adapter 不能提供的状态必须跳过并保留较低等级。例如 GUI adapter 只能到 `submitted`，之后保持 `submitted_untracked`，不能用计时器推断 `running` 或 `succeeded`。

### 5.9 Receipt & Artifact Ledger

职责：保存 requestId、taskId、attempt、adapter、外部 ID、事件序号、产物和验证结果。

最小回执：

```typescript
type CapabilityReceipt = {
  invocationId: string;
  taskId: string;
  attempt: number;
  capabilityId: string;
  adapterId: string;
  state: string;
  externalRunId?: string;
  evidence: Evidence[];
  artifacts: ArtifactRef[];
  occurredAt: string;
};
```

迟到事件只能更新匹配的 attempt；不能覆盖新 attempt。无 external ID 的 GUI 投递按 invocationId 和不可重放占用处理。

### 5.10 Memory Service

职责：保存用户明确确认的偏好和规则，为 router 提供建议。

Workbench 现有 `assistant_memory_entries` 作为迁移来源，但需要增加：

- canonical principal
- scope type/id
- version
- source task/message
- capability ref
- adapter ref
- validity/expiry
- last used

PocketDesk 不再建立独立长期记忆表；本机只缓存已签名/带版本的只读 projection。

### 5.11 PocketDesk Local Capability Provider

职责：通过 loopback API 向 Workbench 提供本机能力：

```text
desktop.app.open
desktop.menu.invoke
desktop.window.list
desktop.window.arrange
desktop.input.clear
desktop.lock
browser.current.read
browser.url.open
agent.gui.submit
```

服务端必须复用 PocketDesk 现有控制租约、焦点核验和副作用占用。Workbench 只发结构化 invocation，不获得任意按键、任意 shell 或密码能力。

### 5.12 UI & Operations

Workbench 管理页需要分开显示：

- 业务能力：能做什么。
- Adapter：由谁、通过什么通道做。
- Readiness：注册、配置、可用、已验证、阻塞。
- 最近验证：时间、版本、样本类型。
- 权限范围：项目、设备、读写和确认策略。

用户看到 WorkBuddy 时至少应出现：

```text
桌面投递：可用 · 结果需到电脑查看
文本总结：可用/待认证
受限文档：探针通过 · 非生产项目通道
项目执行：未接通
续接：不支持
远端停止：未验证
```

## 6. WorkBuddy 正式接入方案

### 6.1 不采用的方案

- 只把 `allowedExecutors` 加上 `workbuddy`。
- 用 PocketDesk GUI 投递冒充 Workbench 正式执行。
- 看到 acceptance.md 就把所有项目任务标记完成。
- 把桌面登录状态当 CLI 认证。
- 在 WorkBuddy 不支持 resume 时伪造续接。

### 6.2 推荐分级接入

#### WB-A：把 PocketDesk GUI 投递纳入 Workbench 台账

目标：先让 Workbench 能调用已经可用的 `workbuddy-desktop-ui`，但保持保守状态。

流程：

```text
Workbench task
→ capability agent.gui.submit
→ PocketDesk Bridge
→ AgentAppDispatch.send(workbuddy)
→ receipt: submitted_untracked
```

价值：入口统一、任务 ID 统一、避免重复投递；不能解决自动完成追踪。

#### WB-B：产品化 WorkBuddy 文本能力

目标：将现有 `textOnly` 内容通道正式声明为 `agent.text.generate`。

要求：

- CLI 认证探针。
- 固定模型/auto 的真实含义说明。
- usage、超时、错误和结果大小边界。
- 无工具保证。
- 结果保存到 Workbench artifact ledger。

适用：摘要、改写、结构化提纲；不用于改项目文件。

#### WB-C：受限文档任务

目标：从固定探针文件扩展为定义清楚的文档任务 sandbox。

要求：

- 每个任务独立目录。
- 输入 manifest 和允许读取文件清单。
- 输出 manifest 和文件哈希。
- 工具 allowlist。
- 本地进程停止和远端结果未知分开。
- 一次 attempt 一个 session ID。

#### WB-D：项目执行

仅在 WorkBuddy CLI/协议能满足以下条件后开放：

- 绑定唯一真实项目目录或隔离 worktree。
- 明确 sandbox 和网络策略。
- 返回稳定 session/run ID。
- 支持恢复，或产品明确声明不支持续接并禁用相关动作。
- 进度和终态事件可归属到 task/attempt。
- 产物、Git diff 或文件哈希可验证。
- 超时、取消、进程重启和迟到事件有确定语义。
- 独立验收与执行模型分开。

如果 CLI 长期不支持这些能力，WorkBuddy 就保持 `agent.text.generate` / `document.generate`，不进入通用 `agent.project.execute`。

## 7. 跨端接口

### 7.1 Workbench 对 PocketDesk

```text
POST /api/bridge/pocketdesk/inbound
GET  /api/bridge/tasks/:id
GET  /api/bridge/tasks/:id/events?after=
GET  /api/bridge/capabilities
POST /api/bridge/capability-results
```

### 7.2 PocketDesk 本机 Provider

只监听 loopback，使用 Workbench 进程持有的 scoped token：

```text
GET  /api/v1/provider/capabilities
POST /api/v1/provider/invocations
GET  /api/v1/provider/invocations/:id
POST /api/v1/provider/invocations/:id/cancel
```

`cancel` 只取消尚未发出的本机步骤；GUI 提交成功后返回 `cannot_recall`，不能声称已停止对端。

### 7.3 幂等和重试

- Inbound：`principal + channel + requestId` 唯一。
- Invocation：`taskId + attempt + stepId` 唯一。
- 外部副作用前先持久占用。
- 超时先按 invocationId 查账。
- GUI 提交未知时禁止自动重放。

## 8. 数据迁移

### 8.1 记忆

1. 保留当前 `assistant_memory_entries`。
2. 新建 versioned memory 表或追加兼容列及事件表。
3. `workbench:owner` 映射 canonical owner。
4. 其他入口生成迁移候选，不自动合并。
5. 用户确认后写 alias/mapping，保留原来源。

### 8.2 任务

1. Workbench 新任务使用统一 task/attempt/step。
2. PocketDesk 新增 `remoteTaskId`、`syncState`、`invocationIds`。
3. 历史 PocketDesk 任务不批量导入，只保留本地历史。
4. 新跨端任务由 Workbench 权威推进，PocketDesk 只投影。

### 8.3 能力

旧工具映射示例：

| 旧工具 | Canonical capability | Adapter |
| --- | --- | --- |
| `workbench_create_task` | `checklist.create` | `workbench-checklist` |
| `/api/notes POST` | `note.create` | `workbench-note` |
| PocketDesk `open_app` | `desktop.app.open` | `pocketdesk-local` |
| PocketDesk `dispatch_to_app` | `agent.gui.submit` | `<agent>-desktop-ui` |
| Workbench content WorkBuddy | `agent.text.generate` | `workbuddy-cli-text` |
| Workbench Codex project runtime | `agent.project.execute` | `codex-cli-project` |

## 9. 实施阶段

### Phase 0：观测和协议

交付：

- 统一 capability/adapter/readiness/receipt 类型和 JSON Schema。
- 现有工具、adapter、API 的映射清单。
- WorkBuddy 四路径分项状态页。
- 只读 capability discovery，不改变执行行为。

验收：UI 和 API 不再用一个 `enabled` 表示所有层级；现有任务回归不变。

### Phase 1：PocketDesk 作为 Channel

交付：

- PocketDesk → Workbench inbound bridge。
- 身份映射和 scoped service token。
- Workbench 返回 task ID、状态和结果。
- PocketDesk 保留本机 Agent 模式作为可切换兼容路径。

验收：同一句话从手机和 Workbench 进入同一 assistant core，使用同一记忆和工具策略；断线不重复创建任务。

### Phase 2：PocketDesk 作为 Capability Provider

交付：

- 本机能力 discovery/invocation/receipt。
- 先迁移 `browser.current.read`、`desktop.app.open`、`agent.gui.submit`。
- 控制租约与 Workbench invocation 绑定。

验收：Workbench 能通过 PocketDesk 打开应用和提交 WorkBuddy GUI 任务；任务只标记 `submitted_untracked`。

### Phase 3：Workbench 业务能力统一

交付：

- `note.create/append`
- `checklist.create/add_item`
- artifact receipt 和 requestId 幂等
- PocketDesk 产物打开入口

验收：手机创建笔记/清单只落 Workbench 一份数据；回包丢失后查回同一 artifact。

### Phase 4：WorkBuddy 能力产品化

依次完成 WB-B、WB-C；WB-D 需要单独通过 entry gate。

验收：每个路径独立显示认证、工具范围、session、进度、用量、产物与限制。文本通道通过不能点亮项目执行。

### Phase 5：切换单一 Assistant Core

PocketDesk 默认使用 Workbench assistant。PocketDesk 本机模型仅保留明确的降级模式，并禁止写共享长期记忆或创建 Workbench 业务产物。

## 10. 测试与验收矩阵

### 协议

- 未知 capability/version 拒绝。
- schema 多字段、少字段和类型错误拒绝。
- adapter 未 verified 时不能自动执行高影响能力。
- capability 与 adapter 不匹配时拒绝。

### 身份与权限

- PocketDesk 配对设备只能访问 owner 授权的任务。
- scoped token 不能调用 Workbench 管理接口。
- 项目规则不能越权到其他项目。
- 记忆偏好不能扩大能力权限。

### 幂等

- 入站超时重试只创建一个任务。
- `note.create` 回包丢失只创建一条笔记。
- GUI 提交未知不自动重发。
- 迟到 attempt 事件不能覆盖新 attempt。

### WorkBuddy

- 桌面 UI 提交只到 `submitted_untracked`。
- CLI 未登录明确 blocked，不回退 Codex。
- textOnly 请求工具立即失败。
- 文档 adapter 越界读写立即失败。
- 不支持 resume 时续接按钮禁用。
- 本地进程中断显示远端结果是否未知。

### 运行恢复

- Workbench 重启后恢复队列，不重放已占用副作用。
- PocketDesk 重连后按 task ID/cursor 补事件。
- Workbench 不可用时本机能力可降级，业务写入进入明确 outbox。
- 两端版本不兼容时停止调用并提示升级，不猜字段。

## 11. 监控指标

- 各 capability 的请求数、成功率、uncertain 率。
- 各 adapter 的 registered/configured/available/verified 状态。
- accepted→running、running→artifact、artifact→approved 耗时。
- 重试、幂等命中和重复副作用阻止次数。
- WorkBuddy CLI 认证失败、协议缺口、越界工具和缺失 usage 次数。
- GUI 投递后用户人工接管/查看比例。
- 各入口命中同一记忆后的路由一致率。

## 12. 技术决策记录

### 已决定

1. Workbench 是统一 Assistant Core 和长期事实源。
2. PocketDesk 是渠道与本机 capability provider。
3. GUI 派单和正式执行是不同 capability。
4. WorkBuddy 按 transport 和能力拆成独立 adapter。
5. 不通过修改单一白名单直接开放 WorkBuddy 项目执行。
6. 记忆参与路由，不参与权限扩张。

### 待验证后决定

1. PocketDesk Bridge 使用 Workbench HTTP 还是新增 Unix domain socket；首版 HTTP loopback 更容易复用现有服务。
2. WorkBuddy CLI 是否能提供稳定持久 session/resume；当前代码证据为不支持。
3. WorkBuddy 正式项目任务需要的 sandbox 能否由 CLI 原生表达。
4. PocketDesk 离线 outbox 是否需要支持业务写入，或只支持本机能力。
5. Workbench task schema 是扩展 `agent_tasks`，还是新建通用 tasks/steps 表再兼容投影。

## 13. 首个实施包

首个实施包只做 Phase 0，不改生产执行路径：

1. 在 Workbench 新增统一类型与只读 registry projection。
2. 将现有 Codex、WorkBuddy text、WorkBuddy probe、Cola、PocketDesk GUI 能力映射到独立 adapter ID。
3. 新增 `/api/capabilities` 只读接口。
4. 新增验证脚本，锁定 readiness 不能由 registry enabled 推导。
5. 在 PocketDesk 新增同构 Codable 类型和只读解析测试。
6. 管理页先展示真实分项状态，暂不提供新的执行按钮。

Phase 0 通过后，再实现 PocketDesk channel bridge。这样能先把术语、状态和证据统一，再迁移真实请求，避免在两套现有任务系统之间制造不可恢复的双写。

## 14. 认知自评与剩余盲区

| 维度 | 评分 | 说明 |
| --- | --- | --- |
| 产品定位 | 5/5 | 两端目标、用户入口和统一方向明确 |
| 模块结构 | 5/5 | 已读取关键任务、记忆、adapter、HTTP 和 GUI 投递代码 |
| 实体关系 | 4/5 | 现有表和模型清楚，统一 schema 尚待实施时定稿 |
| 状态流转 | 4/5 | Codex/内容线/GUI 边界明确，WorkBuddy 原生远端状态能力待实测 |
| 权限模型 | 4/5 | 现有 token、控制租约和项目白名单明确，Bridge scoped token 尚未实现 |
| 真实交付 | 3/5 | 有历史探针和数据库证据，尚未做新的 WorkBuddy CLI/GUI 端到端验收 |

剩余最高优先级盲区：

- WorkBuddy 当前安装版本的 CLI 登录、session、resume、cancel 和 sandbox 真实能力。
- PocketDesk 与 Workbench 同机服务之间最小权限认证方式。
- Workbench 现有任务表扩展到通用 capability steps 时的迁移兼容性。
- 手机端在 Workbench 不可用时的明确产品降级范围。
