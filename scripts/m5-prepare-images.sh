#!/bin/bash
# m5-prepare-images.sh — M5 回归矩阵的测试镜像准备 (需 sudo 运行一次)
#
# 产出 (真实用户主目录 ~/NTFSTest/):
#   test-multi.img — GPT 双 NTFS 分区镜像 (整盘弹出协调验证)
#   test-dirty.img — 脏日志镜像 (未干净卸载 + norecover 验证)
#
# 用法: sudo ./scripts/m5-prepare-images.sh
set -uo pipefail

# sudo 下解析真实用户与主目录
REAL_USER="${SUDO_USER:-$(stat -f '%Su' "$HOME")}"
REAL_UID="$(id -u "$REAL_USER")"
REAL_HOME="$(eval echo "~$REAL_USER")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NTFS3G="$ROOT/third_party/dist/ntfs3g/sbin/mkntfs"
DIR="$REAL_HOME/NTFSTest"

pass(){ echo "✅ $*"; }
fail(){ echo "❌ $*"; exit 1; }

# 以真实用户身份创建用户级文件 (镜像后续要被用户级附载, 不能归 root 所有)
user_mkfile(){
  sudo -u "$REAL_USER" -H mkfile -n "$1" "$2" || fail "mkfile 失败: $2"
}
cleanup_device(){
  local img="$1"
  for _ in 1 2 3; do
    local dev
    dev=$(hdiutil info | awk -v i="$img" '/image-path/{p=($0 ~ i)} p && /\/dev\/disk/{print $1; exit}')
    [ -z "$dev" ] && break
    diskutil eject "$dev" >/dev/null 2>&1
    sleep 1
  done
}

mkdir -p "$DIR"
chown "$REAL_UID" "$DIR"

# 清理上次运行遗留的脏卷挂载 (ntfs-3g 进程 → NFS 挂载 → 附载会话),
# 否则遗留进程持有设备 flock, 新运行的 mkntfs/挂载全部 EAGAIN
echo "=== 0) 清理上次运行遗留 ==="
pkill -9 -f "/Volumes/DIRTY-TEST" 2>/dev/null && echo "已终止遗留 DIRTY-TEST 驱动进程" || true
pkill -9 -f "/Volumes/MULTI-" 2>/dev/null && echo "已终止遗留 MULTI 驱动进程" || true
sleep 1
for m in $(mount | awk '/DIRTY-TEST|MULTI-/ {print $2}'); do
  diskutil unmount force "$m" >/dev/null 2>&1 || true
done
for img in "$DIR/test-multi.img" "$DIR/test-dirty.img"; do
  cleanup_device "$img"
done
pass "遗留清理完成"

echo "=== 1) GPT 双 NTFS 分区镜像 (test-multi.img) ==="
IMG_MULTI="$DIR/test-multi.img"
cleanup_device "$IMG_MULTI"
rm -f "$IMG_MULTI"
user_mkfile 2g "$IMG_MULTI"
# 空镜像无法正常附载 (无 FS 可挂), 必须以 -nomount 取裸设备再分区
ATTACH_OUT=$(hdiutil attach -nomount "$IMG_MULTI" 2>&1) || fail "附载失败: $ATTACH_OUT"
DEV=$(echo "$ATTACH_OUT" | grep -oE "^/dev/disk[0-9]+" | head -1)
echo "附载: $DEV (root 权限下执行分区与格式化)"
# 注意: macOS 27 的 partitionDisk 对裸镜像 "Free Space" 变体会假成功写空 GPT (DiskImages2 quirk),
# 必须配真实文件系统占位, 随后 mkntfs 覆写为 NTFS
diskutil partitionDisk "$DEV" GPT "MS-DOS FAT32" P1 49% "MS-DOS FAT32" P2 R >/dev/null || fail "分区失败"
# diskutil list 输出裸设备名 (disk4s1), 去掉 /dev/ 前缀再匹配
DEVBARE="${DEV#/dev/}"
S1=$(diskutil list "$DEV" | grep -oE "${DEVBARE}s1" | head -1)
S2=$(diskutil list "$DEV" | grep -oE "${DEVBARE}s2" | head -1)
[ -n "$S1" ] && [ -n "$S2" ] || { diskutil list "$DEV"; fail "未找到分区"; }
echo "分区: $S1 + $S2 → 等待切片设备激活 → mkntfs"
# partitionDisk 后 BSD 切片节点异步创建, 等待就绪
for _ in $(seq 1 20); do
  [ -e "/dev/$S1" ] && [ -e "/dev/$S2" ] && break
  sleep 0.5
