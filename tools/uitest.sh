#!/bin/bash
# uitest.sh —— 自动化验证 MacLoc 主窗口：激活 → 读按钮真实位置 → 点击 → 轮询状态
#
#   ./uitest.sh <按钮名>          例如 ./uitest.sh 上海
#   ./uitest.sh --dump            只打印窗口几何
#
# 原理：按钮位置随 Auto Layout / 语言 / 窗口大小变化，硬编码坐标必然过期。
#      这里改用辅助功能 API（AX）直接读按钮在屏幕上的真实位置，再点过去。
#
# ★ 为什么要「点完校验 + 重试」：
#      窗口有弹出动画，动画期间 AX 报的位置可能是旧布局，
#      点下去就打到隔壁按钮（以前就因为这个多发了一条错误城市的 SET）。
#      所以：点完读回坐标，跟目标城市比；不符就**重新取位置再点**，最多 3 轮。
#
# ★ 城市表不写死：直接从 ui/MacLocBar.swift 的 PLACES 里解析
#      （zh / en / 短名 / 坐标全都有），UI 加了新城市这里自动跟上。

set -u
cd "$(dirname "$0")/.."

SRC="ui/MacLocBar.swift"

# App 位置：2026-11 起装在 /Applications（和别的 App 待一起）；
# 老版本可能在 ~/Applications，留个兜底。
if [ -d "/Applications/MacLocBar.app" ]; then
    APP="/Applications/MacLocBar.app"
elif [ -d "$HOME/Applications/MacLocBar.app" ]; then
    APP="$HOME/Applications/MacLocBar.app"
else
    echo "✘ 找不到 MacLocBar.app（/Applications 或 ~/Applications 都没有）"
    exit 1
fi

# 状态文件：daemon 的 root 权威副本优先，用户域副本兜底
STATE_FILE="/var/db/macloc/state"
[ -r "$STATE_FILE" ] || STATE_FILE="$HOME/.macloc/state"

# ---- 城市表：zh|en|enShort|zhShort|lat|lon ----
PLACES_TSV="$(grep -E '^ *Place\(zh:' "$SRC" | sed -E 's/.*zh: "([^"]*)".*en: "([^"]*)".*zhShort: "([^"]*)".*enShort: "([^"]*)".*lat: *(-?[0-9.]+).*lon: *(-?[0-9.]+).*/\1|\2|\3|\4|\5|\6/')"

# 找一行：按 zh/en/短名 任意一个匹配 → 打印 "zh|en|enShort|zhShort|lat lon"
lookup_place() {
    local q="$1" row
    while IFS='|' read -r zh en zhshort enshort lat lon; do
        [ -z "$zh" ] && continue
        if [ "$zh" = "$q" ] || [ "$en" = "$q" ] || [ "$zhshort" = "$q" ] || [ "$enshort" = "$q" ]; then
            echo "$zh|$en|$zhshort|$enshort|$lat $lon"
            return 0
        fi
    done <<< "$PLACES_TSV"
    return 1
}

ax() {   # ax <完整的 AX 表达式>
    osascript -e "tell application \"System Events\" to tell process \"MacLocBar\" to get $1" 2>/dev/null
}

frontmost_app() {
    osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null
}

# 把 MacLocBar 顶到前台，并确认它真的是前台（合成点击只会发给前台 App，
# 前台被别的程序抢走时点击就打到别人身上去了 —— 这就是「点了没反应」的真正原因）
activate_app() {
    local i
    for i in 1 2 3 4 5; do
        osascript -e 'tell application "MacLocBar" to activate' >/dev/null 2>&1
        sleep 0.6
        if [ "$(frontmost_app)" = "MacLocBar" ]; then
            return 0
        fi
    done
    return 1
}

# 等窗口位置稳定下来。
# ★ 激活 App 会触发 applicationShouldHandleReopen → panel.show() → centerOnScreen()，
#   窗口会**移动**。移动过程中 AX 报出来的是旧位置，
#   照着点就会打到别的按钮上（实测：点 Paris 选中了 London）。
#   所以点之前必须等窗口几何连续两次读数一致。
wait_window_stable() {
    local prev="" cur="" i
    for i in $(seq 1 12); do
        cur="$(ax "{position, size} of window 1")"
        if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then
            return 0
        fi
        prev="$cur"
        sleep 0.3
    done
    return 1
}

# 激活 App（把窗口顶到最前，AX 查询和点击都要前台）
open -a "$APP" >/dev/null 2>&1
activate_app || true
sleep 1

if [ "${1:-}" = "--dump" ]; then
    ax "{position, size} of window 1"
    exit 0
fi

NAME="${1:-}"
if [ -z "$NAME" ]; then
    echo "用法: $0 <城市名，例如 上海>"; exit 1
fi

ROW="$(lookup_place "$NAME")"
if [ -z "$ROW" ]; then
    echo "✘ 不认识的城市「${NAME}」（PLACES 里没有）"
    echo "可选：$(printf '%s' "$PLACES_TSV" | cut -d'|' -f1 | tr '\n' ' ')"
    exit 1
fi
P_ZH=$(printf '%s' "$ROW"  | cut -d'|' -f1)
P_EN=$(printf '%s' "$ROW"  | cut -d'|' -f2)
P_ZHS=$(printf '%s' "$ROW" | cut -d'|' -f3)
P_ENS=$(printf '%s' "$ROW" | cut -d'|' -f4)
EXP=$(printf '%s' "$ROW"   | cut -d'|' -f5)
T_LAT=$(printf '%s' "$EXP" | cut -d' ' -f1)
T_LON=$(printf '%s' "$EXP" | cut -d' ' -f2)

