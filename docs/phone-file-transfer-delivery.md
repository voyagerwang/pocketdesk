# 电脑向安卓手机多文件传输交付

2026-09-20。ZCode 完成初版后，返修因额度耗尽停止；Codex 按用户要求接手完成代码返修与隔离验证。
执行目录：`/Users/yz/.codex/worktrees/phone-file-transfer/PocketDesk`。

## 当前交付状态

代码及下列本机隔离验证已完成。隔离交付后，用户授权安装：现已将文件传输增量合入本机工作目录并安装、重启 ~/Applications/PocketDesk.app；保留其他任务改动，未推送或提交。
**安卓真机下载、实际 Finder 拖放与自动化授权仍未验证，不能称端到端真机验收通过。**

## 用户行为

- 访达多文件拖到小精灵、读取访达当前选择、按名称通过 Spotlight 查找文件。
- 同名候选由用户确认；只查路径，不把文件正文上传模型。索引未命中时可提供完整路径或拖入。
- 手机独立收件区显示文件信息，由用户明确接收；随后点显式下载链接。
- 2–20 个文件生成一个 ZIP；单文件保持内容与名称。手机保存位置由浏览器决定。
- 一批原文件/单文件上限 512 MiB，持久快照总量 1 GiB，32 项，保留24小时；票据10分钟，可重新确认换票；下载上限3路。
- 安装级共享配对身份，不宣称隔离不同物理手机。

## 返修结论

1. 发布前在暂存库锁内调用控制权回调；AgentRunner 校验任务仍 running 且控制会话有效。复制/打包期间撤权不发布，清理半成品。
2. 批次的两处查重均包含 subject；同任务同路径在不同配对主体下得到各自收件项。
3. 手机列表代际与逐项操作分离。不同收件项并行确认、响应逆序仍各自保留下载链接；迟到列表不能复活已移除项。
4. 反馈面板恢复交接基线360pt，并同步原生测试断言；不再用旧HEAD的720pt覆盖交接状态。
5. HTTP 下载完成/失败/取消/超时共用一次性清理。使用可取消 timer 并清空事件处理器及连接回调，释放文件与流计数，避免闭包引用环。
6. 真实点击下载链接才显示“已发起下载”，不声称已保存。

## 本轮实际验证

所有下列命令在隔离 worktree 执行，退出码0；编译产物在 `/tmp`，不启动桌面应用。

| 检查 | 实际结果 |
| --- | --- |
| 全量 Swift 构建 | PASS；仅编译不运行，日志 `/tmp/pd-final-build.log` |
| Store 临时目录测试 | PASS，72项断言；快照字节、Unicode/空文件、ZIP/同名/20文件、幂等与并发、配额、票据/重启、撤权、跨主体、源文件已删除及快照目录写失败 |
| Agent 替身测试 | PASS，15项；Finder/搜索替身、参数、失权拒绝、诚实回执。日志 `/tmp/pd-final-agent.log` |
| HTTP 实际网络联测 | PASS；生产 PhoneFileHTTP + 假Auth/临时库，127.0.0.1随机端口；无需生产服务 |
| 手机页面静态回归 | PASS，作为结构检查，不代替浏览器测试 |
| 手机 Chromium 运行时 | PASS，320/390px、44px触控、长名/XSS、并行逆序确认、迟到列表、非法下载URL、断网重试、点击下载及刷新恢复 |
| sprite-flow 浏览器回归 | PASS，日志 `/tmp/pd-final-sprite-flow.log` |

HTTP 测试实际读取响应字节并与源内容精确比较，检查 UTF-8 attachment 名称、no-store/nosniff、空文件；覆盖无/错误 Bearer、伪造票据和路径穿越请求、确认换票旧票失效、拒绝后票据失效、断流后重试、三条慢流时第四条503、慢流期间列表仍响应、两秒测试超时后槽位可重用。生产默认超时保持600秒。
跨主体和票据过期由 Store 时钟替身验证；未把它冒充真实物理手机测试。

复跑命令：

