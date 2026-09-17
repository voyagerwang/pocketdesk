# GitHub 语音项目调研：TTS 音色 + Agent 直接对话

> 调研日期：2026-09-18。所有 star / license / 更新时间均通过 GitHub API 实拉，非估算。
> 目的：给 PocketDesk 小精灵（Swift macOS 桌面助手）找可直接抄的语音项目参考。

## 0. 一句话结论

- **要「能直接对话 + 音色好」的成品参考** → 抄 `cursorvoice/cursor-voice`（Swift，OpenAI Realtime，几乎就是小精灵的语音版）。
- **要开源可商用的好音色 TTS** → `resemble-ai/chatterbox`（MIT）和 `boson-ai/higgs-audio`（Apache-2.0）最贴「对话感 Agent」；中文最佳是 `QwenAudio/CosyVoice`（Apache-2.0）。
- **要本地/离线嵌进 Swift** → `k2-fsa/sherpa-onnx`（C++ 有 Swift 绑定，macOS 全离线一站式）+ `FluidInference/FluidAudio`（Swift 原生 Parakeet ASR）。
- **要框架编排 Agent 语音** → `pipecat-ai/pipecat`（40+ 集成）或 `livekit/agents`（有 Swift starter）。

---

## 1. ⭐ 最值得抄：和 PocketDesk 几乎同构的 macOS 语音助手

### `cursorvoice/cursor-voice` — ★21 · MIT · Swift · pushed 2026-06-10

**为什么它最对口**：原生 macOS 语音助手，在光标旁浮一个球，按热键说话，能看屏幕、驱动 Mac、回答回来。**和 PocketDesk 的构建方式、能力栈几乎逐条对齐。**

| 它用的 | PocketDesk 现状 |
|---|---|
| 纯 Swift 源码 `Sources/`，**`swiftc` 裸编**，无 Xcode project | ✅ 完全一致（`swiftc Sources/*.swift`） |
| OpenAI Realtime `wss://api.openai.com/v1/realtime`（URLSessionWebSocketTask） | 现在是 chat/completions，可平滑加 |
| `AVAudioEngine` 采集 24kHz PCM16，`AVAudioPlayerNode` 播放 | 需新增 |
| **barge-in 打断**：`response.cancel` + `conversation.item.truncate` | 现无 |
| `ScreenCaptureKit` 看屏幕 | ✅ 已有 ScreenStream/CursorMonitor |
| `CGEvent` 合成鼠标键盘 + AXTree 按名字点元素 | ✅ 已有 PointerExecutor/InputExecutor |
| AppleScript + Shell 执行 | ✅ 已有 |
| **Carbon `RegisterEventHotKey`** 全局热键 | ✅ 已在用 Carbon 框架 |
| 唤醒词 `SFSpeechRecognizer`（**on-device**，"Hey Cursor"） | 需新增 |
| 菜单栏球 UI（SwiftUI NSPanel，audio-reactive 动画） | ✅ 正在做小精灵情绪球 |
| API Key 存 Keychain；沙盒关闭 | ✅ 一致 |
| Apple Silicon only, arm64-apple-macos14.0 | ✅ |

**模型可选**：`gpt-realtime`（默认）/ `gpt-realtime-2`（推理，慢）/ `gpt-realtime-1.5`（**音色最好**）/ `gpt-realtime-mini`（便宜快）/ `gpt-realtime-translate`。

**坑（它自己写明）**：App Sandbox 必须关（shell/AppleScript/CGEvent 需要）；ad-hoc 签名未公证，首次启动要右键打开或 `xattr -dr com.apple.quarantine`；授予屏幕录制/辅助功能权限后**必须重启进程**才生效。

> 判断：star 只有 21，但**场景 100% 对口、代码组织可读、MIT 可抄**。它是「路线 2：可打断自然对话」的最佳实现模板。

### `ykdojo/super-voice-assistant` — ★214 · Swift · pushed 2026-08-20

**本地优先 + 云端可选**的 macOS 语音助手，热键范式成熟，值得抄交互与「本地/云端切换」设计。

