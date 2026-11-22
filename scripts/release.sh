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

echo "[release] 品牌化 DMG (背景图 + Finder 布局, 参考 MarkLeaf create-branded-dmg.sh)"
DMG_VOLUME_NAME="${NTFSMATE_DMG_VOLUME_NAME:-$APP_NAME $APP_VERSION}"
SETUP_VOLUME_NAME="$DMG_VOLUME_NAME"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ntfsmate-branded-dmg.XXXXXX")"
STAGE_DIR="$BUILD_ROOT/stage"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ntfsmate-dmg-vol.XXXXXX")"
RW_DMG="$BUILD_ROOT/NTFSMate-rw.dmg"
ATTACHED=0
APP_SIZE_KB="$(du -sk "$APP_STAGE" | awk '{print $1}')"
DMG_SIZE_KB="$((APP_SIZE_KB + 65536))"
cleanup_dmg() {
    if [ "${ATTACHED:-0}" = 1 ]; then hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true; fi
    rm -rf "$BUILD_ROOT" "${DMG_STAGING:-}" "$APP_STAGE" 2>/dev/null || true
}
trap cleanup_dmg EXIT

# 1) stage: 应用 + Applications 链接 + 背景
mkdir -p "$STAGE_DIR/$APP_NAME.app"
cp -R "$APP_STAGE/" "$STAGE_DIR/$APP_NAME.app/"
ln -s /Applications "$STAGE_DIR/Applications"
bash "$HERE/ntfsmate-dmg-layout.sh" prepare "$STAGE_DIR"

# 2) 建临时可读写 DMG 并挂载 (错误即中止; tail 吞错会产出半成品)
if ! hdiutil create -volname "$SETUP_VOLUME_NAME" -size "${DMG_SIZE_KB}k" -srcfolder "$STAGE_DIR" \
    -ov -format UDRW "$RW_DMG" >/dev/null; then
    fail "hdiutil create 失败"
fi
if ! hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_DIR" -nobrowse -quiet; then
    fail "hdiutil attach 失败"
fi
ATTACHED=1

# 3) 应用 Finder 布局 (AppleScript)。Finder 异步写 .DS_Store, 必须验证落盘,
#    否则 convert 产出的 DMG 没有背景布局 (实测踩坑)
LAYOUT_OK=0
for attempt in 1 2 3; do
    bash "$HERE/ntfsmate-dmg-layout.sh" apply "$MOUNT_DIR"
    sync
    for _ in $(seq 1 10); do
        [ -f "$MOUNT_DIR/.DS_Store" ] && break
        sleep 1
    done
    if [ -f "$MOUNT_DIR/.DS_Store" ]; then
        echo "[release] Finder 布局已落盘 (尝试 $attempt)"
        LAYOUT_OK=1
        break
    fi
    echo "[release] 布局未落盘, 重试 ($attempt/3)..."
done
[ "$LAYOUT_OK" = "1" ] || fail ".DS_Store 迟迟未落盘, Finder 布局失败"
sync
sleep 1

# 4) 卸载 (必须成功, 否则 convert 会拷出未写盘的卷) 并转换为压缩 UDZO
if ! hdiutil detach "$MOUNT_DIR" -quiet; then
    fail "hdiutil detach 失败"
fi
ATTACHED=0
if ! hdiutil convert "$RW_DMG" -format UDZO -o "$APP_DMG" -ov >/dev/null; then
    fail "hdiutil convert 失败"
fi

# 5) 终验: 挂载最终 DMG, 确认 .DS_Store 与背景图都在
FINAL_VOL="$(mktemp -d "${TMPDIR:-/tmp}/ntfsmate-verify.XXXXXX")"
if hdiutil attach "$APP_DMG" -mountpoint "$FINAL_VOL" -nobrowse -quiet; then
    [ -f "$FINAL_VOL/.DS_Store" ] || { hdiutil detach "$FINAL_VOL" -quiet || true; fail "最终 DMG 缺少 .DS_Store (布局未持久化)"; }
    [ -f "$FINAL_VOL/.background/$BACKGROUND_NAME" ] || { hdiutil detach "$FINAL_VOL" -quiet || true; fail "最终 DMG 缺少背景图"; }
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
