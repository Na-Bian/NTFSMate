#!/usr/bin/env bash
# ntfsmate-dmg-layout.sh — 品牌化 DMG Finder 布局 (参考 MarkLeaf markleaf-dmg-layout.sh 模式)
#
# 用法:
#   $0 prepare <stage-dir>     — 装入背景图到 stage/.background (隐藏)
#   $0 apply <mounted-volume>  — 对已挂载卷应用 Finder 图标布局 (AppleScript)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKGROUND_NAME="NTFSMate-dmg-background.png"
BACKGROUND_SOURCE="$HERE/dmg-assets/$BACKGROUND_NAME"

# Finder 布局参数 (逻辑 640×400 窗口; 与背景图设计对位)
WINDOW_BOUNDS="{100, 100, 740, 500}"     # 左, 上, 右, 下
ICON_SIZE=112
APP_POSITION="{165, 220}"                # 应用图标 (左)
APPS_POSITION="{475, 220}"               # Applications 链接 (右, 箭头指向处)

usage() { echo "Usage: $0 prepare <stage-dir> | apply <mounted-volume>" >&2; exit 2; }
fail() { echo "[dmg-layout] error: $*" >&2; exit 1; }
[ "$#" -eq 2 ] || usage
ACTION="$1"; DMG_ROOT="$2"
[ -d "$DMG_ROOT" ] || fail "目录不存在: $DMG_ROOT"

case "$ACTION" in
    prepare)
        [ -f "$BACKGROUND_SOURCE" ] || fail "缺少 DMG 背景: $BACKGROUND_SOURCE"
        mkdir -p "$DMG_ROOT/.background"
        cp "$BACKGROUND_SOURCE" "$DMG_ROOT/.background/$BACKGROUND_NAME"
        xattr -c "$DMG_ROOT/.background/$BACKGROUND_NAME" 2>/dev/null || true
        # 强制 144dpi (@2x): Finder 按 pt 渲染背景图, 72dpi 会让整图放大一倍
        # sips 写入成功也会打印 "Error 2" 虚警并以非零退出 — 容忍之, 以下 DPI_W 校验才是真关卡
        sips -s dpiWidth=144 -s dpiHeight=144 "$DMG_ROOT/.background/$BACKGROUND_NAME" >/dev/null 2>&1 || true
        DPI_W=$(sips -g dpiWidth "$DMG_ROOT/.background/$BACKGROUND_NAME" | awk '/dpiWidth/{print $2}')
        [ "$DPI_W" = "144.000" ] || fail "背景图 DPI 写入失败 (got $DPI_W)"
        chflags hidden "$DMG_ROOT/.background" 2>/dev/null || true
        echo '[dmg-layout] 背景图已装入 stage (144dpi)'
        ;;
    apply)
        OSASCRIPT_BIN="${OSASCRIPT_BIN:-/usr/bin/osascript}"
        [ -x "$OSASCRIPT_BIN" ] || fail 'osascript 不可用; 拒绝生成无品牌布局的 DMG'
        MOUNTED_PATH="$(cd "$DMG_ROOT" && pwd)"
        echo "[dmg-layout] 应用 Finder 布局: $MOUNTED_PATH"
        if ! "$OSASCRIPT_BIN" - "$MOUNTED_PATH" <<APPLESCRIPT
on run argv
    set mountedPath to item 1 of argv
    tell application "Finder"
        set targetDisk to disk (POSIX file mountedPath as alias)
        try
            set oldWindow to container window of targetDisk
            close oldWindow
        end try
        open targetDisk
        delay 4
        set targetWindow to container window of targetDisk
        set current view of targetWindow to icon view
        set toolbar visible of targetWindow to false
        set statusbar visible of targetWindow to false
        set pathbar visible of targetWindow to false
        set bounds of targetWindow to $WINDOW_BOUNDS
        set viewOptions to icon view options of targetWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set text size of viewOptions to 13
        set backgroundFile to (POSIX file (mountedPath & "/.background/$BACKGROUND_NAME")) as alias
        set background picture of viewOptions to backgroundFile
        delay 3
        set position of item "NTFSMate.app" of targetDisk to $APP_POSITION
        set position of item "Applications" of targetDisk to $APPS_POSITION
        update targetDisk without registering applications
        delay 2
        try
            tell application "System Events"
                tell process "Finder"
                    set frontmost to true
                    perform action "AXRaise" of window (name of targetWindow)
                    if exists menu item "Hide Sidebar" of menu 1 of menu bar item "View" of menu bar 1 then
                        click menu item "Hide Sidebar" of menu 1 of menu bar item "View" of menu bar 1
                    end if
                end tell
            end tell
        end try
        delay 1
        close targetWindow
    end tell
end run
APPLESCRIPT
        then
            fail 'Finder 布局应用失败; 拒绝生成无品牌布局的 DMG'
        fi
        echo '[dmg-layout] Finder 布局已应用'
        ;;
    *) usage ;;
esac