- ASR 本地：**WhisperKit** 或 **FluidAudio Parakeet**（Parakeet v2 ~110x realtime / 1.69% WER；v3 ~210x realtime / 1.8% WER / 25 语言）
- ASR 云端：Gemini；TTS：**Gemini Live** 流式，智能断句
- 热键：Cmd+Opt+Z（本地转写）/ X（云端）/ S（朗读选中文本）/ C（屏幕录制转写）/ A（历史）/ V（粘贴）
- 权限三件套：麦克风、辅助功能（全局热键+自动粘贴）、屏幕录制
- Keychain 存 key：`security add-generic-password -U -s gemini-api-key -a "$USER" -w KEY`
- `config.json` 文本替换纠正识别错（如 "Cloud Code"→"Claude Code"）

> 判断：这是「路线 1：push-to-talk 本地优先」的最佳交互模板。它的 `config.json` 纠错机制可直接复用到 PocketDesk 的术语/应用名纠正。

---

## 2. TTS：音色好的开源模型（重点关注「对话感」+ 可商用）

| 项目 | ★ | License | 最后更新 | 定位 | 对 Pocket 的可用性 |
|---|---|---|---|---|---|
| `fishaudio/fish-speech` | 32727 | ⚠️ **NOASSERTION**（Fish Audio Research License） | 2026-09-16 | SOTA 多语 TTS，S2 Pro 4B | 音色顶级但**授权非标准**，商用须确认 |
| `resemble-ai/chatterbox` | 26456 | **MIT** | 2026-07-21 | 对话感 TTS，5 秒克隆 | ✅ **最推荐**：可商用、对话感强 |
| `QwenAudio/CosyVoice` | 23661 | **Apache-2.0** | 2026-05-25 | 中文最佳，18+ 方言，150ms 流式 | ✅ **中文首选**，可商用 |
| `nari-labs/dia` | 19399 | **Apache-2.0** | 2025-11-19 | 一次生成超真实**多角色对话** | ✅ 多角色对话场景 |
| `boson-ai/higgs-audio` | 8352 | **Apache-2.0** | 2026-06-05 | **情感表达最强**，多角色对话 | ✅ **最适合「有灵魂的 Agent 声音」** |
| `hexgrad/kokoro` | 8877 | **Apache-2.0** | 2025-08-06 | 82M 小模型，**CPU 可跑** | ✅ 本地兜底/低配，中文 MOS 3.9 一般 |
| `2noise/ChatTTS` | 39848 | — | 2026-04-10 | 中文对话感（停顿/笑声/插话） | 一致性一般，偏实验 |
| `OpenBMB/VoxCPM` | 37736 | — | 2026-09-02 | VoxCPM2 无 tokenizer TTS | 新，多语+克隆 |
| `RVC-Boss/GPT-SoVITS` | 61868 | MIT | 2026-08-18 | 1 分钟数据克隆音色 | 克隆强，偏音色复刻 |
| `myshell-ai/OpenVoice` | 37554 | MIT | 2025-04-19 | 零样本跨语种克隆 | 更像能力模块 |
| `index-tts/index-tts` | 24039 | — | 2026-08-18 | 时长精确控制、情感解耦 | 配音向 |
| `KittenML/KittenTTS` | 15464 | — | 2026-08-19 | **<25MB** 超小 | 端侧/嵌入备选 |
| `k2-fsa/sherpa-onnx` | 14827 | **Apache-2.0** | 2026-09-17 | C++ 全离线 ASR+TTS+VAD+KWS | ✅ **Swift/macOS 可嵌**（见下） |

**Fish Audio S2 Pro 实测指标**（README 官方）：Seed-TTS Eval 中文 WER **0.54%**（全场最佳）、英文 0.99%；Audio Turing Test 0.515；EmergentTTS-Eval 胜率 81.88%；支持 **15,000+ 自然语言情感标签**（`[whisper]` `[excited]` `[angry]` `[laughing]`…）；**原生多说话人（`<|speaker:i|>`）+ 多轮对话生成**；SGLang 下 TTFA ~100ms。
→ 音色和「对话」能力确实最强，但 **4B 模型 + 授权非标准开源**，直接商用有法律风险。

**音色排名参考**（Artificial Analysis Speech Arena 2026 Q3，Elo）：ElevenLabs Turbo v2.5 1350 > Zonos2 8B 1320 > CosyVoice 3 1280 > Fish Speech 1.6 1260 > Chatterbox Turbo 1240 > Step Audio EditX 1230 > Kokoro 1150。开闭源差距已从 223 分缩到 ~81 分。

---

## 3. 让 Agent「直接对话」的框架

