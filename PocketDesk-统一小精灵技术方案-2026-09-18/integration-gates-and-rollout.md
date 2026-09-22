<!--
[INPUT]: 主架构 v0.2、PocketDesk 书签/甩送/反馈/派单代码、方案评审、A/B 第二轮验收及 2026-09-22 部署事实清单
[OUTPUT]: 部署核实行动、现有路径覆盖、逐能力切流与旧模型循环退役门禁
[POS]: 主架构 v0.3 的实施门禁补充；不定义第二套协议，不把计划当部署事实
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
-->
# 接入与切流门禁

版本：v0.3 · 2026-09-19。本文落实动作和验收责任；不改变 Fastify/SQLite、Swift、现有 runtime 和任务权威设计。

2026-09-22 事实回填：[deployment-manifest.md](deployment-manifest.md) 已记录本机运行 PocketDesk 的旧包证据与未确认的 Workbench 拓扑；部署门禁尚未通过。G1/G2 增量源码和隔离验证已有实施，但未进行真实写入切换；本文件下方 G3/G4 要求不变。

## 1. 部署核实：先做行动，后做连接

责任分工：实施负责人通过已授权的主机访问入口收集事实，主管复核后记录部署决策；主机访问不可得时请用户提供运行主机/现有访问方式，不索取密钥正文、不扩大权限。该项与 G0 纯协议/只读投影可并行，是 G1 真实写入和 G3 传输装配的前置门禁。

| 核实项 | 只读核实手段 | 交付与通过条件 |
|---|---|---|
| 进程实际所在主机 | 服务监听 PID、启动命令、服务管理配置、现有转发规则 | 区分 Mac 本机 Node 与转发进程；不能仅凭健康 URL 判同机 |
| 运行版本 | 运行目录、发布版本标识、对应 commit；记录 dirty 状态 | 源码 checkout 与实际运行包分别标注，不能用仓库 HEAD 冒充部署版本 |
| 数据和附件 | 已授权配置中的路径、主库位置与备份记录 | 明确唯一权威与恢复负责人；不读取业务正文，不复制主库 |
| 调用方向与设备 | Workbench 主机、PocketDesk Mac、控制设备绑定 | 每个 binding 指向明确设备；远端 loopback 不代替 Mac 地址 |
| 身份和网络 | 实际监听地址、传输加密/证书验证、用途凭证及撤销配置 | 不在清单写 token；转发工具存在不等于应用授权已完成 |

建议产物为 deployment-manifest.md，字段：observedAt、collector、reviewer、WorkbenchHost、runtimeRevision、checkoutDirty、PocketDeskHost、dataRoot、artifactRoot、serviceAddress、transport、credentialReference、deviceBinding、startup、backupRestoreEvidence、sleepDisconnectBehavior、unknowns、decisionStatus。未知项保留 unknown，不编造完成状态。

同机分支：Provider 专用 loopback 监听；用途独立凭证；验证局域网不能直接访问及凭证撤销生效。跨机分支：先写独立部署决策，采用一种主动出站领取/回传机制；跨主机应用流量使用具备证书验证的 TLS（HTTPS/WSS）或经明确审阅的等效加密认证通道，禁止为了连通而关闭证书校验。仍需应用级主体、设备绑定与撤销。

跨机实施顺序：① 明确传输/身份/路由；② 只读请求与回执关联；③ 重连查账、重复投递去重、设备离线与凭证撤销测试；④ G1/G3 分别准入写操作。通过标准：回包丢失不重复副作用，错误设备不能领取，撤销后不得开始新副作用，睡眠恢复不抢控制权，手机可鉴权访问成果。拓扑核实后再估算分支工作量，不给未经验证的固定工期。

## 2. 当前 PocketDesk 路径覆盖

本机 HEAD 8288831 只是已提交基准；验收同时记录 git status/diff 和被测文件摘要，不把未提交演进遗漏。下表描述源码现状，不代表真机与跨端全部通过。

