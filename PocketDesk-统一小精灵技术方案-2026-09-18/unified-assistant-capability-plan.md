<!--
[INPUT]: 统一架构 v0.2、Workbench 既有工具与适配器、PocketDesk 本机执行契约
[OUTPUT]: 单一能力命名、调用身份、回执和恢复规格；后续 JSON Schema 的唯一字段来源
[POS]: 统一架构的协议细化；不另建 runtime，不复制业务服务，不改变原授权
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
-->
# PocketDesk × Workbench 统一能力协议

版本：v0.3 · 2026-09-19。状态：设计规格；A 已交付首批 JSON Schema 与 TS 隔离验证，C 的 Swift 隔离实现已验收（111 项断言、共享 66 样例），两端均未接生产。A 当前 wire 仅含首批 14 个 ID，后续书签映射尚未加入。实施阶段唯一引用[主架构 G0–G4](pocketdesk-workbench-unified-assistant-architecture.md)。

## 1. 复用关系

Workbench assistant-tools 是模型可见工具；canonical capability 是跨端业务契约；adapter 是具体实现。首版把已有工具与服务包在统一边界内，不让旧工具和新 adapter 分别实现同一业务。

| 现有实现 | canonical capability | adapter / 边界 |
|---|---|---|
| Workbench notes 服务 | note.create / note.append | workbench-note；读回原业务记录 |
| Workbench tasks 清单服务 | checklist.create / checklist.add_item | workbench-checklist；不与 agent_tasks 混淆 |
| Workbench 项目 runtime | agent.project.execute | codex-cli-project；沿用项目/模型/入口/沙箱准入 |
| 内容总结路径 | agent.text.generate | codex-cli-text / workbuddy-cli-text / cola-cli-text；只表示文本能力 |
| WorkBuddy 文档探针 | document.generate | workbuddy-cli-document-probe；仅探针环境，不标生产可用 |
| PocketDesk read_page | browser.current.read | pocketdesk-local；绑定页面、权限与时效 |
| PocketDesk ChromeBookmarks 检索/打开 | browser.bookmarks.search / browser.bookmarks.open（规划，尚未进入当前 A schema） | pocketdesk-local；按 profile + ID 重读，歧义询问，G3 前两端补样例 |
| PocketDesk open_app | desktop.app.open | pocketdesk-local；原打开执行器 |
| PocketDesk dispatch_to_app | agent.gui.submit | 各应用独立 desktop-ui binding；投递不等于执行 |
| PocketDesk 窗口/菜单工具 | desktop.window.list/arrange、desktop.menu.invoke | 后续按原动作白名单接入 |
| PocketDesk lock_computer | desktop.lock | 独立受控能力；不包含解锁密码 |

旧文档的 desktop.open_app、browser.read_current 只在迁移映射中转为上述 canonical ID。新调用不继续传播别名。首批只开放 note.create，再逐项加入 note.append/checklist.create/checklist.add_item；不是所有登记能力都开放给手机。

已有飞书 CLI、日程、知识和 Skill 继续按原业务权限执行；同一业务可有多个实现，首版只选择既有经过准入的路径，不同时调用两套实现“择优”。

甩送复用普通提交，不另建业务能力；桌面反馈为只读投影，不另建入站主体。完整迁移清单见 [接入与切流门禁](integration-gates-and-rollout.md)。G1 保持单一契约，只实现 note.create 闭环所需路径，不实现所有预留对象的运行机制。

## 2. 类型分层

以下为字段语义设计；A 首批实现的 wire 校验以统一 JSON Schema 为权威，Swift/TS 共享 fixtures。本文的新增规划须经 schema 变更与双端验收后才成为已支持契约，其他文档不复制类型。

