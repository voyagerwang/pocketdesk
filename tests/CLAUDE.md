# tests/
混合甩送回归：motion-recognizer.test.cjs 覆盖加速度相对小幅前翻提前 40ms 到滞后 120ms 的五种时序，均只触发一次；超时或反向帧上的脉冲不得复活旧动作。34 项轨迹与 motion-send 集成回归通过，未替代真机验收。
侧握轨迹回归：motion-recognizer 覆盖正负 45/60 度起始侧握、双向横屏、反向不触发、慢速换姿与转屏作废；motion-send 检查识别到提交入口的时间诊断。合成数据不替代手机实际动作验收。
chrome-bookmarks.test.swift：临时 Chrome 书签树验证嵌套文件夹、名称、网页和文件地址、多配置文件 ID 隔离及重新读取；motion-send 回归新增仅加速度不能通过探测、探测中关闭与挂起不得迟到启动。
> L2 | 父级: ../CLAUDE.md

screen-core.test.js: Node 内建断言验证常规/横向旋转正反坐标、位移换算、瞄准取消/失控及双指接管不补点击、独立滚动/滚轮结束、60/120Hz 惯性一致与取消、黑边排除、取消手势松键与提交队列隔离，不依赖电脑输入权限。
workspace_browser.py: 覆盖慢请求在途时切换取消排队快照不冻结、返回首页继续同步，以及 Android 悬浮键盘下长按全过程不主动失焦、冗余粘贴按钮已移除；Playwright 以本地静态文件和模拟接口验证触控板、画面、原生输入及草稿提交回归；图片提交使用有序数组状态，不连接真实桌面控制服务。

runtime-smoke.cjs: 已安装服务的只读冒烟，验证控制握手隔离、真实 JPEG 元数据、ACK 背压和超时，不注入输入或保存画面。
runtime_browser.py: 独立浏览器连接真实服务验证 JPEG 解码、四种视口按钮可见性和关闭停止；拦截远端输入。

heartbeat_browser.py: 真实浏览器连接真实服务验证手机页心跳失败的分级与归因——失败 <15 秒只给琥珀色"正在自动重试…"，≥15 秒才升红并报出中断时长与"轻点此处立即重试"；手机离线（`navigator.onLine === false`）单独归因，不与电脑端问题混为一谈；恢复时必须报出中断时长；`heartbeatAdvice` 对 401 / 非 401 的 HTTP 失败 / 页面脚本错误 / 网络失败给出四句互不相同的话。只放行 GET 与 `/api/pair`，其余写接口全部拦截，不注入任何桌面输入。

WorkBuddy 整页 AXValue 漂移回归：`live-draft.test.swift` 证明非编辑区同长变化时，本次插入片段+精确光标可认账；删除结果不等于目标时仍必须失败。`agent-client.test.cjs` 另锁住终态后 `send()` 直接新建（不是旧任务补充）、执行中拒绝再派、刷新找回活动任务，以及任务卡父层的 `hidden` 解除路径。

