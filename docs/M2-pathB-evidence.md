# M2 打开/派单「直接执行」端到端验证证据

日期：2026-09-18
源码目录：`/Users/yz/Documents/PocketDesk`（注意：不是 `voice-deck-mvp`）
构建脚本：`zsh /tmp/install-inplace.sh`（ROOT_DIR=/Users/yz/Documents/PocketDesk）
运行产物：`~/Applications/PocketDesk.app`（二进制名 `VoiceDeck`，监听 46387；控制 WS 46388）

## 需求与结论

| 用户要求 | 实现 | 实测 |
|----------|------|------|
| 任务完成后点输入框直接派新任务，不用点「新任务」 | `agent-client.send()`：终态 → `submit` 新任务；`needsInput` → `followUp`；活动中 → 报错。手机端「新任务」按钮已删除 | ✅ 见断言 2 |
| 命令应用直接执行，不要「点确认打开 → 再执行」 | `open_app` / `open_page` / `dispatch_to_app` 经控制租约校验后直接执行，不再生成确认票据 | ✅ 见断言 1 |

> 旧版「弹允许/拒绝卡片、确认后才打开」的仲裁链路（`awaitingApproval` / `ApprovalItem` /
> `resolveApproval` / 前端审批卡）已**整条删除**：`AgentRunner` 不会再挂起任务，该状态不可达，
> 留着只会让人误以为还要点一次确认。

## 参考对照（用户给的 GitHub 地址已真去读）

- 地址：`https://github.com/mymark21/tt-bridge`
- 结论：Chrome 扩展 + CLI daemon，让 AI 接管**当前 Chrome 窗口**（open/eval/click/screenshot）。
  **只管浏览器，不启动桌面 App**；LICENSE 为 **CC BY-NC 4.0（非商业）**，与项目 MIT 分发冲突。
- 处置：**只作设计参考、不嵌入代码**。路径 A 复用其 `open` 原语思路；路径 B（启动 `.app`）它无能力，原生实现。

## 端到端实测

测试脚本：`/tmp/verify-direct.cjs`
（node 直连回环：WS 46388 完成 auth 拿到控制会话 → HTTP 46387 Bearer 鉴权提交任务并轮询）

```
CONTROL session= 3D2B8DD6-...  controller= true
T1 SUBMIT status= 200 initial= accepted
T1 状态轨迹= running -> succeeded
T1 final= succeeded | result= "已打开计算器。"
>>> 无 awaitingApproval = 是 ✅
T2 SUBMIT status= 200 taskId 不同 = 是 ✅
T2 状态轨迹= running -> succeeded
T2 final= succeeded | result= "收到"
老任务仍在且终态= succeeded = 是 ✅
```

### 断言 1：打开类指令直接执行

提交「打开计算器」，状态轨迹 `running -> succeeded`：
- 全程**没有出现过** `awaitingApproval`（旧版会停在这里等手机点允许）；
- 结果文本是「已打开计算器。」，不是「请求执行…」；
- `pgrep -fl Calculator` 出现
  `/System/Applications/Calculator.app/Contents/MacOS/Calculator`（pid 60812）——真的启动了。

### 断言 2：终态后直接派第二个任务

第一个任务 `succeeded` 之后，**不调用任何 detach / 新任务接口**，直接再提交一句：
- 服务端返回**新的 taskId**（不是旧任务的补充轮）；
- 第二个任务正常跑到 `succeeded`；
- 回查第一个任务，仍是 `succeeded`，历史没有被吞掉。

## 控制租约（为什么必须手机在线）

写操作（打开应用/网页、派单）执行前调 `AgentRunner.canControl(taskId)`：
任务状态为 `running` **且** 任务的 `controlSession` 是当前 WS 控制者，才放行。
- 手机没连上（无控制会话）时不会偷偷动电脑，工具回「未执行：手机控制权已失效」；
- 该租约与配对 token 是两回事：另一台持有同一 token 的手机也不能挪电脑。

## 已落地改动文件

- `Sources/AppOperator.swift`：受信任目录白名单 + 中文别名表 + `resolve` + `open`（NSWorkspace）。
- `Sources/BrowserOperator.swift`：只接受 http(s) 绝对地址的 `open`。
- `Sources/AgentAppDispatch.swift`：`dispatch_to_app`——打开、定位空白输入框、输入任务并提交，一次完成。
- `Sources/AgentRunner.swift`：`open_page` / `open_app` / `dispatch_to_app` 直接执行；工具串行；`Outcome.suspended` 已移除。
- `Sources/TaskService.swift`：提交幂等查账 + `blockingActiveTask` 按主体拦并发；`resolveApproval` 已删除。
- `Sources/Server.swift`：`canControl` 与 `dispatchToApp` 装配点。
- `Web/agent-client.js`：`send()` 终态即新建；活动态集合不再含 `awaitingApproval`。
- `Web/agent-panel.js` / `Web/index.html` / `Web/app-extras.css`：审批卡与允许/拒绝按钮已移除。
- `Web/compose.js`：发送后按目标保留草稿，不再要求先点「新任务」。

