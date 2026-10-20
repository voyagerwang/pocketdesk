# tests/
混合甩送回归：motion-recognizer.test.cjs 覆盖加速度相对小幅前翻提前 40ms 到滞后 120ms 的五种时序，均只触发一次；超时或反向帧上的脉冲不得复活旧动作。34 项轨迹与 motion-send 集成回归通过，未替代真机验收。
侧握轨迹回归：motion-recognizer 覆盖正负 45/60 度起始侧握、双向横屏、反向不触发、慢速换姿与转屏作废；motion-send 检查识别到提交入口的时间诊断。合成数据不替代手机实际动作验收。
chrome-bookmarks.test.swift：临时 Chrome 书签树验证嵌套文件夹、名称、网页和文件地址、多配置文件 ID 隔离及重新读取；motion-send 回归新增仅加速度不能通过探测、探测中关闭与挂起不得迟到启动。
> L2 | 父级: ../CLAUDE.md

mijia-sensor-query.test.swift: 单句温湿度的保守解析、来源与时间短回执，以及真实Gateway范围注入/零模型一次查询；临时任务和账号替身，复合/补充/页面与失权边界不放宽，无真实设备控制。
mijia-sensor.test.py: 综合温湿度查询的唯一目标/同家庭/规格白名单，设备直读与纯缓存回退、时间归一化及请求计数；所有网络/SDK为替身，灯开关原读取保持兼容。

mijia-home-scope.test.swift: 临时账号/配置与真实范围协调器验证动作/场景零调用拒绝、未选拒绝、账号绑定、保存失败保留、选择重载、迟到准备与执行互斥，以及家庭 HTTP 形状，不使用正式授权。
console-mijia-scope.test.cjs: DOM/请求替身验证单户也不默认选择、草稿/已保存区分、失败保留、迟到结果与换账号隔离，以及慢家庭接口不阻塞扫码。
mijia-connection.test.swift: 隔离账号目录、进程/时钟/核验替身验证扫码会话刷新/取消/过期、迟到事件拒绝、旧授权保留及核验后原子提交，覆盖米家 HTTP 的参数与短期二维码边界。
mijia-login-process.test.swift: 临时真实子进程验证扫码 NDJSON 事件先于完成、输出上限、超时/取消及后代持有 stdout 时的有界退出，不访问账号或网络。
mijia-setup.test.py: 临时 uv 替身验证安装取消转发 TERM/INT/HUP、强制回收忽略信号的进程及失败阶段不继续，不修改正式运行环境。
mijia-login.test.py: SDK 替身与临时子进程验证二维码即时 flush、唯一终态、超时分类、敏感日志隔离、暂存权限及取消不修改正式授权。
console-mijia.test.cjs: 无依赖 DOM/计时器/请求替身验证扫码状态渲染、刷新/取消与旧结果隔离、过期撤码和页面可见性恢复，不访问正式账号。
console-mijia-browser.py: 完整控制台的截留网络浏览器回归；验证米家连接操作、二维码失效与网络恢复，以及桌面/窄屏布局，全部状态为合成替身。
mijia-gateway.test.swift: 真实 TaskStore 与进程/模型替身验证动作/场景不进入模型schema、安全提示与米家目标规范化去重、重载/旧快照不重放、失权零写入、账号/同名候选恢复和真实 AgentRunner 工具回灌；完整清单仍限定家庭，云端在线标记原样回传，verified/accepted 保留各自确认强度；临时 Python 验证 stdin 参数、JSON 布尔、stderr 隔离及超时终止，不访问账号或设备。
mijia-bridge.test.py: 注入 SDK/API/官方规格替身验证零消息预检、认证/网络/设备离线分类、单操作规格去重与跨操作重新核验；复用已取家庭房间信息且零新增查询、跨家庭/歧义不补房间；覆盖家庭隔离、类型/范围/动作输入、准备零副作用、目标漂移拒绝、直接读回/未知结果、凭证权限和严格 JSON，不联网、不读正式凭据。
mijia-network.test.py: requests 替身与临时公开规格缓存验证同 URN 成功/失败去重、SDK/动作规格复用、完整 URN 严格匹配/隔离、有效期/损坏恢复、落盘失败降级、私有文件与超时/认证分类；缺少 type 的实时响应不落盘，账号/设备 HTTP 不缓存，家庭 owner 仅单次 SDK 操作复用，不访问真实网络或正式授权。
task-store.test.swift 的米家补充回归：首次占用、并发/重载/旧快照保持证据、完成回执不可替换、结束后只能补事实、旧缓存兼容；所有存储指向临时目录。

