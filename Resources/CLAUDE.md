# Resources/
> L2 | 父级: ../CLAUDE.md

成员清单

Info.plist: PocketDesk 独立 macOS App 的身份声明，保留 dev.voicedeck.app 以延续辅助功能授权；同时承载访达多选所需 NSAppleEventsUsageDescription 与 NSScreenCaptureUsageDescription，缺此键时 ScreenCapture 的授权请求会被 TCC 终止进程。
icon-source.png: 当前蓝紫 P 口袋图标原稿，末端融合鼠标指针、内部保留单个显示器，由导入器生成分辨率资产。
icon-source-original.png: 本次优化前的图标原稿，供对照与回退。
AppIcon.icns: 安装脚本消费的 macOS 图标包，由 iconutil 打包。
AppIcon.iconset/: 10 张透明 PNG，覆盖 16–1024 实际像素与 Retina 命名。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

本次完整集成版为 0.3.1（build 4）；保留录屏与访达自动化用途声明，包含文件发送与原生安卓配对。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

NSAppleEventsUsageDescription 同时说明按用户指令访问访达所选文件与清理 Chrome 重复标签页；系统自动化授权仍按应用分别管理。
