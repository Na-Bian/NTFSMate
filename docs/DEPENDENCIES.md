# NTFSMate 依赖与分发边界档案（M0）

> 更新: 2026-11-21 · 环境: macOS 27.3 (26C5047e) / Darwin 27.3.0 / arm64 / Swift 6.4.2 / Xcode CLT

## 一、锁定的组件版本

| 组件 | 锁定版本 | 来源 | SHA-256 校验 | 校验依据 | 许可证 |
|---|---|---|---|---|---|
| ntfs-3g（含 ntfsprogs） | **2026.9.28** (Stable, 2026-09-28) | https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz | `350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8` | 与 [官方发布说明](https://github.com/tuxera/ntfs-3g/releases/tag/2026.9.28) 中公布值一致 | **GPLv2**（库部分含 LGPL 文件，实际使用 GPLv2 模式）；文本: `Resources/licenses/ntfs-3g-GPLv2.txt` |
| FUSE-T | **1.2.6** (fuse-t-macos-installer-1.2.6.pkg) | https://github.com/macos-fuse-t/fuse-t/releases/download/1.2.6/fuse-t-macos-installer-1.2.6.pkg | `fcfd95e4c09fb1f90efa134ef9b328b5757c59b43d6c7c23384a6a7001db4eb3` | 与 GitHub Release 资产 digest（`sha256:fcfd95…`）一致 | **二进制许可: 非商业免费；商业使用或与商业软件捆绑需向 FUSE-T 作者购买商业许可**；内含 LIBFUSE 库为 LGPL。文本: `Resources/licenses/fuse-t-LICENSE.txt` |
| 后备 ntfs-3g | 2022.10.3（未锁定构建，仅记录备选） | https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2022.10.3.tgz | 构建前须重新核验 | — | GPLv2 |

## 二、许可分析与分发决策

### FUSE-T（关键结论，纠正此前"MIT"误判）

- **源码仓库 License.txt 与安装包 LICENSE.rtf 条款一致**：均为"非商业免费 + 捆绑/商用需商业许可"，**不是 MIT**。早前网络检索所得的"MIT"结论有误，已纠正。
- 开源、免费发布、获准再分发是三件事：
  1. 自用/原型（本机安装 FUSE-T、通过独立进程调用）：**非商业使用免费**，可行；
  2. **公开发布内嵌 FUSE-T 的 .app：需商业许可**（或上游书面确认免费产品可豁免）；
  3. 若发布"引导用户自行安装 FUSE-T"的版本（不含其运行时），应用本身不分发 FUSE-T 二进制，风险显著降低——仍建议取得书面确认。
- **M3（应用自包含）在取得覆盖 1.2.6 framework、go-nfsv4 后端、再分发与实际链接方式的许可依据前，保持暂缓。**
- libfuse-t 动态库含 LGPL 的 libfuse 分叉部分：若未来静态链接或修改，按 LGPL 义务处理；当前仅动态链接原样分发。

### ntfs-3g（GPLv2 义务）

- 对应源码交付：源码 tarball 锁定于 `third_party/downloads/`（已核验校验值）；**无源码补丁**——所有 macOS 适配均为构建脚本参数（见下节），脚本随仓库交付即构成完整"对应源码 + 构建方式"。
- UI 主程序与 ntfs-3g 通过独立进程协作（XPC → 子进程 exec），非直接链接，UI 代码许可不由 ntfs-3g 自动传染；**但** ntfs-3g 与 libfuse-t 的链接组合（GPLv2 + 非商业二进制许可）在公开分发前需单独审查——个人自用无影响。
- 发行包不携带格式化工具（mkntfs 等仅用于测试镜像构建，留在测试工具目录）。

## 三、FUSE-T 1.2.6 运行时布局（解包核验）

安装包含两个子包：

- `fuse-t-core.pkg`：
  - `/Library/Frameworks/fuse_t.framework`（注意下划线命名）
  - `/Library/Application Support/fuse-t/`：
    - `bin/go-nfsv4[-1.2.6]` — NFS 后端（Go，universal x86_64+arm64）；**libfuse-t 内部硬编码查找 `/usr/local/bin/go-nfsv4`**（strings 证实），安装脚本会在 `/usr/local/bin` 建 symlink
    - `include/fuse`（libfuse2 兼容头文件）、`include/fuse3`
    - `lib/libfuse-t-1.2.6.dylib`（install name `@rpath/libfuse-t.dylib`）、`libfuse3.4.dylib`、静态库
    - `pkgconfig/fuse-t.pc`（fuse2 兼容，`-I…/include/fuse`）、`fuse3.pc`
    - `cfg/fuse-t.ini`（默认 backend=nfs；日志 `~/Library/Logs/fuse-t/`）
  - postinstall（root 安装）：将 dylib **复制**到 `/usr/local/lib` 并建 `libfuse-t.dylib → libfuse-t-1.2.6.dylib` symlink；`/usr/local/bin/go-nfsv4` symlink；向 `/etc/hosts` 添加 `fuse-t → 127.0.0.1` 别名（仅影响 Finder 显示名）
  - postinstall（非 root 安装，`installer -target CurrentUserHomeDirectory`）：payload 落到 `~/Library/Application Support/fuse-t`，symlink/复制落在 `~/.fuse-t/usr/local/…`
- `fuse-t-fskit.pkg`：FSKit 后端（macOS 26+），独立子包

## 四、ntfs-3g 构建记录（无源码补丁，全部为脚本参数）

脚本: `scripts/build-ntfs3g.sh`（可重建）。构建适配点：

1. **pkg-config shim**（`third_party/stage-fuse-t/pkgconfig/fuse.pc`）：把 fuse-t.pc 改名为模块 `fuse`，Version 字段由 fuse-t 自身版本 `1.2.6` 改写为兼容的 macfuse API 级别 `2.9.9`——否则 ntfs-3g 的 `fuse >= 2.6.0` 检查失败。
2. **`-D_FILE_OFFSET_BITS=64`**：fuse-t 的 fuse2 兼容头文件强制要求（macOS 原生 off_t 已 64 位，configure 不会自动加）。
3. **`make install` 传 `rootlibdir/rootbindir/rootsbindir=<dist>`**：绕过 Linux 专属的 `.so → /lib` 迁移钩子与 `/bin /sbin` 系统目录写入。
4. `--disable-crypto --disable-ldconfig --disable-mount-helper`。
5. 产物 `bin/ntfs-3g` 链接 `@rpath/libfuse-t.dylib`，rpath 含 `/usr/local/lib`（系统安装）与 `~/.fuse-t/usr/local/lib`（用户安装）两路；`libntfs-3g.91.dylib` 目前以绝对路径链接（原型可接受，打包阶段需 install_name 修正）。

configure 的 "FUSE binaries were NOT installed with root executable prefix" WARNING 为 Linux 场景提示，可忽略。

## 五、分发形态结论

| 形态 | 许可状态 | 状态 |
|---|---|---|
| 本机使用（系统安装 FUSE-T + 打包 ntfs-3g） | 非商业使用免费 | ✅ 采用（最终形态） |
| 公开分发内嵌 FUSE-T 的 .app | 需商业许可或书面豁免 | ❌ **已放弃**（2026-11-22 策略决定，不做内嵌分发） |
| 公开发布"引导用户自装 FUSE-T"版本 | 应用本身不分发 FUSE-T | ✅ 发行路径：应用诊断页提示安装 FUSE-T，用户自行通过 brew/pkg 安装 |
| 公开分发含 ntfs-3g 的版本 | GPLv2 义务（对应源码 + 许可文本随包） | 义务已就绪 |

> **M3 策略变更（2026-11-22）**: 放弃内嵌 FUSE-T 的自包含分发。发行前提为用户自装 FUSE-T 运行时
> （非商业使用免费），应用不再打包 fuse-t.framework；若未来要改变此决定需先取得商业许可。
