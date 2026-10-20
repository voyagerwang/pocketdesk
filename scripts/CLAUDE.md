# scripts/
> L2 | 父级: ../CLAUDE.md

成员清单

mijia-sensor.py: 一次家庭设备发现与规格核验的只读温湿度编排；准确设备/房间唯一匹配，在线传感器直读一次、失败后纯云缓存一次，离线只取缓存；可信秒/毫秒归一化并区分读取时间与上报时间，无账号或设备缓存。

mijia-policy.py: 米家最小能力纯策略；标准设备/服务/属性URN交叉核验，仅开放灯/开关基础标量及标准温湿度只读值，验证单位/范围/位宽；准备/执行/读回共用，名称、摄像头和通用动作不得扩权。

mijia-bridge.py: 委托mijia-policy默认拒绝敏感/未知设备，隐藏场景并取消通用动作执行； 独立安装的 mijiaAPI 5.0.0 JSON 适配；家庭清单仅返 ID/原名，指定家庭时实时核对设备归属，并用本次已取得家庭的唯一 roomlist/dids 映射补房间，错误不回退全部家庭；普通业务直接验证账号、status 查询真实家庭接口，公开规格失败本次不重试，云端离线回执保留明确代码并说明 Mesh 网关前提，不把手机蓝牙可控等同于云端可达；--login-events 输出二维码/唯一终态，独立暂存由 App 提交；--check-runtime 无网络检查固定 SDK。
mijia-network.py: 米家传输边界；按请求阶段脱敏网络/接口错误、限时调用和本次家庭 owner 复用；只对固定 MIOT 公开规格端点按完整 URN 合并请求并缓存七天，私有原子落盘且限制大小/格式，失败只在本次调用内复用，家庭/设备归属不跨调用缓存。
setup-mijia.sh: 米家可选依赖安装与电脑扫码入口；固定 SDK 5.0.0，独立用户 venv，--no-login 只安装，随 App 打包供控制台首次连接准备依赖，不将 SDK/凭证打包进 App；取消转发信号并回收当前 uv/登录子进程。
install-headset-services.py: 安装脚本的用户级服务交接；自测与映射核验通过后部署 launchd，保留旧服务和旧 App 备份，恢复 PocketDesk 登录启动。
sync-orb-svg.js: 比对 Web 球体引擎与 orb.svg 静态帧的几何、渐变和来源契约；仅检查，不重新生成或手改素材。

build-session-probe.sh: 构建独立本机会话验证应用和临时 Aqua LaunchAgent；RUN.txt 明确先注册 Launch Services 再启动，确保 TCC 能定位应用；prelogin/baseline 只改变 Mach-O 预登录标记，保留相同签名身份；不自动启动、不安装 root 服务、不改正式应用。

unlock-preflight.py: Python 标准库只读探针；仅连接回环 TCP 5900，协商 RFB 版本并读取认证类型后断开，不认证、不传密码、不采集画面、不发输入；区分权限阻断、拒绝连接与协议可达，结果始终保留 unlock_verified=false。

install-app.sh: 链接 AppKit/WebKit 编译、稳定签名并安装 PocketDesk，消费 Resources/AppIcon.icns 后启动应用。**启动前必须先退出旧实例**：`open` 对已运行的应用只会激活它、不会换成新装进去的二进制，不先 pkill 则改完的代码永远不生效（"改了却没变化"的根源）；进程名是可执行文件 VoiceDeck，与 app 名 PocketDesk 不同（历史遗留），pkill/pgrep 要用 `-x VoiceDeck`。退出后 sleep 1.5 等端口 46387 释放，否则新进程绑不上端口、白装一次。
import-icon.swift: 当前蓝色 P 图标的导入器，识别蓝色底板并输出透明边距及精确像素的 iconset。
make-icon.swift: 历史麦克风矢量图标备用生成器，不参与当前品牌构建。
ax-probe.swift: LIVE_INPUT_PROPOSAL.md 的 P0 兼容性探针——对**用户当前聚焦的那个输入框**做 AX 能力探测，输出应用/role/`AXValue` 可读可写/选区可读写，加 `--write` 才做「写测试串 → 读回比对 → 恢复原值」。**一律只输出长度、不输出正文**；默认只读不改动目标框。独立一次性工具，不并入应用本体（它是另一个二进制，辅助功能授权要单独勾一次）。用法见文件头。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

setup-secure-channel.sh: 生成本机 HTTPS 身份与手机信任用 CA 证书，私有文件权限隔离、保留已有身份，签发后删除 CA 私钥，不自动改变系统信任；已有身份时只补派生内存装配所需 DER 副本（`server-key.der`/`server-cert.der`），绝不重签——重签会让手机已信任的 CA 与已授权的传感器权限全部作废。

pull-rebuild.sh: 仅快进当前分支上游后重装；拒绝脏工作区、分叉、游离HEAD及未完成Git操作，保留正常SSH校验。
rebuild-safe.sh: 构建并签名Mac应用，停止旧实例后将旧安装移到废纸篓并启动新版本；不同步Git分支。
