# PocketDesk × Workbench 统一助手能力层实施规划

版本：v0.1 · 2026-09-18

## 结论

PocketDesk 与 Workbench 不需要各自再做一套工具系统。应建立一套统一的业务能力协议，由 Workbench 作为跨设备能力注册与长期任务/产物事实源，PocketDesk 作为手机入口和本机执行适配器。

第一阶段只统一协议、能力声明和结果回执，不迁移所有旧工具；第二阶段再把笔记、清单、任务和知识库能力接到统一协议。

## 1. 当前代码盘点

### Workbench 已有能力

- `server/src/services/assistant-memory.ts` 已有 SQLite 助手记忆服务：显式命令、面板手动写入、查看、停用、删除、项目绑定和提示词预算。
- 当前记忆身份由入口和用户/会话组成，非 Workbench 入口按来源用户隔离，**目前不会跨渠道合并**。
- `server/src/services/assistant-tools.ts` 已有记忆相关工具；`routes/assistant.ts` 已提供读取、更新、条目新增、停用和删除接口。
- `server/src/services/agent-registry.ts`、`executor-readiness.ts` 和各类 adapter 已有执行者登记、探针、能力声明和验证回执，但能力信息仍分散在 registry、adapter、readiness 和工具分组中。
- Workbench 的随手记和清单已经共用 `DocumentDetail`，业务差异由 `NoteDocument` / `TaskDocument` 映射；这是 `note.*` 与 `checklist.*` 统一产物接口的现成基础。
- Workbench 有 Codex、WorkBuddy、Cola 和内容执行适配器，但“已注册、可连接、可执行、已有验证产物”目前仍是不同状态。

### PocketDesk 已有能力

- `TaskService` / `TaskStore` 是小精灵任务事实源，提供幂等提交、任务状态、事件、追问、放弃和来源。
- `AgentRunner` 使用模型工具调用，但本机工具由 PocketDesk 执行；模型本身不直接操作电脑。
- `TaskService.executors()` 已返回部分执行器能力，但仍是 PocketDesk 专用摘要，不是共享能力注册表。
- `AgentAppDispatch`、`FeishuMessaging` 和桌面控制模块已有副作用占用、授权和执行证据，可作为本机适配器的安全基础。

### 不能直接假定的部分

- Workbench 当前是否已经有稳定的跨设备身份和外部客户端认证协议，仍需按实际服务配置核对。
- PocketDesk 与 Workbench 是否已经有可用的双向任务事件通道，不能用两个现有 HTTP 接口名称推断。
- Workbench 当前的能力声明不等于每个能力都能被手机调用；必须逐项验证 transport、权限、执行和结果交付。

## 2. 统一后的领域模型

### 2.1 Capability：能做什么

能力是稳定的业务动作，不按应用名称命名：

```text
note.create
note.append
note.update
checklist.create
checklist.add_item
checklist.complete_item
task.create
task.update
calendar.create
knowledge.attach
browser.read_current
desktop.open_app
desktop.input_text
```

实现方式由 adapter 决定：

```text
note.create
├── workbench-notes
├── feishu-doc
└── apple-notes
```

### 2.2 CapabilityDescriptor：能力声明

统一注册表的最小字段：

```typescript
type CapabilityDescriptor = {
  id: string;
  version: string;
  owner: 'workbench' | 'pocketdesk' | 'adapter';
  inputSchema: object;
  sideEffect: 'read' | 'write' | 'external_send' | 'desktop_control';
  risk: 'low' | 'medium' | 'high';
  requiresConfirmation: boolean;
  supportsIdempotency: boolean;
  supportsUndo: boolean;
  evidence: string[];
  scopes: string[];
  readiness: 'registered' | 'configured' | 'available' | 'verified' | 'blocked';
  checkedAt?: string;
};
```

`readiness` 只能由探针、授权和实际回执推进，不能由 `enabled=true` 推断。

### 2.3 CapabilityInvocation：一次调用

```typescript
type CapabilityInvocation = {
  requestId: string;
  taskId: string;
  attempt: number;
  capability: string;
  capabilityVersion: string;
  adapter: string;
  actor: 'user' | 'assistant' | 'system';
  arguments: object;
  expectedRevision?: number;
  confirmation?: { required: boolean; confirmedAt?: string };
};
```

