# PocketDesk MVP - 手机语音输入到桌面应用的本地与私网桥接器
Swift + Network + Quartz Event Services，搭配零依赖手机 Web 页面；局域网直连或经 Tailscale 私网跨网连接，macOS 先行，命令协议为 Windows helper 保留稳定边界。

<directory>
Sources/ - macOS HTTP 服务、控制台接口、目标应用配置持久化、应用激活、Unicode 输入注入与触控板 WebSocket 指针注入、ScreenCaptureKit 按需画面回传、鼠标位置观测与广播 (14 个 Swift 源文件，按职责分模块；目标单文件 ≤300 行，当前 InputExecutor.swift 452 行、Server.swift 419 行为已知超标，待拆)
Web/ - 手机输入页 + 电脑端控制台 (5 个静态文件)
Resources/ - 独立 macOS App 的 bundle 元数据与应用图标 (plist + icns + iconset)
scripts/ - 独立应用安装脚本与图标生成脚本 (3 个脚本)
</directory>

<architecture>
三条独立通路，改任何一条前先想清楚它跑在哪条上：
  画面：Mac 桌面 → ScreenCaptureKit → JPEG → HTTP → 手机 <img>（约 1fps，重，可丢帧）
  光标：Mac 光标位置 → CursorMonitor → WS 广播 → 手机 #screen-cursor 叠加层（约 30Hz，轻，latest-only）
  控制：手机触控板 → WS 上行 → PointerExecutor → CGEvent 注入（既有，不可丢帧）
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
LIVE_INPUT_PROPOSAL.md - 手机草稿实时同步的可行性、AX 控件兼容验证、会话与版本协议、独立提交和执行验收方案（尚未实现）
FULLSCREEN_POINTER_PROPOSAL.md - 全屏手机操控优化建议：绝对定位、单/双击协议、手势仲裁、权威光标、画面延迟与 UU 对照验收（方案）
AGENT_PRODUCT_ARCHITECTURE.md - Agent 整体产品设计：任务与记忆、规则路由、Workbench 集成契约、执行权限/接管、token 成本及分阶段验收（方案）
</config>
