<!--
[INPUT]: 2026-09-22 安装前基线、机主本机部署授权、备份/构建/安装与运行检查
[OUTPUT]: 本机独立验收的安装/HTTP/重启查账证据及后续门禁；保留历史观测，不含密钥或业务正文
[POS]: integration-gates-and-rollout 的部署事实清单；源码进度不替代此处运行证据
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
-->
# 统一小精灵部署清单

## 最新增量：当前 Mac 独立验收部署

**09:24 更新：权限阻塞已解除，本机连通验收通过。** 机主明确回复允许后，原 Workbench 服务直接恢复，健康接口与首页 200。通过已安装 PocketDesk 的原配对鉴权进行 G1 创建、同号重投、查账和成果逐字读回，均成功；无配对请求 401。独立库保留一篇“本机部署验收（可删除）”，notes 和 pocketdesk_operations 各仅一条。G2 任务/记忆查询均 200，目前为验收库空集合。

确认验收库没有 agent_tasks/tasks 后，对原 LaunchAgent 做一次受控重启；PID 更新为 58098，健康页与原编号只读查账仍成功，成果 ID 159996738846193 不变，未重新派发。手机真机操作、真实模型派发与正式数据迁移仍待验收；下表 08:50 为权限放行前的安装过程，不再代表当前阻塞。

2026-09-22 08:50（Asia/Shanghai）。机主已授权先部署这台电脑，后续由机主决定 GitHub 同步及另一台电脑更新。以下是安装事实，不代表两端闭环已验收。

| 项目 | 证据与边界 |
|---|---|
| 安装与进程 | 新构建安装到 `/Users/yz/Applications/PocketDesk.app`；PID 57071，46387 正常响应；原签名标识保留，codesign 严格验证通过 |
| 静态资源 | agent-client.js、workbench-notes.js、workbench-overview.js 的安装包与当前源码 SHA256 全部相同 |
| 原入口保护 | identity 携原配对 Bearer 返回 200，不携凭据返回 401；保留模型/配对/历史，未提交新的 Agent 模型任务 |
| 备份 | `/Users/yz/Library/Application Support/WorkbenchLocal/backup-dZECKJ` 包含原 App、VoiceDeck 完整数据、Workbench 数据与 .env；私有目录，不进入 Git |
| Workbench 数据 | 独立 `/Users/yz/Library/Application Support/WorkbenchLocal/data`；未导入旧 yao.db/workbench.db，未启用云同步或外部连接；旧库数据选择已询问，未获选择前使用已告知的独立库 |
| 配置 | 私有 deployment.json、VoiceDeck/workbench-bridge.json 与 LaunchAgent 均已生成；两端 JSON 权限 0600；随机用途凭据、同机设备绑定，只读授权对应现有共享配对主体，不冒充每台手机独立权限 |
| 常驻服务 | com.workbench.local-preview 已 bootstrap，PID 57070、首次启动未退出；绑定当前 checkout 和 Node 路径，不加载仓库 .env |
| 当前阻塞 | node 在读取 Documents 中启动入口时等待系统权限；tccd 明确记录 DocumentsFolder AUTHREQ_PROMPTING，8787 尚未监听；已请机主允许，不绕过 TCC、不创建第二个服务 |
| 待验证 | 机主允许后检查健康页，再通过已安装 PocketDesk 测试 G1 创建/重投/查账/读回及 G2 只读；手机真机刷新与操作仍需验收 |
| 不在本轮范围 | 未推送 GitHub、未更新另一台电脑、未启用 Jev、未修复供应商模型连接、未开放 G2 写入/G3 Provider/G4 切流 |

Workbench 新库没有旧模型设置；PocketDesk 原模型保持不变。启动/停用/换电脑步骤见 [本机验收部署](../../workbench/scripts/local-preview.md)。若任务快照已发生新版写入，不能将旧二进制直接用于新版数据目录，回退须先核对新请求台账。

## 安装前历史基线（下列字段不是当前状态）

观测时间：2026-09-22 02:15（Asia/Shanghai）。这是一次观测，不保证之后进程/文件未变化。

