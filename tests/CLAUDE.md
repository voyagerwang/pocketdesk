# tests/
> L2 | 父级: ../CLAUDE.md

screen-core.test.js: Node 内建断言验证常规/横向旋转正反坐标、位移换算、瞄准取消/失控及双指接管不补点击、独立滚动/滚轮结束、60/120Hz 惯性一致与取消、黑边排除、取消手势松键与提交队列隔离，不依赖电脑输入权限。
workspace_browser.py: 覆盖慢请求在途时切换取消排队快照不冻结、返回首页继续同步；Playwright 以本地静态文件和模拟接口验证触控板、画面、原生输入及草稿提交回归；图片提交使用有序数组状态，不连接真实桌面控制服务。

runtime-smoke.cjs: 已安装服务的只读冒烟，验证控制握手隔离、真实 JPEG 元数据、ACK 背压和超时，不注入输入或保存画面。
runtime_browser.py: 独立浏览器连接真实服务验证 JPEG 解码、四种视口按钮可见性和关闭停止；拦截远端输入。

live-draft.test.swift: 隔离编辑器验证整值替换、Unicode 光标、暂存不落字、桌面修改/焦点/选区冲突和失败停止、提交封闭；选区替换保留原有前后文，连续纠正零退格；读回延迟恢复及应用切回后当前焦点续发均不重复写入，未知写入/冲突/提交阶段停止不可重放。清空另有独立断言块：按**当前实际内容**整段删净（不比旧基线，故能修掉"清空后每次还剩第一个字"）、只发一次删除键、已空幂等不再多按；门禁失效/控件不可读/无法确定删除范围三种"证明不了"一律如实失败；基线被外部改动而冻结后，清空能破冰并把同一轮续写接上，删不干净则保留正文停在冻结态，结果未知的停止不给清空开后门。配套内存替身 `FakeField` 刻意让**插入落在光标处**（否则 `start` 偏移那类 bug 复现不出来），退格无选区时吃光标前一个字。

image-batch-store.test.swift: 隔离验证不同批次隔离、多图身份幂等、重复提交身份拒绝、显式顺序、缺图整批拒绝、8 张/8MiB 上限、成功消费与损坏图片拒绝。
image-paste-policy.test.swift: 隔离验证 Chrome 多图逐张粘贴的剪贴板稳定/网页消费等待、只在非末张后要求插入点点击，以及 Group/StaticText 焦点向上归一到 WebArea、传统输入框取自身、浏览器工具栏拒绝；Chrome 单图、原生飞书、UU 仍沿用既有节奏，无剪贴板、鼠标与按键副作用。

multi_image_browser.py: 覆盖 Canvas 不可用时长图 JPEG 预览/上传原字节保留和透明 PNG 转 JPEG 白底；Playwright 模拟接口验证多选删除保序、上传失败保留重试、正文/纯图等待压缩、损坏图片不吞旧选择、满额删除追加及横向布局；覆盖健康状态重复点击当前目标不换草稿，失败后重选当前目标或切换目标才更换草稿/队列，同时保留正文、附件批次并隔离旧目标；截图写入 /tmp，不连接真实桌面服务。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

phone-settings.test.cjs: 静态结构回归，验证首页设置入口唯一、触控板内无齿轮、三个旧控件 ID 与范围未变且未被复制第二份、翻腕开关默认关闭且不写死 disabled、翻腕偏好只存用户意愿、翻腕练习（按钮/读数条/仪表/控制器练习通道）已彻底移除而带度数的灵敏度档位仍在、新脚本同时进入页面引用与 Server.swift 静态白名单；并锁住免证书降级——`#wrist-group` 默认 `hidden` 且由设置面板按状态显隐，证书向导的任何一个词（CA 路径、`probeSecure`、描述文件安装、信任开关、探测跳转）都不得再出现在手机端设置面板与体感模块里，失败只给「暂时无法使用翻腕发送，请使用发送按钮」一句人话，四级状态与有效数据探测、挂起恢复必须真实存在；控制台只留局域网/跨网地址链接且不再有安全连接整块。

motion-recognizer.test.cjs: 纯函数识别器单测，覆盖正常翻腕触发与震动/扭转/转屏/短触/静止的拒绝，以及灵敏度预设差异；不依赖浏览器。

web-globals.test.cjs: 静态结构回归，验证 window.pocketdeskSend 只由 pad.js 赋值（screen.js 的画面指令通道）、compose.js 以 pocketdeskComposeSend 暴露发送入口、motion-send.js 不读该全局、index.html 中 pad.js 先于 compose.js 加载，以及安卓专属输入补丁（残留焦点再聚焦/内边距补聚焦/IME 重建）全部受 androidInputPatch 门禁约束。

live-recovery.test.cjs: 静态契约回归，直接对 compose.js 的 `probeLive`/`scheduleProbe`/`stopRecovery` 函数体做否定与结构断言——`scheduleProbe` 在 `liveProbing` 为真时必须把续期请求登记到 `recoveryPending`/`recoveryPendingDelay` 而非直接 return（早期版本在这里 self-break，导致弹窗关掉后只能切应用才能恢复）；`probeLive` 的 `finally` 必须在落地后补排 pending；`stopRecovery` 必须清空 pending；`RECOVERY_MAX_ATTEMPTS` 须足以覆盖“电脑侧弹窗自己关掉”的时长（20 ≈ 30s）；`probeLive` 绝不调用任何写入路径；index.html 必须有 `#live-flag`、`#screen-input-status`，且 compose.js 向两者写入。

live-recovery.runtime.py: 永久浏览器运行时回归，在浏览器内打桩 `/api/live-input`（桌面零写入），覆盖 A（打断→冻结→只读探针自我续期→`recoverable` 才恢复；冻结期零写入、禁止体感候选）与 B（连续轮次：提交一轮后换新草稿身份继续实时同步）两类场景，共 17 项断言；`/usr/bin/python3 tests/live-recovery.runtime.py` EXIT=0 表示全过。配套纯函数/门禁测试见 `draft-state.test.swift` / `input-activity.test.swift` / `pointer-geometry.test.swift`。

draft-state.test.swift: 隔离验证 `LiveDraft` 五态机（`active`/`interrupted`/`recoverable`/`needsUserFocus`/`committed`）与 `probe` 只读分支——探针只比对不写字符，且只发最后确认版本之后的差量（复用 KeyboardDraftWriter 公共前缀算法）。`swiftc -parse-as-library` 编译（测试文件不含 main.swift）。

input-activity.test.swift: 隔离验证 `InputActivity` 进程级活动闸（NSCountingLock + 时间戳）——计数进入/离开对称、超时判定、以及 ServerWatchdog 据此推迟自愈重启；`swiftc -parse-as-library` 编译。

pointer-geometry.test.swift: 隔离验证 `PointerGeometry`（纯几何）与 `TargetWindowLocator`（AX + WindowServer 窗口解析）的落点计算——窗口内保持、跨屏取最大有效交集中心、被遮挡跳过、负坐标/纵向/L 形排列不回退主屏中心；`swiftc -parse-as-library` 编译。

输入追加回归：workspace_browser.py 验证暂停后删空携原 ID 核验、删空后继续输入及电脑原文不反填；screen-core.test.js 验证失败回执晚到时保留同草稿删除，跨草稿仍拒绝恢复。

提交清空回归：workspace_browser.py 验证有草稿的回车快捷键只提交一次并清空、空草稿回车仍走原接口、旧编辑元素迟到事件不回填或重发、历史配额异常不阻断已确认提交的收尾；失败保留与显式重试仍覆盖。
