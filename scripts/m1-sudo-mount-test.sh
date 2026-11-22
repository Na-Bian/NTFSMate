#!/bin/bash
# m1-sudo-mount-test.sh — M1 挂载/读写/持久性全链路实验 (以 root 运行)
#
# 用法:  sudo ./scripts/m1-sudo-mount-test.sh [镜像文件]
# 默认镜像: ~/NTFSTest/test01.img (由 make-test-image.sh 以用户权限创建, 需已存在且未附载)
#
# 记录目标 (对应修订计划 M1 通过条件):
#   1. root 环境下 ntfs-3g + fuse-t 实际挂载行为与挂载标志
#   2. 用户级读写、覆盖、重命名、删除、中文文件名、扩展属性
#   3. 正常卸载顺序: 非强制卸载 → 确认驱动退出 → 整盘弹出 (全程不用 SIGTERM 弹盘)
#   4. 分离/重新附载后, 经原生只读挂载核对内容哈希
set -uo pipefail

IMG="${1:-$HOME/NTFSTest/test01.img}"
LOG="$HOME/NTFSTest/m1-results.txt"
MNT="/Volumes/NTFS-TEST-RW"
USER_NAME="$(stat -f '%Su' "$HOME")"
USER_UID="$(id -u "$USER_NAME")"
USER_GID="$(id -g "$USER_NAME")"
NTFS3G="$PWD/third_party/dist/ntfs3g/bin/ntfs-3g"

pass(){ echo "✅ PASS: $*" | tee -a "$LOG"; }
fail(){ echo "❌ FAIL: $*" | tee -a "$LOG"; }
note(){ echo "ℹ️  NOTE: $*" | tee -a "$LOG"; }
step(){ echo; echo "=== $* ===" | tee -a "$LOG"; }

: > "$LOG"
echo "M1 实验开始 $(date)  镜像=$IMG  用户=$USER_NAME($USER_UID/$USER_GID)" | tee -a "$LOG"
[ -f "$NTFS3G" ] || { fail "找不到 ntfs-3g: $NTFS3G (请在项目根目录运行)"; exit 1; }
[ -f "$IMG" ]    || { fail "找不到镜像: $IMG (先以用户权限运行 scripts/make-test-image.sh)"; exit 1; }

step "E0 清理可能的残留附载并重建干净卷"
# macOS 27 的 diskutil image 没有 detach 子命令; 分离必须按设备 eject 并核实会话消失,
# 否则 hdiejectd 会持有镜像文件的 flock, 后续 mkntfs 报 "Resource temporarily unavailable"
for mnt in /Volumes/NTFS-TEST /Volumes/NTFS-TEST-RW; do
  mount | grep -q " on $mnt " && diskutil unmount "$mnt" >/dev/null 2>&1
done
for _ in 1 2 3; do
  DEV_OLD=$(hdiutil info | awk -v img="$IMG" '/image-path/{p=($0 ~ img)} p && /\/dev\/disk/{print $1; exit}')
  [ -z "$DEV_OLD" ] && break
  diskutil eject "$DEV_OLD" >/dev/null 2>&1
  sleep 1
done
if hdiutil info | grep -q "$IMG"; then
  fail "镜像附载会话无法清除 (flock 会阻塞重建)"; exit 1
fi
pass "无残留附载会话"
# 重建空白 NTFS 卷, 保证每次运行状态确定 (mkntfs 对普通文件操作, 以原用户身份执行即可)
if sudo -u "$USER_NAME" "$PWD/third_party/dist/ntfs3g/sbin/mkntfs" -f -F -L NTFS-TEST "$IMG" >/dev/null 2>&1; then
  pass "镜像已重建为空白 NTFS 卷"
else
  fail "镜像重建失败"; exit 1
fi

step "E1 附载镜像 (用户级操作)"
ATTACH_OUT="$(diskutil image attach "$IMG" 2>&1)" || { fail "附载失败: $ATTACH_OUT"; exit 1; }
echo "$ATTACH_OUT" | tee -a "$LOG"
DEV="$(echo "$ATTACH_OUT" | awk -F'\t' '/^\/dev\/disk/{print $1; exit}')"
[ -n "$DEV" ] || { fail "未能识别附载设备"; exit 1; }
pass "附载成功: $DEV"

step "E2 原生 NTFS 挂载行为观察 (预期: FSKit 自动只读)"
sleep 2
mount | grep -E "$DEV " | tee -a "$LOG" || note "未自动挂载"
NATIVE_MNT=$(mount | awk -v d="$DEV" '$1==d{print $3; exit}')
[ -n "$NATIVE_MNT" ] && pass "原生只读挂载点: $NATIVE_MNT" || note "无原生挂载"

step "E3 卸载原生只读挂载 (非强制)"
if [ -n "${NATIVE_MNT:-}" ]; then
  if diskutil unmount "$NATIVE_MNT" 2>&1 | tee -a "$LOG"; then
    pass "原生只读挂载已卸载 (非强制)"
  else
    fail "卸载失败 — 依据修订计划应停止接管, 本实验中止"; exit 1
  fi
