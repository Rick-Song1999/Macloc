#!/bin/bash
# macloc install-login —— 开机自启 MacLocBar（**可选，默认不开**）
#
#   ./install-login.sh          安装并立即启动
#   ./install-login.sh --remove 卸载
#
# 装的东西：~/Library/LaunchAgents/com.macloc.bar.plist
#   RunAtLoad=true，参数 --background（只驻留菜单栏图标，不弹主窗口）
#
# ★ 2026-11 起默认**不装**：App 改成「打开才跑」——
#   想开机就有图标再跑这个脚本，不想常驻就别跑。
#
# 卸载：./install-login.sh --remove

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

LABEL="com.macloc.bar"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
APP="/Applications/MacLocBar.app"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--remove" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    launchctl remove "$LABEL" 2>/dev/null
    rm -f "$PLIST" "$PLIST.disabled"
    say_ok "已卸载开机自启（App 现在是「打开才跑」）"
    exit 0
fi

if [ ! -d "$APP" ]; then
    say_err "没找到 ${APP}，先跑 ./build-ui.sh"
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>              <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP}/Contents/MacOS/MacLocBar</string>
        <string>--background</string>
    </array>
    <key>RunAtLoad</key>          <true/>
    <key>KeepAlive</key>         <false/>
    <key>ProcessType</key>       <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null 2>&1 || { say_err "plist 语法错误"; plutil -lint "$PLIST"; exit 1; }

launchctl remove "$LABEL" 2>/dev/null        # 清掉 legacy load 覆盖（否则 bootstrap 会 EIO）
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    say_ok "已注册并启动开机自启（${LABEL}）"
else
    # 兜底：直接拉起进程（plist 仍在，开机照样自启）
    nohup "$APP/Contents/MacOS/MacLocBar" --background >/dev/null 2>&1 &
    say_ok "已写 plist（开机自启），当前进程直接拉起"
fi

sleep 1
if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then
    say_ok "launchd 状态：running"
else
    launchctl print "$DOMAIN/$LABEL" 2>&1 | grep -E "state|program|last exit" | head -4
fi
pgrep -lf "MacLocBar.app/Contents/MacOS" | head -2
say_dim "菜单栏现在应该有蓝色地图点；双击 App 会直接弹出主窗口"
echo
