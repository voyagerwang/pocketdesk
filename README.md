# Voice Deck MVP

把手机系统键盘、iPhone 听写或 Gboard 语音输入变成桌面应用的输入方式。手机只在浏览器中打开一个本地网页：选中 Codex、ChatGPT、飞书或 Chrome，输入整段文本，按发送后 Mac 激活应用、用 Quartz 注入 Unicode 文本，再按 Return。

点击任一应用卡片时，Voice Deck 会立即启动或唤醒该应用，并把窗口置于 Mac 前台；输入框仍留在手机上等待听写。发送时会再次确认目标处于前台，再注入文本。

手机首页以单行原生应用图标呈现目标，支持左右滑动；长按图标约 0.45 秒后拖动即可排序，顺序保存在当前手机浏览器中。

> 这是 macOS 优先的本地 MVP；它不做 ASR、不采集音频、不使用云端服务。

## 架构

```text
手机浏览器 / 手机系统键盘或听写
              │ HTTP JSON（局域网）
              ▼
VoiceDeck Swift helper :46387
              │ activate → 450 ms → Unicode CGEvent → Return
              ▼
Codex / ChatGPT / 飞书 / Chrome
```

传输与执行分离。`POST /api/activate` 只负责唤醒并置顶应用，`POST /api/send` 负责置顶、输入和提交。发送请求体是稳定的 `SendCommand`：

```json
{"targetId":"codex","text":"帮我检查这个页面"}
```

Windows helper 未来只需实现同一个命令和目标解析层（例如 `SetForegroundWindow` + `SendInput`），网页不需要改变。

## 快速启动（macOS 13+）

```bash
cd voice-deck-mvp
swiftc Sources/main.swift -o VoiceDeck -framework AppKit -framework Network
./VoiceDeck
```

### 安装为独立应用（推荐）

```bash
./scripts/install-app.sh
```

它会在临时目录构建，只安装并启动 `~/Applications/Voice Deck.app`，不会留下第二个可被 Spotlight 找到的构建副本。这样 macOS 的辅助功能授权会明确显示为 **Voice Deck**，不会归属到终端、ChatGPT 或 Codex 宿主。

本机网页：<http://localhost:46387>

更新 Voice Deck 后，请在手机浏览器刷新一次页面；页面使用带版本号的脚本地址，刷新后不会继续执行旧的点击逻辑。

手机使用字母主机名访问：`http://<这台Mac的LocalHostName>.local:46387`。例如本机的 LocalHostName 是 `YZdeMacBook-Air` 时，手机地址是 `http://YZdeMacBook-Air.local:46387`。Voice Deck 同时通过 Bonjour 以 **Voice Deck** 名称发布，不占用或伪装成 Workbench 的服务。

标准浏览器的 HTTP 地址必须携带端口，除非服务使用受 macOS 保护的 80 端口（需要管理员权限，且容易与其他产品冲突）。因此这个 MVP 保留独占的 `46387` 端口，而不使用 Workbench 的端口；用户无需记忆数字 IP。

需要查看本机字母主机名时运行：

```bash
scutil --get LocalHostName
```

手机与 Mac 必须在同一 Wi-Fi，且不能处于访客网络/客户端隔离网络。若同一网络无法解析 `.local`，再以局域网 IP 作为排障备用方案。

## 必需权限

首次运行时 Voice Deck 会唤起 macOS 的官方授权提示。随后前往 **系统设置 → 隐私与安全性 → 辅助功能**，允许运行 `VoiceDeck` 的宿主：

- 从终端运行时，通常授权 **终端** 或你的终端应用；
- 若把它包装成 `.app`，授权该 `.app`。

辅助功能权限是 macOS 对激活/模拟键盘事件的保护。没有它，网页会显示“需授权”，发送会被明确拒绝。

## 目标应用

MVP 已配置 Codex、ChatGPT、飞书/Lark、Chrome、ZCode、Workbody 和微信。它优先通过正在运行的应用名与 macOS bundle identifier 定位目标，安装路径只作为兜底。当前 Codex 桌面端虽然位于 `/Applications/ChatGPT.app`，系统标识实际是 `com.openai.codex`，Voice Deck 已兼容这种名称差异；微信使用本机确认过的 `com.tencent.xinWeChat`。

本机已检测到 Codex/ChatGPT、Lark、Chrome 和 ZCode；当前尚未检测到 Workbody。Workbody 启动后若系统显示名为 `Workbody`/`WorkBody`，Voice Deck 会直接识别；也预留了 `/Applications/Workbody.app` 路径。

## 安全与已知限制

- 服务默认监听局域网，**没有配对或身份验证**；仅在受信任网络运行，切勿向公网转发 46387 端口。
- 应用启动/切换使用固定 450 ms 等待；冷启动非常慢时，文字可能先于焦点到达。下一版可为每个应用提供可配置延迟或前台确认。
- CGEvent 不能可靠地输入到安全输入框、macOS 登录界面、部分沙盒/提权窗口；Windows 也会受到 UIPI 限制。
- 输入会直接提交 Return；适用于聊天/命令输入框，不适合希望保留换行的场景。网页中可用 Shift+Enter 保留换行。
- 某些编辑器可能按自身逻辑处理 Unicode 合成事件；Codex、ChatGPT、飞书、Chrome 应优先在各自普通文本框中实测。

## 开源参考与许可证

架构参考 [joonlab/MacPilot](https://github.com/joonlab/MacPilot)：它使用本地 HTTP/WebSocket、手机 Web 客户端、Quartz `CGEvent` Unicode 注入，并提供 macOS/Windows helper 思路。其许可证为 MIT（© 2026 Park Joon / JoonLab）。

本仓库为独立、从零实现，未复制 MacPilot 源码；本仓库同样采用 [MIT License](LICENSE)。