```sh
swiftc Sources/*.swift -o /tmp/pd-final-build -framework AppKit -framework WebKit -framework Network -framework CoreImage -framework Carbon
swiftc -parse-as-library Sources/PhoneFileStore.swift tests/phone-file-store.test.swift -o /tmp/pd-final-store
/tmp/pd-final-store
swiftc -parse-as-library Sources/PhoneFileStore.swift Sources/PhoneFileHTTP.swift tests/phone-file-http.fixture.swift -o /tmp/pd-http-fixture
python3 tests/phone-file-http.test.py /tmp/pd-http-fixture
node tests/phone-files.test.cjs
python3 tests/phone-files.runtime.py
python3 tests/sprite-flow.test.py
```

Agent测试：用 `swiftc -parse-as-library` 编译 `Sources` 除 `main.swift` 的全部Swift文件与 `tests/phone-file-agent.test.swift`，链接与完整构建相同的五个framework，输出 `/tmp/pd-final-agent` 后运行。使用已有测试替身，不执行真实Finder授权。

运行时截图：`/tmp/pd-phone-files-320.png`、`/tmp/pd-phone-files-390.png`。它们是模拟尺寸的独立收件组件，非安卓真机截图。

## 未验证项和实际限制

- NOT RUN：真实Finder多选拖入球体命中、切应用时显现/恢复的手感、系统自动化授权与锁屏下拖入行为。
- NOT RUN：安卓浏览器真正下载、下载保存位置、真实网络切换/大文件性能。现已安装到当前应用，仍需安卓手机实际确认下载。
- NOT RUN：原生sprite-panel窗口测试。本轮恢复宽度并调整断言，未弹桌面窗口；ZCode此前的原生庆祝断言有环境失败记录，不宣称该测试全过。
- NOT RUN：真实磁盘满、读取过程中源文件被删除的竞态、设备断电等故障注入。已有复制前后属性核验、写目录失败与失败不发布测试不等价于这些场景。
- 浏览器点击接收后还需点击下载链接。这用于保持明确用户手势，不是自动保存到相册。
- 暂存总量限制针对已发布快照；复制/ZIP过程中有额外临时磁盘占用，未做真实低磁盘压力测试。

## 相对交接基线交付

`phone-file-transfer-delivery.patch` 仅包含本任务相对 `handoff-baseline` 的变化，包含新增测试，不包含其他任务原有差异。`phone-file-transfer-files.json` 列出变更文件及SHA-256，便于后续核验。
保留初稿已有的Server路由、工具注册和首页接缝；未把其他夜间任务的基线变更当作本任务成果。
GEB 根地图、Sources/Web/tests/docs地图与变更头部同步；旧ZCode自动催办已停止。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

## 用户授权安装后的检查

2026-09-20T22:43:55.447338+08:00：当前工作目录集成后完整构建退出码0，安装脚本退出码0。新进程监听46387；phone-files.js/css服务字节与源码一致；未鉴权收件请求401，已配对请求200。已准备无隐私的 PocketDesk-发送测试.txt，真实应用收件列表确认待接收，未代替用户点击接收。
旧应用和集成前源码备份：`/Users/yz/.codex/deployments/phone-files-20260920-224233`。手机保存结果及Finder拖放仍待用户实测。

## Via HTTPS 与发送入口反馈修正

补充原生Dock右键/应用文件菜单“发送文件到手机…”入口。下载票据支持HEAD；链接在新页打开；默认私网IP HTTPS页面提供用户主动选择且明确标注未加密的局域网兼容下载，不自动切换协议。Via具体失败原因尚未获得设备日志，不把证书推测写成已证实根因。HTTP含HEAD、320/390运行时、完整构建及真实浏览器点击下载→保存字节验证通过。Via真机仍需用户复测。

补充：点击下载后只更新状态文字，不重绘/移除链接；重启后无票据时明确提示先换新链接。最终安装退出码0，运行中服务脚本字节与源码一致。原生菜单自动化查看遇到超时，尚未通过电脑操作工具实点选择器；菜单已编译安装。

原生配对整合后的 0.3.1 完整安装版再次通过文件 HTTP 与浏览器实际下载回归；保留 PhoneFilePicker 菜单、拖入、工具路由及原有收件，运行中接口与静态资源已核验。