live-draft.test.swift: 隔离编辑器验证整值替换、Unicode 光标、暂存不落字、桌面修改/焦点/选区冲突和失败停止、提交封闭；选区替换保留原有前后文，连续纠正零退格；读回延迟恢复及应用切回后当前焦点续发均不重复写入，未知写入/冲突/提交阶段停止不可重放。`update` 删除降级链独立断言块：受控输入框（AX 设不上）按「AX 连败退避（连败 3 次停用、成功清零，一次读回迟滞不再永久逐字）→ Cmd+A 单和弦整框全选（旧文恰为整框且光标在文末时读回确认后一次覆盖；Cmd+A 被吞直接退逐字；送达没落 DOM 先按 Right 还原光标再逐字）→ 逐字 Backspace」降级；空替换不补刀回归锁在此（旧版多发一次退格多删前缀一字且冻结草稿）。清空另有独立断言块：按**当前实际内容**整段删净（不比旧基线，故能修掉"清空后每次还剩第一个字"）、只发一次删除键、已空幂等不再多按；成功判据始终是"读回为空"——AX 设选区**假成功**（select 声称成功却不落 DOM，ZCode 实况）与**设不了选区**都自动退到真实键盘 Cmd+A 兜底删净，退格被吞删不动时两轮后如实失败并保留正文；门禁失效/控件不可读照样拒绝；基线被外部改动而冻结后，清空能破冰并把同一轮续写接上，删不干净则保留正文停在冻结态，结果未知的停止不给清空开后门。配套内存替身 `FakeField` 刻意让**插入落在光标处**（否则 `start` 偏移那类 bug 复现不出来），退格无选区时吃光标前一个字，并提供 `selectLies`（AX 选区假成功）、`backspaceNoop`（退格被吞）、`keyboardSelectAll`（Cmd+A 吞键）、`keyboardSelectAllNoop`（Cmd+A 送达没生效）四个故障注入开关与 `selectAttempts`（AX 尝试计数，验证连败退避）。

image-batch-store.test.swift: 隔离验证不同批次隔离、多图身份幂等、重复提交身份拒绝、显式顺序、缺图整批拒绝、8 张/8MiB 上限、成功消费与损坏图片拒绝。
image-paste-policy.test.swift: 隔离验证 UU 文字把 1.2s 远端同步等待放在 Cmd+V 前、按键后只留 200ms 消费时间；同时覆盖 Chrome 多图剪贴板稳定与插入点策略，以及画布多图方向键分离节奏（仅右/下键、间隔为正）的合法性，测试本身无剪贴板、鼠标与按键副作用。

multi_image_browser.py: 覆盖 Canvas 不可用时长图 JPEG 预览/上传原字节保留和透明 PNG 转 JPEG 白底；Playwright 模拟接口验证多选删除保序、上传失败保留重试、正文/纯图等待压缩、损坏图片不吞旧选择、满额删除追加及横向布局；覆盖健康状态重复点击当前目标不换草稿，失败后重选当前目标或切换目标才更换草稿/队列，同时保留正文、附件批次并隔离旧目标；截图写入 /tmp，不连接真实桌面服务。

model-config.test.swift: 隔离验证 `ModelConfigStore` 的纯函数——端点归一化（补尾缀、不重复拼接）与协议白名单（file/ftp/无 scheme 必须拒绝），以及脱敏视图：keyHint 只给首尾、`hasKey` 为真时视图里任何字段都不得出现 Key 主体、短 Key 只回「已保存」；另锁 `isConfigured` 要求三项齐全。不联网、不读写真实配置。

m0-model-probe.cjs: M0 运行时验证探针（方案 §12 M0-A）。
task-store.test.swift: 任务存储的幂等与冲突（同 requestId 同内容回到同一任务、不同内容报 conflict）、事件 seq 单调与 after 增量补取、清理不删活动任务，以及接收者顺序的迁移语义（小精灵只插一次、不被重新置顶、未知引用清理）。经 `TaskStore.resetCache(directory:)` 指向临时目录，不碰用户真实数据。
agent-client.test.cjs: 在 vm 沙箱里注入最小的 window/localStorage/fetch 替身执行 `Web/agent-client.js`，断言提交必带 requestId 与 Bearer、**回包丢失时先按同一 requestId 查账而不是新建任务**、查账也失败才抛服务端人话，以及轮询节奏常量（2s/1.5x/10s）。只发 HTTP，验证 OpenAI 兼容接口的五项真实能力——文本返回、工具调用闭环（模型请求→本地伪造结果回传→模型给出最终回答）、同上下文续接、请求可中止（中止后 5s 内必须真的结束，否则视为取消不可靠）、错误分类与 usage 是否可读；不支持的能力记 UNKNOWN 不记 PASS。凭证只从 `PD_MODEL_BASE_URL` / `PD_MODEL_API_KEY` / `PD_MODEL_NAME` 三个环境变量读取，不落盘、不进日志。`node tests/m0-model-probe.cjs` EXIT=0 表示无 FAIL。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

