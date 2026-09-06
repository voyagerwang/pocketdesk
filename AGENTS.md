# PocketDesk MVP - 手机语音输入到桌面应用的本地桥接器
Swift + Network + Quartz Event Services，搭配零依赖手机 Web 页面；macOS 先行，命令协议为 Windows helper 保留稳定边界。

<directory>
Sources/ - macOS HTTP 服务、控制台接口、目标应用配置持久化、应用激活、Unicode 输入注入与触控板 WebSocket 指针注入 (1 个 Swift 源文件)
Web/ - 手机输入页 + 电脑端控制台 (4 个静态文件)
Resources/ - 独立 macOS App 的 bundle 元数据与应用图标 (plist + icns + iconset)
scripts/ - 独立应用安装脚本与图标生成脚本 (2 个脚本)
</directory>

<config>
README.md - 安装、权限、安全边界与协议说明
LICENSE - 本项目 MIT 许可证
</config>
