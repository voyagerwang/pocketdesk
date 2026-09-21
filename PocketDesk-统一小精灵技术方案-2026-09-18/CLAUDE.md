# PocketDesk-统一小精灵技术方案-2026-09-18/
> L2 | 父级: ../CLAUDE.md

职责：承接 Workbench 既有小精灵规划，定义 PocketDesk 的增量接入，不另立产品总方案或替换既有技术底座。事实先读基线，实施再读主架构和专项；历史研究不覆盖实施契约。

成员清单
assistant-product-and-routing.md: 产品与路由补充，说明统一助手/双入口、工具发现、GUI 观察闭环与共享记忆；新增场景为规划，未改冻结 wire。
current-state-and-integration-baseline.md: 事实入口，两端当前/目标调用图、S01–S22 校准、源码与七项隔离测试证据、部署拓扑未知项。
pocketdesk-workbench-unified-assistant-architecture.md: 主架构 v0.3，职责权威、部署门禁、调用方向、身份、恢复与 G0–G4 迁移；继承 Workbench 技术裁决。
unified-assistant-capability-plan.md: 协议专项 v0.3，canonical ID、能力/适配/观测分层、唯一调用回执字段及幂等恢复规则；A 首批 schema 已交付，书签仍为后续规划。
sprite-memory-plan.md: 记忆专项 v0.3，复用普通记忆和执行偏好两来源，统一管理与确定性路由，规定迁移、撤销和离线边界。
integration-gates-and-rollout.md: v0.3 实施门禁，部署核实责任与证据、书签/甩送/桌面展示覆盖、无退化切流、旧 loop 退役及首期协议范围。
memory-research-2026-09.md: 历史调研与未重新核验的外部参考，不作为当前能力和实施裁决依据。

维护规则：进度变化更新事实基线并附源码/测试/部署证据；架构变化回写主架构，协议语义在能力专项维护，已落地 wire 字段以单一 schema 与共享 fixtures 验收。主架构仅负责两端接入，Workbench 九环节和 S01–S22 原产品路线继续有效。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
