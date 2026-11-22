#!/bin/bash
# fetch-dependencies.sh — 可重建地获取 M0 锁定的依赖并解包 (对应 docs/DEPENDENCIES.md)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DL="$ROOT/third_party/downloads"
INSPECT="$ROOT/third_party/inspection"

# M0 锁定值 (修改版本必须同步更新 docs/DEPENDENCIES.md)
NTFS3G_URL="https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.9.28.tgz"
NTFS3G_SHA256="350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8"
FUSET_URL="https://github.com/macos-fuse-t/fuse-t/releases/download/1.2.6/fuse-t-macos-installer-1.2.6.pkg"
FUSET_SHA256="fcfd95e4c09fb1f90efa134ef9b328b5757c59b43d6c7c23384a6a7001db4eb3"

mkdir -p "$DL" "$INSPECT"

fetch() { # url sha256 outfile
  local url="$1" sha="$2" out="$3"
  if [ -f "$out" ] && [ "$(shasum -a 256 "$out" | cut -d' ' -f1)" = "$sha" ]; then
    echo "已存在且校验通过: $out"; return
  fi
  echo "下载 $url"
  curl -fSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$out" "$url"
  echo "$sha  $out" | shasum -a 256 -c -
}

fetch "$NTFS3G_URL" "$NTFS3G_SHA256" "$DL/ntfs-3g_ntfsprogs-2026.9.28.tgz"
fetch "$FUSET_URL"  "$FUSET_SHA256"  "$DL/fuse-t-macos-installer-1.2.6.pkg"

# 解包 fuse-t pkg (许可与布局审计用)
if [ ! -d "$INSPECT/fuse-t-pkg" ]; then
  pkgutil --expand "$DL/fuse-t-macos-installer-1.2.6.pkg" "$INSPECT/fuse-t-pkg"
fi
for sub in fuse-t-core fuse-t-fskit; do
  if [ ! -d "$INSPECT/$sub" ]; then
    mkdir -p "$INSPECT/$sub"
    (cd "$INSPECT/$sub" && gunzip -dc "../fuse-t-pkg/$sub.pkg/Payload" | cpio -idm 2>/dev/null)
  fi
done

# 解压 ntfs-3g 源码
if [ ! -d "$ROOT/third_party/build/ntfs-3g-2026.9.28" ]; then
  mkdir -p "$ROOT/third_party/build"
  tar -xzf "$DL/ntfs-3g_ntfsprogs-2026.9.28.tgz" -C "$ROOT/third_party/build"
fi

echo "依赖就绪。许可文本归档见 Resources/licenses/，档案见 docs/DEPENDENCIES.md"