agent-open-history.test.swift: 真实公开目标的模拟历史与执行器替身验证首次成功打开的准确名称复用、调用回执配对、主体/时效隔离、历史冲突及查询地址拒绝、当前书签优先与失权零操作；52项通过，--replay 对真实创建应用页任务命中已有地址、解析约1.6ms，仅测历史查找而非网页加载；回放不打开网页、不请求模型、不写生产存储，语音到网页的完整提速待下一次实际输入验收。

agent-quick-open.test.swift: 模型/桌面替身与临时 TaskStore 验证本机打开零模型、四个打开工具显式 completesTask 成功回执少一轮、缺失/false/字符串/数字不收尾、URL 标点保真、准确匹配/歧义退回、租约失败零动作，以及复合/项目/补充/恢复/页面上下文不短路；全量编译和隔离回归通过，无真实网页、应用与消息副作用，真实模型语义判断与语音耗时待验收。

codex-selection.test.swift: Codex 项目匹配、选择问题与导航焦点序列隔离回归；准确PocketDesk/语音空格名称优先于旧目录附带命中，真实同名/共用路径仍澄清，显式旧项目不丢；中文候选无JSON/UUID且限5项，必要目录与~/可准确再次选择；注入焦点/时钟验证未知→目标、未知超时、明确其他应用、失权/锁屏与确认后失焦，不读取真实桌面。--live 只读本机项目配置，不开应用、不派单。
input-focus-owner.test.swift: 共享应用归属纯策略回归；值替身验证明确 AX 优先/畸形成功拒绝、缺值/暂不可读的活动应用与即时进程一致补证、缓存/Carbon/系统控件反证、活动歧义/缺 PID、硬错误、未授权及安全输入拒绝；Codex 导航序列消费同一补证 PID，并验证确认后反证与授权/环境门禁停止。不调用运行时归属读取、不访问真实 AX/UI或外发任务。
agent-runner.test.swift 的 Codex 复合指令回归：仅打开不能收尾用户的派单目标；同批/跨轮发送保持项目与完整条件，待选择 transcript 保留原任务并允许补充选择；模型输出规范采用简洁中文且不显示内部JSON。全部使用替身，不向外部Agent发送任务。

headset-voice-focus.test.swift: 注入 Driver 驱动真实定位服务，覆盖只读正文/未知唯一编辑器、完整扫描与不完整/多候选拒绝、冷树与准备取消、原应用/窗口/鼠标/权限/迟到回调；纯策略验证缺值补证必须即时进程一致且系统控件无反证，不读取真实桌面或发键。
headset-native-route.test.swift: 临时规则存储与真实 Runtime/Actions 的合成中键边沿；验证来源/健康 JSON 绑定唯一当前设备 registry，同型号不同序列号、重插、未知/歧义连接隔离；双 registry 或旧连接晚回执即使新鲜也拒绝，断到唯一202仍拒绝101回执，仅202正确新鲜回执放行，旧健康缺 registries 拒绝。沿用scope、准备/松开、旧代际、接收框双击及兼容观察者边界；不监听硬件、不写正式租约或发键。helper 的 --self-test 验证真实父链策略、identity→registry 回执、同型号服务隔离、缺失 registry 及租约过期恢复，无真实映射写入。
headset-hold.test.swift: 默认有线按压纯状态回归；消费取消后的重复脉冲、阈值和松开不启动录音，下一轮独立长按仍可用。
headset-volume-source.test.swift: 音量来源票据、鼠标滑块语义与操作学习的纯回归；覆盖普通点击后耳机候选仍有效、非音量滑块不取消或冷却、鼠标核验超过80ms保留票据、真实音量滑块点击/持续拖动排除、迟到回执代际隔离，以及键盘来源与耳机双击边界；不读取真实 AX、改音量、录音或执行动作。

headset-voice-pause.test.swift: 注入设备策略、转写、时钟与按键接收器驱动真实自定义语音动作，验证文字续期与一次结束、转写不可观察时暂停且恢复重算、空文/原文、手动/长按/切换、准备代际、取消/焦点、小精灵同源文字、自行停止后不重复取消面板、显式取消与环境中断仍释放录音、设备隔离及结束后稳定满0.6秒即发送；保留显式等待2秒和立即发送0.4秒门禁。不启动生产单例、计时器、录音或真实输入，日志使用无操作替身。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