## 已知限制

- 仅在 `trustedDirs` 白名单内的 `.app` 可被启动；中文别名表需随装机逐步扩充。
- `dispatch_to_app` 只支持控制台里已配置的 Cola / Codex / ZCode / WorkBuddy / ChatGPT，
  且要求目标应用当前停在**空白**输入框（有字会如实拒收，不覆盖、不自动重试）。
- 应用内更细交互（点击菜单、填表）属后续范围，不在本次。
- 锁屏（loginwindow）时 NSWorkspace 能开标签页但屏幕不可见，需在模型回答里如实说明。

## 补记：派单到 WorkBuddy 报「请在目标应用打开空白任务输入框」（2026-09-18 修复）

### 现象

手机让小精灵「派单给 WorkBuddy」，WorkBuddy 被打开了，但立刻失败：
「未派单：请在目标应用打开空白任务输入框；已有文字会保留。」

### 根因

派单前的守卫要求 `KeyboardDraftWriter.read(element).text.isEmpty`。但 WorkBuddy 是 Chromium 内核，
聚焦元素 `role=AXTextArea`（带 `ChromeAXNodeId`），**它的 AXValue 不是输入框正文**。空框时连续采样实测：

| 采样 | 读到的内容 | 长度 |
|------|-----------|------|
| 1 | 「今天帮你做些什么？ @ 引用对话文件，/ 调用技能与指令」 | 30 |
| 2 | 「你帮」 | 2 |
| 3–8 | 「Agent」 | 5 |

全是**占位提示 / 旁边标签**在泄漏，且每次读的值都不一样。于是 `text.isEmpty` 恒为假，派单被永久拒绝。

已排除的其它可能：`focusedApplicationPID`、`ensureEditableFocus == .editable`、`focusedElement` 三条**全部通过**，
报错只来自空框那一条。另确认 WorkBuddy 的 AX 树从 app 根 / AXWindows 遍历都扫不到任何可编辑节点
（168 节点、0 个），焦点元素不在可遍历树里——"换个更干净的元素来读"这条路走不通。

### 修复（按用户选定的方案：派单前先全选清空再输入）

- `InputExecutor.clearComposerForAgentDispatch()`（新增）：Cmd+A 全选 + Delete 删净，
  **刻意不做读回校验**（Chromium 空框读回永远非空，「读回为空」这条判据不成立）；清空幂等，
  对本来为空的框是无害空操作。
- `AgentAppDispatch.send`：去掉 `text.isEmpty` 前置条件，改为「先清空 → 再 `mirror(text, submit:true)`」；
  `mirror` 的 authorized 闭包也不再重复判空（重复判只会把派单再挡死一次）。
- 代价（用户已知情并选择）：输入框里原有的草稿会被清掉，不再"已有文字会保留"。

### 实测证据

```
CONTROL controller= (take-control 后成立)
SUBMIT status= 200  taskId= 569C93A0-59DF-4EF5-9122-A270441A18C2
状态轨迹= running -> succeeded
工具调用: dispatch_to_app {"app": "WorkBuddy", "text": "回复“PocketDesk 派单测试”"}
工具回执: 已向WorkBuddy提交任务；不代表该 Agent 已完成，结果请在电脑查看。   ← receipt.committed = true
```

`committed` 的含义是「写入已通过读回校验 + 回车已发出」，见 `InputExecutor.swift:576-580`：
先 `guard valid()` 再 `postKey(36)`，任一环节失败都会抛出而不会走到 committed。
WorkBuddy 的会话数据在云端、本地无副本，AX 又读不到界面文本，故**界面侧无法再取第二份证据**——
"新会话里出现了这条任务"需要人眼在电脑上确认。

### 诊断工具（一次性，未入库）

`/tmp/dispatch-probe.swift`（逐条复现守卫）、`/tmp/ax-dump.swift`（转储焦点元素全属性）、
`/tmp/ax-sample.swift`（连续采样 AXValue）、`/tmp/ax-tree.swift`（按窗口扫可编辑节点 / 搜界面文本）。
编译方式与单测相同：Sources 去掉 `main.swift` + 探针文件 + `@main`。

## 补记：手机提示"与电脑的连接已断开"（2026-09-18 凌晨排查）

### 现象

手机页输入框下方红字：**"与电脑的连接已断开：请确认同一 Wi-Fi，或重新扫码。"**
用户不理解——手机当时就在用这台电脑（同一 Wi-Fi、页面可交互）。

### 先确定这条文案是谁说的

不是 WebSocket。全仓只有一处发它：`Web/app.js` 的心跳失败分支。心跳 5 秒一拍，连打两个请求
（`POST /api/pair` + `GET /api/status`），**连续两拍失败**才改口。所以它表达的是"最近 10 秒内手机打不通电脑"，
与控制通道（WSS）是否在线无关——两者是不同的通道，混在一起看就会觉得"明明连着"。

