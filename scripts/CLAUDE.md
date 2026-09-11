# scripts/
> L2 | 父级: ../CLAUDE.md

成员清单

build-session-probe.sh: 构建独立本机会话验证应用和临时 Aqua LaunchAgent；RUN.txt 明确先注册 Launch Services 再启动，确保 TCC 能定位应用；prelogin/baseline 只改变 Mach-O 预登录标记，保留相同签名身份；不自动启动、不安装 root 服务、不改正式应用。

unlock-preflight.py: Python 标准库只读探针；仅连接回环 TCP 5900，协商 RFB 版本并读取认证类型后断开，不认证、不传密码、不采集画面、不发输入；区分权限阻断、拒绝连接与协议可达，结果始终保留 unlock_verified=false。

install-app.sh: 编译、稳定签名并安装 PocketDesk，消费 Resources/AppIcon.icns 后启动应用。**启动前必须先退出旧实例**：`open` 对已运行的应用只会激活它、不会换成新装进去的二进制，不先 pkill 则改完的代码永远不生效（"改了却没变化"的根源）；进程名是可执行文件 VoiceDeck，与 app 名 PocketDesk 不同（历史遗留），pkill/pgrep 要用 `-x VoiceDeck`。退出后 sleep 1.5 等端口 46387 释放，否则新进程绑不上端口、白装一次。
import-icon.swift: 当前蓝色 P 图标的导入器，识别蓝色底板并输出透明边距及精确像素的 iconset。
make-icon.swift: 历史麦克风矢量图标备用生成器，不参与当前品牌构建。
ax-probe.swift: LIVE_INPUT_PROPOSAL.md 的 P0 兼容性探针——对**用户当前聚焦的那个输入框**做 AX 能力探测，输出应用/role/`AXValue` 可读可写/选区可读写，加 `--write` 才做「写测试串 → 读回比对 → 恢复原值」。**一律只输出长度、不输出正文**；默认只读不改动目标框。独立一次性工具，不并入应用本体（它是另一个二进制，辅助功能授权要单独勾一次）。用法见文件头。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

setup-secure-channel.sh: 生成本机 HTTPS 身份与手机信任用 CA 证书，私有文件权限隔离、保留已有身份，签发后删除 CA 私钥，不自动改变系统信任；已有身份时只补派生内存装配所需 DER 副本（`server-key.der`/`server-cert.der`），绝不重签——重签会让手机已信任的 CA 与已授权的传感器权限全部作废。