| 字段 | 当前证据与边界 |
|---|---|
| observedAt | 2026-09-21 18:15 UTC |
| collector | 当前 Codex 任务；只读检查，未安装、重启或修改运行配置 |
| reviewer | 待机主确认正式环境；未获得拓扑结论 |
| WorkbenchHost | unknown；本机 `lsof -nP -iTCP:8787 -sTCP:LISTEN` 无监听结果，不证明其他主机或端口无服务 |
| runtimeRevision | Workbench unknown；PocketDesk 运行二进制对应 commit unknown，不用 checkout HEAD 代替 |
| checkoutDirty | 两仓均有本轮未提交修改及既有用户修改；Workbench main 基准 554067e6e149；PocketDesk codex/android-ux-unlock 基准 36c9a3fd5a74 |
| PocketDeskHost | 当前 Mac 可观察到进程 PID 38750，映像路径 `/Users/yz/Applications/PocketDesk.app/Contents/MacOS/VoiceDeck`；是否为用户指定正式环境仍待确认 |
| installedBundle | 磁盘 Info.plist 为 0.3.1 / build 4；进程启动时间 Sep 22 00:13:54。本字段不是已加载代码的 commit 证明 |
| dataRoot / artifactRoot | 正式 Workbench 主库、附件根和 PocketDesk 任务备份均 unknown；未复制/迁移真实数据 |
| serviceAddress | PID 38750 监听 `*:46387` 与 `*:46487`；Cola PID 61694 监听 `127.0.0.1:19532`。监听不等于模型或业务可用 |
| transport | 当前新 Bridge 源码仅实现显式同机 loopback；同机/跨机正式选择 unknown；未启用新传输 |
| credentialReference | 源码配置引用 POCKETDESK_BRIDGE_TOKEN、POCKETDESK_DEVICE_ID、POCKETDESK_OWNER_READ_PRINCIPALS；正式用途凭据/撤销与绑定配置未核实，不记录值 |
| deviceBinding | unknown；现有手机配对 token 为共享主体，不是每台手机独立授权 |
| startup | PocketDesk 可见运行进程；正式启动/保活配置与 Workbench 启动方式 unknown |
| backupRestoreEvidence | 缺失；PocketDesk tasks.json storageVersion=2 首写迁移前须备份整个 tasks 目录，旧程序不能直接回写新数据 |
| sleepDisconnectBehavior | 隔离请求恢复与去重测试通过；当前安装包、正式模型、真实手机的睡眠/重启/断网验收缺失 |
| decisionStatus | 未通过真实接入/发布门禁；不安装、不启用 Bridge，不默认切流，不自动重派未知任务 |
| unknowns | 正式 Workbench 主机/版本/唯一数据、备份恢复、部署拓扑、用途凭据引用、机主授权的共享范围与真实入口验收 |

## 安装包与本轮源码对照

读取磁盘包 `Contents/Resources/Web/` 与当前 PocketDesk checkout；未发业务请求。

| 文件 | 安装包 SHA256 | 当前源码 SHA256 |
|---|---|---|
| agent-client.js | e46c5ad3d5069a12cd0f88772acba3fbd17f8ef5922b22bdb29d9d27d9b1dcb9 | 4e73df42514c6cc39425f7bc0744b47c2101ae19073afb934d51e6b43adba862 |
| workbench-notes.js | 文件不存在 | 0bd40a14d98d49eacb3f4a4e3855b4ba4c9f79ba9161efb521e4fae5fea7e4d3 |
| workbench-overview.js | 文件不存在 | 8fa60f4f0094056700b94f3dcd7a635e2c2141e35ad46681ab6191ea50e9944c |

结论：这个磁盘安装包没有本轮两个跨端入口，原任务客户端也不是本轮修复版。源码测试通过不能证明用户当前入口已经改善。

## 模型侧边界

重新读取本轮真实探针文件：WorkBuddy 为 verified（仅受限文档）；Codex 与 Cola 均为 needs_reconciliation，未重复派发。当前任务进程环境没有 TYPESAFE_API_KEY，不代表所有主机都未配置。模型阻塞及文件证据见 [Workbench 交付记录](../../workbench/docs/assistant-reliability-delivery-2026-09-22.md)。

## 解除门禁所需信息

1. 机主确认 Workbench 实际主机和已有访问方式，以及当前 Mac 是否为正式 PocketDesk 主机；不要提供密钥正文。
2. 在确认主机后核实运行版本、唯一主库/附件和备份恢复，再选定同机或跨机传输；跨机需单独实施，不把 loopback URL 改成远程地址就发布。
3. 在受保护配置中修复 Codex/Cola 模型连接，并提供 Jev 可用的凭据引用和评测样本。外部结果未知的旧探针先核对，不重派。
4. 逐项验收真实手机原入口、同任务成果读回、断线查账和原手动通道后再切流。G3 Provider、G4 旧循环退役仍需完成各自门禁。

未把 WorkBuddy 通用项目适配、跨端任务写入、旧 Agent 自动重启恢复等未完成项改标为完成；完整差距以交付记录为准。
