# Agent 新建任务派单

> 父级：CLAUDE.md；2026-09-18

小精灵负责创建接收任务，再把正文交给目标 Agent。正文中的 Computer Use 指目标 Agent 执行任务的方式，不改变派单入口。默认 `dispatch_to_app(mode="new")`；只有明确要求继续当前对话才用 `current`。Workbody 归一为 WorkBuddy，z code 归一为 ZCode。

| 应用 | 新建方式 | 放行证据 |
| --- | --- | --- |
| Codex | 官方 `codex://threads/new?prompt=` | 目标窗口中唯一正文完全相同的撰写框，精确焦点；只提交、不重复输入 |
| WorkBuddy | 唯一“新建任务”入口 | 新建页签已选中、欢迎标题、空白或已知占位文本 |
| Cola | 唯一“新建会话”入口 | 本次新增草稿会话、空白撰写框；未选模型则停止 |
| ZCode | 唯一“新建任务”入口 | 选择项目入口、新任务专属占位符与空白撰写框 |

Cola 新会话可能要求先选择模型。当前实现不会替用户选择模型或计费方案：报告新会话已到达但未派单，用户选择后明确要求继续当前会话即可。

副作用前 TaskStore 原子保存占用，旧快照保存不能抹除；一次任务不自动重复新建或重发。新建页核验失败不复用旧对话；输入队列写入前再核验空白，避免排队期间覆盖用户草稿。控制权、目标焦点、锁屏状态在动作处继续核验。成功回执仅代表提交已发出，不声称目标 Agent 已接受或已完成工作。

## 验证边界

Computer Use 实际观察并点击了 WorkBuddy、Cola、ZCode 的新建入口，确认页面证据；未向这些应用发送测试任务。Cola 新会话实际显示“请选择模型”。Codex 的 Computer Use 访问被工具策略阻止，未绕过限制进行端到端操作；深链行为依据[官方命令文档](https://learn.chatgpt.com/docs/reference/commands)。因此编译和隔离回归通过不等同于四应用实际派单全部通过。

本次全量 Swift 编译、agent-runner 与 task-store 隔离测试、agent-client/live-recovery/web-globals/phone-settings 四组回归均通过；已通过安装脚本更新本机应用，服务健康端点返回 HTTP 200。

隔离测试覆盖模式、别名、旧页面拒绝、深链编码、并发和重载去重。版本升级造成页面证据变化时，应更新适配器与证据测试，不能改成猜坐标或退回旧会话。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
