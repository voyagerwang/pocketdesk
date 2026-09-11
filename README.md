# PocketDesk MVP

把手机系统键盘、iPhone 听写或 Gboard 语音输入变成桌面应用的输入方式。手机只在浏览器中打开一个本地网页：选中目标应用（ChatGPT、飞书、Chrome、UU远程等，可在电脑端增删），手机输入和纠正实时展示到电脑输入框，点击发送才按 Return 提交；修订通过选区一次替换，避免逐字回删。

> 项目前身名为 Voice Deck；执行文件与 bundle 标识仍为 VoiceDeck/dev.voicedeck.app，用于保持辅助功能授权与既有配置不变。

点击任一应用卡片时，Voice Deck 会立即启动或唤醒该应用，并把窗口置于 Mac 前台；输入框仍留在手机上等待听写。发送时会再次确认目标处于前台，再注入文本。

手机首页为单页布局，无模式切换：应用 Dock、触控板卡片、文本输入区同屏。触控板收起时是一条 96px 的精简条（可直接双指滑动、点按），点"展开"变成全屏浮层获得完整控制面积，"收起"即回到输入。触控板作用于 Mac 当前前台应用；手机选中态每 3 秒跟随 Mac 前台——用鼠标点到 Dock 里某个目标应用，手机会自动选中它，前台应用不在 Dock 里则保持原选中。

## 电脑端控制台

首次运行或尚未授权时，Voice Deck 会自动用默认浏览器打开 <http://localhost:46387/console>，三步完成接入：

1. **系统授权**：显示辅助功能授权状态，一键跳转"系统设置 → 隐私与安全性 → 辅助功能"；
2. **手机扫码连接**：展示局域网地址二维码，手机扫码即打开输入面板，控制台实时显示手机在线状态（手机页面每 5 秒上报心跳）；
3. **目标应用管理**：搜索本机已安装应用（含 /Applications、/System/Applications、~/Applications）添加目标，上下调整手机面板顺序，图标自动取自应用本身，取不到时可上传自定义图片覆盖。

配置持久化在 `~/Library/Application Support/VoiceDeck/targets.json`；应用图标在 Dock 与控制台均使用仓库内生成的 `Resources/AppIcon.icns`（由 `Resources/icon-source.png` 经 `scripts/import-icon.swift` 导入产出）。

## 触控板

手机首页的触控板可展开或收起。触控板作用于 Mac 当前前台应用（先用输入页或「唤醒」按钮把目标切到前台），手势经 WebSocket `ws://<主机名>.local:46388` 发送，每帧合并一条消息：

| 手势 | 电脑端行为 |
|---|---|
| 单指移动 | 移动光标（灵敏度可在板下调） |
| 点按 | 左键单击 |
| 长按后移动 / 松手 | 左键拖动 / 抬起 |
| 双指滑动 | 滚动（自然方向：内容跟随手指；速度可调） |
| 双指点按 | 右键 |
| 双指捏合 | 页面缩放（经 Cmd+滚轮合成，Chrome 页面缩放生效） |

实现要点：采集端用 Pointer Events + `getCoalescedEvents()` 取全量采样、`touch-action:none` 防止页面抢手势；服务端 `PointerExecutor` 维护虚拟光标位置并按**所有活动显示器的包围盒**钳制（双屏可跨屏移动）；滚动用像素级 `CGEventCreateScrollWheelEvent` 并携带 began/changed/ended 滚动相位（Chrome 按触控板式直接位移处理，无逐格动画迟滞，小数残差在服务端累积）；缩放以带 `maskCommand` 修饰的滚轮事件合成。触控板会话建立时自动抬起可能残留的左键，防止断线导致的点击失灵。

> 这是 macOS 优先的本地 MVP；它不做 ASR、不采集音频、不使用云端服务。

## 架构

```text
手机浏览器 / 手机系统键盘或听写
              │ HTTP JSON（局域网）
              ▼
PocketDesk Swift helper (VoiceDeck) :46387
              │ activate → 450 ms → Unicode CGEvent → Return
              ▼
ChatGPT / 飞书 / Chrome / UU远程 …（控制台可配置）
```

传输与执行分离。`POST /api/activate` 只负责唤醒并置顶应用，`POST /api/send` 负责置顶、输入和提交。发送请求体是稳定的 `SendCommand`：

```json
{"targetId":"chatgpt","text":"帮我检查这个页面"}
```

