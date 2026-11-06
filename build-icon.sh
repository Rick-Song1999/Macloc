#!/bin/bash
# macloc build-icon —— 生成 MacLocBar 的 App 图标（.icns）
#
#   ./build-icon.sh [dark|light|neon]
#
# 产出：
#   ~/macloc/ui/AppIcon.icns
#
# 原理：tools/makeicon 画 1024×1024 PNG → 切成 iconset 各尺寸 → iconutil 合成 .icns

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

STYLE="${1:-dark}"
MAKEICON="$MACLOC_DIR/tools/makeicon"
OUT="$MACLOC_DIR/ui/AppIcon.icns"
TMP="$(mktemp -d /tmp/macloc-icon.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$MAKEICON" ]; then
    say_info "编译 makeicon…"
    xcrun swiftc -swift-version 5 -O "$MACLOC_DIR/tools/makeicon.swift" -o "$MAKEICON" 2>&1 | grep error | head -10
    codesign -s - -f "$MAKEICON" >/dev/null 2>&1
fi
if [ ! -x "$MAKEICON" ]; then
    say_err "makeicon 编译失败"
    exit 1
fi

say_info "画图标（style=${STYLE}）…"
"$MAKEICON" "$TMP/icon_1024.png" "$STYLE" 1024 >/dev/null

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

# iconutil 需要的具体尺寸
sips -z 16 16   "$TMP/icon_1024.png" --out "$ICONSET/icon_16x16.png"      >/dev/null 2>&1
sips -z 32 32   "$TMP/icon_1024.png" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null 2>&1
sips -z 32 32   "$TMP/icon_1024.png" --out "$ICONSET/icon_32x32.png"      >/dev/null 2>&1
sips -z 64 64   "$TMP/icon_1024.png" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null 2>&1
sips -z 64 64   "$TMP/icon_1024.png" --out "$ICONSET/icon_64x64.png"      >/dev/null 2>&1
sips -z 128 128 "$TMP/icon_1024.png" --out "$ICONSET/icon_64x64@2x.png"   >/dev/null 2>&1
sips -z 128 128 "$TMP/icon_1024.png" --out "$ICONSET/icon_128x128.png"    >/dev/null 2>&1
sips -z 256 256 "$TMP/icon_1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
sips -z 256 256 "$TMP/icon_1024.png" --out "$ICONSET/icon_256x256.png"    >/dev/null 2>&1
sips -z 512 512 "$TMP/icon_1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
sips -z 512 512 "$TMP/icon_1024.png" --out "$ICONSET/icon_512x512.png"    >/dev/null 2>&1
cp "$TMP/icon_1024.png" "$ICONSET/icon_512x512@2x.png"

rm -f "$OUT"
iconutil -c icns "$ICONSET" -o "$OUT" 2>&1 | head -3
if [ ! -f "$OUT" ]; then
    say_err "iconutil 合成失败"
    exit 1
fi

say_ok "已生成 $OUT  ($(du -h "$OUT" | cut -f1))"
say_dim "预览：$MACLOC_DIR/ui/AppIcon-preview-${STYLE}.png"
cp "$TMP/icon_1024.png" "$MACLOC_DIR/ui/AppIcon-preview-${STYLE}.png"
echo
