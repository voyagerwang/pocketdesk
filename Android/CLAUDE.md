# Android/
> L2 | 父级: ../CLAUDE.md
安卓 11+ 客户端；完整 Web 工作台配合原生文件、设备与解锁页面；快捷解锁独立认证。
settings.gradle: 依赖仓库与 app 模块声明。
build.gradle: 固定 Android Gradle Plugin 8.9.1。
gradle.properties: AndroidX 与构建内存设置。
app/: 原生应用和协议单测，见 app/CLAUDE.md。
[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md

gradlew / gradlew.bat / gradle/wrapper/: 固定 Gradle 8.11.1 的可复现构建入口，含官方发行包 SHA256。