screen-core.test.js: Node 内建断言验证常规/横向旋转正反坐标、位移换算、瞄准取消/失控及双指接管不补点击、独立滚动/滚轮结束、60/120Hz 惯性一致与取消、黑边排除、取消手势松键与提交队列隔离，不依赖电脑输入权限。
compose-return.test.cjs: Node VM 验证首页/全屏共用回车提交、229软键盘的输入事件、不可取消与仅input的换行撤回、选区与多行正文保留、Shift换行、候选确认和重复按键门禁；不访问真实桌面。
screen-pip.test.cjs: Node VM 注入多触点事件验证小窗捏合放大/缩小与中点锚定、视口和最小尺寸、第三指隔离、松指/取消收尾、按钮排除，以及单指/边柄兼容和位置持久化；不访问真实桌面。
workspace_browser.py: 覆盖慢请求在途时切换取消排队快照不冻结、返回首页继续同步，以及 Android 悬浮键盘下长按全过程不主动失焦、冗余粘贴按钮已移除；Playwright 以本地静态文件和模拟接口验证触控板、画面、原生输入及草稿提交回归；小窗通过真实浏览器双触点验证缩小、放大与持久化；全屏验证原生回车、IME换行事件单次提交与上下文、候选/Shift不发送、失败保留原ID再重试；图片提交使用有序数组状态，不连接真实桌面控制服务。

runtime-smoke.cjs: 已安装服务的只读冒烟，验证控制握手隔离、真实 JPEG 元数据、ACK 背压和超时，不注入输入或保存画面。
runtime_browser.py: 独立浏览器连接真实服务验证 JPEG 解码、四种视口按钮可见性和关闭停止；拦截远端输入。

heartbeat_browser.py: 真实浏览器连接真实服务验证手机页心跳失败的分级与归因——失败 <15 秒只给琥珀色"正在自动重试…"，≥15 秒才升红并报出中断时长与"轻点此处立即重试"；手机离线（`navigator.onLine === false`）单独归因，不与电脑端问题混为一谈；恢复时必须报出中断时长；`heartbeatAdvice` 对 401 / 非 401 的 HTTP 失败 / 页面脚本错误 / 网络失败给出四句互不相同的话。只放行 GET 与 `/api/pair`，其余写接口全部拦截，不注入任何桌面输入。
connection-recovery.test.cjs: 真实连接编排与徽标函数的虚拟时钟/可迟到HTTP行为回归；覆盖首次503/401、单事务并发闸、响应头/响应体挂起截止、接收者配置降级、停止/超时迟到隔离、任务找回挂起不阻塞心跳、首败草稿不绑定新前台、HTTP未成功前WS认证不越权就绪及WS未认证/关闭事实；不访问生产服务或输入桌面。
connection-recovery-browser.py: 完整手机页面与隔离HTTP/WS替身验证首次失败无需刷新恢复接收者和任务初始化、已有草稿跨断线保留、恢复零输入/提交请求，以及控制WS关闭即时降级；不连接生产服务，不能替代手机跨Wi-Fi及睡眠恢复验收。

WorkBuddy 整页 AXValue 漂移回归：`live-draft.test.swift` 证明非编辑区同长变化时，本次插入片段+精确光标可认账；删除结果不等于目标时仍必须失败。`agent-client.test.cjs` 另锁住成功终态后 `send()` 新建、未完成默认补充且可显式换件事、执行中拒绝再派、刷新找回活动任务，以及任务卡父层的 `hidden` 解除路径。

live-draft.test.swift: 隔离编辑器验证整值替换、Unicode 光标、暂存不落字、桌面修改/焦点/选区冲突和失败停止、提交封闭；选区替换保留原有前后文，连续纠正零退格；读回延迟恢复及应用切回后当前焦点续发均不重复写入，未知写入/冲突/提交阶段停止不可重放。`update` 删除降级链独立断言块：受控输入框（AX 设不上）按「AX 连败退避（连败 3 次停用、成功清零，一次读回迟滞不再永久逐字）→ Cmd+A 单和弦整框全选（旧文恰为整框且光标在文末时读回确认后一次覆盖；Cmd+A 被吞直接退逐字；送达没落 DOM 先按 Right 还原光标再逐字）→ 逐字 Backspace」降级；空替换不补刀回归锁在此（旧版多发一次退格多删前缀一字且冻结草稿）。清空另有独立断言块：按**当前实际内容**整段删净（不比旧基线，故能修掉"清空后每次还剩第一个字"）、只发一次删除键、已空幂等不再多按；成功判据始终是"读回为空"——AX 设选区**假成功**（select 声称成功却不落 DOM，ZCode 实况）与**设不了选区**都自动退到真实键盘 Cmd+A 兜底删净，退格被吞删不动时两轮后如实失败并保留正文；门禁失效/控件不可读照样拒绝；基线被外部改动而冻结后，清空能破冰并把同一轮续写接上，删不干净则保留正文停在冻结态，结果未知的停止不给清空开后门。配套内存替身 `FakeField` 刻意让**插入落在光标处**（否则 `start` 偏移那类 bug 复现不出来），退格无选区时吃光标前一个字，并提供 `selectLies`（AX 选区假成功）、`backspaceNoop`（退格被吞）、`keyboardSelectAll`（Cmd+A 吞键）、`keyboardSelectAllNoop`（Cmd+A 送达没生效）四个故障注入开关与 `selectAttempts`（AX 尝试计数，验证连败退避）。

