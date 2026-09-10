> 最新状态（2026-09-10）：用户级原生通道已接入并安装。本机探针的字符出现/自动删除由用户确认；HTTPS/WSS 证书验证、共享租约与异常请求拒绝通过。完整密码解锁尚未验收。下文早期 VNC 预检为历史记录，不是当前安装方案。

# 日常锁屏解锁：最小验证规格

状态：用户已批准改走会话服务路线。独立原型已构建并由用户级 LaunchAgent 启动；等待用户授予原型权限并进行现场锁屏测试。原型不是生产解锁功能。系统屏幕共享路线及开启服务要求维持暂停。

最新进展：两项权限已生效，用户现场确认测试圆点出现在锁屏密码框并自动消失；本机普通用户 Aqua 会话 + 预登录标记组合下，字符输入和删除均获得人工确认。锁屏画面内容仍需独立确认，尚未完成手机端密码传输及完整解锁验收。下文等待授权记录保留为历史过程。

## 目标与边界

Mac 已登录、PocketDesk 仍运行时，用户在手机上完成密码输入，返回同一个桌面会话，原画面和控制连接恢复。首轮不覆盖注销、重启、FileVault 启动前认证，也不通过关闭锁屏或自动登录替代解锁。

原先以减少自有高权限代码为由优先选择系统屏幕共享，但没有先核对指定竞品，依据不足。当前优先验证登录会话服务；系统屏幕共享降为备选。普通 CGEvent 输入仅作为已有实现的对照；尚无证据证明它能满足锁屏输入。服务化不是自动获得全部权限，仍需验证会话、画面采集和输入能力。

## 补充：本机 UU 证据与路线修正

读取已安装 `/Applications/UURemote.app/Contents/Info.plist`：版本 4.38.0（616），bundle ID 为 `com.netease.uuremote`。

