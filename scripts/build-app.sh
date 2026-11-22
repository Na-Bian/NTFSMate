#!/bin/bash
# build-app.sh — 编译 Swift 包并组装 NTFSMate.app (签名 + 打包 ntfs-3g)
#
# 签名: 优先使用 Apple Development 身份 (SMAppService 需要), 可用
#       NTFSMATE_SIGN_IDENTITY 覆盖; 未找到任何身份时回退 ad-hoc (仅限本机实验)。
# 产物: build/NTFSMate.app, 并可选安装到 /Applications (NTFSMATE_INSTALL=1)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/NTFSMate.app"

echo "==> swift build (release)"
cd "$ROOT"
# 部署目标保持 macOS 13, 但把实际 SDK 版本写入 LC_BUILD_VERSION ——
# AppKit 按"链接 SDK 边界"判定系统外观 (Liquid Glass 窗口设计)。
# 裸 swift build 会把 sdk 字段写成部署目标, 导致整个应用回退旧版窗口设计。
MACOS_MIN_SYSTEM_VERSION="13.0"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
SDK_LINKER_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MACOS_MIN_SYSTEM_VERSION" -Xlinker "$SDK_VERSION")
swift build -c release "${SDK_LINKER_FLAGS[@]}" 2>&1 | tail -3

BIN="$(swift build -c release "${SDK_LINKER_FLAGS[@]}" --show-bin-path)"

echo "==> 组装应用包结构"
# 构建号 = git 提交数 (版本元数据单一来源, 可用 NTFSMATE_BUILD 覆盖)
BUILD_NUMBER="${NTFSMATE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Library/LaunchDaemons" \
         "$APP/Contents/Resources/ntfs3g" \
         "$APP/Contents/Resources/licenses"

# SwiftPM 产物名 = 目标名; 组装时改名为包内角色名
cp "$BIN/NTFSMateApp"  "$APP/Contents/MacOS/NTFSMate"
cp "$BIN/NTFSHelper"   "$APP/Contents/MacOS/ntfs-helper"
cp "$ROOT/Resources/app-Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
echo "  构建号: $BUILD_NUMBER"
cp "$ROOT/Resources/com.ntfsmate.helper.plist" "$APP/Contents/Library/LaunchDaemons/com.ntfsmate.helper.plist"

echo "==> 打包 ntfs-3g (运行时套件; mkntfs 等格式化工具不随发行包携带)"
NTFS_DIST="$ROOT/third_party/dist/ntfs3g"
cp "$NTFS_DIST/bin/ntfs-3g" "$APP/Contents/Resources/ntfs3g/ntfs-3g"
cp "$NTFS_DIST/lib/libntfs-3g.91.dylib" "$APP/Contents/Resources/ntfs3g/libntfs-3g.91.dylib"

echo "==> 修正 ntfs-3g 动态库引用为包内路径"
# 原构建的 libntfs-3g 引用是绝对路径 (third_party/dist), 改为 @loader_path 同目录解析
install_name_tool -change "$NTFS_DIST/lib/libntfs-3g.91.dylib" \
    "@loader_path/libntfs-3g.91.dylib" "$APP/Contents/Resources/ntfs3g/ntfs-3g"
install_name_tool -id "@loader_path/libntfs-3g.91.dylib" \
    "$APP/Contents/Resources/ntfs3g/libntfs-3g.91.dylib"
# 注: @rpath/libfuse-t.dylib 依赖 fuse-t 运行时安装 (系统 /usr/local/lib 或用户级 rpath, M1 记录)

echo "==> 应用图标 (缺失时用 make-icon.swift 生成)"
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    (cd "$ROOT" && swift scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns)
fi
echo "==> 许可证文本随包"
cp "$ROOT/Resources/licenses/"* "$APP/Contents/Resources/licenses/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> 多语言资源 (en / zh-Hans / zh-Hant)"
for lproj in "$ROOT/Resources/l10n/"*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done

echo "==> 签名"
IDENTITY="${NTFSMATE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)
fi
if [ -z "$IDENTITY" ]; then
    echo "  未找到 Apple Development 身份, 回退 ad-hoc 签名 (SMAppService 注册可能受限)"
    IDENTITY="-"
fi
echo "  签名身份: $IDENTITY"

# 时间戳仅公证/发行需要 (M5); 开发签名不强制, 避免依赖苹果 TSA 网络可用性
TS_FLAG=""
if [ "${NTFSMATE_TIMESTAMP:-0}" = "1" ]; then TS_FLAG="--timestamp"; fi

# 顺序: 包内 ntfs-3g → helper → 应用包 (签名需先内后外)
codesign --force $TS_FLAG --sign "$IDENTITY" "$APP/Contents/Resources/ntfs3g/ntfs-3g"
codesign --force $TS_FLAG --sign "$IDENTITY" \
    --identifier "com.ntfsmate.helper" "$APP/Contents/MacOS/ntfs-helper"
codesign --force $TS_FLAG --sign "$IDENTITY" "$APP"

echo "==> 校验签名"
codesign --verify --strict --verbose=1 "$APP" && echo "  应用包签名有效"
codesign --verify --strict --verbose=1 "$APP/Contents/MacOS/ntfs-helper" && echo "  helper 签名有效"

echo "==> 检查 ntfs-3g 运行时依赖"
otool -L "$APP/Contents/Resources/ntfs3g/ntfs-3g"

if [ "${NTFSMATE_INSTALL:-0}" = "1" ]; then
    echo "==> 安装到 /Applications"
    rm -rf "/Applications/NTFSMate.app"
    cp -R "$APP" "/Applications/NTFSMate.app"
    echo "  已安装: /Applications/NTFSMate.app"
fi

echo
echo "完成: $APP"
echo "下一步: NTFSMATE_INSTALL=1 $0 安装到 /Applications 后启动, 在窗口内注册 helper。"