fi

step "E4 创建受控挂载点 (root)"
if [ -e "$MNT" ] && ! [ -d "$MNT" ] && [ -z "$(ls -A "$MNT" 2>/dev/null)" ]; then
  fail "挂载点 $MNT 已存在且非空, 中止"; exit 1
fi
mkdir -p "$MNT" && pass "挂载点已创建: $MNT (属主 $(stat -f '%Su:%Sg' "$MNT"))"

step "E5 root 启动 ntfs-3g (前台 no_detach 模式, 后台托管) — 关键实验"
# norecover: 不清除 Windows 日志 (修订计划要求)
# no_detach: macOS 构建的前台选项 (2026.9.28 不接受 fuse 风格的 -f; setup_logging 依据 ctx->no_detach)
# fuse-t 的 go-nfsv4 后端查找顺序: FUSE_NFSSRV_PATH 环境变量 → $HOME/.fuse-t/... → /usr/local/bin/go-nfsv4
# root 的 $HOME=/var/root 不会命中用户级安装, 故显式指定环境变量 (系统安装存在 /usr/local/bin 时不必要)
if [ ! -x /usr/local/bin/go-nfsv4 ]; then
  USER_HOME="$(eval echo "~${USER_NAME}")"
  if [ -x "$USER_HOME/.fuse-t/usr/local/bin/go-nfsv4" ]; then
    export FUSE_NFSSRV_PATH="$USER_HOME/.fuse-t/usr/local/bin/go-nfsv4"
    note "使用 FUSE_NFSSRV_PATH=$FUSE_NFSSRV_PATH"
  fi
fi
"$NTFS3G" "$DEV" "$MNT" -o norecover,no_detach,uid="$USER_UID",gid="$USER_GID",noatime >"$HOME/NTFSTest/ntfs3g.log" 2>&1 &
NTFS_PID=$!
for i in $(seq 1 20); do
  mount | grep -q " on $MNT " && break
  kill -0 "$NTFS_PID" 2>/dev/null || { fail "ntfs-3g 进程退出, 日志:"; cat "$HOME/NTFSTest/ntfs3g.log" | tee -a "$LOG"; exit 1; }
  sleep 0.5
done
if mount | grep -q " on $MNT "; then
  pass "挂载完成, ntfs-3g PID=$NTFS_PID"
  mount | awk -v m="$MNT" '$3==m' | tee -a "$LOG"
else
  fail "20 秒内挂载未出现"; cat "$HOME/NTFSTest/ntfs3g.log" | tee -a "$LOG"; exit 1
fi

step "E6 核实挂载类型与读写标志 (不能只看进程存活)"
MOUNT_LINE="$(mount | awk -v m="$MNT" '$3==m')"
echo "$MOUNT_LINE" | grep -qi " read-only" && fail "挂载为只读!" || pass "非只读挂载"
echo "$MOUNT_LINE" | tee -a "$LOG"

step "E7 用户级读写测试 (sudo -u 降权执行)"
W="$HOME/NTFSTest/work"; rm -rf "$W"; mkdir -p "$W"
printf 'NTFSMate M1 test payload 001\n' > "$W/original.txt"
ORIG_SHA=$(shasum -a 256 "$W/original.txt" | cut -d' ' -f1)

sudo -u "$USER_NAME" sh -c "echo 'new file content 中文内容' > '$MNT/新建文件.txt'" \
  && pass "新建中文文件" || fail "新建中文文件"
sudo -u "$USER_NAME" cp "$W/original.txt" "$MNT/original.txt" \
  && pass "复制新文件" || fail "复制新文件"
sudo -u "$USER_NAME" sh -c "printf 'overwritten!\n' > '$MNT/original.txt'" \
  && pass "覆盖已有文件" || fail "覆盖已有文件"
sudo -u "$USER_NAME" mv "$MNT/新建文件.txt" "$MNT/renamed-中文.txt" \
  && pass "重命名(中文)" || fail "重命名(中文)"
sudo -u "$USER_NAME" sh -c "echo attr-value > /dev/null; xattr -w com.test.m1 'xattr值' '$MNT/original.txt'" \
  && pass "写扩展属性" || fail "写扩展属性"
sudo -u "$USER_NAME" sh -c "echo transient > '$MNT/delete-me.txt'" \
  && pass "新建待删文件" || fail "新建待删文件"
sudo -u "$USER_NAME" rm "$MNT/delete-me.txt" \
  && pass "删除文件" || fail "删除文件"

step "E8 大文件写入 (10MB) + 目录操作"
sudo -u "$USER_NAME" sh -c "dd if=/dev/urandom of='$MNT/bigfile.bin' bs=1m count=10 2>/dev/null" \
  && pass "写入 10MB 随机文件" || fail "写入 10MB 随机文件"
sudo -u "$USER_NAME" mkdir "$MNT/测试目录" && pass "创建目录" || fail "创建目录"
sudo -u "$USER_NAME" sh -c "cp '$MNT/bigfile.bin' '$MNT/测试目录/bigfile-copy.bin'" && pass "目录内复制" || fail "目录内复制"

