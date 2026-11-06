#!/bin/bash
# macloc install —— 一键安装 macOS 全系统定位伪装（偏好通道）
#
#   ./install.sh [纬度 经度]
#
# 做四件事：
#   1. 检查环境（macOS 版本 / 架构 / SIP 状态）
#   2. 打开 macOS「定位服务」总开关（locationd 的 LocationServicesEnabled）
#   3. 打开 locationd 的「允许模拟定位」并写入坐标
#   4. 重启 locationd 并验证
#
# 需要一次系统管理员授权（弹窗输入密码）。

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

LAT="${1:-39.9042}"
LON="${2:-116.4074}"

# 坐标会拼进「以 root 执行的 shell 脚本」，必须先规范化：
# 否则 $(...) / 反引号 / 引号 breakout 就是 root 命令注入。
if ! NORM="$(sanitize_coord "$LAT" "$LON")"; then
    say_err "坐标不合法: $LAT $LON  （纬度 -90..90，经度 -180..180）"
    exit 1
fi
LAT="${NORM%% *}"
LON="${NORM##* }"

echo
printf "${c_blu}══ macloc install ══${c_off}   macOS $(sw_vers -productVersion) ( $(uname -m) )\n"
echo

# ---------------------------------------------------------------- 0. 环境
if [ "$(uname -m)" != "arm64" ]; then
    say_err "只支持 Apple Silicon (arm64)，当前是 $(uname -m)"
    exit 1
fi
SIP="unknown"
if csrutil status 2>/dev/null | grep -q "disabled"; then SIP="disabled"; fi
say_info "SIP: $SIP"
if [ "$SIP" != "disabled" ]; then
    say_dim "偏好通道不需要关 SIP。只有 xpc-push.sh（实时切换）才需要。"
fi

# ---------------------------------------------------------------- 1. 权限
if ! have_admin_prompt; then
    say_err "找不到 osascript，无法弹出管理员授权框"
    exit 1
fi

# ---------------------------------------------------------------- 2. 写偏好 + 重启
say_info "准备写入 locationd 偏好并重启 locationd（会弹管理员授权框，请输入密码）…"
PAYLOAD="$(payload_write_coords "$LAT" "$LON" 1)"
OUT="$(admin_run "$PAYLOAD")"
printf '%s\n' "$OUT" | sed 's/^/  /'
if ! printf '%s\n' "$OUT" | grep -q "^MACLOC_OK$"; then
    say_err "写入/重启失败或授权被取消（详见上面输出）"
    exit 1
fi

# ---------------------------------------------------------------- 3. 验证
sleep 2
N=$(sim_count 10)
if [ "$N" -gt 0 ]; then
    say_ok "locationd 正在产出模拟定位（10 秒内 $N 条 @ClxSimulated）"
else
    say_warn "10 秒内没有 @ClxSimulated，检查日志：/usr/bin/log show --predicate 'process == \"locationd\"' --last 2m --style compact | grep -i simul"
fi

if /usr/bin/log show --predicate 'process == "locationd"' --last 2m --style compact 2>/dev/null \
    | grep -qi "Using simulated location from defaults"; then
    say_ok "偏好通道生效（Using simulated location from defaults）"
fi

save_state "$LAT" "$LON" 1
mkdir -p "$MACLOC_HOME"
printf '%s %s\n' "$LAT" "$LON" > "$MACLOC_HOME/loc.conf"
# 若 daemon 在跑，把它的权威状态也同步成一致（否则 status/UI 读到的还是旧坐标）
if [ -S "/var/run/macloc.sock" ]; then
    printf 'SYNC %s %s 1\n' "$LAT" "$LON" | nc -U "/var/run/macloc.sock" 2>/dev/null | head -1 >/dev/null
fi

echo
say_ok "安装完成，当前坐标 $LAT, $LON"
say_dim "验证：open -a Maps  →  蓝点应落在该坐标"
say_dim "改坐标：./set.sh <纬度> <经度>"
say_dim "关闭：  ./stop.sh"
echo