调用必须经过权限和幂等检查。模型只产生结构化调用意图，不能产生任意 shell 字符串。

### 2.4 CapabilityReceipt：结果证据

```typescript
type CapabilityReceipt = {
  requestId: string;
  taskId: string;
  attempt: number;
  status: 'accepted' | 'running' | 'succeeded' | 'failed' | 'uncertain';
  artifact?: {
    type: string;
    id: string;
    url?: string;
    revision?: string;
  };
  evidence: {
    kind: 'server_record' | 'external_id' | 'file_hash' | 'ui_delivery' | 'observed_state';
    value: string;
  }[];
  error?: { code: string; message: string };
};
```

“模型回答完成”不是能力成功证据。创建笔记必须返回笔记 ID 或可鉴权 URL；创建清单必须返回清单 ID 和条目结果；桌面 GUI 投递无法核实时只能是 `uncertain` 或 `delivered_to_target`，不能冒充业务完成。

## 3. 能力归属

| 能力 | 事实源 | 首选执行端 | PocketDesk 角色 |
| --- | --- | --- | --- |
| `note.create/update/append` | Workbench 文档服务或明确指定的外部文档 | Workbench API | 录入、派发、显示回执 |
| `checklist.create/add/complete` | Workbench tasks | Workbench API | 语音输入、快速创建、查状态 |
| `task.create/update` | Workbench agent/task 服务 | Workbench API | 发起、补充、查看 |
| `knowledge.attach` | Workbench 知识资料服务 | Workbench API | 提交来源或资料引用 |
| `calendar.create` | 用户选定的日历服务 | 对应 adapter | 收集参数、确认、展示事件证据 |
| `browser.read_current` | 当前受控浏览器/设备 | PocketDesk | 读取当前页并返回绑定引用 |
| `desktop.open_app/input_text` | Mac 本机 | PocketDesk | 控制权仲裁、执行和回执 |
| `git.*` / 项目执行 | Workbench 执行服务 | Codex/WorkBuddy adapter | 派发与接收状态，不复制执行目录 |

PocketDesk 可以在 Workbench 不可用时继续执行低风险本机能力，但不得在本地创建一套长期笔记/清单事实源。离线任务应进入 `queued_for_sync` 或明确标记为本地草稿。

## 4. 统一流程

```text
入口输入
  ↓
任务规范化（intent + target + contextRefs）
  ↓
能力匹配（scope + readiness + policy）
  ↓
记忆路由（只选择默认执行器，不扩大权限）
  ↓
权限/确认/幂等检查
  ↓
CapabilityInvocation
  ↓
Adapter 执行
  ↓
CapabilityReceipt + Artifact
  ↓
任务状态与通知
```

记忆和能力的关系必须保持单向：记忆可以建议 `executor/adapter/destination`，能力注册表决定它是否存在和当前是否可用；记忆不能凭空创造能力或扩大授权。

## 5. 分阶段实施

### M0：统一协议，不改变现有行为

目标：形成可测试的共享词汇和映射。

1. Workbench 新增 `CapabilityDescriptor`、`CapabilityInvocation`、`CapabilityReceipt` 的 TypeScript 类型和 JSON Schema。
2. 为现有 Workbench adapter 补齐 capability ID、版本、readiness 和 evidence 声明。
3. PocketDesk 增加同构的 Swift Codable 类型，但先只用于读取/记录，不切换现有 AgentRunner 工具调用。
4. 建立映射表：旧工具名 → canonical capability → adapter。
5. 增加注册、配置、可用、验证四层测试。

验收：同一能力在两端拥有同一个 ID；未验证的 adapter 不会被标记为可自动执行；现有任务行为不变。

### M1：先打通 Workbench 笔记和清单

1. Workbench 将现有 Note/Task 服务包装为 `note.create` 和 `checklist.create`。
2. 返回稳定 `artifact.id`、`artifact.type`、`revision` 和内部 URL。
3. PocketDesk 新增只读能力发现接口，手机提交时携带 `capabilityId`、`taskId`、`requestId`。
4. Workbench 负责落库，PocketDesk 只展示任务状态和产物链接。
5. 创建动作使用 requestId 幂等；回包丢失时先查账，不盲目重建笔记或清单。

验收：同一请求重试只产生一条笔记/一个清单；服务端返回的 ID 可在工作台打开；PocketDesk 断线重连能找回同一任务和产物。

