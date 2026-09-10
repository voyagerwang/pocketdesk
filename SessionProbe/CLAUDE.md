# SessionProbe/
> L2 | 父级: ../CLAUDE.md

成员清单

main.swift: 独立本机会话试验应用；由用户级 LaunchAgent 启动，观察锁屏通知、会话标志和 ScreenCaptureKit 帧状态。缺少权限时明确弹出未开始原因并记录 blocked_permissions，返回应用时刷新首次验证前的权限状态。输入试验必须由用户明确勾选，三项状态同时成立才发一次测试字符，不提交密码；记录发送而非成功，不提供网络或提权入口。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

录屏授权请求返回未允许时直接定位系统录屏设置并记录 pending，不将请求发出视为授权成功，也不重复等待系统弹窗。