image-batch-store.test.swift: 隔离验证不同批次隔离、多图身份幂等、重复提交身份拒绝、显式顺序、缺图整批拒绝、8 张/8MiB 上限、成功消费与损坏图片拒绝。
image-paste-policy.test.swift: 隔离验证 UU 文字把 1.2s 远端同步等待放在 Cmd+V 前、按键后只留 200ms 消费时间；同时覆盖 Chrome 多图剪贴板稳定与插入点策略，以及画布多图方向键分离节奏（仅右/下键、间隔为正）的合法性，测试本身无剪贴板、鼠标与按键副作用。

multi_image_browser.py: 覆盖 Canvas 不可用时长图 JPEG 预览/上传原字节保留和透明 PNG 转 JPEG 白底；Playwright 模拟接口验证多选删除保序、上传失败保留重试、正文/纯图等待压缩、损坏图片不吞旧选择、满额删除追加及横向布局；覆盖健康状态重复点击当前目标不换草稿，失败后重选当前目标或切换目标才更换草稿/队列，同时保留正文、附件批次并隔离旧目标；截图写入 /tmp，不连接真实桌面服务。

model-config.test.swift: 隔离验证端点/协议/凭证同源、多服务商递归脱敏、旧单条稳定 legacy-api 迁移与精确品牌命名、新格式无重复凭证往返、当前 API 兼容字段投影和显式选择；删除/失效/空活动 ID 不选列表首项，Codex 与 API 列表独立，不联网或读写生产配置。

m0-model-probe.cjs: M0 运行时验证探针（方案 §12 M0-A）。
task-store.test.swift: 任务存储的幂等与冲突（同 requestId 同内容回到同一任务、不同内容报 conflict）、事件 seq 单调与 after 增量补取、清理不删活动任务，以及接收者顺序的迁移语义（小精灵只插一次、不被重新置顶、未知引用清理）。经 `TaskStore.resetCache(directory:)` 指向临时目录，不碰用户真实数据。
agent-client.test.cjs: Node VM注入window/localStorage/fetch替身执行真实客户端；验证Bearer与requestId、未完成默认补充/显式新话题、同任务稳定票据、丢包查账/冲突拒绝、提交与切换互斥、旧revision隔离、待核实重试保留原请求及轮询节奏，不连接真实服务。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

phone-settings.test.cjs: 静态结构回归，验证首页设置入口唯一、触控板内无齿轮、三个旧控件 ID 与范围未变且未被复制第二份、翻腕开关默认关闭且不写死 disabled、翻腕偏好只存用户意愿、翻腕练习（按钮/读数条/仪表/控制器练习通道）已彻底移除而带度数的灵敏度档位仍在、新脚本同时进入页面引用与 Server.swift 静态白名单；并锁住免证书降级——证书向导的任何一个词（CA 路径、`probeSecure`、描述文件安装、信任开关、探测跳转）都不得再出现在手机端设置面板与体感模块里，失败只给「暂时无法使用翻腕发送，请使用发送按钮」一句人话，四级状态与有效数据探测、挂起恢复必须真实存在；控制台默认 IP 主入口、电脑名称码默认折叠，不恢复安全连接或证书区。

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

