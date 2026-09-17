# PocketDesk 小精灵语音能力方案调研

> 目标：给运行在 Mac 上的桌面助手「小精灵」对接语音能力，给出可选方案对比与推荐。
> 调研日期：2026-09-18。价格/延迟为 2026 年 9 月公开快照，选型前以厂商最新页为准。

## 0. 约束（来自现有架构，决定选型边界）

- **Mac 是执行端**：负责工具调用、凭证访问、本地执行；模型只做理解与规划，不能直接操作电脑（见 `ModelClient.swift` / `AGENT_PRODUCT_ARCHITECTURE.md`）。
- **Agent 大脑已存在且可插拔**：走 OpenAI 兼容的 `/chat/completions`，支持 `tool_calls`。语音应是「套在文本 Agent 外的一层 I/O」，不是推翻重做。
- **隐私原则**：架构明确「原始音频首版不收集」，且 Mac 端凭证不写日志。本地处理天然契合。
- **成本分项**：架构要求「语音识别、模型、搜索等费用分别列出」。本地方案语音费 = 0，只计 LLM token；云端按分钟另计，需改造 usage ledger。
- **首版交互模型**：架构原定「手机键盘语音输入，独立 ASR 与常听唤醒不属于首版」。桌面小精灵的语音是后续能力，建议**先 push-to-talk 热键**，不做常驻唤醒词。
- **语言**：中文用户，macOS 平台。

## 1. 语音能力四层

| 层 | 作用 | Pocket 是否必须 |
|---|---|---|
| ASR（语音→文本） | 听懂用户说话 | 必须 |
| TTS（文本→语音） | 小精灵开口 | 可选（先文字反馈也行） |
| Realtime（语音↔语音全双工） | 可打断的自然对话 | 进阶 |
| Wake / VAD（唤醒词 / 语音活动检测） | 何时开始听 | 首版用热键即可，不必常驻 |

## 2. ASR（语音转写）方案对比

| 方案 | 部署 | 中文 | 延迟 | 价格（2026-09） | 备注 |
|---|---|---|---|---|---|
| **Apple SpeechAnalyzer**（macOS 原生） | 本机 | 待验证（支持多语） | 低 | 免费 | WWDC25 起全离线，长音频优化，官方称比 Whisper Turbo 快 ~2.2x；中文准确性需实测 |
| **mlx-whisper**（Apple Silicon） | 本机 | 好（100+ 语含中文） | 中（turbo 5–8x 加速） | 免费 | 开源，Apple Silicon 优化；large-v3 / turbo 可选，占内存 |
| whisper.cpp（GGML） | 本机 | 好 | 中 | 免费 | 最成熟本地方案，但多为文件转写，实时性差 |
| **OpenAI gpt-4o-transcribe** | 云 | 好（100 语） | ~1s（非实时） | $0.003/min（最便宜档） | 中文好但延迟偏高，非流式 |
| **Deepgram Nova-3** | 云 | 中（36 语） | 流式 sub-250ms | $0.0043/min 批 / $0.0077 流式 | 实时流式最强，但中文覆盖弱 |
| ElevenLabs Scribe v2 | 云 | 好（99 语） | 异步最高准 | ~$0.22+/hr | 异步转写准度第一，不适合实时 |
| Azure / Google Chirp / Speechmatics | 云 | 好 | 300ms 级 | $0.016–0.024/min | 企业合规强，中文可用 |

**结论**：Mac 本地优先选 `mlx-whisper`（中文稳、开源、Apple Silicon 加速）或 `Apple SpeechAnalyzer`（零依赖、最省电，中文待验证）。要实时流式且不在乎上云再选 Deepgram/OpenAI。

## 3. TTS（语音合成）方案对比

| 方案 | 部署 | 中文自然度 | 延迟 | 价格 | 备注 |
|---|---|---|---|---|---|
| **火山引擎 TTS（字节）** | 云（国内直连） | 9.2/10 | 首包 300–400ms | 1.3 元/千字，有试用 | 中文最佳之一，支持 SSML/流式/5 秒克隆，国内无代理 |
| **Fish Audio / CosyVoice** | 云+开源 | 9.5 / 8.8 | 低 | 免费/开源档 | 中文多音字处理最强，CosyVoice 为阿里开源 |
| ElevenLabs | 云（需代理） | 8.8（英文 9.8） | 450ms+ | 2.1 元/千字 | 英文天花板，中文需代理，贵 |
| Azure TTS | 云 | 8.5 | ~120ms（最低） | 50 万字符/月免费 | 700+ 音色、低延迟、企业稳 |
| OpenAI TTS | 云（需代理） | 7.5（弱） | 400ms+ | 0.10 元/千字 | 代码极简，中文不推荐 |
| **ChatTTS / mlx-audio** | 本机 | 对话式好（MOS 4.5+） | 中 | 免费 | 开源、口语化、隐私；占算力 |

