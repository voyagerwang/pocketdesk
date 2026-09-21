# docs/
> L2 | 父级: ../CLAUDE.md

成员清单

desktop-sprite-execution-plan.md: 用户已确认的桌面对话球首版交接；定义居中球球、手机草稿同步、真实任务反馈、焦点与乱序隔离、WorkBuddy Hy4 实施步骤和验收；本期只交付文字闭环，附审核修复记录与待真机项。

desktop-feedback-tts-plan.md: 电脑反馈与 TTS 调研提案；复用任务事实建立不抢焦点的文字反馈，再接系统朗读，明确外部 Agent 回复回传边界、官方依据与分阶段验收，尚未实现。

voice-solution-research.md: 小精灵语音能力候选调研；覆盖 ASR/TTS/Realtime，原价格与评分待核验；本次电脑反馈需求的落地顺序和证据以 desktop-feedback-tts-plan.md 为准。

sprite-agent-implementation-plan.md: 小精灵用户服务交付计划；保留已落地的接收者、草稿、任务 API 和浏览器仲裁技术契约，v1.2 新增真实流程产品审计与 S0–S5 服务路线，要求每阶段交付一项用户可独立使用、可验证成败的服务，历史 M0–M3 仅作实施记录。

voice-agent-browser-plan.md: 单一语音入口与 tt-bridge 浏览器工具集成提案；承接 Agent 整体方案，划分输入与任务、运行时与浏览器桥职责，记录许可证边界、能力验证及 M0–M3 验收。

wrist-send-no-certificate-plan.md: 免手动证书翻腕规划；**阶段 2（默认网页能力降级）与阶段 3（Mac 控制台 HTTPS 配对码）已实施**——证书向导撤除、四级状态与有效数据探测落地、非安全上下文整组隐藏、控制台直出 HTTPS 配对码（内嵌 token、复用自签证书一次性例外、不装 CA）；阶段 1（真机基线）、4（双机发布验收）仍待真机。Tailscale 作为可信入口的路径已于 2026-09-11 经用户决策否决。

app-selection-pointer-plan.md: 显式选择应用后的鼠标就位方案；限定窗口可见落点、控制权与并发取消规则及 WorkBuddy 实现验收边界。

wrist-send-reliability-and-pointer-plan.md: 翻腕发送依赖的 HTTPS 钥匙串、连续草稿与弹窗焦点恢复方案，并编排应用选择后的鼠标就位实施顺序与真机验收。

superpowers/specs/: 已确认的小范围交互规格；记录实现边界、数据流、冲突规则与验收标准，供后续实现按单一规则落地。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

orb-attribution.md: 工作台球球静态 SVG 的来源、原始声明与非商业素材许可；不适用项目 MIT 许可。

orb-turn-preview.html: 独立动效评审，内嵌原版全部表情与彩带，对照双眼变圆的正视过渡与多倾角彩带飘动（仅预览引擎启用）；含 52px 手机尺寸、暂停/重播/正侧定格/手动进度、减少动态效果适配，不替换生产页面。许可见 orb-attribution.md。

接收者交互以 sprite-agent-implementation-plan.md 的 2026-09-18 修订为准：默认跟随前台，手动进入小精灵，输入栏往返，草稿保护。

agent-new-task-dispatch.md: Agent 新建任务契约、四应用页面核验、失败语义与实际验证边界；记录 9 月 20 日 WorkBuddy 新页核验故障、AX 兼容加固及隔离部署范围。

orb-interaction-preview.html: 手机尺寸点击/输入节奏试验，原版默认图与等待表情；点击轻抬、首字点头、输入柔光、停笔暂停，含模拟输入与减少动态效果；不修改生产应用。

phone-file-transfer-plan.md: ZCode 9月20日9点前文件传输执行工单；多文件拖入/查找/访达选择、手机确认、初稿编译缺口与隔离交付验收。

quick-unlock-zcode-plan.md: ZCode 免手装证书快捷解锁工单；可信网页与出站转发、本机 Keychain 与授权验签、锁屏状态适配、隔离实现及双手机验收；未部署、未验收。

phone-file-transfer-delivery.md: 电脑向手机文件发送的交付记录；最终行为、相对 HANDOFF_BASELINE 变更清单、精确测试命令与退出码、验收表（含环境受阻与真机未验收项）及剩余限制。
phone-file-transfer-files.json: 相对交接基线的文件清单与内容SHA-256，用于隔离交付补丁核验。
phone-file-transfer-delivery.patch: 仅本任务相对handoff-baseline的可应用补丁，不包含原仓库其他任务差异。

android-native-unlock.md: 安卓局域网快捷解锁协议、配对流程与验证边界；原生 App 与现有网页、文件发送共存。
android-pairing-ux-fix.md: 安卓扫码依赖和三阶段配对体验修复、13 项测试证据及真机限制。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

workspace-recovery-20260920.md: 主线程崩溃证据、统一工作台二维码、Android 0.2.0 集成与实际验收边界。

android-layout-shortcuts-fix.md: Android单顶栏布局与控制台save全局冲突根因、交互回归和真机边界。
interaction-console-native-20260921.md: 网页文件发送与本机解锁管理、Android原生文件设备页、亮屏回调的实现边界、验证与交付记录。

product-interaction-review-20260921.md: 0.4任务优先导航、状态解锁、低频管理收纳、设计语言与解锁故障可诊断边界。
continue-on-another-mac.md: 独立分支交接、另一台Mac及Android构建、配置/签名边界、已验证状态与未完成解锁验收顺序。
