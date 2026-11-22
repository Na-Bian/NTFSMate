# M1 实验档案 — CLI 镜像验证（可复核记录）

> 日期: 2026-11-21 · 环境: macOS 27.3 (26C5047e) / Darwin 27.3.0 / arm64
> 组件: ntfs-3g 2026.9.28 (外部 FUSE 29) + FUSE-T 1.2.6 (用户级安装)
> 复现: `./scripts/make-test-image.sh` → `sudo ./scripts/m1-sudo-mount-test.sh`
> 最终结果: **28 PASS / 0 FAIL**（结果文件 `~/NTFSTest/m1-results.txt`）

## 一、权限矩阵（逐环节实测记录）

| 环节 | 用户级 | 说明 |
|---|---|---|
| mkntfs 对普通文件建 NTFS 卷 | ✅ | 需 `-F`（--force），2026.9.28 拒绝非块设备目标除非强制 |
| mkfile 造稀疏文件 | ✅ | — |
| 附载镜像 `diskutil image attach` | ✅ | — |
| 原生 NTFS 只读挂载 | ✅ 自动 | **macOS 27.3 原生走 FSKit**（mount 标志含 `fskit`），以登录用户身份挂载 |
| `diskutil unmount` | ✅ | 用户自己挂的 FSKit 卷，用户可非强制卸载 |
| `mkdir /Volumes/*` | ❌ | `/Volumes` 不可写，**root 才能创建挂载点** |
| ntfs-3g 挂载 | ❌ | **驱动自身拒绝**: "Unprivileged user can not mount NTFS block devices using the external FUSE library" |
| 打开 `/dev/disk*` 读写 | ❌ | `brw-r----- root:operator`，普通用户无写权限 |
| root 执行 ntfs-3g | ✅ | 全链路成立（见下） |

**结论: 挂载链路必须 root，特权 helper (SMAppService LaunchDaemon) 架构为必要设计。**

## 二、挂载命令与实际标志

```bash
ntfs-3g /dev/disk4 /Volumes/NTFS-TEST-RW -o norecover,no_detach,uid=501,gid=20,noatime
# 环境变量: FUSE_NFSSRV_PATH=/Users/<user>/.fuse-t/usr/local/bin/go-nfsv4  (用户级 fuse-t 安装时必须)
```

ntfs-3g 自报（`~/NTFSTest/ntfs3g.log`）:

```
Version 2026.9.28 external FUSE 29
Mounted /dev/disk4 (Read-Write, label "NTFS-TEST", NTFS 3.1)
Cmdline options: norecover,no_detach,uid=501,gid=20,noatime
Mount options: allow_other,nonempty,noatime,default_permissions,fsname=/dev/disk4,blkdev,blksize=4096
Global ownership and permissions enforced, configuration type 1
Unmounting /dev/disk4 (NTFS-TEST)      ← 非强制卸载时的优雅退出路径
```

系统侧: `localhost:/NTFS-TEST-RW on /Volumes/NTFS-TEST-RW (nfs)`，非只读。

关键行为记录:
- **`no_detach`** = macOS 构建的前台模式（不接受 fuse 风格 `-f`；源码 `setup_logging` 依据 `ctx->no_detach` 决定是否 daemon()）。helper 托管必须用此选项。
- **`norecover`** 在 macOS 构建中可用（`ntfs-3g_common.c:109`）——自动挂载路径禁用日志清除的要求可满足。
- **`allow_other` 默认开启**（见上方日志）→ 多用户可见性需第二账号验收（列入 M4/M5），且确认 `default_permissions` 同时生效。
- fuse-t 后端查找顺序: `FUSE_NFSSRV_PATH` 环境变量 → `$HOME/.fuse-t/…` → 硬编码 `/usr/local/bin/go-nfsv4`。root 进程 `$HOME=/var/root` 不命中用户级安装，**helper 启动 ntfs-3g 时必须显式设置 FUSE_NFSSRV_PATH**。

## 三、弹盘顺序（修订计划核心要求）——实测确认

1. `diskutil unmount`（非强制）→ 成功后 **ntfs-3g 进程自行退出**（fuse-t: 文件系统进程死亡即卸载后端；反向: 卸载完成后进程亦退出），全程未用 SIGTERM；
2. `diskutil eject <整盘>` → 成功；
3. 分离/重附载 → 经原生 FSKit 只读挂载核对。

占用场景（busy 时保留挂载并报告）在 M4 状态机与 M5 矩阵中验收。

## 四、持久性验证（卸载前后哈希对比，全部一致）

| 用例 | 结果 |
|---|---|
| 新建文件（含中文文件名） | ✅ |
| 复制新文件 | ✅ |
| 覆盖已有文件 | ✅ 内容持久化正确 |
| 重命名（中文） | ✅ 持久化正确 |
| 删除文件 | ✅ 持久化正确（重附载后不存在） |
| 10MB 随机文件 | ✅ 哈希一致 |
| 目录操作（建目录、目录内复制） | ✅ |
| 全部文件 SHA-256 + 目录结构 | ✅ 卸载前后一致 |
| 扩展属性写入 | ✅ 经 ntfs-3g 写入成功 |

## 五、已知问题与待查（进入后续里程碑）

1. **xattr 经原生 FSKit 只读挂载不可见**（ntfs-3g 路径写入成功；FSKit 原生实现不展示 ntfs-3g 存储的扩展属性）。M5 矩阵改用 ntfs-3g 挂载路径核对 xattr 持久性。
2. **AppleDouble（`._*`）文件**出现在卷上——macOS 对非原生文件系统的元数据文件，属预期行为，UI/文档需说明。
3. **macOS 27 的 `diskutil image` 没有 detach 子命令**（仅 attach/info/create/resize）；分离必须按设备 `diskutil eject <dev>` 并核实 hdiutil 会话消失，否则 hdiejectd 持有镜像 flock（本次实验中踩坑并已在脚本修正）。
4. 多账号（第二本地账号）访问验证 → M4/M5。
5. 占用/忙场景、同盘多分区、异常卷（休眠/未干净卸载）→ M4 状态机 + M5 矩阵（需构造样本镜像）。
6. 实机 USB（桥接芯片、断连、睡眠唤醒）→ 有硬件后单独验收（镜像测试保留为自动回归）。

## 六、M2 输入（直接指导 helper 实现）

- helper 以 root exec ntfs-3g: 绝对路径、参数数组、`no_detach` + `norecover`，设置 `FUSE_NFSSRV_PATH`（发现顺序: `/usr/local/bin/go-nfsv4` 存在则不设，否则探测用户级 `~/.fuse-t/...`）；
- 挂载点由 helper 在 `/Volumes` 下以 root 创建（目录唯一、受控）；
- uid/gid 取自已认证会话所属用户；
- 卸载: `diskutil unmount`（非强制）→ 轮询 ntfs-3g 进程退出（超时报告占用）→ `diskutil eject` 整盘 → 核实 hdiutil 会话消失；
- 探测挂载结果: 不只看进程存活，核对 mount 表类型(nfs)与只读标志 + ntfs-3g 自身 "Mounted (Read-Write)" 输出。
