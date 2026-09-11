# 应用选择后鼠标就位

状态：方案已定，交给 WorkBuddy 实现。2026-09-11。

## 用户体验

手机手动点选应用 → 现有流程激活应用 → 确认目标窗口可见 → 鼠标移到该窗口可见区域中央，用户直接用触控板继续操作。

- 对所有手动点选的应用生效，包括再次点选当前应用；鼠标已在目标窗口的可见区域内则保持原位。
- 只移动，不点击，不修改文本选区，不猜输入框位置，不增加按钮、开关或常驻提示。
- 前台自动跟随、状态轮询、发送文本/图片、快捷键中隐式激活均不触发。
- 目标窗口不存在、仍最小化、不可见、锁屏、权限不足或控制租约失效时跳过定位。激活结果与鼠标结果分开，不能把定位失败误报为应用激活失败。
- 拖动或鼠标键按住时跳过；激活等待期间用户继续移动鼠标或开始新手势时取消本次定位，不能等手势结束再突然移动。
- 快速点 A 再点 B，只有最后一次选择可定位；A 的迟到回执也不得改变 B 的面板、提示或草稿同步。

## 参考与证据边界

优先检查 UU 官方入口 https://uuyc.163.com/，本次网页工具无法读取；搜索所得仿冒相似域名不作为官方证据。尚未验证 UU 真实界面是否具有“切应用自动移鼠标”，不得声称复刻该功能。

Omnissa 官方 HTML Access 文档说明移动端触控板模式通过指针操作远程桌面或应用：https://docs.omnissa.com/zh-CN/HorizonHTMLAccessGuide-V2312/UsingaRemoteDesktoporPublishedApplication 。这支持沿用现有相对触控板；自动就位是本项目针对显式应用选择提出的减少滑动步骤的设计，不是该文档记载的功能。实施前可只读检查已安装 UU 的操作入口，记录能验证的事实，不为调研发起远程连接或改变设置。

## 现有代码与实现边界

1. Web/app.js 的 selectTarget → activateTarget → POST /api/activate 是显式选择入口。添加本次选择代际及控制会话信息，保留原有 beginDraftForExplicitTarget 语义。定位意图必须显式传递，协议默认关闭以兼容旧客户端。
2. Sources/Server.swift 与协议模型解析可选定位意图；复用现有控制租约校验，执行前再次验证。不要仅凭配对 token 或客户端自报控制权允许新增鼠标操作。
3. Sources/InputExecutor.swift 的 activateTarget 同时被其他业务复用，不可直接给所有激活附加鼠标副作用。沿用 openApplication 与现有激活核验；通过小型回调/结果暴露已确认目标，显式入口编排后续定位。现有“另一块屏幕”分支需核验，不能误把合法副屏窗口判成失败。
4. 目标几何：优先目标 PID 的 AX focused window，其次同 PID 的 main window；通过屏幕可见窗口列表验证，必要时退到同 PID 的最前普通可见窗口。排除其他应用、桌面、菜单栏和零尺寸窗口。使用 CoreGraphics 全局桌面点，不能混用 NSScreen 左下原点或 Retina 像素。
5. 窗口跨屏时分别求与有效显示器的交集，选择面积最大的有效区域中心；窗口中心本就可见时可直接使用。必须落在真实有效屏区域且属于目标窗口；明显被其他窗口遮挡的落点跳过，无法证明可见就不移动。支持负坐标、纵向和 L 形排列，不回退主屏中心。
6. PointerExecutor 是唯一鼠标执行者：添加最小定位接口，通过现有指针队列执行，复用有效屏钳制和事件注入；在同一队列核验会话、代际、拖动和用户活动后再注入，更新 expected。禁止从 InputExecutor 独立发 CGEvent，禁止把 CursorMonitor 观测值写入 expected。现有全屏绝对点击不受影响。
7. 实际移动仍由 CursorMonitor 真实观测并广播；HTTP 回执可区分 moved/unchanged/skipped（附原因），不能用命令预期伪造手机光标。没有系统确认的事件只记“已发出”。
8. 最小组装改动放 main.swift 或既有依赖注入处；几何若需独立可测试模块再抽取，不增加通用事件总线。InputExecutor 已超过 800 行，不继续堆定位几何，适度分离新增职责。

## 验收

