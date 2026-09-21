# 在另一台 Mac 继续开发与验收

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

## 分支与范围

开发分支：`codex/android-ux-unlock`，远端仓库：`git@github.com:voyagerwang/pocketdesk.git`。
这是本机当前开发状态的交接快照，包含 Android 0.4.0、网页和原生交互、文件传输、锁定/解锁、相关小精灵调整、测试与设计记录。不是正式发布，也没有合并 main。本地原 main 另有此前未推送的提交，作为本分支祖先保留。

仓库当前没有 `.github/workflows`；本次不创建自动发布或部署流程。原仓库之外的第三方集成不在本地代码可验证范围内。

## 获取代码

新目录克隆：

```sh
git clone --branch codex/android-ux-unlock git@github.com:voyagerwang/pocketdesk.git
cd pocketdesk
git status
```

已有克隆时，先提交或自行暂存原电脑上的修改，然后执行：

```sh
git fetch origin
git switch --track origin/codex/android-ux-unlock
```

若本地已有同名分支，使用 `git switch codex/android-ux-unlock`。后续更新只运行 `git pull --ff-only`；不要合并 main，直到此轮验收完成并明确决定集成。

## 构建

Mac 需要 Xcode Command Line Tools（含 Swift 与 macOS SDK），在仓库根目录运行：

```sh
zsh scripts/rebuild-safe.sh
```

它会安装到当前用户 `~/Applications/PocketDesk.app` 并启动。另一台电脑需要自行授予辅助功能、屏幕录制等必要权限。`scripts/pull-rebuild.sh` 可在干净工作区下快进当前分支上游并重装；不会切到 main、删除 Git 锁或绕过 SSH 校验。

Android 需要 JDK 17、Android SDK 35。通过 `ANDROID_HOME` 或本机 `Android/local.properties` 配置 SDK 后：

```sh
cd Android
./gradlew assembleDebug testDebugUnitTest lintDebug
```

APK：`Android/app/build/outputs/apk/debug/app-debug.apk`。仓库带 Gradle 8.11.1 wrapper，依赖来自官方仓库；不依赖前一台电脑的 `/tmp` Maven 代理。首次构建需能访问这些仓库。

不同电脑默认生成不同 Android debug 签名，因此新构建可能无法覆盖手机上已有 APK。不要为此直接卸载而丢失配对；需使用同一签名的安全交接方案或独立测试设备。私有签名文件不放入 Git。

## 本机配置与秘密

不迁移登录密码、钥匙串、TLS 私钥、手机配对 token、模型 API Key、SDK 路径或构建缓存。新 Mac 首次运行生成自己的身份，手机连接与解锁授权需重新配对；不要复用另一台 Mac 的钥匙串或证书目录。电脑控制台设置必要配置，再按界面完成本机钥匙串授权。

## 已验证与未完成

已验证：Android 0.4.0（versionCode 6）构建、26 项单测、lint；320/390 宽度的状态解锁入口、底部应用栏、主题和控制台回归；Swift 本机配置接口边界与解锁隔离测试。界面截图使用模拟状态，不代表真机解锁成功。

优先待验收：

1. 真正锁屏：现在发送 ⌃⌘Q 后核验会话状态，已移除 pmset 息屏替代。需真机确认系统接受该组合键。
2. 真机解锁仍失败，根因尚未闭环。新版 App 保留服务端 detail 和错误码；电脑控制台显示最近一次解锁回执。先复现并读取具体错误，不继续猜测、不重试密码、不放宽验证。
3. 钥匙串：后台不得弹授权框；在电脑已解锁时点击“检查并授权钥匙串”，由用户处理系统提示并确认后台读取通过，再进行锁屏验收。
4. 打开 App，锁定时首屏提供解锁入口；只有点击才验证身份，成功回到原工作台。确认草稿保留、无自动解锁或自动重试。
5. 文件发送、局域网下载、覆盖安装和应用切换需手机实测。HTTP 下甩送传感器限制尚未解决。

相关记录：`product-interaction-review-20260921.md`、`interaction-console-native-20260921.md`、`android-native-unlock.md`。代码与文档冲突时，以当前实现和可重复验证的事实为准。
