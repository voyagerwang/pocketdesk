# PocketDesk MVP - 手机语音输入到桌面应用的本地与私网桥接器
Swift + Network + Quartz Event Services，搭配零依赖手机 Web 页面；局域网直连或经 Tailscale 私网跨网连接，macOS 先行，命令协议为 Windows helper 保留稳定边界。

<directory>
Sources/ - HTTP、控制/光标与持续画面三通道；应用配置、焦点/输入上下文、草稿快照、图片批次、输入活动闸、指针几何与窗口定位及系统输入执行（29 个 Swift 文件）
Web/ - 手机首页、全屏工作台与电脑控制台，零依赖经典脚本按职责拆分（17 个静态文件）
Resources/ - 独立 macOS App 的 bundle 元数据与应用图标 (plist + icns + iconset)
scripts/ - 应用安装、图标生成、焦点与锁屏通道探针（7 个脚本）
SessionProbe/ - 独立用户级会话验证应用，比较预登录标记下的锁屏帧状态与显式测试按键；不是生产解锁服务
tests/ - 无桌面副作用的几何/手势/提交队列测试与模拟浏览器回归
docs/ - 已确认交互方案的短规格与实现前决策记录
</directory>

<architecture>
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
WRIST_SEND_EXECUTION_PLAN.md - 翻腕发送与唯一手机设置入口的执行交接：iPhone 撤销冲突、面板结构、HTTPS/WSS、发送一致性和真机验收（尚未实现）
LIVE_INPUT_PROPOSAL.md - 手机草稿实时同步的原始方案，当前行为以 LIVE_INPUT_REVISION.md 为准
LIVE_INPUT_REVISION.md - 已确认的语音纠正无回删方案、适配边界和验证记录
FULLSCREEN_POINTER_PROPOSAL.md - 全屏手机操控优化建议：绝对定位、单/双击协议、手势仲裁、权威光标、画面延迟与 UU 对照验收（方案）
FULLSCREEN_WORKSPACE_PLAN.md - 全屏改造主方案：基于 v2.9.23 的缺陷复核、UU 官方交互参考、触屏/指针工作台、键盘视口与持续画面链路、分阶段执行和验收；覆盖旧全屏方案的重叠决策（已落地首版，真机及性能验收待完成）
FULLSCREEN_IMPLEMENTATION.md - 全屏首版效果、实现范围、协议、验证记录及真机待验收项
AGENT_PRODUCT_ARCHITECTURE.md - Agent 整体产品设计：任务与记忆、规则路由、Workbench 集成契约、执行权限/接管、token 成本及分阶段验收（方案）
</config>

锁屏解锁：用户级预登录标记支持当前会话锁屏事件；HTTPS/WSS :46487–46489 与原通道共享控制租约，密码只走 LockScreenInput，不写日志/历史/剪贴板。首次手机信任本机 CA；不覆盖重启后的 FileVault 登录。
