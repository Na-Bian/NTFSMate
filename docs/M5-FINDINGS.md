# M5 实验档案 — 回归矩阵与发行就绪度

> 日期: 2026-11-22 · 结论: **验收矩阵三项全绿**, 应用达到发行候选状态 (镜像验证预览版)

## 一、回归矩阵结果

### 回归 A — 多分区整盘弹出协调 ✅

样本: `test-multi.img` (GPT 双 NTFS 分区, MULTI-1/MULTI-2)
流程: 附载 → 自动挂载接管两卷 (rw) → 点任一卡「弹出」→ 整盘弹出

helper 日志铁证:
```
整盘弹出开始: disk4, 托管卷: ["disk4s1", "disk4s2"]
弹出流程: 卸载 disk4s1 → 卸载完成 (驱动退出=是)
弹出流程: 卸载 disk4s2 → 卸载完成 (驱动退出=是)
弹出流程: diskutil eject disk4
```
会话/挂载/进程全部归零。

**修复的关键 bug — `parentDisk` 切片误判**: 朴素 `range(of: "s")` 搜索命中 "disk" 中的 s,
导致 `wholeDiskBSD` 恒为切片自身 → 同盘串行化队列按切片分裂、整盘弹出变成弹切片。
改为正则锚定结尾 `s[0-9]+$`。

### 回归 B — 脏卷 norecover 保守挂载 ✅

样本: `test-dirty.img` (挂载写入后 SIGKILL 驱动 = 脏 Windows 日志, 卷内含 dirty-evidence.txt)
流程: 附载 (FSKit 只读) → 自动挂载接管 → helper 以 `norecover` 挂载 rw → 写入 → 面板卸载 → 分离重附载核对

结果: rw 挂载成功且未修复日志 (norecover 语义), `dirty-evidence.txt` 与新写文件经分离重附载后完好。

**修复的关键 bug — 陈旧托管状态误报读写成功**: 应用重启/helper 重启后, 上个会话的托管状态可能
指向已死的挂载; doMount 的"已托管直接返回"分支只查 states[bsd] 存在, 把**当前的原生只读挂载点**
当作托管读写返回 —— 审计预警的"误报读写成功"实测命中。修复为四重验证 (挂载点存活 + nfs 类型 +
非只读 + 驱动进程存活), 不满足则清除陈旧状态走全新挂载; recoverState 增加状态对账。

### 回归 C — 占用时拒绝弹出 ✅

构造: 后台进程 CWD 占据卷 (lsof 证实) → 点「弹出」
结果: 非强制卸载被拒 → 卷保持挂载 → 不发"可以拔出"通知 → 内联错误行显示「整盘弹出失败: 同盘上有卷正被占用」
→ 占用释放后再点 → 弹出成功且错误标记自动清除。全程无强制卸载、无数据风险。

## 二、M5 阶段发现并修复的问题

1. **AppModel 懒加载导致监控不启动 (最重磅)**: AppModel/VolumeMonitor 挂在 PanelView 的
   `@StateObject` 上, 而 MenuBarExtra 窗格内容是懒加载 —— 用户不点面板, 监控根本不存在,
   插盘/自动挂载全部失效。修复: AppModel 单例化, AppDelegate.applicationDidFinishLaunching
   即创建 (监控随应用启动激活, 面板只引用共享实例)。
2. **陈旧托管状态误报读写** (见回归 B)。
3. **`parentDisk` 切片误判** (见回归 A)。
4. **空镜像无法正常附载**: `diskutil image attach` 对无文件系统的 raw 镜像整体失败
   ("Failed to mount the volume") → 必须用 `hdiutil attach -nomount` 取裸设备。
5. **macOS 27 的 partitionDisk "Free Space" 变体假成功**: 退出码 0 但写入空 GPT (0 条目),
   内核回退按 MBR 解析 → 切片不出现。改用真实文件系统 (MS-DOS FAT32) 占位分区, mkntfs 覆写。
   (DiskImages2 quirk, 已实测三种变体)
6. **SIGKILL 后 NFS 挂载条目残留内核挂载表** (fuse-t 生命周期边界): 需 `umount -f` 清理;
   残留条目会占用卷名导致后续挂载命名漂移 (DIRTY-TEST 1)。脚本增加遗留进程/挂载/会话清理步骤。
7. **自动接管与系统原生 automount 竞态**: helper 挂载 nfs rw 后, FSKit 的只读挂载可能随后
   落到别名挂载点 (DIRTY-TEST 1) —— 影子只读挂载, 无害但待加挂载后清理 (列入 M5 遗留)。
8. 弹出占用错误文案精简 (去掉零信息量的 diskutil 原文), 错误行 fixedSize 防截断。

## 三、发行就绪度

| 项 | 状态 |
|---|---|
| 镜像回归矩阵 (A/B/C) | ✅ 全绿 |
| 三语言 (简/繁/EN) 含 helper 错误消息 | ✅ |
| 环境检测 + FUSE-T 安装引导 | ✅ |
| 应用图标 / 关于窗口 / 版权 | ✅ |
| 实盘验收 (USB 桥接/断连/睡眠唤醒) | ⏳ 待硬件 |
| Developer ID 签名 + 公证 | ⏳ 发行时执行 (`NTFSMATE_TIMESTAMP=1` + Developer ID 身份) |
| xpc_string 截断 quirk 在正式版复核 | ⏳ 正式版系统复核 (M2 档案 §二.4) |

## 四、可重复回归资产

- `scripts/make-test-image.sh` — 单卷镜像 (用户级)
- `scripts/m5-prepare-images.sh` — 双分区 + 脏卷镜像 (sudo 一次)
- `scripts/m1-sudo-mount-test.sh` — 28 项 CLI 全链路回归
- `tests/foreign-client-probe.swift` — XPC 鉴权负向测试