phone-settings.test.cjs: 静态结构回归，验证首页设置入口唯一、触控板内无齿轮、三个旧控件 ID 与范围未变且未被复制第二份、翻腕开关默认关闭且不写死 disabled、翻腕偏好只存用户意愿、翻腕练习（按钮/读数条/仪表/控制器练习通道）已彻底移除而带度数的灵敏度档位仍在、新脚本同时进入页面引用与 Server.swift 静态白名单；并锁住免证书降级——`#wrist-group` 默认 `hidden` 且由设置面板按状态显隐，证书向导的任何一个词（CA 路径、`probeSecure`、描述文件安装、信任开关、探测跳转）都不得再出现在手机端设置面板与体感模块里，失败只给「暂时无法使用翻腕发送，请使用发送按钮」一句人话，四级状态与有效数据探测、挂起恢复必须真实存在；控制台只留局域网/跨网地址链接且不再有安全连接整块。

motion-recognizer.test.cjs: 纯函数轨迹回归，覆盖多采样率传感器噪声、稳定握姿、慢速漂移、快翻达角度立即触发、不依赖悬停或回弹、超时、回位再触发、圆周角与无效数据、逐帧事件及灵敏度差异；不依赖浏览器。
motion-send.test.cjs: vm 浏览器事件替身驱动真实控制器与识别器，并执行 compose 实际门禁，验证前翻中立即调用提交入口、输入静默等待与动作采集并行、未静默候选不补发、统一提交入口、连续倾斜不重复、设置/草稿/输入门禁中断不补发及恢复新动作、关闭与挂起；不连接桌面服务。

web-globals.test.cjs: 静态结构回归，验证 window.pocketdeskSend 只由 pad.js 赋值（screen.js 的画面指令通道）、compose.js 以 pocketdeskComposeSend 暴露发送入口、motion-send.js 不读该全局、index.html 中 pad.js 先于 compose.js 加载，以及安卓专属输入补丁（残留焦点再聚焦/内边距补聚焦/IME 重建）全部受 androidInputPatch 门禁约束。

live-recovery.test.cjs: 静态契约回归，直接对 compose.js 的 `probeLive`/`scheduleProbe`/`stopRecovery` 函数体做否定与结构断言——`scheduleProbe` 在 `liveProbing` 为真时必须把续期请求登记到 `recoveryPending`/`recoveryPendingDelay` 而非直接 return（早期版本在这里 self-break，导致弹窗关掉后只能切应用才能恢复）；`probeLive` 的 `finally` 必须在落地后补排 pending；`stopRecovery` 必须清空 pending；`RECOVERY_MAX_ATTEMPTS` 须足以覆盖“电脑侧弹窗自己关掉”的时长（20 ≈ 30s）；`probeLive` 绝不调用任何写入路径；index.html 必须有 `#live-flag`、`#screen-input-status`，且 compose.js 向两者写入。

live-recovery.runtime.py: 永久浏览器运行时回归，在浏览器内打桩 `/api/live-input`（桌面零写入），覆盖 A（打断→冻结→只读探针自我续期→`recoverable` 才恢复；冻结期零写入、禁止体感候选）与 B（连续轮次：提交一轮后换新草稿身份继续实时同步）两类场景，共 17 项断言；`/usr/bin/python3 tests/live-recovery.runtime.py` EXIT=0 表示全过。配套纯函数/门禁测试见 `draft-state.test.swift` / `input-activity.test.swift` / `pointer-geometry.test.swift`。