**结论**：中文体验优先 → 火山引擎（国内直连、便宜、质量高）。隐私优先 → 本地 ChatTTS / mlx-audio。系统自带 `AVSpeechSynthesizer` 可作零成本兜底（自然度一般）。

## 4. Realtime 全双工对话对比（进阶）

| 方案 | 架构 | p50 延迟 | 价格/min | 中文 | 函数调用 |
|---|---|---|---|---|---|
| **OpenAI Realtime API** | 半双工（音频直出） | ~420ms | ~$0.30（含模型） | 50+ 语 | 原生 function calling |
| **Gemini Live**（3.8/2.0 Flash） | 原生多模态 | ~130–200ms | $0.012–0.024 | 支持 | 支持（含视频/屏幕） |
| ElevenLabs Conversational | 管线（STT→LLM→TTS） | ~350ms | ~$0.05–0.12 | 30+ 语 | 支持 |
| Seeduplex | 全双工 | ~200ms | $0.008 | EN+ZH（早期） | 支持 |

**注意**：Realtime 把「语音 + 模型」打包按分钟计费，与 Pocket 现有「LLM 按 token、语音另计」的 usage ledger 不同，需改造计费口径；且音频必上云，隐私最弱。

## 5. 三档推荐方案

### 方案 A — 本地优先（推荐作为首条落地路径）
- ASR：mlx-whisper 或 Apple SpeechAnalyzer（全离线）
- TTS：本地 ChatTTS / mlx-audio，或系统 TTS 兜底
- 交互：push-to-talk 热键（⌘/Option + Space）
- 管线：`麦克风 → 本地 ASR → 文本 → 现有 Agent(/chat/completions+tool_calls) → 文本 → 本地 TTS → 扬声器`
- **优点**：音频不出 Mac（契合隐私）、语音费 ¥0、离线可用、复用现有 Agent、零网络延迟
- **缺点**：中文 TTS 自然度一般；本地模型占内存/算力；Apple SpeechAnalyzer 中文待验

### 方案 B — 云端高质量（中文体验优先）
- ASR：OpenAI gpt-4o-transcribe 或 Deepgram（实时）
- TTS：火山引擎（国内直连）或 Fish Audio / CosyVoice
- 交互：热键，或 Porcupine 唤醒词
- **优点**：中文识别/合成质量高、延迟可控、开发快
- **缺点**：音频上云、按分钟计费、部分需代理（火山/Fish 国内直连无此问题）

### 方案 C — 实时全双工（premium，可打断）
- OpenAI Realtime（与现有 OpenAI 栈契合，原生 function calling）或 Gemini Live（延迟更低、含屏幕/视频）
- **优点**：接近真人、可打断、直接复用工具调用
- **缺点**：最贵（$0.30/min OpenAI）、音频上云、需重写对话管理（现有是轮次 chat/completions）

## 6. 最终推荐与落地路径

1. **先做方案 A 的「语音 I/O 层」**：本地 ASR（mlx-whisper）+ 本地/系统 TTS，套在现有文本 Agent 外。最快出可用原型、零边际成本、隐私合规、不动 Agent 核心。最符合 PocketDesk「Mac 端执行、音频不收集、成本分项」的设计原则。
2. **中文 TTS 不够自然时**，单点替换为火山引擎（国内直连、质量高、便宜）→ 形成「混合方案」，性价比甜点。ASR 仍本地。
3. **要做可打断自然对话且接受成本/隐私权衡时**，再上方案 C；优先 OpenAI Realtime（现有即 OpenAI 兼容，迁移最低），或 Gemini Live（取延迟与多模态）。

**Wake / VAD**：首版用热键（与 OpenWhisper 的 Option+Space 一致），避免常驻监听的隐私/功耗问题；确需「随时喊」再接 Porcupine（Picovoice）唤醒词 + WebRTC / Apple SpeechDetector VAD。

## 7. 风险与待验证项
- Apple SpeechAnalyzer 中文离线准确率（需真实录音测）。
- 本地大模型在用户 Mac 上的内存/算力占用与续航。
- 火山引擎 / Fish Audio 的中文克隆音色授权与商用条款。
- Realtime 方案对现有 usage ledger（分开计费）的改造量。
- 国内访问 OpenAI/ElevenLabs 需代理，火山/Fish 国内直连无此问题——落地前确认部署区域。

## 8. 数据来源
- ASR 基准：novascribe.ai / futureagi.com / mixpeek.com / aivoicereview.com（2026-07～09 基准）
- TTS 对比：ai-nav-build.com / freeaitool.com / developer.volcengine.com（火山引擎实测）
- Realtime：samcomtechnologies.com / tokenmix.ai / seeduplex.io / dev.to（Gemini 3.8 Live）
- 本地方案：oatmealapp.com / voicekeyboardpro.com / freevoicereader.com / github.com/Ionmi/OpenWhisper