### M2：统一记忆和能力路由

1. 将 Workbench 当前按入口隔离的 memory identity 扩展为稳定的共享 profile identity。
2. 保留旧入口隔离作为兼容模式，迁移前不自动合并相同文本记忆。
3. 记忆条目增加 scope、source、version、validity、memory type 和 `capabilityRef`。
4. PocketDesk 的“记住这条”提交 Workbench memory preview/save，不在本地另写长期规则。
5. 任务快照保存命中的 memory ID/version 和 capability ID/version。

验收：PocketDesk 和 Workbench 新任务能命中同一条共享规则；删除或停用后两端的新任务都不再命中；旧任务仍可解释历史版本。

### M3：扩展到 CLI、知识库和外部服务

1. 将 Codex、WorkBuddy、Cola、内容执行器包装成 capability adapter，而不是暴露成无约束 executor 名称。
2. CLI 只提供结构化白名单能力，例如 `git.status`、`git.diff`、`workbench.build`，不提供默认的 `shell.execute`。
3. 外部消息、日历、删除、发布等动作带独立 policy 和确认字段。
4. 统一 usage、attempt、receipt、artifact 和 late-event 处理。

验收：能力注册、传输、执行和验证状态能分别展示；远端未确认的任务不会被报告为完成；迟到回执不会覆盖新 attempt。

## 6. 代码落点

### Workbench

建议新增或演进：

```text
server/src/services/capability-registry.ts
server/src/services/capability-policy.ts
server/src/services/capability-invocation.ts
server/src/services/capability-receipt.ts
server/src/services/capability-adapters/workbench-documents.ts
server/src/services/capability-adapters/pocketdesk.ts
server/src/schema.sql                  # registry/receipts/outbox，按迁移规范追加
server/src/routes/capabilities.ts
```

已有 `agent-registry.ts`、`executor-readiness.ts`、`agent-execution.ts` 和 adapter 不立即删除；先由新 registry 读取或包装，避免同时重写执行链。

### PocketDesk

建议新增：

```text
Sources/CapabilityModels.swift
Sources/CapabilityClient.swift
Sources/CapabilityReceiptStore.swift
Sources/WorkbenchBridge.swift
```

`TaskService` 继续是本机任务事实源；跨端任务增加 `origin`、`capabilityRef`、`artifactRef` 和 `syncState`，不把 Workbench 的数据库文件复制到 PocketDesk。

现有 `AgentRunner` 先保留旧工具路径，新增 adapter 仅承接 `note.*` / `checklist.*` 的远端调用，待 M1 通过后再迁移其他工具。

## 7. 第一批实现的边界

首批只实现四个能力：

```text
note.create
note.append
checklist.create
checklist.add_item
```

暂缓：发送消息、删除、发布、任意 CLI、跨服务批量操作、自动选择高权限执行器。这四个能力足以验证能力发现、记忆路由、幂等、产物回执和跨端任务续接，不会一次性把权限面铺开。

## 8. 必须保留的安全边界

- `capabilityId` 不是授权；每次调用仍要检查主体、项目、设备和动作权限。
- `executor` 不是 capability；执行器只是实现能力的一种 adapter。
- `enabled` 不是 verified；必须有实际探针或结果证据。
- CLI 参数结构化、路径白名单化，禁止模型默认生成任意 shell。
- PocketDesk 的本机控制权和 Workbench 的项目写权限分开管理。
- 任务取消、远端停止和产物删除分别建模，不能共用一个“停止”状态。
- 旧入口的记忆在没有用户确认前不自动跨渠道合并。

## 9. 本轮实现建议

本轮先做 M0 的协议和映射，不直接改动现有执行行为。具体顺序：

1. 在 Workbench 先落 JSON Schema 和 capability registry 只读投影。
2. 为 `note.create`、`checklist.create` 做两个真实 adapter 声明和验证回执。
3. 在 PocketDesk 实现 Codable 类型、只读能力发现和 receipt 记录。
4. 用一个端到端测试验证“手机发起 → Workbench 创建 → 回包丢失查账 → PocketDesk 找回 artifact”。
5. M0 通过后再迁移记忆身份和写入入口。

这样可以先验证协议和事实源，再决定是否把跨端 Bridge 做成 HTTP、事件流或 Workbench 的现有同步通道，不提前假定一个尚未核实的 transport。