done
[ -e "/dev/$S1" ] && [ -e "/dev/$S2" ] || { diskutil list "$DEV"; fail "切片设备未激活"; }
# FAT32 占位分区会被自动挂载, mkntfs 前必须卸载 (否则设备 busy)
for _ in $(seq 1 10); do
  diskutil unmount "/dev/$S1" >/dev/null 2>&1
  diskutil unmount "/dev/$S2" >/dev/null 2>&1
  mount | grep -qE "$S1|$S2" || break
  sleep 0.5
done
mount | grep -qE "$S1|$S2" && { mount | grep -E "$S1|$S2"; fail "占位分区无法卸载"; }
pass "占位分区已卸载, 设备空闲"
sync
MK1=$("$NTFS3G" -f -F -L MULTI-1 "/dev/$S1" 2>&1) || { echo "$MK1" | tail -3; fail "mkntfs $S1 失败"; }
MK2=$("$NTFS3G" -f -F -L MULTI-2 "/dev/$S2" 2>&1) || { echo "$MK2" | tail -3; fail "mkntfs $S2 失败"; }
diskutil eject "$DEV" >/dev/null || fail "分离失败"
chown "$REAL_UID" "$IMG_MULTI"
pass "test-multi.img 就绪 (MULTI-1 / MULTI-2, 属主 $REAL_USER)"

echo
echo "=== 2) 脏日志镜像 (test-dirty.img) ==="
IMG_DIRTY="$DIR/test-dirty.img"
cleanup_device "$IMG_DIRTY"
rm -f "$IMG_DIRTY"
user_mkfile 512m "$IMG_DIRTY"
"$NTFS3G" -f -F -L DIRTY-TEST "$IMG_DIRTY" >/dev/null 2>&1 || fail "mkntfs 失败"
ATTACH2=$(diskutil image attach "$IMG_DIRTY") || fail "附载失败: $ATTACH2"
DEV2=$(echo "$ATTACH2" | awk -F'\t' '/^\/dev\/disk/{print $1; exit}')
sleep 2
# 先卸载附载时自动出现的原生只读挂载 (ntfs-3g 拒绝在已挂载设备上重复挂载)
diskutil list "$DEV2" | grep -q "DIRTY-TEST" && diskutil unmount "$DEV2" >/dev/null 2>&1 || true
MNT="/Volumes/DIRTY-TEST-RW"
mkdir -p "$MNT"
echo "root 挂载 rw → 写入 → SIGKILL 驱动 (模拟断电)"
"$ROOT/third_party/dist/ntfs3g/bin/ntfs-3g" "$DEV2" "$MNT" \
  -o norecover,no_detach,uid="$REAL_UID",gid=20,noatime >"$DIR/dirty-mount.log" 2>&1 &
NPID=$!
sleep 3
kill -0 "$NPID" 2>/dev/null || { cat "$DIR/dirty-mount.log"; fail "挂载失败"; }
echo "dirty evidence $REAL_USER" > "$MNT/dirty-evidence.txt"
sync
sleep 1
kill -9 "$NPID" 2>/dev/null
sleep 2
diskutil unmount "$MNT" >/dev/null 2>&1 || true
diskutil eject "$DEV2" >/dev/null 2>&1 || true
rmdir "$MNT" 2>/dev/null || true
chown "$REAL_UID" "$IMG_DIRTY"
pass "test-dirty.img 就绪 (含 dirty-evidence.txt, NTFS 日志为脏状态)"

echo
echo "全部镜像就绪 (属主 $REAL_USER):"
ls -la "$DIR"/test-multi.img "$DIR"/test-dirty.img
echo
echo "后续在应用内操作 (无需 sudo):"
echo "  a) 多分区弹出: 附载 test-multi.img → 挂载 MULTI-1 → 点『弹出』→ 两卷同卸、整盘弹出"
echo "  b) 脏卷保守挂载: 附载 test-dirty.img → 点『读写挂载』→ 验证 norecover 不清日志、文件还在"
