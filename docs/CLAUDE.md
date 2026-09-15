# docs/
> L2 | 父级: ../CLAUDE.md

成员清单

sprite-agent-implementation-plan.md: 小精灵完整实施交接稿；应用同行且可排序的内置目标、默认输入与键盘、轻甩统一提交、草稿隔离、任务 API、浏览器控制仲裁及 M0–M3 验收，具体交互优先于早期浏览器提案；第 15 节补充现有应用工具化、微信流程及桌面 Computer Use 接法。

voice-agent-browser-plan.md: 单一语音入口与 tt-bridge 浏览器工具集成提案；承接 Agent 整体方案，划分输入与任务、运行时与浏览器桥职责，记录许可证边界、能力验证及 M0–M3 验收。

wrist-send-no-certificate-plan.md: 免手动证书翻腕规划；**阶段 2（默认网页能力降级）与阶段 3（Mac 控制台 HTTPS 配对码）已实施**——证书向导撤除、四级状态与有效数据探测落地、非安全上下文整组隐藏、控制台直出 HTTPS 配对码（内嵌 token、复用自签证书一次性例外、不装 CA）；阶段 1（真机基线）、4（双机发布验收）仍待真机。Tailscale 作为可信入口的路径已于 2026-09-11 经用户决策否决。

app-selection-pointer-plan.md: 显式选择应用后的鼠标就位方案；限定窗口可见落点、控制权与并发取消规则及 WorkBuddy 实现验收边界。

wrist-send-reliability-and-pointer-plan.md: 翻腕发送依赖的 HTTPS 钥匙串、连续草稿与弹窗焦点恢复方案，并编排应用选择后的鼠标就位实施顺序与真机验收。

superpowers/specs/: 已确认的小范围交互规格；记录实现边界、数据流、冲突规则与验收标准，供后续实现按单一规则落地。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