agent-runner.test.swift: 包含真实失败参数“7号机器人”经模型工具循环补查并单次回执收尾； 无桌面副作用验证直接打开、派单、控制租约与失败状态，注入模型和执行器替身；重复派单使用临时任务记录，要求在激活/清空前同步拒绝。另覆盖 WorkBuddy AX 数字/字符串选中状态、占位符换行兼容与真实草稿拒绝。
agent-workspace.test.swift: WorkBuddy/ZCode 本地工作空间协议与纯导航回归；验证准确/同名/Unicode 名称、菜单操作项隔离、选中项目后的重开、模型/权限排除及 AX 名称/值/子文本选中证据；覆盖 WorkBuddy ComboBox/PopUpButton 与工作空间/分支/Worktree 局部行识别，同名分支与歧义行不得补成项目，工作空间菜单须唯一且有双动作证据，“不使用工作空间”不冒充项目。WorkBuddy 5.8.2 可见欢迎标题（含仅辅助名称）、工作空间选择器与唯一空框优先证明当前新页并直接聚焦，证据缺失/隐藏/真实草稿回退导航，选中的新建页签不能借隐藏欢迎标题放行旧会话空框；模型权限值不充当选择器，直接聚焦不受导航入口歧义影响，多空框仍拒绝。共享焦点获取候选只接受可见、启用、正文可读且为空/已知占位的 AXTextArea，排除草稿和其他输入角色，同物理矩形归一、不同空框保留歧义。焦点一致性要求双方为可见、启用的 AXTextArea 且原引用或精确同矩形相符，空框/完整正文分别核验，原引用也不能绕过角色和值检查；发送前原正文框候选要求全文匹配且原 AX 身份或精确原矩形相符；重建引用可绑定，全文变化/隐藏/禁用/不可读/位置不符拒绝，身份与位置指向不同框时保留歧义。语义发送按钮排除隐藏/禁用/近似名称，同角色同矩形引用归一，不同真实按钮保留歧义；消息计数排除撰写框子文本，新增外部完整消息与空框才提供本次接收证据，旧消息或近似正文不冒充新增；不调用真实聚焦或发送动作。合成快照覆盖唯一侧栏展开、隐藏 AX 同名副本不参与导航或选中证据、同角色且精确同矩形的物理控件双引用归一，不同矩形/无矩形/不同角色仍独立；覆盖禁用/近似/可见歧义入口拒绝、展开后不重击、初次空树等待至新建就绪、AXTab/AXLink 完整可访问名称、已知占位与欢迎/选中证据及真实草稿保护。AX 元素仅作身份替身，不读取或修改真实桌面；有界子文本抽取由 WorkBuddy 5.6.2 实机 PocketDesk→workbench 任务验收核对。
agent-new-task-draft.test.swift: WorkBuddy 原生新建的纯窗口/草稿策略与实际指针队列替身回归；宿主只接受本应用 file renderer URL，混合身份、远程/其他本地路径和截断树不提供窗口证据；覆盖真实空值/已知占位/草稿/不可读及多候选，旧会话草稿可先导航，已证home但编辑器未就绪不降级，隐藏草稿不污染可见新框候选。独立窗口菜单须唯一且完整名称匹配，本次唯一新增窗必须成为焦点，既有独立窗、多个新增窗或未知焦点不授权写入；注入事件接收器验证默认左键、显式右键、移动后取消不按下及按下后取消仍成对释放，事件只留内存。不读真实桌面、保存用户草稿或发送正文/鼠标事件。
agent-runner.test.swift 工作空间派单回归：复合指令同批/跨轮 open_project→send_task 不提前结束，保留完整正文并要求派单事实；只打开仍直接收尾，省略逗号前指定项目拒绝通用派单，接收未知不自动重发。
sprite-flow.test.py: Playwright 模拟任务与应用接口，验证小精灵成功接收写入历史、未接收保留草稿且不记历史、存储失败不阻断发送收尾，并覆盖甩送发送门禁、连续任务、简洁状态、手动/明确意图自动接续、迟到不抢新草稿及球球加载；截图位于 /tmp。

sprite-flow.test.py 追加：小精灵切应用保留正文并同步，切回小精灵不产生桌面写入；待机/执行动效与减少动态偏好验证。

agent-runner.test.swift 追加只读应用解析：本机存在 UU 时验证 UU远程/UU 远程/uu/UURemote、自定义配置名和歧义拒绝；不打开真实应用。

feishu-messaging.test.swift: 临时 TaskStore 与 CLI 替身验证原词查询优先、机器人/群语境词空结果补查、真实带类型词名字保护、补查准确同名/歧义/非准确候选与失权零外发，以及联系人/群/机器人收件者发送、完整群成员核验、真实 post 提及节点、同名群/成员逐轮选择与冻结正文/提及计划、截断/权限/租约失效拒绝及幂等/未知不重发；--live 仅查本人资料，绝不真实发信。

