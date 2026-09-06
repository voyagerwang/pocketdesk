# PocketDesk MVP

把手机系统键盘、iPhone 听写或 Gboard 语音输入变成桌面应用的输入方式。手机只在浏览器中打开一个本地网页：选中目标应用（ChatGPT、飞书、Chrome、UU远程等，可在电脑端增删），输入整段文本，按发送后 Mac 激活应用、用 Quartz 注入 Unicode 文本，再按 Return。

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

手机页顶部「输入 / 触控板」切换。触控板作用于 Mac 当前前台应用（先用输入页或「唤醒」按钮把目标切到前台），手势经 WebSocket `ws://<主机名>.local:46388` 发送，每帧合并一条消息：

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

手机与 Mac 必须在同一 Wi-Fi，且不能处于访客网络/客户端隔离网络；若 `.local` 无法解析，用控制台给出的局域网 IP 备选地址。更新 PocketDesk 后，请在手机浏览器刷新一次页面；页面使用带版本号的脚本地址，刷新后不会继续执行旧逻辑。

## 必需权限

首次运行时 PocketDesk 会唤起 macOS 的官方授权提示。随后前往 **系统设置 → 隐私与安全性 → 辅助功能**，允许 **PocketDesk**（bundle 标识 `dev.voicedeck.app`）：

- 从终端运行时，通常授权 **终端** 或你的终端应用；
- 若把它包装成 `.app`，授权该 `.app`。

辅助功能权限是 macOS 对激活/模拟键盘事件的保护。没有它，网页会显示“需授权”，发送会被明确拒绝。

## 目标应用

默认配置 ChatGPT、飞书/Lark、Chrome、ZCode、Workbody、微信和 UU远程；这些只是首次运行的种子，实际以控制台保存的列表为准。它优先通过安装路径与 macOS bundle identifier 定位目标。图标从应用 bundle 自动提取，特殊情况下可在控制台上传自定义图标。

## 安全与已知限制

- 服务默认监听局域网，**没有配对或身份验证**；仅在受信任网络运行，切勿向公网转发 46387 端口。控制台页面拥有目标应用的管理权，与手机页共用同一端口，跨网暴露前必须先补访问令牌。
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
