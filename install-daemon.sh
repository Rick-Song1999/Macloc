#!/bin/bash
# macloc install-daemon —— 安装 root 守护进程，实现「免密码改坐标」
#
#   ./install-daemon.sh
#
# 装的东西：
#   /Library/LaunchDaemons/com.macloc.agent.plist   launchd 配置（socket 激活，按需运行）
#   /usr/local/libexec/macloc/maclocd               守护进程本体
#   /var/run/macloc.sock                           unix socket（0666，launchd 建的）
#   /var/db/macloc/state                           权威状态（root:wheel 0644）
#   /var/log/maclocd.log                           daemon 日志（root 拥有）
#
# ★ 按需运行（2026-11 改造）：
#   plist 里 RunAtLoad=false / KeepAlive=false，并加了 Sockets 字典。
#   launchd 只负责把 /var/run/macloc.sock 建出来，**不常驻进程**；
#   有客户端连上来才拉起 maclocd，干完活空闲 20 秒自动退出。
#   → 没打开 App 时，系统里一个 macloc 进程都没有。
#
# 安全要点：
#   * daemon 绝不以 root 身份写用户家目录，状态只落在 root 拥有的路径
#   * plist 用 PlistBuddy 生成（手写 XML 容易把 </key> 写成 </string>）
#   * 每次安装都重新编译，避免装上旧版本

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

BIN_SRC="$MACLOC_DIR/daemon/maclocd"
SHIM="$MACLOC_DIR/daemon/LaunchShim.h"
DST_DIR="/usr/local/libexec/macloc"
DST_BIN="$DST_DIR/maclocd"
PLIST="/Library/LaunchDaemons/com.macloc.agent.plist"
STATE_DIR="/var/db/macloc"
DAEMON_LOG="/var/log/maclocd.log"
SOCK_NAME="com.macloc.sock"
SOCK_PATH="/var/run/macloc.sock"

say_info "编译 maclocd…"
rm -f "$BIN_SRC"
if ! xcrun swiftc -swift-version 5 -O "$MACLOC_DIR/daemon/maclocd.swift" \
        -import-objc-header "$SHIM" -o "$BIN_SRC" 2>/tmp/maclocd.build.log; then
    say_err "maclocd 编译失败："
    head -20 /tmp/maclocd.build.log | sed 's/^/  /'
    exit 1
fi
codesign -s - -f "$BIN_SRC" >/dev/null 2>&1
if [ ! -x "$BIN_SRC" ]; then
    say_err "maclocd 编译失败（需要 Xcode Command Line Tools）"
    exit 1
fi

say_info "安装 root daemon（会弹管理员授权框）…"

PAYLOAD=$(cat <<EOF
set -u
mkdir -p "$DST_DIR"
cp "$BIN_SRC" "$DST_BIN"
chmod 755 "$DST_BIN"
codesign -s - -f "$DST_BIN" >/dev/null 2>&1 || true

# 状态目录 + 日志文件：daemon 只写这两个 root 拥有的路径
mkdir -p "$STATE_DIR"
chmod 755 "$STATE_DIR"
chown root:wheel "$STATE_DIR"
mkdir -p "$STATE_DIR/backup"
chmod 700 "$STATE_DIR/backup"
chown root:wheel "$STATE_DIR/backup"
touch "$DAEMON_LOG"
chmod 644 "$DAEMON_LOG"
chown root:wheel "$DAEMON_LOG"

# launchd 配置：用 PlistBuddy 生成，避免手写 XML 标签写错
PB=/usr/libexec/PlistBuddy
rm -f "$PLIST"
plutil -create xml1 "$PLIST"
"\$PB" -c "Add :Label string com.macloc.agent"                 "$PLIST"
"\$PB" -c "Add :ProgramArguments array"                         "$PLIST"
"\$PB" -c "Add :ProgramArguments:0 string $DST_BIN"             "$PLIST"
# ★ 不随系统启动、不常驻：进程由 socket 激活按需拉起
"\$PB" -c "Add :RunAtLoad bool false"                           "$PLIST"
"\$PB" -c "Add :KeepAlive bool false"                           "$PLIST"
"\$PB" -c "Add :ProcessType string Background"                  "$PLIST"
# ★ socket 激活：launchd 建 socket，有连接才拉进程
"\$PB" -c "Add :Sockets dict"                                   "$PLIST"
"\$PB" -c "Add :Sockets:${SOCK_NAME} dict"                      "$PLIST"
"\$PB" -c "Add :Sockets:${SOCK_NAME}:SockPathName string $SOCK_PATH" "$PLIST"
"\$PB" -c "Add :Sockets:${SOCK_NAME}:SockPathMode integer 438"  "$PLIST"
"\$PB" -c "Add :Sockets:${SOCK_NAME}:SockFamily string Unix"     "$PLIST"
"\$PB" -c "Add :EnvironmentVariables dict"                      "$PLIST"
"\$PB" -c "Add :EnvironmentVariables:MACLOC_SOCKET_NAME string ${SOCK_NAME}" "$PLIST"
"\$PB" -c "Add :StandardOutPath string $DAEMON_LOG"             "$PLIST"
"\$PB" -c "Add :StandardErrorPath string $DAEMON_LOG"           "$PLIST"
plutil -lint "$PLIST" >/dev/null || { echo "plist 生成失败"; exit 1; }
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

# 先停旧的（旧版是 RunAtLoad+KeepAlive 的常驻 daemon）
launchctl bootout system/com.macloc.agent >/dev/null 2>&1 || true
launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
pkill -f "$DST_BIN" >/dev/null 2>&1 || true
sleep 1
# 旧 daemon 自己 bind 的 socket 要删掉，否则 launchd 建 socket 会 EADDRINUSE
rm -f "$SOCK_PATH"

launchctl enable system/com.macloc.agent >/dev/null 2>&1 || true
launchctl bootstrap system "$PLIST" >/dev/null 2>&1
sleep 1
if launchctl print system/com.macloc.agent >/dev/null 2>&1; then
    echo "macloc.agent loaded (on-demand)"
else
    echo "macloc.agent FAILED"
    exit 1
fi
EOF
)

OUT="$(admin_run "$PAYLOAD")"
RC=$?
printf '%s\n' "$OUT" | sed 's/^/  /'

if [ $RC -ne 0 ]; then
    say_err "安装失败（授权被取消或脚本出错）"
    exit 1
fi

sleep 1
if [ -S "$SOCK_PATH" ]; then
    say_ok "socket 已就绪：${SOCK_PATH}（launchd 托管）"
    ls -l "$SOCK_PATH" | sed 's/^/  /'
    # 握手：这一步会按需拉起 daemon
    PONG=$(printf 'PING\n' | nc -U "$SOCK_PATH" 2>/dev/null | head -1)
    if [ "$PONG" = "PONG" ]; then
        say_ok "握手成功（PING → PONG），daemon 已按需拉起"
    else
        say_warn "socket 在但握手异常：$PONG"
    fi
    sleep 1
    if pgrep -f "$DST_BIN" >/dev/null 2>&1; then
        say_ok "进程：$(pgrep -f "$DST_BIN" | tr '\n' ' ')（用完空闲 20 秒自动退出）"
    fi
else
    say_err "socket 没起来，检查 /var/log/maclocd.log"
    exit 1
fi
echo