feishu-gateway.test.swift: 模拟风险帮助与业务执行验证各域入口、参数隔离、固定身份、写去重、高风险确认、群聊及用户授权状态；精简 PATH 的 npm 符号链接入口验证直接调用同包原生 CLI、自定义入口兼容、Node 缺失具体错误与未知响应拒绝。--live 仅验证授权、群列表和命令帮助。

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
sprite-panel.test.swift: 原生面板集成验证；注入异步系统焦点与内存应用激活回执，覆盖明确取消归还原应用、空焦点/自身焦点、重试保留目标、切应用/其他key窗口/新接收/原应用退出/锁屏使迟到归还失效，不激活真实外部应用；恢复原因与下一步直显，能力限制允许澄清目标，补充/新任务按钮携带明确输入意图；测试锁屏替身仅在独立编译使用，验证显式重选、锁屏隔离、非激活窗口与长回答滚动区域；真实 field editor 合成中文/emoji/组合字符，验证透明接收层仍可输入、UTF-16组合范围及相同正文范围变化同步蓝线、确认后清线、显式换行与连续长句自然折行标记，核验聆听→执行/核验期间同一字幕的全文、字号、面板及屏幕坐标、滚动位置固定，accepted/running 忽略旧结果，终态或待补充才替换正文；待补充/失败后直接重开与未完成组合文字时重新接收均在一秒内获得真实系统 key；执行及结束接收释放 NSApp.keyWindow 且面板可见，无测试额外聚焦或收起；文字转语音收起前文说明，短句及超过三行字幕、marked 收尾、失焦拒绝与独立空标题继续覆盖，导出 voice-listening/voice-executing 原生截图；不录音、不注入按键、不提交任务。

sprite-panel.test.swift 直接装载 WKWebView 本地原版组件，断言原生字号/居中、无收起按钮和默认问候、表情抢占及锁屏隔离，导出 /tmp 原生渲染截图；完成可呈现庆祝或短暂隐藏后的满意稳态，可见时须播放，精确庆祝时序由 orb-desktop.test.py 隔离验证。

sprite-flow.test.py 新增选择与草稿上报断言，防止手机界面正常但桌面旁路未接通。

sprite-report.test.cjs 增加连续输入共享 150ms 节流窗口断言，避免持续听写使上报饥饿。sprite-panel.test.swift 增加默认透明面板与短句单行检查。

sprite-session.test.swift 验证历史终态不自动展示、本会话回执仍恢复结果；sprite-flow.test.py 验证 320/390 宽度实时草稿、长句不溢出与切走隐藏。

orb-desktop.test.py: 原版引擎浏览器回归，验证开心唤醒、SVG 帧变化、输入抢占、轮询不重播、隐藏/减少动态停帧，截图只写 /tmp。

执行反馈回归：sprite-session 覆盖 Phase 优先级、提交/执行不回显原话、新草稿替换终态、交接不庆祝；sprite-panel 验证原生输入→执行→完成标题/正文和实际庆祝表情；orb-desktop 验证重选执行不欢迎、同任务不重复庆祝和连续任务独立庆祝。

原生动效验收必须让 NSApp.run 真正处理窗口事件，用异步测试等待 WebKit，不能在主队列内阻塞轮询；同时核对 document 可见与引擎 active，防止静态首帧被误判为动画通过。

agent-runner.test.swift 派单误报回归：确认/失败/未核实均不再续轮请求模型，未核实进入 submitted 且无 error，同批重复派单只执行一次并封闭 transcript。

sprite-session.test.swift 验证未完成按恢复类型展示，派单未核实保留“接收待核实”与核对入口，普通追问显示具体问题；已交接仍正常退场。

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
console-actions-browser.py: 真实控制台完整脚本验证接收者请求在途时默认 IP 入口与二维码仍更新、电脑名称码保持可选且不随 IP 刷新、可见文字不泄漏 token、服务失败撤下旧码及恢复，并覆盖文件选择、两文件分块拖放、网页密码/配对/撤销与窄屏布局；所有网络截留在合成替身。
console-file-upload.test.swift: 隔离验证控制台分块上传的精确字节重组、Unicode名、空文件、错序和路径名拒绝，不碰真实收件箱。
unlock-native.test.swift 补充确认解锁后恰好调用一次唤醒；失败、拒绝和重放不唤醒。
phone-files.runtime.py 补充局域网下载入口直接可见、排列首位且HTTPS入口保留的窄屏回归；不依赖打开失败帮助。