- `/Library/LaunchDaemons/com.netease.uuremote.daemon.plist` 启动 `UURemoteDaemon -daemon`，配置 RunAtLoad、KeepAlive 和 MachServices。
- `/Library/LaunchAgents/com.netease.uuremote.agent.plist` 启动 `UURemoteService -agent`，`LimitLoadToSessionType` 同时列出 `LoginWindow` 与 `Aqua`。
- 这些是客户端安装结构的直接证据，不等于已确认 UU 的密码输入 API、加密协议，或已完成手机锁屏解锁实测。不能据此宣称其一定不调用系统屏幕共享。
- [RustDesk 项目部署说明](https://github.com/rustdesk/rustdesk/wiki/macOS-Auto%E2%80%90Start-Service-Setup-%28for-Remote---MDM-Deployment%29) 同样描述启动 daemon 和覆盖 LoginWindow/Aqua 的 agent，支持将此结构作为候选进行验证。

产品目标保持：用户完成一次必要的本机安装授权，之后在原远控画面操作系统锁屏；优先不要求开启另一套网络屏幕共享服务。设计高权限部分时，网络解析留在低权限进程，特权组件只提供必要操作、校验调用方且可卸载。密码仍由系统验证，不能缓存系统密码以实现假一键解锁。具体实现和安全性待验证。

## 当前执行：预登录标记的最小对照试验

进一步用 `otool -l` 核对本机 UU 的 UURemoteService：存在 `__CGPreLoginApp/__cgpreloginapp` 段。RustDesk 的[构建配置](https://github.com/rustdesk/rustdesk/blob/master/.cargo/config.toml)也显式创建此段。仅配置 LaunchAgent 不等于已具备登录会话输入能力，所以先验证二进制标记与现有用户会话的组合。

`SessionProbe/main.swift` 是独立原型，`scripts/build-session-probe.sh` 构建并生成临时 LaunchAgent。默认 prelogin 包含标记，baseline 不包含；二者使用相同应用身份。程序拒绝 root 运行、不监听网络、不读取密码或输入控件正文、不保存画面，只保存帧状态、权限及事件发送状态。录屏权限允许它统计 ScreenCaptureKit 回调，不代表它看到了有效锁屏内容。

首轮 LaunchAgent 只运行于当前用户 Aqua 会话，这是有意缩小的实验，不声称已经复刻 UU 覆盖 LoginWindow 的完整服务。如果本轮证明不足，再验证登录窗口会话归属及高权限 helper；不将整个现有 HTTP 服务提权。

1. 原型窗口中授予屏幕录制权限；需要测试按键时再授予辅助功能。
2. 默认只观察；如用户明确勾选按键试验，必须保持电脑旁可手动恢复。
3. 点击开始后手动锁屏。45 秒内记录状态；锁屏通知、会话锁定标志、Secure Event Input 同时成立且辅助功能已授权时，只尝试一个 q，0.8 秒后在条件仍成立时尝试删除，不发回车。条件未知则不发。试验期间不要同时输入真实密码，待试验按键结束再现场解锁。
4. 现场核对是否出现测试圆点以及是否被删除；`*_sent_unverified` 只表明已调用发送，不能当成按键生效。当前试验不传送真实密码，因此不会单独完成解锁验收。
5. 对照实验前先停止并卸载当前临时 agent，再构建 baseline，重复相同动作；不能同时运行两个测试实例。

已完成检查：Swift 编译、严格签名验证、Mach-O 标记核验、plist 语法、shell 语法、diff 空白检查。已通过 launchctl 实际启动，运行 UID 为 501，界面自动化读到原型窗口；启动报告显示辅助功能与录屏权限均为 false，输入事件和样本列表为空，unlockVerified=false。尚未采集锁屏状态，也未完成加密手机通道、生产 helper 或手机端解锁入口。

本次可复核产物位于 `/private/tmp/pocketdesk-session-probe.a7omSu`；启动命令及移除命令在 `RUN.txt`，报告为 `report.json`。验证后先执行 `launchctl bootout gui/501/dev.voicedeck.session-probe`，从系统隐私权限中移除独立原型，再删除该临时目录。未向 Library 安装持久 plist，未开启系统屏幕共享，未替换正式 PocketDesk。

用户反馈“开始按钮没有反应”后复核：截图两项权限均未允许，报告 phase=ready、samples 和 inputEvents 均为空。根因是 startRun 的权限 guard 仅重复原状态后返回，没有明确说明验证未启动。已改为弹出缺失权限及独立应用授权说明、写入 blocked_permissions，并明确无需在手机或 PocketDesk 输入。用户手动锁屏的描述不能代替程序发键记录，也不能据此宣布解锁能力通过。

修复验证：重新编译、验证签名并替换同一路径的原型，重新启动 LaunchAgent；真实点击开始后，界面出现“验证尚未开始”及缺失屏幕录制权限的提示，报告为 blocked_permissions，输入事件和样本仍为空。此次只验证了权限阻断反馈，未触发锁屏或按键试验。

后续权限请求根因：点击应用自身两项授权按钮仍未弹出提示。tccd 日志明确出现 `failed to find an Application URL` 及 `kLSApplicationNotFoundErr`，说明直接由 LaunchAgent 启动临时 bundle 前未完成 Launch Services 注册。不能只归因于用户授权了其他应用。已对当前 bundle 执行 `lsregister -f`，并在构建产物 RUN.txt 中补齐注册步骤；未重置或编辑 TCC 数据库。重试前电脑被手动锁定，界面工具报告无法操作；实际弹窗与授权结果仍待解锁后核对。

后续实机核对：临时目录注册后，辅助功能列表仍未显示测试程序，因此不能视为授权问题已解决。已将同一签名应用安装到 `/Users/cm/Applications/PocketDeskSessionProbe.app`，重新注册，并将临时 agent.plist 的可执行路径切到该固定位置后重启。系统添加窗口现已实际选中 PocketDeskSessionProbe，等待用户点击“打开”确认添加；此时尚未声称权限生效。清理时除临时报告目录外，还需在停止 agent、移除隐私授权后删除此独立测试 App。

录屏按钮反馈修复：系统界面已确认 PocketDeskSessionProbe 的辅助功能开关为 on，录屏开关为 off，应用已出现在两份权限列表中。requestScreen 原先丢弃请求返回值，仅重复状态；现在未获准时记录 screen_permission_pending 并跳转录屏设置，已获准时记录 granted。已重新编译、严格验证签名并更新固定安装路径；录屏开关仍需用户确认开启，不能把打开设置等同于授权完成。

## 首次真实锁屏输入结果

用户完成授权后，PID 92007、UID 501 的 prelogin 试验中观察到 locked/unlocked 通知。第 12–19 秒的会话 locked 与 secureInput 均为 true；这段采样的 complete 帧计数从 59 增至 93、blank 计数为 0。程序记录 q_sent_unverified 与 delete_sent_unverified。用户随后回复“有出现”，将 q 的送达从调用证据提升为现场观察；未明确确认删除，因此删除仍标记未验证。

此结果支持在当前用户会话内继续验证，无需先新增 root 守护服务或启用系统屏幕共享。没有 baseline 对照，不能将成功全部归因于预登录标记。complete 帧计数增长也不能证明实际捕获到了锁屏图像；需核对呈现内容，且不能把解锁后的新帧当作锁屏画面的证据。用户现场手动解锁不属于程序完成密码解锁。

后续追问获得用户明确确认：“是，自动消失了”。字符出现与删除均有现场证据。45 秒试验已自动结束，记录保留在 report.json；仍保持 unlockVerified=false，避免把测试按键等同于完整认证。

以下系统屏幕共享验证步骤是原候选路线的记录，现已暂停，不作为当前用户操作要求。

## 已核对的事实

- 当前主机 macOS 15.7.7（24G720）。
- `Server.swift` 的 `/api/screen/wake` 只调用 `caffeinate -u -t 1`；没有解锁端点。
- `Web/screen.js` 的 `ready()` 在 `screenLocked` 为真时禁止控制；密码不能走现有草稿全文同步链路。
- 沙箱内本机 TCP 5900 报 EPERM；经授权在沙箱外复测，IPv4 与 IPv6 回环均报 ECONNREFUSED。这是没有可连接服务的证据，不是“系统不支持解锁”的证据。
- 苹果说明系统屏幕共享兼容 VNC，并可限制获准访问的账户；此说明不能证明本机锁屏可控或 PocketDesk 已兼容认证协议。
- 已有锁屏字典标志及窗口层级检测曾出现可靠性疑问；不能仅用一个 `locked=false` 宣布验收通过。

## 验证顺序

1. 用户在系统设置开启屏幕共享，仅允许自己的账户。不要求启用传统 VNC 共享密码，不改变远程管理配置来强行腾出通道。
2. 运行 `python3 scripts/unlock-preflight.py`。只连接固定回环地址，读取 RFB 版本、协商标准版本、读取安全类型后断开；不选择认证类型，不读取密码、不进入桌面。
3. 按真实广播类型确定客户端兼容性。协议可达、认证成功、画面可见、输入可用分别记录，任何一级不能代表下一级通过。
4. 建立兼容客户端及受保护的手机连接后，由用户现场输入密码完成锁屏试验。密码不通过聊天、命令行参数、环境变量、剪贴板、日志、历史或草稿链路传递；未建立可信加密连接前不开放密码输入。
5. 确认返回原用户会话，画面获得新帧且能控制原桌面，才记录一次真实解锁成功；验证失败立即停止，不自动重试密码。

## 接入约束

现有手机 HTTP 页面和 WS 不能直接承担登录密码传输。后续接入前必须完成可信 HTTPS/WSS 或经验证的加密私网路径，并确认客户端到本机桥接通道全程保护凭据。配对令牌用于 PocketDesk 授权，不替代系统账户认证。

产品接入仅在真实试验通过后进行：锁屏时按需显示一个解锁入口；与普通草稿隔离，提交后清除输入，不持久化密码。断线、控制权丢失或锁屏状态变化时停止当前输入，不排队、不重放；错误密码交由系统处理，不自动尝试。

## 验收

| 场景 | 通过标准 |
| --- | --- |
| 屏幕共享未开启 | 明确报告无可用通道，不收集密码 |
| 服务只完成握手 | 报告协议可达，解锁仍标记未验证 |
| 日常锁屏 + 正确密码 | 用户现场确认回到原桌面，持续新画面和指针控制恢复 |
| 错误密码 | 保持锁屏，不自动重试，不回显或记录密码 |
| 输入期间断线/接管 | 立即停止，恢复连接后不补发旧输入 |
| 本机先解锁 | 远端停止密码输入，避免落到普通应用 |
| 重启或注销 | 明确属于本轮范围外，不以会话内测试推定支持 |

## 当前结果

2026-09-10：真实系统通道停在服务未开启阶段；尚未执行认证、锁屏、密码输入或恢复桌面的试验。预检结果不等于功能完成。未修改系统共享配置，未安装或重启 PocketDesk。

探针隔离验证通过：RFB 3.889/3.7/3.3 分片读取、零安全类型拒绝、非 RFB、未知主版本、截断、权限拒绝、连接拒绝及超时；检查只发出版本协商字节，没有认证或输入字节。`git diff --check` 通过。沙箱外运行正式探针后，两组回环地址仍为 `connection_refused`，`unlock_verified=false`。

## 资料与证据边界

- [Apple：开启或关闭屏幕共享](https://support.apple.com/en-ie/guide/mac-help/-mh11848/mac)：系统设置与 VNC 兼容性依据。
- [RFB 协议](https://github.com/rfbproto/rfbproto/blob/master/rfbproto.rst)：探针仅覆盖版本和安全类型协商。
- [RustDesk 锁屏输入问题 #11802](https://github.com/rustdesk/rustdesk/issues/11802)：一手项目中的失败报告说明需要逐机验证，不能作为本项目已失败或已成功的结论。
- 本轮未验证 UU 远程真实锁屏界面，不将上述候选方案称为 UU 同款交互。

## 正式接入与验证

- 采用已检查 UU 本机安装与 RustDesk 预登录标记的用户级候选路径；不安装 root daemon，不启用系统屏幕共享。探针能输入/删除不证明完整认证成功或标记的单独因果。
- HTTPS 46487、控制 WSS 46488、画面 WSS 46489，共享原控制租约；密码端点强制配对令牌及租约，HTTP 即使回环也拒绝。
- 30 秒一次性挑战绑定锁屏代际；逐键检查锁屏/Secure Event Input/AX/租约，接管、断线、取消、解锁失效；先完整映射键盘布局，不能映射则整段拒绝。无自动重试。
- 新应用已安装到 ~/Applications/PocketDesk.app；保留 /private/tmp/pocketdesk-before-unlock.app，正式手机验收通过后可删除。
- Swift 编译及签名检查通过；5 项隔离表单测试与现有 screen-core 回归通过；真实可信 HTTPS/WSS 握手、明文/未配对/错误租约/未锁屏拒绝通过，正式应用辅助功能权限仍有效。
- 手机仍需用户在系统中安装本机 CA 并验证安全连接；不绕过证书警告。当前没有完整密码解锁或锁屏画面内容验证证据。

补充验收：隔离浏览器工作台回归通过（等待异步旋转布局后断言）；已安装服务只读画面冒烟通过，147 帧、观测约 12fps、最大片龄 78ms，无 ACK 超时正确关闭。以上为未锁屏桌面验证，不能替代手机完整解锁。
