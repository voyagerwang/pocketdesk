# PocketDesk MVP - 手机语音输入到桌面应用的本地与私网桥接器
Swift + Network + Quartz Event Services + WebKit（桌面原版球体），搭配零依赖手机 Web 页面；局域网直连或经 Tailscale 私网跨网连接，macOS 先行，命令协议为 Windows helper 保留稳定边界。

<directory>
Android/ - 安卓 Web 工作台配合原生文件、设备与快捷解锁页面、统一扫码（Gradle + Java，详见 Android/CLAUDE.md）
Sources/ - HTTP、控制/光标与持续画面三通道；应用配置、焦点/输入上下文、草稿快照、图片批次、输入活动闸、指针几何与窗口定位及系统输入执行，模型服务配置/客户端与 Agent 路由，以及小精灵的任务模型/存储/服务/执行/网页读取/接收者顺序与 Agent 新任务/桌面动作适配（72 个 Swift 文件）
Web/ - 手机首页、全屏工作台与电脑控制台，零依赖经典脚本按职责拆分；含小精灵的任务客户端与任务卡（32 个静态文件）
Resources/ - 独立 macOS App 的 bundle 元数据与应用图标 (plist + icns + iconset)
scripts/ - 应用安装、图标生成、焦点与锁屏通道探针（7 个脚本）
SessionProbe/ - 独立用户级会话验证应用，比较预登录标记下的锁屏帧状态与显式测试按键；不是生产解锁服务
tests/ - 无桌面副作用的几何/手势/提交队列测试与模拟浏览器回归
docs/ - 已确认交互方案的短规格与实现前决策记录
PocketDesk-统一小精灵技术方案-2026-09-18/ - 小精灵统一方案与现状基线；承接 Workbench 既有规划，区分源码/专项/部署证据，冻结增量接入边界（成员见目录 CLAUDE.md）
</directory>

<architecture>
桌面小精灵反馈：控制连接隔离手机展示快照，复用 TaskStore 事实，经 SpriteFeedback 投影到非激活原生面板，文字原生绘制、球体复用离线 EmotionBall 组件；展示不执行任务，不抢输入焦点；输入时显示草稿，提交/执行时明确状态，完成时庆祝并保留结果，旧终态不默认恢复，预填派单由语义发送按钮与撰写框清空核验收尾。
三条独立通路，改任何一条前先想清楚它跑在哪条上：
  画面：Mac 桌面 → ScreenCaptureKit → 最新 JPEG → 独立 WS :46389 → 手机 <img>（目标 30fps；PiP/失败降级走 HTTP 单帧）
  光标：Mac 光标位置 → CursorMonitor → WS 广播 → 手机 #screen-cursor 叠加层（约 30Hz，轻，latest-only）
  控制：手机触控板 → WS 上行 → PointerExecutor → CGEvent 注入（位移可合并，离散指令有序；断线清空，不重放）
看与控的真实性红线：观测值（CursorMonitor）与命令期望值（PointerExecutor）永不互相写入；
画面停表了、光标在别的屏、链路断了，一律不画叠加层——画了就是假实时；
命令没被服务端确认就不许说"已生效"。宁可显示旧一点、慢一点，也不给一个看起来成功的假象。
</architecture>