图文发送通过 `POST /api/image` 逐张暂存；新客户端携带 `batchId/imageId/data`，提交时用 `imageBatchId/imageIds` 明确顺序，旧客户端的 `data` + `usePendingImage` 单图协议继续兼容。一次最多 8 张、单张 8MB、批次 40MB，暂存 15 分钟且进程总量不超过 80MB。桌面端先输入文字，再依次粘贴图片，最后只按一次 Return。Chrome 飞书网页多图会在每次 Cmd+V 后等待消费，并在下一张前点击一次发送开始时的鼠标位置来重建插入点；发送前请把电脑鼠标停在飞书文档、表格单元格或输入区内，PocketDesk 以当前 Chrome PID、聚焦窗口及鼠标命中的 WebArea 共同核验，不依赖 Chromium 不稳定的 AX 对象身份，地址栏、标签栏、后台窗口和其他应用均不通过。固定等待和点击不证明附件已经上传或消息已经送达，仍需实机确认。应用切走再切回或输入绑定失效后，再次发送会保留正文与附件，按当前输入位置重新绑定；暂停前已实时输入的正文只沿用、不重复注入，随后继续图片与提交动作。健康状态重复点击当前目标不会重建，避免再次追加已有正文。

Windows helper 未来只需实现同一个命令和目标解析层（例如 `SetForegroundWindow` + `SendInput`），网页不需要改变。

## 快速启动（macOS 13+）

### 直接下载安装（普通用户，Apple Silicon）