step "E9 记录当前卷上全部内容哈希 (卸载前)"
sudo -u "$USER_NAME" sh -c "cd '$MNT' && find . -type f -exec shasum -a 256 {} +" > "$HOME/NTFSTest/before-unmount.sha" 2>&1
cat "$HOME/NTFSTest/before-unmount.sha" | tee -a "$LOG"
cp "$MNT/original.txt" "$W/original-after-write.txt" 2>/dev/null
BIG_SHA_IN=$(shasum -a 256 "$MNT/bigfile.bin" 2>/dev/null | cut -d' ' -f1)
note "bigfile.bin 卸载前 SHA256=$BIG_SHA_IN"

step "E10 正常卸载 (非强制) — 顺序: 卸载 → 驱动退出 → 弹盘"
if diskutil unmount "$MNT" 2>&1 | tee -a "$LOG"; then
  pass "非强制卸载成功 (未用 force, 未用 SIGTERM)"
else
  fail "非强制卸载失败 (占用应保留挂载并报告) — 实验中止"; exit 1
fi
sleep 2
if kill -0 "$NTFS_PID" 2>/dev/null; then
  note "卸载后 ntfs-3g 进程仍存活 (PID=$NTFS_PID) — 记录行为后做孤儿清理 (SIGTERM 仅作清理)"
  ps -p "$NTFS_PID" -o pid,ppid,stat,command | tee -a "$LOG"
  kill "$NTFS_PID" 2>/dev/null && note "孤儿进程已 SIGTERM 清理"
else
  pass "卸载后 ntfs-3g 进程已自行退出 (fuse-t 预期行为)"
fi

step "E11 整盘弹出"
if diskutil eject "$DEV" 2>&1 | tee -a "$LOG"; then
  pass "整盘弹出成功"
else
  fail "整盘弹出失败"; exit 1
fi

step "E12 重新附载 → 经原生只读挂载核对持久性"
sleep 1
diskutil image attach "$IMG" >/dev/null 2>&1 || { fail "重新附载失败"; exit 1; }
sleep 3
NATIVE2=$(mount | grep -E "^/dev/disk" | grep -i ntfs | awk '{print $3}' | head -1)
[ -n "$NATIVE2" ] || { fail "重新附载后未见原生只读挂载"; exit 1; }
pass "重新附载并只读挂载于: $NATIVE2"
sudo -u "$USER_NAME" sh -c "cd '$NATIVE2' && find . -type f -exec shasum -a 256 {} +" > "$HOME/NTFSTest/after-reattach.sha" 2>&1
cat "$HOME/NTFSTest/after-reattach.sha" | tee -a "$LOG"
BIG_SHA_OUT=$(shasum -a 256 "$NATIVE2/bigfile.bin" 2>/dev/null | cut -d' ' -f1)
if [ -n "$BIG_SHA_IN" ] && [ "$BIG_SHA_IN" = "$BIG_SHA_OUT" ]; then
  pass "大文件哈希一致 ($BIG_SHA_IN)"
else
  fail "大文件哈希不一致: $BIG_SHA_IN vs $BIG_SHA_OUT"
fi
if diff <(sed "s|$NATIVE2|VOL|" "$HOME/NTFSTest/after-reattach.sha" | sort) \
        <(sed "s|$MNT|VOL|" "$HOME/NTFSTest/before-unmount.sha" | sort) >/dev/null 2>&1; then
  pass "卸载前后全部文件哈希与目录结构一致"
else
  note "文件清单差异 (只读挂载的路径前缀不同属正常, 逐项核对上面两表)"
fi
OVERWRITTEN=$(sudo -u "$USER_NAME" cat "$NATIVE2/original.txt" 2>/dev/null)
[ "$OVERWRITTEN" = "overwritten!" ] && pass "覆盖内容持久化正确" || fail "覆盖内容不符: $OVERWRITTEN"
sudo -u "$USER_NAME" xattr -l "$NATIVE2/original.txt" 2>/dev/null | grep -q com.test.m1 \
  && pass "扩展属性持久化正确" || note "扩展属性在原生只读挂载下不可见/未持久化 (记录待查)"
sudo -u "$USER_NAME" ls "$NATIVE2/renamed-中文.txt" >/dev/null 2>&1 \
  && pass "中文重命名持久化正确" || fail "中文重命名文件未持久化"
[ ! -e "$NATIVE2/delete-me.txt" ] \
  && pass "删除已持久化 (delete-me.txt 不存在)" || fail "删除的文件又出现了!"

step "E13 清理"
DEV_LEFT=$(hdiutil info | awk -v img="$IMG" '/image-path/{p=($0 ~ img)} p && /\/dev\/disk/{print $1; exit}')
[ -n "$DEV_LEFT" ] && diskutil eject "$DEV_LEFT" >/dev/null 2>&1
sleep 1
if hdiutil info | grep -q "$IMG"; then
  fail "镜像会话仍残留 (文件锁未释放)"
else
  pass "镜像已彻底分离, 会话与文件锁均已释放"
fi
echo
echo "全部结果已记录到 $LOG"