<config>
README.md - 安装、权限、安全边界与协议说明
LICENSE - 本项目 MIT 许可证
DESIGN.md - 界面视觉约束与品牌图标策略
CURSOR_VIEW_PROPOSAL.md - 按需查看与鼠标实时反馈的交接方案、技术风险、分阶段实现和验收标准
GYRO_MOUSE_RESEARCH.md - 手机体感鼠标的成熟交互、传感器与 HTTPS 限制、双击滚动方案及实验验收
WRIST_SEND_EXECUTION_PLAN.md - 翻腕发送与唯一手机设置入口的执行交接：iPhone 撤销冲突、面板结构、发送一致性和真机验收（已实现；其中"手机必须信任 CA"的强制要求已被 docs/wrist-send-no-certificate-plan.md 的免证书降级取代）
docs/wrist-send-no-certificate-plan.md - 翻腕免手动证书方案：能力降级、四级状态边界与真机验收（阶段 2 与阶段 3 HTTPS 配对码已实施，阶段 1/4 待真机；Tailscale 可信入口路径已否决）
LIVE_INPUT_PROPOSAL.md - 手机草稿实时同步的原始方案，当前行为以 LIVE_INPUT_REVISION.md 为准
LIVE_INPUT_REVISION.md - 已确认的语音纠正无回删方案、适配边界和验证记录
FULLSCREEN_POINTER_PROPOSAL.md - 全屏手机操控优化建议：绝对定位、单/双击协议、手势仲裁、权威光标、画面延迟与 UU 对照验收（方案）
FULLSCREEN_WORKSPACE_PLAN.md - 全屏改造主方案：基于 v2.9.23 的缺陷复核、UU 官方交互参考、触屏/指针工作台、键盘视口与持续画面链路、分阶段执行和验收；覆盖旧全屏方案的重叠决策（已落地首版，真机及性能验收待完成）
FULLSCREEN_IMPLEMENTATION.md - 全屏首版效果、实现范围、协议、验证记录及真机待验收项
docs/sprite-agent-implementation-plan.md - 小精灵用户服务交付计划：记录已落地的接收者/任务/受控打开能力，v1.2 按真实交互审计重排 S0–S5，每阶段必须交付用户可用且可验证的完整服务
AGENT_PRODUCT_ARCHITECTURE.md - Agent 整体产品设计：任务与记忆、规则路由、Workbench 集成契约、执行权限/接管、token 成本及分阶段验收（方案）
AGENT_MODE_PLAN.md - 口述办事一期：意图底座与确定性动作（P1）、窗口摆放与一键布局（P2）、给应用发消息（P3）的分步方案与验收（方案）
</config>

锁屏解锁：用户级预登录标记支持当前会话锁屏事件；HTTPS/WSS :46487–46489 与原通道共享控制租约，密码只走 LockScreenInput，不写日志/历史/剪贴板。首次手机信任本机 CA；不覆盖重启后的 FileVault 登录。小精灵通过 lock_computer 复用已有锁屏执行器，锁屏状态核验后直接回执；解锁仍只走专用入口。
甩送：免手动证书降级——手机不得为它下载、安装或信任 CA；Android App 0.4.1+ 的 HTTP 工作台使用受限原生传感器桥接，普通浏览器仍要求安全上下文；能力以真实有效传感器数据证明，运动权限并入开启那次点按（详见 docs/wrist-send-no-certificate-plan.md）。

派单状态以执行器回执直接收尾：发送后未核验到接收状态进入待确认，不作为失败，不自动重发；已确认回执不再受模型续轮影响。

手机派单后默认跟随真实前台，首页/全屏接收者与输入绑定同步；手动点小精灵返回，草稿与派单执行期间暂缓自动切换。

电脑向手机文件发送已在隔离 worktree 实现：独立快照/收件/短票据分块下载通路，多文件 ZIP、桌面拖入（拖拽期间短暂显现球体）、访达多选与 Spotlight 文件名查找；Codex 已接手修复发布授权、批次主体查重与并发收件；完整构建、存储/工具、loopback HTTP 下载及手机页面运行时验证通过，真机拖放与安卓下载待验收（docs/phone-file-transfer-delivery.md）。

原生安卓快捷解锁已集成：与文件发送、输入和看屏共存；局域网 HTTPS 直连，扫码固定电脑身份，无需手装证书或中转服务器。电脑控制台打开原生设置生成配对码；密码只存 Mac 钥匙串，默认关闭。安卓 0.1.1 修复扫码依赖和配对引导；真实锁屏解锁仍待验收，见 docs/android-native-unlock.md 与 docs/android-pairing-ux-fix.md。

本机文件发送支持 Dock右键/应用菜单选择和控制台网页拖放；拖放按6MiB分块后复用现有快照边界。手机每项只显示下载与移除/拒绝，点击下载即换取短票据并交给浏览器，不展示协议选项。

电脑常用操作统一到网页：ConsoleActions 严格限定本机同源的文件选择、密码写入与配对授权，原生面板保留兼容。解锁成功后调用亮屏请求；不以亮屏代替锁屏状态核验。Android 0.3.0 增加原生文件/设备导航，工作台复用现有Web业务，返回不重载草稿。

锁定不再使用 pmset 息屏：发送 ⌃⌘Q 后核验会话锁定。原生解锁在签名验证后先请求亮屏，输入准备最多等待2秒安全输入门禁，保留具体失败原因；确认解锁后仍请求亮屏。真机锁定/解锁尚待验收。

Android0.4移除工作台/文件/设备底部Tab：底部复用网页应用切换，首页锁定状态提供显式解锁入口，低频管理收进设置，原生页跟随网页主题。解锁失败细节保留并在电脑本机显示最近回执；真机解锁尚未验收。
