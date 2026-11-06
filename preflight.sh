#!/bin/bash
# macloc preflight —— 装之前把所有前置条件查一遍
#
#   ./preflight.sh            中文
#   ./preflight.sh --en       English
#   MACLOC_LANG=en ./preflight.sh
#
# 退出码：0 = 全部通过；1 = 有 FATAL（装不了）
#
# 检查项来源就是各个脚本里真正会卡住的地方，不是猜的。

set -u
cd "$(dirname "$0")"

LANG_T="${MACLOC_LANG:-zh}"
case "${1:-}" in
    --en) LANG_T="en" ;;
    --lang) LANG_T="${2:-zh}" ;;
esac
case "$LANG_T" in en|EN) LANG_T="en" ;; *) LANG_T="zh" ;; esac

FATAL=0
WARN=0

C_RED='\033[31m'; C_GRN='\033[32m'; C_YEL='\033[33m'; C_DIM='\033[2m'; C_BLD='\033[1m'; C_OFF='\033[0m'

# t <中文> <English> —— 按当前语言取一个
t() { if [ "$LANG_T" = "en" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

# pad <文本> <目标显示列数> —— 中日韩字符按 2 列算（printf 的 %-Ns 按字节算，会错位）
pad() {
    local s="$1" target="$2" chars wide w
    chars="$(printf '%s' "$s" | wc -m | tr -d ' ')"
    wide="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\177' | wc -m | tr -d ' ')"
    w=$(( chars + wide ))
    while [ "$w" -lt "$target" ]; do s="${s} "; w=$((w+1)); done
    printf '%s' "$s"
}

# row <级别> <中文名> <English名> <中文说明> <English说明>
row() {
    local lvl="$1" msg tag color
    case "$lvl" in
        OK)   tag="[ OK ]"; color="$C_GRN" ;;
        WARN) tag="[WARN]"; color="$C_YEL"; WARN=$((WARN+1)) ;;
        FAIL) tag="[FAIL]"; color="$C_RED"; FATAL=$((FATAL+1)) ;;
        *)    tag="[INFO]"; color="$C_DIM" ;;
    esac
    msg="$(t "$4" "$5")"
    printf "${color}%s${C_OFF} %s %s\n" "$tag" "$(pad "$(t "$2" "$3")" 22)" "$msg"
}

if [ "$LANG_T" = "en" ]; then
    BANNER="══ macloc preflight ══"
else
    BANNER="══ macloc preflight ══"
fi

echo
printf "${C_BLD}${BANNER}${C_OFF}   macOS $(sw_vers -productVersion 2>/dev/null) ($(uname -m))\n"
echo

# ---------------------------------------------------------------- 硬件 / 系统
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
    row OK "架构" "Architecture" "Apple Silicon (arm64) ✅" "Apple Silicon (arm64) ✅"
else
    row FAIL "架构" "Architecture" \
        "只支持 Apple Silicon，当前是 ${ARCH} —— install.sh 会直接退出" \
        "Apple Silicon only, current is ${ARCH} — install.sh will exit"
fi

# ---------------------------------------------------------------- 图形会话
CONSOLE="$(stat -f%Su /dev/console 2>/dev/null)"
case "$CONSOLE" in
    ""|root|_mbsetupuser|loginwindow)
        row FAIL "图形会话" "Graphical session" \
            "当前没有图形桌面的登录用户（控制台 = '${CONSOLE:-无}'）—— 管理员授权框弹不出来，纯 SSH 跑不了 install.sh" \
            "No logged-in graphical user (console = '${CONSOLE:-none}') — the admin prompt cannot be shown; install.sh will not work over plain SSH"
        ;;
    *)
        row OK "图形会话" "Graphical session" \
            "控制台用户 = ${CONSOLE} ✅（管理员授权框需要它）" \
            "console user = ${CONSOLE} ✅ (required for the admin prompt)"
        ;;
esac

# ---------------------------------------------------------------- 权限
if command -v osascript >/dev/null 2>&1; then
    row OK "授权弹窗" "Admin prompt" \
        "osascript 可用（安装时弹一次系统授权框）✅" \
        "osascript available (one system authorization prompt at install) ✅"
else
    row FAIL "授权弹窗" "Admin prompt" \
        "找不到 osascript，install.sh 会退出" \
        "osascript not found — install.sh will exit"
fi

if id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin; then
    row OK "管理员组" "admin group" \
        "当前用户在 admin 组 ✅" \
        "current user is in the admin group ✅"
else
    row WARN "管理员组" "admin group" \
        "当前用户不在 admin 组 —— 写 /Library、/Applications 会要密码" \
        "current user is not in the admin group — writing /Library and /Applications will ask for a password"
fi

if [ -w /Applications ]; then
    row OK "/Applications" "/Applications" \
        "可写 ✅（build-ui.sh 装 App 免密）" \
        "writable ✅ (build-ui.sh installs without a prompt)"
else
    row WARN "/Applications" "/Applications" \
        "不可写 —— build-ui.sh 会弹一次系统授权框" \
        "not writable — build-ui.sh will prompt once"
fi