- 单屏：鼠标在窗口外会就位；在窗口内保持；随后首次相对滑动从新位置连续移动、不跳回。
- 多窗口应用选择实际前台窗口；副屏、负坐标、跨屏、Retina 均落在正确可见区域；拔屏后不误移主屏。
- 重复选择、A/B 快切和乱序回执只允许最新选择生效；等待期间实体鼠标/触控板操作不被迟到定位抢走。
- 拖动、锁屏、无权限、观看者、控制权交接、无窗口/启动失败均安全跳过并保留正确激活反馈。
- 自动跟随、草稿同步、文本图片发送与快捷键无新增鼠标动作；不改文字、不产生点击。
- 运行适配本仓库的 Swift 构建、几何与门禁纯测试、前端乱序回执回归。真机鼠标移动测试只针对明确测试窗口，不能点击或输入用户正在工作的内容；不具备条件则明确列为待验收，不伪报通过。

## 交付要求

由 WorkBuddy 完成代码、验证与 L3/L2/L1 文档回环，并在本文件补充实际结果。工作区现有 Web/compose.js、Web/index.html 未提交改动属于正在进行的修复，应保留并协调；先完成当前及已排队修复，再顺序实施本方案，避免同仓库并发覆盖。无需再次询问是否开始；不顺带改其他交互，不自动推送远端。

## 验收记录（2026-09-11 实现完成）

### 实际改动

- `Web/app.js`：`selectTarget → activateTarget → POST /api/activate` 带 `selectGeneration`（每次手动点选自增）与定位意图 `locate: true`（仅手动选择显式传，自动跟随/隐式激活/恢复探针一律默认关闭）；回执代际与当前不一致整条丢弃，A/B 快切时 A 的迟到回执不改动 B 的面板/提示/同步。
- `Sources/Server.swift`：`/api/activate` 解析 `locate`/`generation`；非回环且未 `controlAuthorized` 时 409；先 `isCursorSettled` 检查（光标已在目标窗口可见区域内 → 直接 `unchanged`、不调 `pointer.locate`），再 `landing`，再 `pointer.locate(to:generation:anchor:)`；回执 `locate: moved/unchanged/skipped` + `locateReason`。
- `Sources/PointerExecutor.swift`：`locate` 只移动不点击，复用现有指针队列与有效屏钳制；同串行队列核验会话、代际、anchored 用户活动门禁后才注入，更新 `expected`；禁止从 `InputExecutor` 独立发 CGEvent、禁止把 `CursorMonitor` 观测值写入 `expected`。
- `Sources/PointerGeometry.swift`（新增，纯几何）：窗口内保持、跨屏取最大有效交集中心、被明显遮挡跳过、负坐标/纵向/L 形排列不回退主屏中心，使用 CoreGraphics 全局桌面点。
- `Sources/TargetWindowLocator.swift`（新增，AX + WindowServer 窗口解析）：优先目标 PID 的 AX focused window，其次同 PID main window，再退到同 PID 最前普通可见窗口；排除其他应用、桌面、菜单栏、零尺寸窗口。
- 与五态恢复协议共用选择代际与控制租约（见 `wrist-send-reliability-and-pointer-plan.md` 验收记录）。

### 自动化结果

- 只读定位探针（不移动鼠标）：WorkBuddy 窗口 (135,91 1200x801) → landing (735,492) `cursorSettled=true`；Finder 被遮挡 → `SKIP occluded`；证明几何 + 窗口解析链路正确。
- `tests/pointer-geometry.test.swift`（`swiftc -parse-as-library`）隔离验证窗口内保持、跨屏最大交集、遮挡跳过、负坐标/L 形不回退主屏中心。
- `tests/live-recovery.test.cjs` 锁定 `app.js` 的 `selectGeneration` 与"定位意图仅手动选择显式传 `true`"的协议默认值。
- Swift 构建无 error；与恢复协议一并部署，HTTPS/HTTP/API 均 200。

### 真机结果（待验收）

- 单屏/多屏（副屏、负坐标、跨屏、Retina）、重复选择、A/B 快切、乱序回执、拖动/锁屏/无权限/控制权交接/无窗口等场景的**真机鼠标移动**只针对明确测试窗口执行，不点击/不输入用户正在工作的内容，待验收。
- 自动跟随、草稿同步、文本图片发送、快捷键无新增鼠标动作，已通过协议与静态回归确认；真机全链路待验收。

### 提交号

与 `wrist-send-reliability-and-pointer-plan.md` 所列看门狗安全化 + 五态恢复 + 四步向导 + 全部测试一并统一提交（见仓库最新 commit）。未推送远端。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