| 项目 | ★ | License | 更新 | 特点 | 备注 |
|---|---|---|---|---|---|
| `pipecat-ai/pipecat` | 15620 | BSD-2-Clause | 2026-09-17 | 40+ 服务集成，**有 Swift client SDK**，2026-04 发 v1.0 | 集成最广，Python 编排 |
| `livekit/agents` | 14239 | Apache-2.0 | 2026-09-17 | 生产级，语义 turn detection，原生 SIP | 有 `agent-starter-swift`(★96) |
| `huggingface/speech-to-speech` | 13259 | Apache-2.0 | 2026-09-06 | 纯开源模型搭 voice agent | 全本地路线参考 |
| `TEN-framework/ten-framework` | 11133 | NOASSERTION | 2026-09-17 | C++ 核心低延迟，图编排，可 C++/Go/Python 扩展 | 重：需 Docker + Agora |
| `pydantic/pydantic-ai` | 20010 | — | 2026-09-17 | 含 realtime voice | 通用 Agent 框架 |
| `KoljaB/RealtimeSTT` | 10136 | — | 2026-08-30 | 低延迟 STT + VAD + **唤醒词** | Python 组件，可直接拿 |
| `KoljaB/RealtimeTTS` | 4030 | — | 2026-08-31 | 实时 TTS | 配 RealtimeSTT 用 |
| `katipally/openlive` | 300 | — | 2026-08-27 | 端侧 voice+vision，**完整 VAD/STT/TTS/barge-in 循环** | 小但思路对 |
| `moonshine-ai/moonshine` | 11101 | — | 2026-08-31 | 超低延迟 STT+意图+TTS，为 voice agent 设计 | C++ |
| `FluxInference/FluidAudio` | 2772 | Apache-2.0 | 2026-09-14 | **Swift 原生 Parakeet**，Apple Silicon | ✅ ASR 本地首选 |

---

## 4. 给 PocketDesk 的三条落地路线（按推荐顺序）

### 路线 1：本地优先 push-to-talk（先做这个）
- ASR：**FluidAudio Parakeet**（Swift 原生，210x realtime）或 WhisperKit
- TTS：`sherpa-onnx`（C++/Swift，macOS 离线，Kokoro/Matcha 含中文）兜底 → 音质升级再换本地小模型或云端
- 交互：Carbon 全局热键，沿用架构「不做常驻唤醒」
- **抄**：`ykdojo/super-voice-assistant` 的热键范式 + `config.json` 术语纠错
- 优点：音频不出 Mac、零语音费、离线、复用现有 Agent；缺点：中文 TTS 自然度一般

### 路线 2：可打断的自然对话（想让小精灵「像人」）
- 直接抄 `cursorvoice/cursor-voice` 的 Realtime 客户端：`AVAudioEngine` 24kHz PCM16 → WebSocket → `AVAudioPlayerNode`，barge-in 用 `response.cancel` + `conversation.item.truncate`
- 唤醒词：`SFSpeechRecognizer`（on-device，音频不匹配不外发）
- 成本 ~$0.30/min，音频上云，需改造 usage ledger（现按 token 分项）

### 路线 3：最好中文音色 + 私有部署
- TTS：`QwenAudio/CosyVoice`（Apache-2.0，中文+方言，150ms 流式）跑本地/私有 sidecar，Swift 走 HTTP 调
- 或 `boson-ai/higgs-audio`（Apache-2.0，情感/多角色对话最强）做「有性格的小精灵」
- 编排若要多供应商可换：上 `pipecat`（有 Swift SDK）

## 5. 风险与提醒
- ⚠️ **`fishaudio/fish-speech` license 是 NOASSERTION（Fish Audio Research License）**，不是 Apache/MIT。README 明写会对违规采取措施。音色最好但**商用前必须书面确认授权**，否则改用 CosyVoice(Apache-2.0) / Chatterbox(MIT)。
- `coqui-ai/TTS`（★46022）最后更新 2024-08，已事实停更；`Zyphra/Zonos` 停更于 2025-03；`rhasspy/piper` 已归档。**别用这些当新项目底座。**
- Realtime 方案把语音+模型打包按分钟计费，与 Pocket 现有「LLM 按 token、语音另计」口径冲突，需改造 usage ledger（见上一份 `voice-solution-research.md`）。
- 本地大模型（4B 级）在 Mac 上不现实，Mac 本地只跑得动 Kokoro(82M)/KittenTTS(<25MB)/Parakeet 这类小模型。