draft-state.test.swift: 隔离验证 `LiveDraft` 五态机（`active`/`interrupted`/`recoverable`/`needsUserFocus`/`committed`）与 `probe` 只读分支——探针只比对不写字符，且只发最后确认版本之后的差量（复用 KeyboardDraftWriter 公共前缀算法）。`swiftc -parse-as-library` 编译（测试文件不含 main.swift）。

input-activity.test.swift: 隔离验证 `InputActivity` 进程级活动闸（NSCountingLock + 时间戳）——计数进入/离开对称、超时判定、以及 ServerWatchdog 据此推迟自愈重启；`swiftc -parse-as-library` 编译。

pointer-geometry.test.swift: 隔离验证 `PointerGeometry`（纯几何）与 `TargetWindowLocator`（AX + WindowServer 窗口解析）的落点计算——窗口内保持、跨屏取最大有效交集中心、被遮挡跳过、负坐标/纵向/L 形排列不回退主屏中心；`swiftc -parse-as-library` 编译。

输入追加回归：workspace_browser.py 验证暂停后删空携原 ID 核验、删空后继续输入及电脑原文不反填；screen-core.test.js 验证失败回执晚到时保留同草稿删除，跨草稿仍拒绝恢复。

提交清空回归：workspace_browser.py 验证有草稿的回车快捷键只提交一次并清空、空草稿回车仍走原接口、旧编辑元素迟到事件不回填或重发、历史配额异常不阻断已确认提交的收尾；失败保留与显式重试仍覆盖。

agent-runner.test.swift: 无桌面副作用验证直接打开、派单、控制租约与失败状态，注入模型和执行器替身；重复派单使用临时任务记录，要求在激活/清空前同步拒绝。另覆盖 WorkBuddy AX 数字/字符串选中状态、占位符换行兼容与真实草稿拒绝。
sprite-flow.test.py: Playwright 模拟任务与应用接口，验证小精灵成功接收写入历史、未接收保留草稿且不记历史、存储失败不阻断发送收尾，并覆盖甩送发送门禁、连续任务、简洁状态、手动/明确意图自动接续、迟到不抢新草稿及球球加载；截图位于 /tmp。

sprite-flow.test.py 追加：小精灵切应用保留正文并同步，切回小精灵不产生桌面写入；待机/执行动效与减少动态偏好验证。

agent-runner.test.swift 追加只读应用解析：本机存在 UU 时验证 UU远程/UU 远程/uu/UURemote、自定义配置名和歧义拒绝；不打开真实应用。

feishu-messaging.test.swift: 临时存储与 CLI 替身验证唯一联系人、同名补充、用户选择轮次、纯文本 argv、幂等/未知不重发/租约；--live 仅查本人资料以验证复用授权，绝不真实发信。

feishu-gateway.test.swift: 模拟风险帮助与业务执行验证各域入口、参数值不成为 CLI 开关、固定身份、写去重、高风险确认和群聊 chat-id；--live 仅验证授权、群列表和命令帮助。

sprite-flow.test.py 动效断言更新为分层 SVG、待机转头、执行扫视、点按正视及减少动态；正视截图写入 /tmp/pocketdesk-orb-facing.png。

球球回退验收：sprite-flow.test.py 验证原始整图加载、待机/执行动效、无独立变形眼层及减少动态；截图 /tmp/pocketdesk-orb-restored.png。

sprite-flow.test.py 新增启动前台/未配置应用之间的绑定隔离、草稿/IME/提交期间延迟跟随、小精灵往返无桌面写入及 320/390/1024 宽度检查；live-recovery.test.cjs 的选择契约从 recipients.js 读取并验证静态资源注册。agent-runner.test.swift 覆盖 Codex 包身份别名、普通 ChatGPT 不误认与候选歧义。

球球选中回归：sprite-flow.test.py 覆盖经典/米白主题无框柔光、圆眼正视和减少动态效果；保留草稿/派单行为回归，未替代真机性能验收。

表情草稿回归：sprite-flow.test.py 覆盖空白开心、输入等待、清空恢复开心及任务优先专注。

