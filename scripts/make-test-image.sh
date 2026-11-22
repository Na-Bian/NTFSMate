#!/bin/bash
# make-test-image.sh — 以【用户权限】创建可重建的 NTFS 测试镜像 (无需 sudo)
#
# 用法:  ./scripts/make-test-image.sh [镜像路径] [大小]
# 默认:  ~/NTFSTest/test01.img 1g
#
# 原理: mkntfs -F 可直接对普通文件建立 NTFS 卷 (用户权限即可, 无需块设备)。
# 注意: 发行包不携带格式化工具, mkntfs 仅用于本测试脚本。
set -euo pipefail

IMG="${1:-$HOME/NTFSTest/test01.img}"
SIZE="${2:-1g}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MKNTFS="$ROOT/third_party/dist/ntfs3g/sbin/mkntfs"

if [ -f "$IMG" ]; then
  echo "镜像已存在: $IMG (如需重建请先删除)"
  exit 0
fi

mkdir -p "$(dirname "$IMG")"
echo "==> 创建 $SIZE 稀疏文件: $IMG"
mkfile -n "$SIZE" "$IMG"

echo "==> mkntfs 格式化 (卷标 NTFS-TEST)"
"$MKNTFS" -f -F -L NTFS-TEST "$IMG"

echo "==> 完成: $IMG"
echo "后续: sudo ./scripts/m1-sudo-mount-test.sh $IMG  (挂载实验需 root)"
