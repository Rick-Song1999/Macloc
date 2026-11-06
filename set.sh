#!/bin/bash
# macloc set —— 修改模拟坐标
#
#   ./set.sh <纬度> <经度>
#   ./set.sh 39.9042 116.4074      # 北京
#   ./set.sh 35.6762 139.6503      # 东京
#
# 生效方式：写 locationd 偏好 → 重启 locationd（实测坐标变化需要这个状态迁移，
# 单纯的偏好热重载不会让 simulated provider 换点）。
# 每次会弹一次管理员授权框。

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

LAT="${1:-}"
LON="${2:-}"

if [ -z "$LAT" ] || [ -z "$LON" ]; then
    say_err "用法: $0 <纬度> <经度>"
    echo "  例: $0 35.6762 139.6503"
    exit 1
fi
if ! valid_coord "$LAT" "$LON"; then
    say_err "坐标不合法: $LAT $LON  （纬度 -90..90，经度 -180..180）"
    exit 1
fi

echo
say_info "写入坐标 $LAT, $LON 并重启 locationd（会弹管理员授权框）…"
OUT="$(admin_run "$(payload_write_coords "$LAT" "$LON" 1)")"
printf '%s\n' "$OUT" | sed 's/^/  /'
if ! printf '%s\n' "$OUT" | grep -q "^MACLOC_OK$"; then
    say_err "写入/重启失败或授权被取消（详见上面输出）"
    exit 1
fi

sleep 2
N=$(sim_count 10)
save_state "$LAT" "$LON" 1
mkdir -p "$MACLOC_HOME"
printf '%s %s\n' "$LAT" "$LON" > "$MACLOC_HOME/loc.conf"
# 同步 daemon 的权威状态文件（/var/db/macloc/state，root 拥有）
# 否则手动跑 set.sh 之后，status/UI 读到的还是 daemon 里的旧坐标
if [ -S "/var/run/macloc.sock" ]; then
    printf 'SYNC %s %s 1\n' "$LAT" "$LON" | nc -U "/var/run/macloc.sock" 2>/dev/null | head -1 >/dev/null
fi

if [ "$N" -gt 0 ]; then
    say_ok "完成，locationd 10 秒内产出 $N 条模拟定位"
else
    say_warn "未看到 @ClxSimulated，检查日志"
fi
say_dim "验证：open -a Maps"
echo