agent-runner.test.swift 新任务回归：new/current 传递与无效类型拒绝、Workbody/z code 别名、各应用新建页面正反证据、Codex 多行特殊字符深链往返、并发原子占用、旧快照与进程重载不能解除派单去重。测试只注入替身，不实际提交外部 Agent。

原版球球回归：sprite-flow.test.py 检查单 SVG 实例、草稿状态映射和减少动态模式下 SVG 几何停止变化；真机耗电/发热未验证。

待机映射更新：空白/清空现在回归左上待机，点击走原版抖动唤醒；仍验证减少动态模式下几何不变。

agent-runner.test.swift 锁屏回归：工具列表暴露已有能力、真实回执直接收尾、未确认与失败不冒充成功、无参数约束、锁屏后同批动作不执行、控制权失效及输入队列末端拒绝。执行器用替身，队列测试固定授权 false，不实际锁屏。

默认原图回归：空白原图静止，唤醒期间隐藏，1.6 秒后恢复；不再期望默认待机持续运动。

点击反馈回归更新：轻抖过程中原图保持可见，结束后无残留动画，替代原版 07 闭眼过程。

agent-runner.test.swift 桌面动作回归：六个动作路由、租约/参数拒绝、重复关闭防护、未确认结果、标题重名拒绝、Unicode 全选与一次删除、选区未确认/焦点变化/正文不可读时不删除。使用内存输入框和执行器替身，不操作真实窗口。

desktop-actions.test.swift: 无副作用验证菜单/布局参数隔离、禁用与重名菜单精确路径、窗口身份稳定、负坐标屏幕和半屏/四角/居中几何；不操作真实桌面。
agent-runner.test.swift 常用动作扩展：动态 schema 所有动作参数路由、只读发现可重复、菜单已发出回执不报失败且不冒充完成；保留原六项动作、清空选区和关闭去重回归。

sprite-flow.test.py 接收者入口更新：首页和全屏均不再提供接收者切换按钮，改点置顶应用栏进入；移除已删除的手动跟随入口测试，保留自动前台跟随和草稿保护验证。

sprite-session.test.swift: 展示会话与任务投影回归；覆盖连接刷新、迟到回执身份、同任务追问、跨任务相同 revision、重选唤醒代际。
sprite-report.test.cjs: 可控网络隔离验证串行上报、草稿合并、不可变提交票据、重连快照、心跳与切走隔离。
sprite-panel.test.swift: 原生面板集成验证；测试锁屏替身仅在独立编译使用，验证显式重选、锁屏隔离、非激活窗口与长回答滚动区域。

sprite-panel.test.swift 直接装载 WKWebView 本地原版组件，断言原生字号/居中、无收起按钮和默认问候、表情抢占及锁屏隔离，导出 /tmp 原生渲染截图。

sprite-flow.test.py 新增选择与草稿上报断言，防止手机界面正常但桌面旁路未接通。

sprite-report.test.cjs 增加连续输入共享 150ms 节流窗口断言，避免持续听写使上报饥饿。sprite-panel.test.swift 增加默认透明面板与短句单行检查。

sprite-session.test.swift 验证历史终态不自动展示、本会话回执仍恢复结果；sprite-flow.test.py 验证 320/390 宽度实时草稿、长句不溢出与切走隐藏。

orb-desktop.test.py: 原版引擎浏览器回归，验证开心唤醒、SVG 帧变化、输入抢占、轮询不重播、隐藏/减少动态停帧，截图只写 /tmp。

执行反馈回归：sprite-session 覆盖 Phase 优先级、提交/执行不回显原话、新草稿替换终态、交接不庆祝；sprite-panel 验证原生输入→执行→完成标题/正文和实际庆祝表情；orb-desktop 验证重选执行不欢迎、同任务不重复庆祝和连续任务独立庆祝。