1. 打开 [Releases](https://github.com/voyagerwang/pocketdesk/releases/latest)，下载 `PocketDesk-macOS-arm64.zip`；
2. 解压得到 `PocketDesk.app`，拖入「应用程序」文件夹；
3. 首次打开：**右键点击应用 → 打开 → 再点「打开」**（应用未经过 Apple 公证，直接双击会被 Gatekeeper 拦截），之后可正常启动；
4. 启动后按电脑端控制台引导：授予辅助功能权限 → 手机扫码 → 选择目标应用。

### 从源码运行（开发者）

```bash
cd voice-deck-mvp
swiftc Sources/*.swift -o VoiceDeck -framework AppKit -framework Network -framework CoreImage
./VoiceDeck
```

### 安装为独立应用（推荐）

```bash
./scripts/install-app.sh
```

它会在临时目录构建，只安装并启动 `~/Applications/PocketDesk.app`，不会留下第二个可被 Spotlight 找到的构建副本。这样 macOS 的辅助功能授权会明确显示为 **PocketDesk**，不会归属到终端、ChatGPT 或 Codex 宿主。

本地构建使用固定 designated requirement `identifier "dev.voicedeck.app"`，避免每次更新因临时 CDHash 改变而反复丢失辅助功能授权。该策略只适合本机开发；对外分发必须改用 Apple Developer ID 签名。

本机网页：<http://localhost:46387>

### 手机连接地址（固定不变）

手机地址由这台 Mac 的 mDNS 主机名生成：`http://<LocalHostName>.local:46387`（控制台第 2 步的二维码就是这个地址）。它不随 DHCP 分配的 IP 变化，**手机保存一次即可长期使用**：iPhone 在 Safari 打开后点分享 →"添加到主屏幕"，之后像 App 一样点开，无需再次扫码。控制台同时给出当前局域网 IP 作为 `.local` 解析失败时的备选。

Voice Deck→PocketDesk 的更名不影响该地址；只有修改电脑主机名或端口才会变化。PocketDesk 同时通过 Bonjour 以 **PocketDesk** 名称发布，不占用或伪装成 Workbench 的服务。

局域网方式要求手机与 Mac 在同一 Wi-Fi，且不能处于访客网络/客户端隔离网络；若 `.local` 无法解析，用控制台给出的局域网 IP 备选地址。更新 PocketDesk 后，请在手机浏览器刷新一次页面；页面使用带版本号的脚本地址，刷新后不会继续执行旧逻辑。

### 跨网连接（Tailscale）

手机与 Mac 不在同一局域网时，在两台设备上安装 Tailscale 并登录同一账户。PocketDesk 会自动识别 Mac 的 Tailscale 私网地址，并在控制台第 2 步显示“跨网地址 · Tailscale”二维码；手机打开 Tailscale 后扫码即可。手机可以使用蜂窝网络，UU 远程等软件继续负责远端画面，PocketDesk 独立传输文字和触控板命令。

跨网地址形如 `http://100.x.y.z:46387`，只在同一 Tailscale 私网内可达。HTTP 写请求和 `:46388` WebSocket 仍使用二维码携带的 PocketDesk 配对 token 鉴权；不要把这些端口直接暴露到公网。

## 必需权限

首次运行时 PocketDesk 会唤起 macOS 的官方授权提示。随后前往 **系统设置 → 隐私与安全性 → 辅助功能**，允许 **PocketDesk**（bundle 标识 `dev.voicedeck.app`）：

- 从终端运行时，通常授权 **终端** 或你的终端应用；
- 若把它包装成 `.app`，授权该 `.app`。

辅助功能权限是 macOS 对激活/模拟键盘事件的保护。没有它，网页会显示“需授权”，发送会被明确拒绝。

## 目标应用

默认配置 ChatGPT、飞书/Lark、Chrome、ZCode、Workbody、微信和 UU远程；这些只是首次运行的种子，实际以控制台保存的列表为准。它优先通过安装路径与 macOS bundle identifier 定位目标。图标从应用 bundle 自动提取，特殊情况下可在控制台上传自定义图标。

## 安全与已知限制

- **配对鉴权**：写操作（发送、激活、快捷键、目标与配置管理）要求配对 token。token 首次启动时生成并持久化在 `~/Library/Application Support/VoiceDeck/token`，通过控制台二维码单向分发——手机扫码 URL 即携带 token，之后写请求带 `Authorization: Bearer` 头、触控板 WebSocket 首帧握手校验（恒定时间比较防计时侧信道）。Mac 本机（localhost 控制台）豁免。局域网内未配对设备无法注入输入或控制指针。
- 应用启动/切换使用固定 450 ms 等待；冷启动非常慢时，文字可能先于焦点到达。下一版可为每个应用提供可配置延迟或前台确认。
- CGEvent 不能可靠地输入到安全输入框、macOS 登录界面、部分沙盒/提权窗口；Windows 也会受到 UIPI 限制。
- 输入会直接提交 Return；适用于聊天/命令输入框，不适合希望保留换行的场景。网页中可用 Shift+Enter 保留换行。
- 某些编辑器可能按自身逻辑处理 Unicode 合成事件；Codex、ChatGPT、飞书、Chrome 应优先在各自普通文本框中实测。

## 开源参考与许可证

架构参考 [joonlab/MacPilot](https://github.com/joonlab/MacPilot)：它使用本地 HTTP/WebSocket、手机 Web 客户端、Quartz `CGEvent` Unicode 注入，并提供 macOS/Windows helper 思路。其许可证为 MIT（© 2026 Park Joon / JoonLab）。

本仓库为独立、从零实现，未复制 MacPilot 源码；本仓库同样采用 [MIT License](LICENSE)。

## 品牌图标构建

白色 P 与口袋开口表达“把桌面控制装进口袋”；P 下端融合鼠标指针，内部的单个简化显示器明确桌面含义，保留第一版蓝紫底板。原版保留在 `Resources/icon-source-original.png`。

```bash
swift scripts/import-icon.swift Resources/icon-source.png Resources/AppIcon.iconset
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
```

导入器为蓝色底板提取边界，生成透明圆角与统一边距；10 张 PNG 按实际像素输出，包含 1024px 的 512@2x。安装脚本直接使用已生成的 icns。

## 查看电脑与全屏工作台（实验版）

点发送栏「画面」先打开可拖动、缩放的浮窗，再点「全屏」进入工作台。竖屏工具栏在底部，横屏在右侧；按钮和输入区保持正向。返回先收起菜单或键盘，再退回浮窗；关闭画面回到首页，保留草稿。

- **触屏模式（默认）**：点哪里操作哪里，单指滑动滚动，双指缩放/平移本地画面，长按后选择此处右键或拖动。
- **指针模式**：单指移动鼠标，轻点单击，双指滚动，长按拖动，双指轻点右键。
- **键盘**：先点电脑输入位置，再点工具栏键盘。手机显示可编辑草稿、目标应用、换行和发送按钮；输入位置或控制权变化会停下并保留草稿。点画面只收起键盘，这一下不点击电脑。
- **更多**：切换显示器、画质、适应画面、调整视野、仅观看、接管控制和已配置快捷键。仅观看仍可调整本地视野。

画面需要 macOS 14+ 和屏幕录制权限。全屏优先持续 JPEG（默认宽度 1280，目标 30fps，可选 1920）；这不是已经实测保证的帧率。慢网络或捕获失败自动回退单帧截图。画面过期时暂停输入，避免对旧画面操作；隐藏网页或关闭查看器停止捕获订阅。

服务端默认使用三个端口：HTTP `46387`、控制/光标 WS `46388`、画面 WS `46389`；自定义 HTTP 端口时另两条通道跟随 +1/+2。跨网私网连接需同时允许这些端口。画面通道使用独立连接，避免 JPEG 大包挤占鼠标操作。

控制与画面均沿用配对 token（本机回环豁免）。新控制会话带 session/seq，2 秒未收到心跳会释放控制；第二个客户端先观看，可显式接管。全屏输入先用 `GET /api/input-context` 取得上下文，再携带 context/session 调用 `/api/live-input`，执行前校验。无法识别具体 AX 输入框的应用只绑定应用，界面会提示确认电脑输入框；同应用内切换这类编辑器仍需人工确认。

`GET /api/screen/displays` 返回显示器与画面端口；`GET /api/screen/frame?display=<id>` 保留截图降级；`POST /api/screen/permission` 请求 Mac 原生授权。持续画面不落盘，最后观看者退出后停止采集。配对鉴权不等于加密，局域网 HTTP/WS 或既有 Tailscale 私网使用方式不变。

首版已通过 Swift 构建、纯逻辑测试与模拟浏览器回归；iPhone Safari、Android 输入法、Retina/多屏和实际延迟仍需真机验证。操作验收与执行细节见 [FULLSCREEN_IMPLEMENTATION.md](FULLSCREEN_IMPLEMENTATION.md)。

## 语音纠正无回删（2026-09-09）

通用应用恢复实时显示：追加文字立即输入，前文纠正时选中本轮需要改写的旧尾部，一次写入新结果，不逐字退格。点击发送只提交已输入的文本。长文本和换行使用剪贴板一次粘贴，短追加沿用 Unicode 注入；主动删除文字时一次删除选区。

AX 能读到文本和选区时，校验输入框原有前后文和光标；选区可写则直接定位，否则使用 Shift+Left 选择本轮文本。读不到 AX 的应用沿用输入位置绑定和有序键流，无法自动确认同应用内光标被人移动或正文被手动修改，使用中需保持电脑输入位置。回执为 `sent`，不声称内容已读回。TextEdit 空白 `.txt` 仍有整值替换通道；UU 特殊远控通道仍在发送时一次粘贴。

`/api/live-input` 使用 `draftId/text/submit/usePendingImage/expectedMode`，全屏仍携带 `context/session`。回执 `mode=replace|selection|deferred`，`outcome=buffered` 仅用于暂存；`committed=true` 表示提交动作已执行，不代表外部消息送达。近期同 ID 同文提交在当前进程内去重，失败后暂停避免重复输入。详情见 [LIVE_INPUT_REVISION.md](LIVE_INPUT_REVISION.md)。

## 锁屏解锁（本机验证阶段）

运行 `zsh scripts/setup-secure-channel.sh` 生成本机 TLS 身份，重启应用后控制台显示 HTTPS 二维码。手机安装 CA 有两条路：在控制台第 2 步点「下载 PocketDesk 证书」，或直接在手机浏览器打开 `http://<电脑IP>:46387/PocketDesk-CA.cer`（HTTP 即可取，无需先信任证书）；在系统证书设置中安装为 CA（iOS 还需在「证书信任设置」中显式启用），再扫描安全连接码。手机端「手机设置 → 翻腕发送」在检测到明文地址时会直接给出可点击的「① 安装 PocketDesk 证书 / ② 在安全地址打开」，不需要手抄地址。不得跳过浏览器证书警告；IP 更换或证书过期需要重新签发，脚本不会覆盖已有身份。

电脑锁屏后，手机画面中出现独立密码框；输入电脑登录密码并提交。密码不进入普通编辑器、历史、日志或剪贴板，提交立即清空；仅已配对的 HTTPS 控制者可提交，一次性挑战绑定当前会话，断线/接管/退出取消且不自动重试。客户端和服务端处理期间仍存在短暂内存副本，不承诺内存安全擦除。

当前只支持已登录用户的锁屏，不支持开机 FileVault 解密。只能发送当前键盘布局可映射的字符；输入前整段检查，无法映射则拒绝。已验证独立探针在系统密码框输入并删除一个字符，正式端完整密码解锁仍待实机验收；持续帧计数不等于锁屏画面内容已验证。