unlock-native.test.swift 验证仅通过签名及授权的请求触发输入前唤醒，拒绝路径不触发。
console-actions.test.swift 验证显式钥匙串授权检查不回传密码或密钥；系统授权弹窗仍需本机用户验证。
console-actions-browser.py 验证即使存在HTTPS地址，连接区默认只显示当前 IP 的App/浏览器通用码，需手机支持解析的电脑名称码位于折叠区；解锁授权码按需显示并标清仅限App。

task-first-browser.py: App0.4首页锁定、未知和解锁状态的入口显隐、无自动授权、顶部应用栏与主题设置入口的320/390回归。
Android LocalClientTest与WorkspaceExperienceTest补充具体错误保留、真实手势才能直达解锁和主题传递；NativePagesTest确认低频页无底部Tab、返回保留工作台。
motion-send.test.cjs 与 Android NativeMotionBridgeTest：锁定 HTTP WebView 原生姿态样本进入既有甩送识别/提交门禁，以及 Android 姿态角和屏幕方向映射；合成测试不替代安卓真机方向与手感验收。

chrome-tab-cleanup.test.swift: 窗口/完整 URL/加载边界、活动页保留、控制失效和未知结果停止；真实 Chrome 字典仅编译固定脚本、不执行。agent-runner.test.swift 另验证去重工具参数、租约、同批抑制和原样部分失败回执。隔离测试不替代 Chrome 实际关闭验收。

Chrome 去重延迟回归：模拟 pending → pending → closed，核验多次仍只关闭一次；持续 pending 在 2 秒内失败且不碰下一页；核验后失权保留已确认计数。脚本语法编译仍不是实际 Chrome 关闭验收。

2026-09-28 Chrome 去重实机验收：修复安装后从手机 Web 小精灵入口提交“关闭 Chrome 里重复打开的标签页。”，任务 2F341124-B689-4AED-A68A-9F1247C8D13D 为 succeeded、回执“已关闭 2 个 Chrome 重复标签页。”；Chrome 标签栏同时减少对应两页，页面展开结果一致。验收后返回控制台结束临时页面连接。

workbench-content.test.swift: 临时 TaskStore 与 HTTP 替身验证四类创建、正文/日期映射、按 ID 核验；省略/null/空日期及仅提醒默认今天，明确未来计划/截止日期保留；跨午夜已完成/pending及旧版无日期操作键不重复写入；失去控制权/服务离线无写入、超时/错正文不重放、旧快照/进程重载去重、并发原子占用及 AgentRunner 工具路由。

workbench-lookup.test.swift: GET 替身验证六工具路由、关键词编码、日期/分页/ID/凭证校验、租约/离线/错误回执、查询零创建及 AgentRunner 结果回灌。

headset-magpie-native.test.swift: AppKit 主线程事件循环验证耳机来源匹配、既有规则、保存门禁、关闭取消与编辑保护；仅 post `TargetStore.themeDidChange` 切换经典/米白，核验同一设置与录制窗口的主题投影和实际画布像素，并导出准备/识别/错误及系统深色预览，不保存正式配置或触发耳机动作。
run-headset-ui-tests.sh: 耳机识别、音量运行时与来源回归的隔离编译入口；`--native` 追加原生主题预览，二进制/缓存/PNG 写入临时或指定目录，不安装应用。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

飞书发送证据回归：task-store.test.swift 验证并发原子占用、旧快照不能抹掉 pending/确认回执、通用操作只推进一次及缓存重载后不重放；agent-runner.test.swift 验证 mentions schema、群提及工具路由和无效参数拒绝，全部使用隔离存储与 CLI 替身。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

task-recovery.test.swift: 模型收尾与服务续接替身回归；追问不报完成、能力限制保留调整目标、错误回执按原信任级别回放；显式补充忽略30分钟窗口与关系分类、完整历史、第6轮仍可继续、票据幂等与未知发送不重放。
agent-recovery.test.cjs: 手机恢复DOM替身验证服务端主动作、具体问题/候选保留、首页/全屏归属、草稿及换件事返回、提交期间禁切换、待核实重试入口和纯文本呈现。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

console-connection.test.cjs: 控制台连接 DOM/时钟替身回归；默认 IP 链接与二维码及时跟随地址变化，可选电脑名称码保持稳定且不代替缺失 IP，可见文字不展示 token；空地址/服务失败清除旧链接与图像，图片失败可同址重试，恢复重现入口；只有数字地址时不显示重复名称码，无授权地址不合成配对码，经典脚本全局隔离。不连接真实服务、不读取真实 token。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