原生动效验收必须让 NSApp.run 真正处理窗口事件，用异步测试等待 WebKit，不能在主队列内阻塞轮询；同时核对 document 可见与引擎 active，防止静态首帧被误判为动画通过。

agent-runner.test.swift 派单误报回归：确认/失败/未核实均不再续轮请求模型，未核实进入 submitted 且无 error，同批重复派单只执行一次并封闭 transcript。

sprite-session.test.swift 验证派单未核实显示短回执“已尝试发送，接收待核实”，普通追问仍显示“等你补充”。

sprite-flow.test.py 派单默认接续回归：真实前台改变自动离开小精灵；无 switchAfter/false 的成功回执也只读跟随同前台应用，首页/全屏/Dock 一致，自动接续零 activate，手动返回后不被旧回执抢回，保留草稿保护。

派单接续补充：提交锁内不消费成功回执的自动接续机会，解锁后仍可切换。

画面断线回归：screen-frames.test.cjs 使用虚拟时钟与网络替身，验证短暂失败静默、持续失败分级/退避、权限立即提示、真实呈现后恢复、流畅通道自动重试与停止/旧代际隔离；无真实桌面输入。

phone-file-store.test.swift: 文件暂存隔离回归；仅编译 PhoneFileStore.swift（Auth/TargetStore 测试替身）与可推进时钟，验证快照 SHA-256 一致、空文件、Unicode 名、单文件/批次/总量/数量限额、目录与 FIFO 拒绝、同任务重试与四路并发同批次信号量接力幂等（首批完成后等待方复用同一收件项）、接受换票/旧票作废/拒绝与过期回收、跨主体隔离、源文件变化不影响快照、ZIP 解压成员哈希一致且同名不覆盖；全部在临时目录，不碰真实用户文件。
phone-file-agent.test.swift: 文件发送工具替身回归（与 agent-runner.test.swift 同一全量编译方式）；验证参数校验、租约失效拒绝、访达多选替身的失败提示/空选/成功回执（只说"等待手机确认"不称已下载）、多文件 ZIP 回执与 search_computer_files 替身的普通文件过滤、截断标记与同名提醒；不触发真实自动化、不读真实文件。
phone-files.test.cjs: 收件页面静态结构回归；锁定 textContent-only 渲染（XSS 防线）、下载地址同源+前缀校验、单按钮直接下载且无协议选项、代际序号防迟到轮询复活、状态文案诚实、index.html 容器与 Server 白名单、HTTP 层 Bearer/票据边界（不用回环豁免）、Info.plist NSAppleEventsUsageDescription、拖拽显现与面板拖动保留、44px 触控令牌。

phone-file-http.fixture.swift: 注入假 Auth 和临时 PhoneFileStore 的生产路由宿主，仅监听 loopback 随机端口；两秒流超时用于可重复资源回收测试。
phone-file-http.test.py: 真实 HTTP/socket 联测，覆盖鉴权、附件字节/中文名/空文件、换票拒绝、断流重试、三路慢下载上限与超时后恢复；只使用夹具临时文件。
phone-files.runtime.py: Playwright Chromium 安卓尺寸运行时，操作真实收件 DOM，以异步请求替身控制并行确认与迟到轮询；验证 XSS/URL、断网重试、下载手势回执、刷新恢复和44px目标。
文件暂存回归另覆盖发布时撤权、跨主体批次和文件系统写失败，不以快照测试代替网络下载测试。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

phone-files.download.py: 生产手机脚本连接隔离HTTP夹具，真实点击产生浏览器download事件，保存后核验UTF-8文件名与字节；不拦截默认链接行为，不能替代Via真机。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

unlock-native.test.swift / unlock-native-http.test.swift: 原生配对、挑战及签名授权与路由拒绝隔离回归；测试替身不触碰真实钥匙串或解锁。
lock-screen-input.test.swift: 在后台队列请求生产键盘布局映射并运行主线程事件循环，确认 Carbon/TIS 查询正确切回主线程且不崩溃；不发送按键。
unlock-coordinator.test.swift / unlock-webauthn.test.swift: 锁屏状态机、撤销与旧验证底座回归，为原生路径共用逻辑提供保护。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

