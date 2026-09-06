# Voice Deck MVP - 手机语音输入到桌面应用的本地桥接器
Swift + Network + Quartz Event Services，搭配零依赖手机 Web 页面；macOS 先行，命令协议为 Windows helper 保留稳定边界。

<directory>
Sources/ - macOS HTTP 服务、目标应用激活与 Unicode 输入注入 (1 个 Swift 源文件)
Web/ - 手机浏览器控制界面 (3 个静态文件)
Resources/ - 独立 macOS App 的 bundle 元数据 (1 个 plist)
scripts/ - 独立应用安装脚本 (1 个 shell 脚本)
</directory>

<config>
README.md - 安装、权限、安全边界与协议说明
LICENSE - 本项目 MIT 许可证
</config>