```typescript
type CapabilityDefinition = {
  id: string;
  version: string;
  inputSchema: object;
  outputSchema: object;
  effect: 'read' | 'write' | 'external_send' | 'desktop_control';
  requiredEvidence: string[];
};
type AdapterBinding = {
  id: string;
  capabilityId: string;
  capabilityVersion: string;
  providerId: string;
  providerVersion: string;
  deviceId?: string;
  transport: string;
  scopeRefs: string[];
  idempotency: 'transactional' | 'provider_key' | 'reserve_only' | 'none';
  cancellation: 'before_start' | 'local_process' | 'remote_confirmed' | 'none';
  resume: boolean;
  undo: boolean;
};
type ReadinessObservation = {
  bindingId: string;
  availability: 'unknown' | 'available' | 'blocked';
  checkedAt: string;
  expiresAt: string;
  environmentFingerprint: string;
  verification: 'unverified' | 'probe_passed' | 'scenario_passed';
  verifiedScope: string[];
  evidenceRefs: string[];
  reason?: string;
};
```

registered/configured 是登记与配置事实，不是永久晋级路径。probe_passed 不自动变为 scenario_passed；实际执行前仍检查配置、权限和资源占用。risk 与是否确认由真实参数和现有 Policy 决定，不能只看静态 boolean。

## 3. 请求与副作用身份

```typescript
type CapabilityInvocation = {
  protocolVersion: 1;
  requestId: string;
  invocationId: string;
  operationId: string;
  agentTaskId?: string;
  attempt?: number;
  bindingId: string;
  capabilityId: string;
  capabilityVersion: string;
  arguments: object;
  argumentHash: string;
  contextRefs: string[];
  expectedResourceRevision?: string;
  deadlineAt: string;
  authorizationRef: string;
};
```

- requestId：原入口请求；由 Bridge 保持稳定，重传不换 ID。
- operationId：一次逻辑业务动作；同动作的调用重试/查账保持不变。明确的新动作才生成新 ID。
- invocationId：具体调用身份；网络重传复用，显式新执行尝试可另建并引用原 operation。
- agentTaskId/attempt：确有 Agent 长任务才填写，必须同时出现且归属合法。不为短操作强建长任务。
- argumentHash：服务端对规范化参数与目标/上下文版本计算并核验；同 operation 不同内容冲突。
- authorizationRef：服务端已有授权或具体确认的引用，不接收“模型已确认”。授权绑定主体、能力、目标与参数摘要；在执行点重新检查。
- principal、scope、device 授权从可信凭证/服务端绑定派生。actor=user/assistant/system 只可作为审计来源，不作为授权证明。

首版无强制 stepId/RunStep/DAG。未知协议主版本、能力版本、额外字段或 schema 错误明确拒绝；可选字段的演进规则随 schema 固定，双方不得自行猜测兼容。

## 4. 统一回执

```typescript
type CapabilityReceipt = {
  protocolVersion: 1;
  requestId: string;
  invocationId: string;
  operationId: string;
  agentTaskId?: string;
  attempt?: number;
  bindingId: string;
  capabilityId: string;
  capabilityVersion: string;
  revision: number;
  state: 'accepted' | 'running' | 'succeeded' | 'failed'
    | 'uncertain' | 'submitted_untracked' | 'cancelled';
  externalRunId?: string;
  evidence: Array<{ kind: string; ref: string; verifiedAt: string }>;
  artifacts: Array<{ type: string; id: string; revision?: string; accessRef?: string }>;
  error?: { code: string; message: string; recovery: 'query' | 'retry_safe' | 'user_action' | 'none' };
  occurredAt: string;
};
```

agentTaskId/attempt 在请求、回执和事件中一致，不让回执自报归属。revision 单调递增，由提供者持久分配；证据引用必须能访问和核验，模型自由文本不是证据。

证据层级用于解释：登记/配置 → 发出 → 对端受理 → 执行中 → 产物 → 验收。不同能力依据完成契约选用，不机械要求每个动作经过所有阶段。

- note.create/append：真实记录 ID、版本与内容读回；只返回 URL 不够。
- checklist.*：真实清单/条目 ID、变更内容与版本。
- desktop.app.open：原打开执行器证据，不声称网页加载完毕。
- agent.gui.submit：有提交证据为 submitted_untracked；发送结果不明为 uncertain；绝不推断 externalRunId。
- agent.project.execute：原 runtime 执行/审核/成果按任务目标验证；进程 exit 0 不等于业务成功。