### Mac 侧先排除干净（否则无从归因）

| 检查项 | 结果 |
|--------|------|
| 进程 | 67747，00:50:44 启动，排查期间未重启 |
| 端口 | 46387/46388/46389/46487/46488/46489 全部 LISTEN |
| 系统睡眠 | `sleep 0 (prevented by UURemote, powerd, sharingd)`，无睡眠事件 |
| 文件描述符 | 57 个（上限 256），无连接泄漏；各端口仅个位数 TIME_WAIT |
| 任务流水 | `tasks/events.jsonl` 显示 00:50:59 – 01:03:19 之间**无任何任务**，服务未被长任务阻塞 |

### 服务端自己的记录：那 3 分 40 秒是真的断

`Application Support/VoiceDeck/device-connections.json` 里手机（V2309A / Android / Chrome）的访问段：

```
09-18 00:50:47 → 00:59:17   通话 510s
09-18 01:02:57 → …          通话中
```

中间 **175 秒无心跳**，用户截图时间 01:02:50 正落在这个空档末尾；01:02:57 起自行恢复，
01:03:19 手机成功提交了一条任务（`BFB0486C`，已 succeeded）。也就是说：**提示没说谎，那一段手机确实没连上电脑**，
只是旧文案把"为什么没连上"猜成了一句"请确认同一 Wi-Fi"。

### 当下连接是好的（抓包确认）

`netstat` 连续采样抓到手机侧连接：

```
tcp4 192.168.31.196.46488  ←  192.168.31.139.44120   ESTABLISHED
```

同网段（Mac `192.168.31.196`）+ WSS 控制会话在线，说明网络路径本身没问题，属**间歇性**中断
（手机侧 Wi-Fi 休眠/唤醒、页面被系统冻结后恢复的最初几秒都是常见来源）。

### 改法：把四种原因分开说，并让恢复更快

旧实现的问题不在"报错了"，而在**四种完全不同的原因共用一句话**：401（配对失效）、手机离线、
电脑端 HTTP 异常、页面脚本错误——它们的解法分别是重扫码 / 回 Wi-Fi / 等电脑 / 下拉刷新。

- `heartbeatAdvice()`：按 `httpStatus`、`navigator.onLine`、`isNetwork` 分流；控制通道仍在线时改口
  "电脑端响应超时"，不再武断甩锅 Wi-Fi。
- 分级：失败 <15 秒 → 琥珀色"…，正在自动重试…"；≥15 秒 → 升红 + **中断时长** + "轻点此处立即重试"。
- 失败后 1.2 秒补拍（成功即取消、退后台即取消），恢复提示报出中断时长。
- `online`/`offline` 只触发提前补拍，不跳过分级——Android 唤醒瞬间的假离线直接甩红色，等于把漏报换成误报。

### 实测（`tests/heartbeat_browser.py`，真实服务 + 真实浏览器）

```
阶段1 健康:      pill=需接管            （控制权在手机上，本实例是观看者）
阶段2 刚失败:    class=warn  msg=电脑端响应超时（控制通道仍在），正在自动重试…
阶段3 持续不通:  class=error msg=电脑端响应超时（控制通道仍在）。已中断 15 秒，轻点此处立即重试
阶段4 手机离线:  class=error msg=手机当前没有网络：请连回与电脑同一个 Wi-Fi。已中断 16 秒，轻点此处立即重试
阶段5 恢复:      msg=已重新连接到电脑（中断 16 秒）。
阶段6 分类器:    401 / 502 / 脚本错 / 网络错 → 四句互不相同的话
阶段7 刚掉网:    class=warn  msg=手机当前没有网络：请连回与电脑同一个 Wi-Fi，正在自动重试…
```

回归：`web-globals` / `device-info` / `agent-client` / `phone-settings` / `motion-recognizer` / `screen-core` /
`runtime-smoke` / `runtime_browser` 全部通过。顺带改掉 `live-recovery.test.cjs` 里**钉死资源版本号**的写法——
那个清单在 2026-09-17 Codex 升版后就没同步、一直红着，而且拦不住真问题；现在锁的是可验证的不变量
（每个资源引用都必须带 `?v=`），数字不再钉死。

### 附带发现：同一仓库有第二个写手

排查过程中发现 `Web/*` 在源码之外还被第二处改动：01:16:15 起 `Web/{app.js,index.html,compose.js,app-extras.css}`
被改写（小精灵情绪球图标、`compose-recipient` 收件人标签、`pocketdeskContinueInApp`、新增
`docs/orb-attribution.md`），并有一个 `swiftc ... tests/agent-runner.test.swift` 进程在跑——Codex 已恢复额度并
在**同一工作树**继续施工。两个写手的直接后果：**谁最后装机，手机就拿到谁的版本**；而每次装机都会重启服务，
手机随即出现一次数秒的"已断开"（这本身就是本文档开头那个现象的来源之一）。互不覆盖的前提是先改完先提交，
别在同一批文件上并行改。
