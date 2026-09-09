# scripts/
> L2 | 父级: ../CLAUDE.md

成员清单

install-app.sh: 编译、稳定签名并安装 PocketDesk，消费 Resources/AppIcon.icns 后启动应用。**启动前必须先退出旧实例**：`open` 对已运行的应用只会激活它、不会换成新装进去的二进制，不先 pkill 则改完的代码永远不生效（"改了却没变化"的根源）；进程名是可执行文件 VoiceDeck，与 app 名 PocketDesk 不同（历史遗留），pkill/pgrep 要用 `-x VoiceDeck`。退出后 sleep 1.5 等端口 46387 释放，否则新进程绑不上端口、白装一次。
import-icon.swift: 当前蓝色 P 图标的导入器，识别蓝色底板并输出透明边距及精确像素的 iconset。
make-icon.swift: 历史麦克风矢量图标备用生成器，不参与当前品牌构建。
ax-probe.swift: LIVE_INPUT_PROPOSAL.md 的 P0 兼容性探针——对**用户当前聚焦的那个输入框**做 AX 能力探测，输出应用/role/`AXValue` 可读可写/选区可读写，加 `--write` 才做「写测试串 → 读回比对 → 恢复原值」。**一律只输出长度、不输出正文**；默认只读不改动目标框。独立一次性工具，不并入应用本体（它是另一个二进制，辅助功能授权要单独勾一次）。用法见文件头。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
