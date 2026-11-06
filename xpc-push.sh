#!/bin/bash
# macloc xpc-push —— 实时切换模拟坐标（XPC 通道，免 root）
#
#   ./xpc-push.sh <纬度> <经度>    实时推一个新坐标
#   ./xpc-push.sh --stop           停掉模拟
#
# 与 set.sh 的区别：set.sh 要重启 locationd（≈2 秒），本脚本直接调用 locationd 的
# 官方 simulation XPC 服务，坐标即时切换，且不需要管理员密码。
#
# 原理：CoreLocation.framework 私有类 CLSimulationManager → mach service
#       "com.apple.locationd.simulation"。该服务校验客户端签名，必须带
#       com.apple.locationd.simulation entitlement —— 全系统只有
#       /System/Library/CoreServices/CoreLocationAgent.app 拥有它。
#       所以把 dylib 注入 CoreLocationAgent，以它的合法身份推。
#
# 前提：SIP 必须关闭（csrutil status = disabled），否则 dyld 拒绝注入 arm64e 平台二进制。

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

AGENT="com.apple.CoreLocationAgent"
JOB="gui/$(id -u)/$AGENT"
DYLIB_SRC="$MACLOC_DIR/spoof.dylib.m"
DYLIB="$MACLOC_HOME/spoof.dylib"

if ! csrutil status 2>/dev/null | grep -q "disabled"; then
    say_err "SIP 未关闭，dyld 会拒绝注入平台二进制。"
    say_dim "先执行：sudo csrutil disable --no-internal  然后重启"
    exit 1
fi

# ---------------------------------------------------------------- 构建
build_dylib() {
    if [ -f "$DYLIB" ] && [ "$DYLIB" -nt "$DYLIB_SRC" ]; then
        return 0
    fi
    say_info "构建注入 dylib (arm64e)…"
    rm -f "$DYLIB.tmp"
    if ! xcrun clang -arch arm64e -dynamiclib -fobjc-arc \
            -framework Foundation -framework CoreLocation \
            -o "$DYLIB.tmp" "$DYLIB_SRC" > /tmp/macloc-build.log 2>&1; then
        say_err "编译失败（需要 Xcode Command Line Tools）："
        head -20 /tmp/macloc-build.log | sed 's/^/    /'
        rm -f "$DYLIB.tmp"
        return 1
    fi
    codesign -s - -f "$DYLIB.tmp" >/dev/null 2>&1
    # 必须原子替换：原地覆盖会被仍被映射的旧 inode 触发 AMFI SIGKILL
    mv -f "$DYLIB.tmp" "$DYLIB"
    say_ok "已构建 $DYLIB"
}

# ---------------------------------------------------------------- 推坐标
push() {
    local lat="$1" lon="$2" stop="$3"

    build_dylib || return 1
    mkdir -p "$MACLOC_HOME"
    [ "$stop" = "1" ] || printf '%s %s\n' "$lat" "$lon" > "$MACLOC_HOME/loc.conf"

    launchctl unsetenv SPOOF_STOP  >/dev/null 2>&1
    launchctl unsetenv SPOOF_LAT   >/dev/null 2>&1
    launchctl unsetenv SPOOF_LON   >/dev/null 2>&1
    if [ "$stop" = "1" ]; then
        launchctl setenv SPOOF_STOP 1
    else
        launchctl setenv SPOOF_LAT "$lat"
        launchctl setenv SPOOF_LON "$lon"
    fi
    launchctl setenv DYLD_INSERT_LIBRARIES "$DYLIB"
    launchctl kickstart -k "$JOB" >/dev/null 2>&1
    sleep 8

    # 撤掉全局注入环境变量（模拟状态留在 locationd 里，不随客户端退出而消失）
    launchctl unsetenv DYLD_INSERT_LIBRARIES
    launchctl unsetenv SPOOF_STOP
    launchctl unsetenv SPOOF_LAT
    launchctl unsetenv SPOOF_LON
    launchctl kickstart -k "$JOB" >/dev/null 2>&1
    sleep 1
}

case "${1:-}" in
    --watch)
        # 常驻模式：保持注入，之后直接改 ~/.macloc/loc.conf 即可实时换点
        echo
        say_info "常驻注入 CoreLocationAgent（Ctrl-C 退出）…"
        build_dylib || exit 1
        mkdir -p "$MACLOC_HOME"
        launchctl unsetenv SPOOF_STOP
        launchctl unsetenv SPOOF_LAT
        launchctl unsetenv SPOOF_LON
        launchctl setenv DYLD_INSERT_LIBRARIES "$DYLIB"
        launchctl kickstart -k "$JOB" >/dev/null 2>&1
        say_ok "已注入。改坐标：echo '<lat> <lon>' > $MACLOC_HOME/loc.conf"
        trap 'launchctl unsetenv DYLD_INSERT_LIBRARIES; launchctl kickstart -k "$JOB" >/dev/null 2>&1; echo; say_info "已撤掉注入"' INT TERM
        while true; do sleep 2; done
        ;;
    --stop)
        echo
        say_info "通过 XPC 通道停掉模拟定位…"
        push 0 0 1
        sleep 2
        N=$(sim_count 10)
        [ "$N" -eq 0 ] && say_ok "已停止（10 秒内 0 条 @ClxSimulated）" || say_warn "仍有 $N 条 @ClxSimulated"
        ;;
    "")
        say_err "用法: $0 <纬度> <经度>   或   $0 --stop"
        exit 1
        ;;
    *)
        LAT="$1"; LON="${2:-}"
        if [ -z "$LON" ]; then
            say_err "用法: $0 <纬度> <经度>"
            exit 1
        fi
        if ! valid_coord "$LAT" "$LON"; then
            say_err "坐标不合法: $LAT $LON"
            exit 1
        fi
        echo
        say_info "XPC 实时推送 $LAT, $LON …"
        push "$LAT" "$LON" 0
        sleep 2
        N=$(sim_count 10)
        [ "$N" -gt 0 ] && say_ok "已生效（10 秒内 $N 条 @ClxSimulated）" || say_warn "没看到 @ClxSimulated，看 ~/.macloc/spoof.log"
        save_state "$LAT" "$LON" 1
        printf '%s %s\n' "$LAT" "$LON" > "$MACLOC_HOME/loc.conf"
        say_dim "验证：open -a Maps"
        ;;
esac
echo
