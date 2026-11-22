# M4 实验档案 — 卷状态机与菜单栏

> 日期: 2026-11-22 · 交付: 菜单栏应用（MenuBarExtra 窗格）+ DiskArbitration 自动挂载 + 生产介质策略 + 通知 + 整盘弹出 UI
> 结论: **M4 核心链路全部闭环**（自动触发 → helper 接管 → 读写挂载 → 安全弹出）

## 一、验收情况（修订计划 M4 完成标准）

| 项 | 结果 | 实现 |
|---|---|---|
| 手动点击和自动事件同时到达只执行一次 | ✅ | `busyBSDs` 去重集合，手动挂载与 DA 自动事件共用 |
| helper 串行化同盘操作 + 介质身份复核 | ✅ (M2 起) | helper 每盘独立串行队列；每次操作前 `diskutil info` 复核 |
| 应用重连后状态重建 | ✅ | helper `recoverState`（ps 扫描孤儿 ntfs-3g）+ 应用启动即列卷 |
| 菜单状态与系统状态一致 | ✅ | 列表以 helper 状态为准；DA appeared/disappeared 事件触发刷新 |
| 生产介质策略 | ✅ | `Internal=false && RemovableMediaOrExternalDevice=true && WritableMedia=true`（helper 侧判定；测试镜像天然满足） |
| 自动挂载默认关闭、用户开启 | ✅ | `@AppStorage` 持久化；开启时**补偿扫描**接管已接入的只读卷 |
| 退出应用停止接管新卷、已挂载卷继续由 helper 托管 | ✅ | helper 状态独立于应用生命周期（已实测：应用退出后卷保持挂载） |
| 整盘弹出接入 UI | ✅ | helper eject op（逐卷非强制卸载 → 驱动退出 → 整盘弹出 → 核实）|
| 通知 | ✅ | 自动挂载成功/失败、安全弹出（UserNotifications，开启自动挂载时请求授权） |
| 登录时启动 | ✅ | SMAppService.mainApp toggle |
| 卸载回退 | ✅ | 未托管卷（原生只读）回退为普通非强制卸载 |

## 二、本阶段发现并修复的问题

1. **SwiftPM 缺 `NSPrincipalClass=NSApplication`** → MenuBarExtra 图标无响应；补 Info.plist 后正常。
2. **`kDADiskDescriptionMediaNameKey` ≠ BSD 设备名**（是"Apple 读/写 Media"这类介质名）→ 必须用 `DADiskGetBSDName()`；此 bug 导致自动挂载事件带非法设备名（`非法设备名: Apple 读/写 Media`），已修复。
3. **`kDADiskDescriptionVolumeMountPointKey` 未导出到 Swift** — 从观测日志中移除该字段。
4. **DADisk 回调签名**：Swift 桥接后 `disk` 为非可选 `DADisk`（类类型），无需 Unmanaged 解包。
5. **开关打开晚于插盘** → 增加开启时补偿扫描。

## 三、观测日志设计（保留为回归工具）

VolumeMonitor 对**全部**磁盘接入事件记录 `磁盘接入: <bsd> kind=<fs> 挂载点=…`，可在诊断 sheet 查看——本次正是靠它定位了 MediaName/BSDName 混淆。

## 四、遗留（→ M5）

- 占用拒绝弹出的显式验证（Finder 打开卷内文件后点弹出 → 应失败且不提示可拔出）
- 同盘多分区镜像（GPT + 双 NTFS 分区）的整盘弹出协调
- 异常卷样本（休眠/未干净卸载）的 `norecover` 行为验证
- 大文件/中文名/扩展属性回归（M1 脚本已覆盖，接入自动回归）
- xpc_string 截断问题在正式版系统复核（M2 档案 §二.4）