# ---------------------------------------------------------------- 工具链
if xcrun --find swiftc >/dev/null 2>&1; then
    row OK "swiftc" "swiftc" \
        "$(xcrun --find swiftc) ✅（编译 daemon / UI）" \
        "$(xcrun --find swiftc) ✅ (compiles the daemon and the UI)"
else
    row FAIL "swiftc" "swiftc" \
        "没有 —— 跑 xcode-select --install（编译 daemon 和 UI 需要）" \
        "missing — run xcode-select --install (needed to build the daemon and the UI)"
fi

if xcrun --find clang >/dev/null 2>&1; then
    row OK "clang" "clang" \
        "$(xcrun --find clang) ✅（编译 dylib / finddot）" \
        "$(xcrun --find clang) ✅ (compiles the dylib and finddot)"
else
    row WARN "clang" "clang" \
        "没有 —— xcode-select --install（XPC 通道和 verify.sh 需要）" \
        "missing — xcode-select --install (needed by the XPC channel and verify.sh)"
fi

MISSING=""
for t in /usr/libexec/PlistBuddy /usr/bin/codesign /bin/launchctl /usr/bin/nc /usr/sbin/screencapture /usr/bin/sw_vers /usr/bin/log /usr/bin/open; do
    [ -x "$t" ] || MISSING="${MISSING} $t"
done
if [ -z "$MISSING" ]; then
    row OK "系统工具" "System tools" \
        "PlistBuddy / codesign / launchctl / nc / screencapture 齐全 ✅" \
        "PlistBuddy / codesign / launchctl / nc / screencapture all present ✅"
else
    row WARN "系统工具" "System tools" \
        "缺少：${MISSING}" \
        "missing: ${MISSING}"
fi

# ---------------------------------------------------------------- SIP
SIP="unknown"
SIPRAW="$(csrutil status 2>/dev/null)"
case "$SIPRAW" in
    *"disabled"*) SIP="disabled" ;;
    *"enabled"*)  SIP="enabled" ;;
    *"partial"*)  SIP="partial" ;;
esac
if [ "$SIP" = "disabled" ]; then
    row INFO "SIP" "SIP" \
        "已关闭（${SIP}）—— 通道 A/B 不需要关；通道 C 需要关" \
        "disabled (${SIP}) — channels A/B do not need it; channel C does"
else
    row INFO "SIP" "SIP" \
        "${SIP} —— 通道 A/B（偏好 / daemon）不需要关；只有 xpc-push.sh 需要关 + 重启" \
        "${SIP} — channels A/B (prefs / daemon) do NOT need it; only xpc-push.sh does, plus a reboot"
fi

# ---------------------------------------------------------------- 定位服务总开关
LSV="$(defaults read "/Library/Managed Preferences/com.apple.locationd" LocationServicesEnabled 2>/dev/null)"
case "$LSV" in
    1|true)
        row OK "定位服务总开关" "Location Services" \
            "已打开 ✅（客户端才有位置可读）" \
            "enabled ✅ (clients can read a position)"
        ;;
    0|false)
        row WARN "定位服务总开关" "Location Services" \
            "当前是关的 —— install.sh 会帮你打开，但系统设置里手动关了的话客户端会拿到 kCLErrorDomain error 1" \
            "currently off — install.sh turns it on, but with it off clients get kCLErrorDomain error 1"
        ;;
    *)
        row WARN "定位服务总开关" "Location Services" \
            "读不到（正常，install.sh 会打开它）" \
            "cannot read it (normal — install.sh turns it on)"
        ;;
esac

# ---------------------------------------------------------------- 已装状态
if [ -S /var/run/macloc.sock ]; then
    row INFO "daemon" "daemon" \
        "已安装（socket 存在）—— 改坐标免密码" \
        "installed (socket present) — changing coordinates needs no password"
else
    row INFO "daemon" "daemon" \
        "未安装 —— ./install-daemon.sh 可装（装完改坐标免密码）" \
        "not installed — run ./install-daemon.sh (then changing coordinates needs no password)"
fi

# ---------------------------------------------------------------- TCC
row INFO "客户端 TCC" "Client TCC" \
    "要验证效果的那个 App 自己得拿到「隐私与安全性 → 定位服务」授权，否则读不到位置" \
    "the app you use to check the result needs its own Location Services permission, otherwise it reads nothing"

echo
if [ "$FATAL" -gt 0 ]; then
    printf "${C_RED}%s${C_OFF}\n" "$(t "有 ${FATAL} 项 FAIL —— 解决后再装。" "${FATAL} FAIL — fix these before installing.")"
elif [ "$WARN" -gt 0 ]; then
    printf "${C_YEL}%s${C_OFF}\n" "$(t "全部硬性条件通过（${WARN} 项 WARN 不影响安装）。" "All hard requirements pass (${WARN} WARN, non-blocking).")"
else
    printf "${C_GRN}%s${C_OFF}\n" "$(t "全部前置条件通过，可以 ./install.sh 了。" "All prerequisites pass — run ./install.sh.")"
fi
echo
exit $(( FATAL > 0 ? 1 : 0 ))
