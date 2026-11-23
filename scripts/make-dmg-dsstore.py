#!/usr/bin/env python3
# make-dmg-dsstore.py — 程序化生成 DMG 卷的 .DS_Store (dmgbuild 同款字段, 完全确定性)
# 用法: python3 scripts/make-dmg-dsstore.py <stage-dir> <bg-relative-path> <app-name>
#   <stage-dir>       DMG staging 目录 (含 .background/<bg>、<app>.app、Applications 链接)
#   <bg-relative-path> 背景图相对卷根路径, 如 .background/NTFSMate-dmg-background.png
# 取代 AppleScript 方案: Finder 异步写盘不可靠, 此脚本直接产出最终 .DS_Store。
import os
import sys
import plistlib

from ds_store import DSStore
import mac_alias

# Finder 窗口布局 (pt)。窗口 frame 含标题栏(~28pt), 故高 428 → 内容恰 640×400,
# 与背景图 (1280×800 px @144dpi = 640×400 pt) 精确一致。
WINDOW_BOUNDS = "{{100, 100}, {640, 428}}"
ICON_SIZE = 112.0
TEXT_SIZE = 13.0
ICON_LOCATIONS = {
    # 图标位置 = 图标中心 (pt)
    "Applications": (475, 220),
}


def main():
    stage = sys.argv[1]
    bg_rel = sys.argv[2]
    app_name = sys.argv[3]

    bg_abs = os.path.join(stage, bg_rel)
    ds_path = os.path.join(stage, ".DS_Store")

    alias = mac_alias.Alias.for_file(bg_abs)

    bwsp = {
        "ShowStatusBar": False,
        "WindowBounds": WINDOW_BOUNDS,
        "ContainerShowSidebar": False,
        "PreviewPaneVisibility": False,
        "SidebarWidth": 0,
        "ShowTabView": False,
        "ShowToolbar": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
    }

    icvp = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,                       # 2 = 图片背景
        "backgroundImageAlias": alias.to_bytes(),  # 指向卷内背景图
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": False,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": TEXT_SIZE,
        "iconSize": ICON_SIZE,
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }

    icvl = (b"type", "icnv")  # 默认视图 = 图标视图

    d = DSStore.open(ds_path, "w+")
    d["."]["vSrn"] = ("long", 1)
    d["."]["bwsp"] = bwsp
    d["."]["icvp"] = icvp
    d["."]["icvl"] = icvl

    d[app_name + ".app"]["Iloc"] = (165, 220)
    for name, loc in ICON_LOCATIONS.items():
        d[name]["Iloc"] = loc
    d.flush()
    d.close()

    print(f".DS_Store 已生成: {ds_path} ({os.path.getsize(ds_path)} 字节)")


if __name__ == "__main__":
    main()