sprite-voice-interaction.test.swift: 真实原生接收框与 SpriteDesktopInput，注入内存按键/焦点/豆包窗口/单调时钟及环境授权；覆盖正确焦点回执晚于旧1秒但仍在共享3秒准备期内即启动、确认后不继续等待或重复发Option，以及超时/取消/环境撤权/明确外部焦点零键；撤权后恢复授权可在同一接收框明确重试，避免拥有者永久waiting。沿用启动去重、超时释放、原文基线与保留重试、迟到焦点隔离、右侧结束和左侧取消待提交、空白等待尾字及未知toggle不盲发；不连接耳机、不录音、不提交任务，--native 回归入口包含此测试。

耳机取消/接续回归：headset-voice-pause.test.swift 覆盖同侧小精灵取消、跨侧语音先于修饰键门禁接续、waiting保留停顿期限、ended不重复回调、失效拥有者恢复及同步退休；长按与普通输入回退保持原行为。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

model-routing.test.swift: 临时配置/任务与模型替身验证旧文件 GET 只读迁移、首次仅保存不激活、A→B→A 凭证持久、非活动/当前条目编辑、Codex 独立、新增/跨 ID/跨源空 Key 拒绝且零请求、指定 ID 草稿不落盘、严格 JSON 布尔与未知操作拒绝、移除当前留未配置及旧清空只删当前；保留回环、探针最终文字闭环、首轮/多轮计量与来源、失败/缺失用量未知回归，不联网或操作真实桌面。

codex-model.test.swift: 假 CLI 进程与纯协议验证 ChatGPT 登录前置、结构化规划/原参数校验、协议完成与退出码一致、原生工具拒绝、超时终止和来源计量；真实模型探针仅在显式 --live 下运行且不执行桌面操作。

console-agent-model.test.cjs: Node VM 与动态 DOM/多记录 HTTP 替身验证服务商列表和脱敏 Key、A→B→A 按 ID 切换、添加仅保存及编辑非活动记录不切换、界面重读保留记录与来源；每条 Key 独立，同记录同源才能空 Key 沿用，新增/跨源空 Key 测试与两种保存零请求，摘要测试不混用草稿；编辑冻结、重复打开保护、纯文本名称、取消清草稿回焦点、旧结果撤下、移除两次确认及失败不变更列表/来源。28 项隔离回归，不联网或读生产配置；持久化磁盘往返由 Swift 存储测试验证。

豆包取消回归：sprite-voice-interaction.test.swift 验证Option已松开但豆包条仍在时必须发送Esc、原焦点保持到关闭确认、残留条只补一次Esc、失败可再次左耳重试、失焦及新录音不受旧取消影响；voiceLog注入防止测试污染正式诊断。headset-voice-pause.test.swift 核验左右Option按下/释放使用hidSystemState、普通Esc使用同一私有源、marker和左右物理标记不变。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

agent-feedback-order.test.swift: 模型与打开执行器替身验证搜索后同批打开/失败反馈不能覆盖真实回执、首项反馈封闭操作、真实失败优先、纯反馈，以及准确/复合/多打开的快捷收尾边界；可显式导出纯公共工具定义做模型对照，无实际桌面副作用。

console-model-browser.py: 完整控制台与两家独立服务商的隔离 Playwright 回归；验证 A→B→A 不串字段、列表刷新持久、新增/非活动编辑仅保存不切与保存启用、摘要测试按服务身份、同源新增和跨源编辑空 Key 零请求、取消/重复打开/二次移除保护、Codex 独立切换及经典蓝/米白模型区窄屏无溢出；全部请求截留，截图写入 /tmp/pocketdesk-provider-switch，不调用真实模型或改动设备配置。

恢复交互回归（2026-10-12）：agent-client.test.cjs 验证同taskId重试、稳定票据查账、旧revision回包拒绝、发送期间归属门禁、未知回执后的独立核对与草稿保护。sprite-panel/session/voice-interaction 验证紧凑恢复、主动作、可见字段/光标、换件事返回及原有字幕/焦点边界。

task-recovery-action.test.swift: 真实任务模型的纯值回归；完整只读历史、明确未发送例外、未知/畸形记录及持久副作用证据，验证跨端主动作与JSON契约一致，不执行工具。

agent-recovery-browser.py: 手机启动和心跳状态请求验证Bearer； 完整手机页面配合内存HTTP/WS替身，覆盖经典/米白、320/390/1024宽度与横屏全屏，验证主动作、双输入归属、草稿保护、重试/待核实入口及44px命中区；批量输出/tmp截图，不连接真实服务。
