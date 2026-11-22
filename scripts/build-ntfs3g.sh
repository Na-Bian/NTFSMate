#!/bin/bash
# build-ntfs3g.sh — 从锁定的 ntfs-3g 源码 + fuse-t 头文件/库构建 ntfs-3g 套件
#
# 版本锁定（M0）:
#   ntfs-3g  2026.9.28  sha256=350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8
#   fuse-t   1.2.6      sha256=fcfd95e4c09fb1f90efa134ef9b328b5757c59b43d6c7c23384a6a7001db4eb3 (pkg)
#
# 前置: third_party/inspection/fuse-t-core 已由 scripts/fetch-dependencies.sh 解包
# 产物: third_party/dist/ntfs3g/{bin,lib,...}  (链接 libfuse-t, 运行期经 rpath 解析)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/build/ntfs-3g-2026.9.28"
DIST="$ROOT/third_party/dist/ntfs3g"
FUSE_INSPECT="$ROOT/third_party/inspection/fuse-t-core/Library/Application Support/fuse-t"
STAGE="$ROOT/third_party/stage-fuse-t"

echo "==> 准备 fuse-t 构建暂存目录 (镜像 postinstall 的 symlink 布局)"
rm -rf "$STAGE"
mkdir -p "$STAGE/lib" "$STAGE/pkgconfig"
# 链接期需要 libfuse-t.dylib 这个名字 (dylib 自身 install name 是 @rpath/libfuse-t.dylib)
ln -sf "$FUSE_INSPECT/lib/libfuse-t-1.2.6.dylib" "$STAGE/lib/libfuse-t.dylib"
ln -sf "$FUSE_INSPECT/lib/libfuse-t-1.2.6.a"     "$STAGE/lib/libfuse-t.a"
# pkg-config 期望名为 'fuse' 的模块 (fuse-t.pc 内容即 fuse2 兼容 API)。
# fuse-t.pc 的 Version 字段是 fuse-t 自身版本(1.2.6), 会让 ntfs-3g 的
# "fuse >= 2.6.0" 检查失败; 这里声明它实际兼容的 macfuse/libfuse2 API 级别。
sed -e 's/^Name: fuse-t$/Name: fuse/' -e 's/^Version: 1\.2\.6$/Version: 2.9.9/' \
    "$FUSE_INSPECT/pkgconfig/fuse-t.pc" > "$STAGE/pkgconfig/fuse.pc"

echo "==> 复制 fuse 头文件"
cp -R "$FUSE_INSPECT/include/fuse" "$STAGE/include_fuse_mkdir_target" 2>/dev/null || true
rm -rf "$STAGE/include_fuse_mkdir_target"
mkdir -p "$STAGE/include"
cp -R "$FUSE_INSPECT/include/fuse" "$STAGE/include/fuse"

echo "==> 配置 ntfs-3g (外部 libfuse = fuse-t)"
mkdir -p "$DIST"
cd "$SRC"
make distclean >/dev/null 2>&1 || true
CC=clang \
PKG_CONFIG_PATH="$STAGE/pkgconfig" \
CFLAGS="-O2 -g -D_FILE_OFFSET_BITS=64 -I'$STAGE/include/fuse' -Wno-implicit-function-declaration" \
LDFLAGS="-L'$STAGE/lib' -Wl,-rpath,/usr/local/lib -Wl,-rpath,$HOME/.fuse-t/usr/local/lib" \
./configure \
  --prefix="$DIST" \
  --disable-crypto \
  --disable-ldconfig \
  --disable-mount-helper \
  2>&1 | tee "$ROOT/third_party/build/ntfs3g-configure.log" | tail -15

echo "==> 编译"
make -j"$(sysctl -n hw.ncpu)" 2>&1 | tee "$ROOT/third_party/build/ntfs3g-make.log" | tail -5

echo "==> 安装到 $DIST"
rm -rf "$DIST"
# rootlibdir/rootbindir/rootsbindir 重定向, 绕过 Linux 专属的 /lib /bin /sbin 安装钩子
# (macOS 无此需要, 不重定向会因写系统目录/非 root 权限而失败)
make install rootlibdir="$DIST/lib" rootbindir="$DIST/bin" rootsbindir="$DIST/sbin" \
  2>&1 | tee "$ROOT/third_party/build/ntfs3g-install.log" | tail -3

echo "==> 产物校验"
file "$DIST/bin/ntfs-3g" "$DIST/sbin/mkntfs"
otool -L "$DIST/bin/ntfs-3g"
echo "构建完成: $DIST"
