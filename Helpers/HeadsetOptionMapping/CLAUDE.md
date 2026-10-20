# Helpers/HeadsetOptionMapping/
> L2 | 父级: ../CLAUDE.md

成员清单

main.m: Foundation + IOKit 常驻映射守护；每次重建 HID 服务快照，合并已配对中键 Option 与减号租约；操作来源携带唯一当前 IOHIDDevice registry，沿服务真实父链及型号核验，不依赖 EventService 暴露序列号、不按同型号兜底；身份未知拒绝接管。先持久化恢复记录再写 Usage 0，读回保留原规则身份 sources 并发布 identity→registry 的 registries 健康映射，防止旧连接晚回执借给新设备；应用退出或租约过期恢复原来源。--self-test 仅测值变换与租约/同型号隔离，不读取或修改真实映射。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
