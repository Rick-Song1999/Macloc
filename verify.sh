#!/bin/bash
# macloc verify —— 自动验证伪装是否生效
#
#   ./verify.sh            打开地图 → 截图 → 自动找出「当前位置」蓝点 → 裁出特写
#   ./verify.sh --quiet    只输出坐标，不切前台
#
# 输出：
#   ~/macloc/verify.png    蓝点特写（人眼看一眼就知道对不对）
#   终端上打印蓝点在屏幕上的像素坐标
#
# 原理：Apple 地图「当前位置」蓝点颜色实测为 RGB(0,145,255)，
#       tools/finddot 在截屏里按这个颜色做聚类。

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

SHOT="$MACLOC_HOME/shot.png"
OUT="$MACLOC_HOME/verify.png"
FINDDOT="$MACLOC_DIR/tools/finddot"

if [ ! -x "$FINDDOT" ]; then
    say_info "编译 finddot…"
    xcrun clang -fobjc-arc -framework Foundation -framework CoreGraphics \
        -framework ImageIO -framework UniformTypeIdentifiers \
        -o "$FINDDOT" "$MACLOC_DIR/tools/finddot.m" 2>/dev/null \
        && codesign -s - -f "$FINDDOT" >/dev/null 2>&1
fi
if [ ! -x "$FINDDOT" ]; then
    say_err "finddot 编译失败（需要 Xcode Command Line Tools）"
    exit 1
fi

if [ "${1:-}" != "--quiet" ]; then
    open -a Maps
    sleep 9
fi

screencapture -x "$SHOT"
OUTLINE="$("$FINDDOT" "$SHOT" "$OUT" 2>&1)"
printf '%s\n' "$OUTLINE" | sed 's/^/  /'

if printf '%s\n' "$OUTLINE" | grep -q '^DOT_PX'; then
    say_ok "找到蓝点，特写已存到 $OUT"
    say_dim "open $OUT   # 看一眼就知道在不在目标位置"
else
    say_warn "没在截屏里找到蓝点（Maps 可能被遮挡，或模拟没生效）"
fi

# 同时报告 locationd 是否还在产出模拟位置
N=$(sim_count 10)
[ "$N" -gt 0 ] && say_ok "locationd 10 秒内产出 $N 条 @ClxSimulated" \
               || say_warn "locationd 最近 10 秒没有 @ClxSimulated"
echo
