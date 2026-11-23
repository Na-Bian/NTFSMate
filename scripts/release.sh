#!/bin/bash
# release.sh — 自签名发行包 (参考 MarkLeaf release/package.sh 模式)
#
# 产物 (dist/release/):
#   NTFSMate-<ver>-macos-<arch>.zip     — 应用压缩包 (分发主体)
#   NTFSMate-<ver>-macos-<arch>.dmg     — 拖拽安装镜像
#   SHA256SUMS.txt                      — 全部产物校验值
#
# 签名: ad-hoc (自签名)。接收方首次打开需右键 → 打开 (Gatekeeper 提示)。
# 正式发行: NTFSMATE_SIGN_IDENTITY="Developer ID Application: …" NTFSMATE_TIMESTAMP=1 ./scripts/release.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP_NAME="NTFSMate"
fail() { echo "[release] error: $*" >&2; exit 1; }
BACKGROUND_NAME="NTFSMate-dmg-background.png"
APP_VERSION="${NTFSMATE_VERSION:-0.4.0}"
ARCH="$(uname -m | sed 's/x86_64/x86_64/;s/arm64/arm64/')"
OUTPUT_DIR="${1:-$ROOT/dist/release}"

# --- 构建 (与 build-app.sh 同源的 SDK 链接参数) ---
cd "$ROOT"
MACOS_MIN_SYSTEM_VERSION="13.0"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_LINKER_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MACOS_MIN_SYSTEM_VERSION" -Xlinker "$SDK_VERSION")

echo "[release] swift build $APP_VERSION ($ARCH)"
swift build -c release "${SDK_LINKER_FLAGS[@]}" 2>&1 | tail -2
BIN="$(swift build -c release "${SDK_LINKER_FLAGS[@]}" --show-bin-path)"

# --- 组装应用包 ---
BUILD_NUMBER="${NTFSMATE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ntfsmate-release.XXXXXX")/$APP_NAME.app"
mkdir -p "$APP_STAGE/Contents/MacOS" "$APP_STAGE/Contents/Library/LaunchDaemons" \
         "$APP_STAGE/Contents/Resources/ntfs3g" "$APP_STAGE/Contents/Resources/licenses"
cp "$BIN/NTFSMateApp"  "$APP_STAGE/Contents/MacOS/NTFSMate"
cp "$BIN/NTFSHelper"   "$APP_STAGE/Contents/MacOS/ntfs-helper"
cp "$ROOT/Resources/app-Info.plist" "$APP_STAGE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_STAGE/Contents/Info.plist"
cp "$ROOT/Resources/com.ntfsmate.helper.plist" "$APP_STAGE/Contents/Library/LaunchDaemons/com.ntfsmate.helper.plist"
cp "$ROOT/third_party/dist/ntfs3g/bin/ntfs-3g" "$APP_STAGE/Contents/Resources/ntfs3g/ntfs-3g"
cp "$ROOT/third_party/dist/ntfs3g/lib/libntfs-3g.91.dylib" "$APP_STAGE/Contents/Resources/ntfs3g/libntfs-3g.91.dylib"
install_name_tool -change "$ROOT/third_party/dist/ntfs3g/lib/libntfs-3g.91.dylib" \
    "@loader_path/libntfs-3g.91.dylib" "$APP_STAGE/Contents/Resources/ntfs3g/ntfs-3g"
install_name_tool -id "@loader_path/libntfs-3g.91.dylib" \
    "$APP_STAGE/Contents/Resources/ntfs3g/libntfs-3g.91.dylib"
cp "$ROOT/Resources/licenses/"* "$APP_STAGE/Contents/Resources/licenses/"
cp "$ROOT/Resources/AppIcon.icns" "$APP_STAGE/Contents/Resources/AppIcon.icns"
for lproj in "$ROOT/Resources/l10n/"*.lproj; do cp -R "$lproj" "$APP_STAGE/Contents/Resources/"; done

# --- 签名 (内→外) ---
IDENTITY="${NTFSMATE_SIGN_IDENTITY:--}"
TS_FLAG=""; [ "${NTFSMATE_TIMESTAMP:-0}" = "1" ] && TS_FLAG="--timestamp"
echo "[release] signing (identity: $IDENTITY)"
codesign --force $TS_FLAG --sign "$IDENTITY" "$APP_STAGE/Contents/Resources/ntfs3g/ntfs-3g" >/dev/null
codesign --force $TS_FLAG --sign "$IDENTITY" --identifier "com.ntfsmate.helper" \
    "$APP_STAGE/Contents/MacOS/ntfs-helper" >/dev/null
codesign --force $TS_FLAG --sign "$IDENTITY" "$APP_STAGE" >/dev/null
codesign --verify --deep --strict "$APP_STAGE" && echo "[release] 签名校验通过"
xattr -cr "$APP_STAGE"