# 坐标差是否在容差内（0.02 度 ≈ 2 公里）
coords_match() {
    awk -v a="$1" -v b="$2" -v c="$3" -v d="$4" '
        BEGIN { da = a - c; if (da < 0) da = -da; db = b - d; if (db < 0) db = -db;
                exit ((da <= 0.02 && db <= 0.02) ? 0 : 1) }'
}

# 找按钮当前真实位置；输出 "X Y W H 按钮名"
# 候选名 = 中/英/短名（中英文界面都试），当前城市会带 "✓ " 前缀
find_button() {
    local cand p size X Y W H
    for cand in "$P_ZH" "✓ $P_ZH" "$P_EN" "✓ $P_EN" \
                "$P_ZHS" "✓ $P_ZHS" "$P_ENS" "✓ $P_ENS"; do
        p="$(ax "position of button \"$cand\" of window 1")"
        [ -n "$p" ] && [ "$p" != "missing value" ] || continue
        size="$(ax "size of button \"$cand\" of window 1")"
        [ -n "$size" ] && [ "$size" != "missing value" ] || size="80, 26"
        X=$(echo "$p"    | cut -d, -f1 | tr -d ' ')
        Y=$(echo "$p"    | cut -d, -f2 | tr -d ' ')
        W=$(echo "$size" | cut -d, -f1 | tr -d ' ')
        H=$(echo "$size" | cut -d, -f2 | tr -d ' ')
        echo "$X $Y $W $H $cand"
        return 0
    done
    return 1
}

# ★ 主用 AXPress：直接让辅助功能触发按钮，不经过屏幕坐标。
#   合成鼠标事件有两个坑：① 窗口激活时会移动，AX 读到的可能是旧位置
#   （实测：点 Paris 选中了 London）；② 第一个点击有时只是「激活窗口」被吞掉。
#   AXPress 两个坑都没有。
press_button() {   # press_button <按钮名>
    osascript -e "tell application \"System Events\" to tell process \"MacLocBar\" to perform action \"AXPress\" of button \"$1\" of window 1" >/dev/null 2>&1
}

echo "状态文件: $STATE_FILE"
echo "目标城市: ${P_ZH} (${P_EN})  目标坐标: ${T_LAT} ${T_LON}"

T0=$(date +%s)
LAST_AT="$(grep MACLOC_AT "$STATE_FILE" 2>/dev/null | tr -d '"')"

for attempt in 1 2 3; do
    # 每轮点之前都强制置前台（用户同时用别的 App 时会抢焦点）
    if ! activate_app; then
        echo "✘ 无法把 MacLocBar 置前台（当前前台：$(frontmost_app)）"
        exit 1
    fi
    read -r X Y W H FOUND <<< "$(find_button)" || {
        echo "✘ 找不到按钮「${NAME}」（主窗口可能没开）"
        exit 1
    }
    CX=$((X + W / 2))
    CY=$((Y + H / 2))
    if press_button "$FOUND"; then
        echo "[第 ${attempt} 轮] AXPress 按钮「${FOUND}」@($X,$Y)"
    else
        # AXPress 用不了（按钮禁用 / AX 异常）→ 退回合成点击
        wait_window_stable || true
        echo "[第 ${attempt} 轮] 合成点击按钮「${FOUND}」@($CX,$CY)"
        ./tools/click "$CX" "$CY"
    fi

    NOW=""; AT=""
    for i in $(seq 1 25); do
        sleep 2
        # 一次性读快照：NOW 和 AT 必须来自同一份文件，
        # 否则 daemon 原子替换状态文件时，两个 grep 会读到不同版本，串出旧坐标。
        SNAP="$(cat "$STATE_FILE" 2>/dev/null)"
        NOW="$(printf '%s' "$SNAP" | grep MACLOC_LAT | tr -d '"')"
        AT="$(printf '%s' "$SNAP" | grep MACLOC_AT | tr -d '"')"
        if [ -n "$AT" ] && [ "$AT" != "$LAST_AT" ]; then
            break
        fi
        LAST_AT="$AT"
    done

    if [ -z "$AT" ] || [ "$AT" = "$LAST_AT" ]; then
        echo "✘ 50 秒内状态未更新（当前 ${NOW}）"
        grep MACLOC_ "$STATE_FILE" 2>/dev/null
        exit 1
    fi

    # ★ 校验：点中的必须是目标城市，否则重新取位置再点
    A_LAT="$(printf '%s' "$NOW" | sed 's/.*=//')"
    A_LON="$(grep MACLOC_LON "$STATE_FILE" | tr -d '"' | sed 's/.*=//')"
    if coords_match "$A_LAT" "$A_LON" "$T_LAT" "$T_LON"; then
        echo "✔ 生效：${NOW} / ${A_LON}  (耗时 $(( $(date +%s) - T0 ))s)"
        grep MACLOC_ "$STATE_FILE"
        exit 0
    fi
    echo "⚠ 点歪了：实际=${A_LAT},${A_LON} 目标=${T_LAT},${T_LON} → 重新取位置再点"
    LAST_AT="$AT"
done

echo "✘ 重试 3 轮都不是目标城市（最后实际：${NOW}）"
grep MACLOC_ "$STATE_FILE" 2>/dev/null
exit 1
