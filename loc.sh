#!/bin/bash
# macloc loc —— 改坐标（自动选通道）
#
#   ./loc.sh 51.49433 -0.08350       # 伦敦
#   ./loc.sh 39.9042 116.4074        # 北京
#
# 通道优先级：
#   1) daemon（/var/run/macloc.sock）→ 免密码，秒切
#   2) set.sh（osascript 授权框）    → 没装 daemon 时的回退

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

LAT="${1:-}"
LON="${2:-}"

if [ -z "$LAT" ] || [ -z "$LON" ]; then
    say_err "用法: $0 <纬度> <经度>"
    echo "  例: $0 51.49433 -0.08350    # 伦敦"
    exit 1
fi
if ! valid_coord "$LAT" "$LON"; then
    say_err "坐标不合法: $LAT $LON"
    exit 1
fi

SOCK="/var/run/macloc.sock"
if [ -S "$SOCK" ]; then
    say_info "走 daemon 通道（免密码）…"
    RESP="$(printf 'SET %s %s\n' "$LAT" "$LON" | nc -U "$SOCK" 2>/dev/null | head -1)"
    case "$RESP" in
        OK*)
            sleep 2
            N=$(sim_count 10)
            save_state "$LAT" "$LON" 1
            mkdir -p "$MACLOC_HOME"
            printf '%s %s\n' "$LAT" "$LON" > "$MACLOC_HOME/loc.conf"
            say_ok "完成（daemon），locationd 10 秒内产出 $N 条模拟定位"
            exit 0
            ;;
        ERR*)
            say_err "daemon 返回: $RESP"
            exit 1
            ;;
    esac
    say_warn "daemon 无响应，回退到授权框通道"
fi

exec ./set.sh "$LAT" "$LON"