结果未知与身份未知分开：已取得真实 externalRunId 的可追踪 runtime 可在 uncertain 保留该 ID 查账；当前 agent.gui.submit 契约不支持外部运行追踪，任何状态不携带 externalRunId。

以上 state 是调用状态。任务可以仍待审核/待补充/部分交付；通知另有送达状态。cancelled 仅用于已证明不会继续的调用，cannot_recall 或停止未知保留事实。

## 5. 调用及恢复规则

| 场景 | 服务端行为 |
|---|---|
| 相同 operation、相同参数 | 返回原调用/产物，不重复执行 |
| 相同 operation、不同参数 | 冲突，不覆盖旧动作 |
| 自有数据库写入 | 业务结果、去重记录、必要回执同事务提交 |
| 外部支持幂等 | 复用对端幂等键并查询结果 |
| GUI/不支持幂等的外部副作用 | 先持久占用；崩溃窗口保留 uncertain，禁止盲重放 |
| 提交超时 | 查 request/operation/invocation；不换本机 Agent 接管 |
| 旧 attempt 回执 | 记旧轮审计，不改新轮主状态 |
| 同轮乱序或重复事件 | 按 eventId/seq/revision 去重与合法状态转换处理 |
| 游标失效 | 刷新持久快照和新游标，不重新执行 |
| 通知失败 | 只恢复通知，不重跑能力 |
| deadline 到期 | 不开始新副作用；对在途请求查证，不能直接判未执行 |

存储保留期须覆盖允许重试/离线恢复窗口；旧幂等键到期后返回明确 expired，需要重新确认新操作，不能默默当新请求执行。

## 6. Bridge 接口职责（待 G0 冻结）

Workbench 面向 PocketDesk：
- `POST /api/bridge/pocketdesk/inbound`：持久接收并返回 request receipt；已接收不等于完成。
- `GET /api/bridge/requests/:requestId`：按可信主体查账，返回关联对话、业务产物或 Agent task。
- `GET /api/bridge/tasks/:id`、`GET /api/bridge/tasks/:id/events?after=`：已准入任务的投影与恢复。
- `GET /api/bridge/capabilities`：仅返回当前主体/入口允许发现的 binding。
- `POST /api/bridge/capability-results`：核验提供者与 invocation 归属后收回执。
- `GET /api/bridge/artifacts/:id`：鉴权成果内容/下载代理，不能任意读路径或转发任意 URL。

PocketDesk Provider（仅同机拓扑下 loopback 暴露）：
- `GET /api/v1/provider/capabilities`
- `POST /api/v1/provider/invocations`
- `GET /api/v1/provider/invocations/:id`
- `POST /api/v1/provider/invocations/:id/cancel`

后续 supplement/revise/switch/cancel 接口按既有来源绑定逐项开放；G1 不能因 taskId 已返回就宣称这些动作全支持。跨机情况下保持同一业务语义，传输装配经主架构部署门禁另定。

## 7. 实现落点与测试

Workbench 先做 registry projection、协议校验和 Bridge 入口，内部调用旧服务；JSON Schema 放单一协议目录。Swift Codable 使用同组 fixtures。Provider 复用 TaskStore 持久占用与原执行器，不再做 GUI 操作实现。

G0 必测：合法/缺字段/多字段/版本不匹配/别名/回执归属；旧登记 enabled 不得点亮生产执行。
G1/G2 必测：并发同请求、回包丢失、事务中断、重启、追加重复、资源版本冲突、鉴权成果访问。
G3/G4 必测：控制权丢失、焦点变化、占用后崩溃、旧轮回执、取消未知、远端超时不触发本机重放。

已有业务与 Agent 测试保持为基线；新 Bridge 测试证明跨端闭环，不能只验证 JSON 可以解析。