# --- 产物 ---
mkdir -p "$OUTPUT_DIR"
APP_ZIP="$OUTPUT_DIR/$APP_NAME-$APP_VERSION-macos-$ARCH.zip"
APP_DMG="$OUTPUT_DIR/$APP_NAME-$APP_VERSION-macos-$ARCH.dmg"
rm -f "$APP_ZIP" "$APP_DMG" "$OUTPUT_DIR/SHA256SUMS.txt"

echo "[release] ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_STAGE" "$APP_ZIP"

echo "[release] 品牌化 DMG (确定性 .DS_Store, dmgbuild 同款字段)"
DMG_VOLUME_NAME="${NTFSMATE_DMG_VOLUME_NAME:-$APP_NAME $APP_VERSION}"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ntfsmate-dmg.XXXXXX")"
RW_DMG="$(mktemp -u "${TMPDIR:-/tmp}/ntfsmate-rw.XXXXXX").dmg"
APP_SIZE_KB="$(du -sk "$APP_STAGE" | awk '{print $1}')"
DMG_SIZE_KB="$((APP_SIZE_KB + 65536))"
cleanup_dmg() { rm -rf "$STAGE_DIR" "$APP_STAGE"; rm -f "$RW_DMG"; }
trap cleanup_dmg EXIT

mkdir -p "$STAGE_DIR/$APP_NAME.app"
cp -R "$APP_STAGE/" "$STAGE_DIR/$APP_NAME.app/"
ln -s /Applications "$STAGE_DIR/Applications"
mkdir -p "$STAGE_DIR/.background"
cp "$HERE/dmg-assets/NTFSMate-dmg-background.png" "$STAGE_DIR/.background/NTFSMate-dmg-background.png"
python3 "$HERE/set-png-dpi.py" "$STAGE_DIR/.background/NTFSMate-dmg-background.png" 144 >/dev/null
DPI_W=$(sips -g dpiWidth "$STAGE_DIR/.background/NTFSMate-dmg-background.png" | awk '/dpiWidth/{print $2}')
[ "$DPI_W" = "144.000" ] || fail "背景图 DPI 写入失败 (got $DPI_W)"

# .DS_Store 需在真实挂载卷上生成 (mac_alias 解析卷 fsid; 临时目录的 fsid 超出 32 位)
hdiutil create -volname "$DMG_VOLUME_NAME" -size "${DMG_SIZE_KB}k" -srcfolder "$STAGE_DIR" \
    -ov -format UDRW "$RW_DMG" >/dev/null || fail "hdiutil create 失败"
# 挂到唯一构建挂载点 (用户可能挂着同名的发行 DMG, 直接用卷名会写错卷)
MOUNT_DIR="/Volumes/ntfsmate-build-$$"
if ! hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet; then fail "hdiutil attach 失败"; fi
ATTACHED=1

# 确定性 .DS_Store: 图标位置/背景 alias/窗口尺寸一次写死 (venv 由 scripts/setup-dmgvenv.sh 创建)
VENV_PY="$ROOT/.build/dmgvenv/bin/python"
[ -x "$VENV_PY" ] || fail "缺少 $VENV_PY (运行 scripts/setup-dmgvenv.sh)"
"$VENV_PY" "$HERE/make-dmg-dsstore.py" "$MOUNT_DIR" ".background/NTFSMate-dmg-background.png" "$APP_NAME"
[ -f "$MOUNT_DIR/.DS_Store" ] || fail ".DS_Store 未生成"
sync
sleep 1
if ! hdiutil detach "$MOUNT_DIR" -quiet; then fail "hdiutil detach 失败"; fi
ATTACHED=0

hdiutil convert "$RW_DMG" -format UDZO -o "$APP_DMG" -ov >/dev/null || fail "hdiutil convert 失败"

# 终验: 挂载最终 DMG, 确认 .DS_Store 与背景图都在
FINAL_VOL="$(mktemp -d "${TMPDIR:-/tmp}/ntfsmate-verify.XXXXXX")"
if hdiutil attach "$APP_DMG" -mountpoint "$FINAL_VOL" -nobrowse -quiet; then
    [ -f "$FINAL_VOL/.DS_Store" ] || { hdiutil detach "$FINAL_VOL" -quiet || true; fail "最终 DMG 缺少 .DS_Store"; }
    [ -f "$FINAL_VOL/.background/NTFSMate-dmg-background.png" ] || { hdiutil detach "$FINAL_VOL" -quiet || true; fail "最终 DMG 缺少背景图"; }
    hdiutil detach "$FINAL_VOL" -quiet
    rmdir "$FINAL_VOL"
    echo "[release] 最终 DMG 布局验证通过"
else
    fail "最终 DMG 无法挂载验证"
fi

echo "[release] SHA-256 校验值"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$(basename "$APP_ZIP")" "$(basename "$APP_DMG")" > SHA256SUMS.txt
    cat SHA256SUMS.txt
)

echo
echo "[release] 完成: $OUTPUT_DIR"
ls -lh "$APP_ZIP" "$APP_DMG" "$OUTPUT_DIR/SHA256SUMS.txt"