| 当前路径 | 层次与复用 | 接入要求与回归 |
|---|---|---|
| ChromeBookmarks + search_bookmarks/open_bookmark | 本机业务能力；检索与打开分开 | 规划 browser.bookmarks.search/open，G3 前扩展唯一 schema 与双端 fixtures；重新核对书签 ID、配置文件、URL、歧义选择；打开成功不声称页面加载完毕 |
| AgentRunner.open_target 自然名称解析 | 原本机解析规则 | 应用优先、唯一书签直开、多候选询问；接入后保持规则，不建另一套歧义解析 |
| motion-send / motion-recognizer | 手机输入手势，复用 pocketdeskComposeSend | 不新增业务 capability；普通点击与甩送共享 request 去重；输入/提交中、失去控制权、断网、后台与迟到授权不补发 |
| AgentAppDispatch | GUI 投递 adapter，映射 agent.gui.submit | 默认新任务、明确 current 才续接；副作用前占用、失焦拒发、新建失败不降级旧会话；保持接续目标事实，不把 GUI 发送当执行完成 |
| SpriteSession / SpriteFeedback / SpriteFeedbackPanel | 手机输入与任务事实的桌面展示，不是独立请求入口 | Bridge 投影提供任务引用、状态、结果与连接事实；保留 draft/generation/seq/提交关联，迟到旧任务不覆盖新草稿；显示未知/离线，不自行推进业务终态 |
| 鼠标/键盘/屏幕/专用解锁 | 原手动通道 | 继续直达 PocketDesk，不等待 Workbench 或模型 |

桌面面板当前是非编辑展示层，不能据此新增一种入站主体。将来若真的增加桌面输入/按钮发起业务，先定义来源、身份和准入再接入。

书签 ID 是规划补项，尚未加入 A 的首批 14-ID 契约；不能仅改方案就宣称 wire 已支持。G3 扩展时同步 schema、TS/Swift fixtures 和版本兼容决策，避免在当前 C 工单夹带新能力。

## 3. 切流与旧 Agent 退役

G1 的 note.create 是验证身份、幂等、查账和成果访问的增量闭环，不是全量替换手机入口。按能力对新请求切流；迁移期明确本机/远端 authority，远端超时只能查账，不能回落本机重做。

G4 默认切流的必须条件：
1. 目标日常路径清单明确，至少包含书签、打开应用、GUI 派单与明确续接、甩送、桌面反馈及原手动三通道；逐项有迁移前后行为与证据，未准入路径继续明确留在旧路径，不能静默消失。
2. 书签/桌面 Provider 达到上述回归标准；真机项目保留设备/版本/限制。桌面反馈能投影远端任务状态与产物，不借本机 TaskService 推进远端终态。
3. 新请求唯一执行权；断网、未知回执、重启、撤销、晚到事件、取消与回滚不双执行；业务记录与产物可查回。
4. 默认切流后旧模型理解/路由循环停止接收新任务；旧在途任务由原负责人收尾，不能跨权威续跑。回滚只影响以后新请求，远端已受理请求保留查账。
5. 观察窗口由实施批次明确记录起止与代表场景，覆盖睡眠/重启/恢复；无必须依赖旧模型循环的未解决路径后，另批移除旧 loop 及其专属配置。

保留本机确定性执行器、控制租约、持久调用账本和历史只读兼容；它们是 Provider 所需能力，不随旧 Agent loop 退役。TaskService/TaskStore 按职责拆分使用或保留，不整体删除。

## 4. 首期协议范围与验收责任

只有一份 wire schema。G1 只实现 note.create 的入口接收、调用关联、同事务去重、回执与成果访问；不实现未用到的项目调度/记忆系统/Provider 发现全链路。requestId、operationId、invocationId 的语义保持不同，简单调用可以一对一关联，不强建 Agent 长任务；agentTaskId/attempt 仅长任务使用。

AdapterBinding/ReadinessObservation 是独立对象，不要求把全部观测字段塞进每条手机笔记请求。authorizationRef 是已验证授权引用，不意味着每次新增人工确认；revision 用于回执恢复，evidence/artifacts 由真实笔记 ID、版本和读回构造，不引入审核模型。新增能力扩展统一 schema 与 fixtures，不维护第二套 G1 schema。

执行点负责重新核验授权、binding/设备、环境指纹、请求 scope 与观测有效期。G0 结构校验通过不等于证据真实、能力可用或幂等已实现。自研校验器不继续扩展为通用标准实现；生产接入前选定可维护的验证依赖/公开接口并验收打包路径。标准校验对照缺失或被 skip 时，不能视为与标准对照通过。