console-shortcut-delete.py: 真实控制台完整脚本的隔离浏览器测试，覆盖全局与应用专属删除、最后一项清空、重载、保存失败恢复、不得误写模型配置。
android-shell-browser.py: App UA 与普通浏览器对比，验证唯一顶栏、设置链接、320/390窄屏与紧凑顶距；不连接实际桌面。

console-actions.test.swift: 内存凭据与隔离证书/选择器替身验证同源写入边界、密码不回传、开关、配对确认防重放与撤销。
console-actions-browser.py: 真实控制台完整脚本的文件选择、两文件分块拖放、网页密码/配对/撤销与窄屏布局回归，所有网络截留在合成替身。
console-file-upload.test.swift: 隔离验证控制台分块上传的精确字节重组、Unicode名、空文件、错序和路径名拒绝，不碰真实收件箱。
unlock-native.test.swift 补充确认解锁后恰好调用一次唤醒；失败、拒绝和重放不唤醒。
phone-files.runtime.py 补充局域网下载入口直接可见、排列首位且HTTPS入口保留的窄屏回归；不依赖打开失败帮助。

unlock-native.test.swift 验证仅通过签名及授权的请求触发输入前唤醒，拒绝路径不触发。
console-actions.test.swift 验证显式钥匙串授权检查不回传密码或密钥；系统授权弹窗仍需本机用户验证。
console-actions-browser.py 验证即使存在HTTPS地址，连接区仍只有一个App/浏览器通用码；解锁授权码按需显示并标清仅限App。

task-first-browser.py: App0.4首页锁定、未知和解锁状态的入口显隐、无自动授权、顶部应用栏与主题设置入口的320/390回归。
Android LocalClientTest与WorkspaceExperienceTest补充具体错误保留、真实手势才能直达解锁和主题传递；NativePagesTest确认低频页无底部Tab、返回保留工作台。
motion-send.test.cjs 与 Android NativeMotionBridgeTest：锁定 HTTP WebView 原生姿态样本进入既有甩送识别/提交门禁，以及 Android 姿态角和屏幕方向映射；合成测试不替代安卓真机方向与手感验收。

chrome-tab-cleanup.test.swift: 窗口/完整 URL/加载边界、活动页保留、控制失效和未知结果停止；真实 Chrome 字典仅编译固定脚本、不执行。agent-runner.test.swift 另验证去重工具参数、租约、同批抑制和原样部分失败回执。隔离测试不替代 Chrome 实际关闭验收。

Chrome 去重延迟回归：模拟 pending → pending → closed，核验多次仍只关闭一次；持续 pending 在 2 秒内失败且不碰下一页；核验后失权保留已确认计数。脚本语法编译仍不是实际 Chrome 关闭验收。

2026-09-28 Chrome 去重实机验收：修复安装后从手机 Web 小精灵入口提交“关闭 Chrome 里重复打开的标签页。”，任务 2F341124-B689-4AED-A68A-9F1247C8D13D 为 succeeded、回执“已关闭 2 个 Chrome 重复标签页。”；Chrome 标签栏同时减少对应两页，页面展开结果一致。验收后返回控制台结束临时页面连接。

workbench-content.test.swift: 临时 TaskStore 与 HTTP 替身验证四类创建、正文/日期映射、按 ID 核验、失去控制权/服务离线无写入、超时/错正文不重放、旧快照/进程重载去重、并发原子占用及 AgentRunner 工具路由。

workbench-lookup.test.swift: GET 替身验证六工具路由、关键词编码、日期/分页/ID/凭证校验、租约/离线/错误回执、查询零创建及 AgentRunner 结果回灌。
