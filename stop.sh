#!/bin/bash
# macloc stop —— 关闭模拟定位，恢复原始行为
#
#   ./stop.sh
#
# 通道优先级：
#   1) daemon（/var/run/macloc.sock）→ 免密码
#   2) osascript 授权框 → 没装 daemon 时的回退
#
# 清掉 AllowSimulatedLocations 与坐标，重启 locationd。
# 「定位服务」总开关保持原样（开了方便以后再用）。

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

SOCK="/var/run/macloc.sock"
if [ -S "$SOCK" ]; then
    say_info "走 daemon 通道（免密码）关闭模拟定位…"
    RESP="$(printf 'OFF\n' | nc -U "$SOCK" 2>/dev/null | head -1)"
    case "$RESP" in
        OK*)
            # 等 provider 彻底停下来再统计。
            # 原来的 10 秒窗口会把「关闭之前」的那几条也算进来，误报「可能还有 XPC 通道」。
            sleep 3
            N=$(sim_count 4)
            save_state "" "" 0
            rm -f "$MACLOC_HOME/loc.conf"
            if [ "$N" -eq 0 ]; then
                say_ok "模拟定位已关闭（4 秒内 0 条 @ClxSimulated）"
            else
                say_warn "仍有 $N 条 @ClxSimulated，可能有 XPC 通道在跑：./xpc-push.sh --stop"
            fi
            exit 0
            ;;
        ERR*)
            say_err "daemon 返回: $RESP"
            exit 1
            ;;
    esac
    say_warn "daemon 无响应，回退到授权框通道"
fi

echo
say_info "关闭模拟定位并重启 locationd（会弹管理员授权框）…"
OUT="$(admin_run "$(payload_write_coords 0 0 0)")"
printf '%s\n' "$OUT" | sed 's/^/  /'
if ! printf '%s\n' "$OUT" | grep -q "^MACLOC_OK$"; then
    say_err "操作失败或授权被取消（详见上面输出）"
    exit 1
fi

sleep 3
N=$(sim_count 4)
save_state "" "" 0
rm -f "$MACLOC_HOME/loc.conf"
# 同步 daemon 的权威状态文件（关掉了就要让 UI 也读到 off）
if [ -S "/var/run/macloc.sock" ]; then
    printf 'SYNC 0 0 0\n' | nc -U "/var/run/macloc.sock" 2>/dev/null | head -1 >/dev/null
fi

if [ "$N" -eq 0 ]; then
    say_ok "模拟定位已关闭（4 秒内 0 条 @ClxSimulated）"
else
    say_warn "仍有 $N 条 @ClxSimulated，可能有 XPC 通道在跑：./xpc-push.sh --stop"
fi
echo
