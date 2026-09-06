# Sources/
> L2 | 父级: ../CLAUDE.md

成员清单

main.swift: macOS 本地 HTTP 服务与输入执行器，提供应用原生图标和独立唤醒置顶能力，串行执行 activate → delay → Unicode text → Return 命令（可选先经 Mac 剪贴板 Cmd+V 粘贴图片）；管理目标应用与快捷键两份本机配置（targets.json / shortcuts.json），快捷键以 CGEvent 组合键注入当前前台应用（POST /api/shortcuts 保存、/api/shortcut-trigger 触发）。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
