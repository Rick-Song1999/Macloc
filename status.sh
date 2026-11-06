#!/bin/bash
# macloc status —— 查看当前定位伪装状态
#
#   ./status.sh

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

echo
printf "${c_blu}══ macloc status ══${c_off}\n"
echo

# --- daemon 通道 ---
SOCK="/var/run/macloc.sock"
if [ -S "$SOCK" ]; then
    PONG="$(printf 'PING\n' | nc -U "$SOCK" 2>/dev/null | head -1)"
    if [ "$PONG" = "PONG" ]; then
        say_ok "daemon 通道    : 运行中（免密码，socket=${SOCK}）"
        ST="$(printf 'STATUS\n' | nc -U "$SOCK" 2>/dev/null | head -1)"
        say_dim "daemon 状态    : $ST"
    else
        say_warn "daemon 通道    : socket 在但无响应（${PONG}）"
    fi
else
    say_dim "daemon 通道    : 未安装（./install-daemon.sh 可装，之后改坐标免密码）"
fi

# --- 本地记录 ---
if read_state; then
    if [ "${MACLOC_ON:-0}" = "1" ]; then
        say_info "本地记录坐标 : ${MACLOC_LAT}, ${MACLOC_LON}   (${MACLOC_AT})"
    else
        say_info "本地记录坐标 : 已关闭"
    fi
else
    say_dim "本地记录坐标 : 无（还没跑过 install.sh / set.sh）"
fi

# --- locationd 是否在产出模拟定位 ---
N=$(sim_count 15)
if [ "$N" -gt 0 ]; then
    say_ok "locationd 模拟定位 : 生效中（15 秒内 $N 条 @ClxSimulated）"
else
    say_warn "locationd 模拟定位 : 未生效（15 秒内 0 条 @ClxSimulated）"
fi

# --- 偏好通道判据 ---
if /usr/bin/log show --predicate 'process == "locationd"' --last 10m --style compact 2>/dev/null \
    | grep -qi "Using simulated location from defaults"; then
    say_ok "偏好通道      : 已启用（locationd 从 defaults 读取模拟坐标）"
else
    say_dim "偏好通道      : 最近 10 分钟无 'Using simulated location from defaults'"
fi

# --- 总开关 ---
if /usr/bin/log show --predicate 'process == "locationd"' --last 10m --style compact 2>/dev/null \
    | grep -qi "location disabled system-wide"; then
    say_err "定位服务总开关: 关闭中（location disabled system-wide）→ 所有 App 拿不到位置"
else
    say_ok "定位服务总开关: 打开"
fi

# --- 注入通道 ---
INJ="$(launchctl getenv DYLD_INSERT_LIBRARIES 2>/dev/null)"
if [ -n "$INJ" ]; then
    say_info "XPC 注入通道  : 活跃  DYLD_INSERT_LIBRARIES=$INJ"
    if [ -f "$MACLOC_HOME/spoof.log" ]; then
        say_dim "$(tail -3 "$MACLOC_HOME/spoof.log" | tr '\n' ' ')"
    fi
else
    say_dim "XPC 注入通道  : 未启用（偏好通道独立工作）"
fi

# --- locationd 进程 ---
say_dim "locationd pid : $(pgrep -x locationd | head -1)   SIP: $(csrutil status 2>/dev/null | tr -d '\n')"
echo
