# NTFSMate

[简体中文](#简体中文) · [English](#english)

---

<a id="简体中文"></a>

## macOS 菜单栏 NTFS 读写工具

在 macOS 上读写外接 NTFS 磁盘。插入磁盘后自动以读写模式挂载，安全弹出全程数据保护。

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue) ![swift](https://img.shields.io/badge/Swift-6-orange) ![arch](https://img.shields.io/badge/arch-arm64%20%7C%20Intel-lightgrey)

### 功能

- 🚀 **自动读写挂载**：插入 NTFS 卷即自动接管（默认关闭，面板内开启）
- 🗂 **整盘安全弹出**：逐卷非强制卸载 → 确认驱动退出 → 整盘弹出；占用时拒绝并提示原因
- 🛡 **数据安全优先**：`norecover` 不触碰 Windows 日志、不误报读写成功、异常卷保持只读
- 🔐 **特权架构**：SMAppService LaunchDaemon + XPC 对端签名校验，外部程序无法伪造请求
- 🌐 **三语言界面**：简体中文 / 繁體中文 / English（错误消息同步本地化）
- 🧭 **环境检测**：启动时检测 FUSE-T 运行时，缺失时引导安装

### 系统要求

| 组件 | 要求 |
|---|---|
| macOS | 13+；macOS 26+ 默认启用 Liquid Glass UI，低版本自动回退兼容样式 |
| 架构 | arm64 (Apple Silicon) / x86_64 |
| [FUSE-T](https://www.fuse-t.org) | **必须**，用户自行安装（非商业使用免费） |

```bash
brew tap macos-fuse-t/homebrew-cask && brew install --cask fuse-t
```

### 构建

```bash
./scripts/fetch-dependencies.sh        # 下载并核验锁定的 ntfs-3g / FUSE-T
./scripts/build-ntfs3g.sh              # 构建 ntfs-3g (链接 FUSE-T)
./scripts/build-app.sh                 # 编译并组装 NTFSMate.app (签名)
NTFSMATE_INSTALL=1 ./scripts/build-app.sh   # 构建并安装到 /Applications
```

首次使用：启动应用 → 面板内「注册 helper」(管理员授权一次) → 开启自动挂载。

### 架构

```
NTFSMate.app (MenuBarExtra, LSUIElement)
 ├─ NTFSMateApp  — SwiftUI 面板 + DiskArbitration 监控 + 卷状态机
 ├─ NTFSHelper   — 特权 LaunchDaemon: 设备复核、托管 ntfs-3g、串行卷操作
 ├─ NTFSShared   — XPC 消息协议 (客户端只提交意图, helper 自行解析设备)
 ├─ ntfs-3g      — 锁定 2026.9.28, 打包进应用 (GPLv2, 对应源码见 scripts/)
 └─ fuse-t       — 系统安装的运行时 (应用不内嵌分发)
```

挂载链路: XPC 意图 → helper (root) 复核设备 → 卸载原生只读挂载 → 受控挂载点 →
`ntfs-3g -o norecover,no_detach` 前台托管 → 核实挂载类型与读写标志 → 上报真实状态。

### 回归与文档

- [`docs/M1-FINDINGS.md`](docs/M1-FINDINGS.md) — 权限矩阵 + 28 项持久性验证
- [`docs/M2-FINDINGS.md`](docs/M2-FINDINGS.md) — 签名/鉴权 + macOS 27.3 beta 平台怪癖
- [`docs/M4-FINDINGS.md`](docs/M4-FINDINGS.md) — 状态机与监控
- [`docs/M5-FINDINGS.md`](docs/M5-FINDINGS.md) — 回归矩阵 (多分区弹出 / 脏卷 / 占用拒绝)
- [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md) — 组件许可与分发边界

### 许可

- 本项目源码: 见 [LICENSE](LICENSE)
- 打包分发的 ntfs-3g: **GPLv2** — 对应源码与构建脚本随本仓库提供
- FUSE-T 运行时: 不随应用分发，由用户自行安装（[许可说明](https://github.com/macos-fuse-t/fuse-t)）

---

<a id="english"></a>

## NTFSMate — Menu-bar NTFS read/write for macOS

Mount external NTFS drives read-write automatically, with data-safety-first eject
and a privileged-helper architecture.

### Features

- Auto read-write mount on insertion (off by default, enable in the panel)
- Safe whole-disk eject: sequential non-forced unmounts, driver-exit verification, busy refusal
- `norecover` mounts never touch the Windows journal; failures are never misreported as success
- Privileged LaunchDaemon with XPC peer-signature validation; clients submit intents only
- Localization: Simplified Chinese / Traditional Chinese / English

### Requirements

- macOS 13+ (Liquid Glass UI on macOS 26+), Apple Silicon (or Intel)
- [FUSE-T](https://www.fuse-t.org) runtime installed by the user (free for non-commercial use)

### Build

```bash
./scripts/fetch-dependencies.sh && ./scripts/build-ntfs3g.sh && ./scripts/build-app.sh
```

### License

This project's source: see [LICENSE](LICENSE). The bundled ntfs-3g is **GPLv2**
(corresponding source and build scripts are provided in this repository).
FUSE-T is not distributed with the app.
