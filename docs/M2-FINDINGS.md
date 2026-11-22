# M2 实验档案 — 最小签名应用与特权 helper

> 日期: 2026-11-22 · 环境: macOS 27.3 beta (26C5047e) / Darwin 27.3.0 / arm64 / Swift 6.4.2
> 交付: `/Applications/NTFSMate.app`（Apple Development 签名）+ SMAppService LaunchDaemon 特权 helper
> 结论: **M2 完成标准全部满足**（注册/批准/鉴权/挂载/卸载/重启恢复/持久性/负向测试）

## 一、验收清单（修订计划 M2 完成标准）

| 项 | 结果 | 证据 |
|---|---|---|
| LaunchDaemon 注册 (BundleProgram + MachServices) | ✅ | `launchctl print system/com.ntfsmate.helper` state=running；`SMAppService.daemon(plistName:)` 注册/注销往返成功 |
| 系统批准流程 | ✅ | notRegistered → enabled；管理员授权一次 |
| XPC 对端校验 | ✅ 正向 | helper 日志: `接受连接: pid=… euid=501 auid=501 ident=com.ntfsmate.app`（audit token 取真实身份，非调用方自报） |
| XPC 对端校验 | ✅ 负向 | 未签名探针 `/tmp/foreign-client-probe` 被拒: `对端路径不匹配 … 拒绝连接`（tests/foreign-client-probe.swift） |
| 会话校验 | ✅ | auid/euid 一致性检查（auid 哨兵值 0xFFFFFFFF/0xFFFFFFFE 拒绝） |
| 测试镜像准入 gate | ✅ | M2 仅放行调用者主目录 `NTFSTest/` 下镜像卷；生产介质策略 M4 落地 |
| 一次挂载和卸载 | ✅ | 多轮往返；`挂载成功: disk4 → /Volumes/NTFS-TEST pid=…` / `卸载完成: disk4 (驱动退出=是)` |
| helper 重启状态恢复 | ✅ | `恢复托管状态: disk4 → /Volumes/NTFS-TEST pid=83471`（ps 扫描采纳孤儿 ntfs-3g） |
| 持久性 | ✅ | 用户经 Finder 写入 3 个文件（含 15.4MB 中文文件名 docx），卸载→重附载→原生只读挂载核对全部在卷 |
| 挂载真实性核验 | ✅ | helper 核对挂载表（nfs + 非只读）+ ntfs-3g 自身 `Mounted (Read-Write)` 输出，非仅进程存活 |

## 二、本阶段发现并修复的问题

1. **SecCodeCopyPath 返回包根路径**：对 bundle 签名的代码，路径校验应比对 `/Applications/NTFSMate.app`（而非可执行文件路径）；同时校验 `kSecCodeInfoIdentifier == CFBundleIdentifier`。
2. **`xpc_connection_get_audit_token` Swift 未导出**：`@_silgen_name` 手动桥接（符号在 libxpc，macOS 13+ 公开）。
3. **`SecCodeCopyPath` 需要 SecStaticCode**（先 `SecCodeCopyStaticCode` 转换）；静态信息用 `SecCodeCopySigningInformation`（`SecCodeCopyStaticInformation` 不在公开头文件）。
4. **★ macOS 27.3 beta: xpc_string 长文本传输截断**——514 字符的字典内字符串在管道中稳定截断为前 ~85 字符（同管道 400 字符的 error 字符串又曾完整到达，行为诡异且确定可复现）。**缓解：所有顶层回包字符串字段改用 `xpc_data`（显式长度）编码，读取端 `xpc_dictionary_get_data` 优先。** M5 需在正式版系统上复核该问题是否仍存在。
5. **`diskutil list -plist` 盲区**：无分区表的整盘 FS（raw 镜像）无 `FilesystemType` 键 → 列卷需补 `diskutil info` 复核；分区卷正常。
6. **`hdiutil info -plist` 键名**：macOS 27 为 `images[].image-path` + `images[].system-entities[].dev-entry`（旧文档 `dev-entries` 不存在）；条目含 `owner-uid`（root 可见用户会话）。
7. **helper 资源路径**：BundleProgram 定位的应用包反推正确，但资源路径需显式包含 `Contents/Resources/...`。
8. **recoverState 解析**：`ps -axo pid=,command=` 行格式为 `<pid> <command>`；采纳孤儿前需 `kill(pid,0)` 存活核验。
9. **托管卷挂载点回填**：diskutil 不回显 NFS 挂载点 → 列表需以 helper 托管状态的 mountPoint 优先，否则 UI 无法弹出。
10. **挂载幂等守卫**：doMount 前先 recoverState + 检查存活托管挂载，防止对已被孤儿 ntfs-3g 挂载的设备重复挂载（设备 flock 冲突 `Resource temporarily unavailable`）。
11. **挂载点选择**：卷已卸载后的同名空目录（root 属主）可复用，否则 `-NTFSMate2` 递增。
12. **helper 空闲退出 + 二进制自检**：15s 无对端连接退出（launchd 按需重启）；新连接时比对自身二进制 mtime，被更新则立即自杀重启——开发期免手动注销/注册。

## 三、开发期流程备忘

- helper 代码更新后：**退出并重开应用即可**（旧 helper 失去对端后 15s 自杀，新连接自动加载新代码）；极少数情况（helper 正被连接占用）需一次「注销 helper → 注册 helper」。
- 挂载测试链路：`./scripts/make-test-image.sh`（用户级造镜像）→ `hdiutil attach` → 应用内挂载 → Finder 写入 → 应用内卸载 → `diskutil eject disk4`。
- helper 日志：`/Library/Logs/NTFSMate/helper.log`（os_log + 文件双写）；ntfs-3g 子进程日志 `ntfs-3g-<bsd>.log`；launchd 输出 `/var/log/ntfsmate-helper.{out,err}`。

## 四、遗留到 M4

- 生产介质接管策略（外接可写 NTFS 数据卷白名单化；当前仅测试镜像 gate）
- DiskArbitration 实时监控 + 自动挂载（默认关、用户开启）
- 菜单栏形态（MenuBarExtra + LSUIElement）与通知
- 整盘弹出接入 UI（helper eject op 已实现未接线）
- 异常卷路径（休眠/未干净卸载样本）、同盘多分区、占用拒绝弹出场景
- 登录时启动（SMAppService.mainApp）
