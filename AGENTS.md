# PocketDesk MVP - 手机语音输入到桌面应用的本地与私网桥接器
Swift + Network + Quartz Event Services，搭配零依赖手机 Web 页面；局域网直连或经 Tailscale 私网跨网连接，macOS 先行，命令协议为 Windows helper 保留稳定边界。

<directory>
Sources/ - HTTP、控制/光标与持续画面三通道；应用配置、焦点/输入上下文、草稿快照、图片批次及系统输入执行 (26 个 Swift 文件)
Web/ - 手机首页、全屏工作台与电脑控制台，零依赖经典脚本按职责拆分 (15 个静态文件)
Resources/ - 独立 macOS App 的 bundle 元数据与应用图标 (plist + icns + iconset)
scripts/ - 应用安装、图标生成、焦点与锁屏通道探针与本机 TLS 配置 (7 个脚本)
SessionProbe/ - 独立用户级会话验证应用，比较预登录标记下的锁屏帧状态与显式测试按键；不是生产解锁服务
tests/ - 无桌面副作用的几何/手势/提交队列测试与模拟浏览器回归
docs/ - 已确认交互方案的短规格与实现前决策记录
</directory>

<config>
README.md - 安装、权限、安全边界与协议说明
LICENSE - 本项目 MIT 许可证
DESIGN.md - 界面视觉约束与品牌图标策略
LIVE_INPUT_REVISION.md - 已确认的语音纠正无回删方案、适配边界和验证记录
FULLSCREEN_WORKSPACE_PLAN.md - 全屏改造主方案与验收标准（已落地首版，真机及性能验收待完成）
FULLSCREEN_IMPLEMENTATION.md - 全屏首版效果、实现范围、协议、验证记录及真机待验收项
</config>

## 产品设计长期约束（用户验收要求，2026-09-09）

- 改交互前先研究成熟产品的最佳实践；本项目远控/键盘优先核对 UU 远程官方资料、真实界面和使用路径，注明证据与未验证部分。
- 优先原生能力、少步骤、少常驻控件、少文字；低频能力按需出现，正常技术状态不要占用主界面。
- 不用功能堆叠替代交互设计；用户已明确认为现有键盘面板复杂，后续调整必须做减法。
- 只有能说明比成熟方案更简单或更适合本项目时，才引入自定义交互；参考与验证必须发生在实施前。
