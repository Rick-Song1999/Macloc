#!/bin/bash
# macloc 公共库 —— 被 install.sh / set.sh / stop.sh / status.sh 复用

MACLOC_HOME="$HOME/.macloc"
# 定位项目根目录（lib/macloc.sh 的上一级）。
# bash 下用 BASH_SOURCE；zsh 等其它 shell 里 BASH_SOURCE 是空的，
# 这时回退到「调用方 cd 之后的 cwd」——所有入口脚本都先 cd 再 source 本文件。
MACLOC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)"
[ -f "$MACLOC_DIR/lib/macloc.sh" ] || MACLOC_DIR="$(pwd)"
STATE_FILE="$MACLOC_HOME/state"
LOG_FILE="$MACLOC_HOME/macloc.log"
# daemon 侧状态（root 拥有，0644）—— 权威来源
DAEMON_STATE_FILE="/var/db/macloc/state"
# 原偏好备份目录（root 拥有，0700）
BACKUP_DIR="/var/db/macloc/backup"

# locationd 自己的偏好目录（真实存储位置）
BYHOST_DIR="/var/db/locationd/Library/Preferences/ByHost"
# MCX 管理偏好（locationd 启动时也会读，作为兜底并保持同步）
MCX_DIR="/Library/Managed Preferences"
MCX_FILE="$MCX_DIR/com.apple.locationd.plist"

c_red='\033[31m'; c_grn='\033[32m'; c_yel='\033[33m'; c_blu='\033[34m'; c_dim='\033[2m'; c_off='\033[0m'

log() {
    local msg="$*"
    # 日志文件不许是符号链接（虽然这里是以用户身份写，但没必要留这种歧义）
    if [ -L "$LOG_FILE" ]; then
        printf '%s\n' "$msg"
        return 0
    fi
    printf '%s\n' "$msg" | tee -a "$LOG_FILE" >/dev/null 2>&1
    printf '%s\n' "$msg"
}

say_ok()   { printf "${c_grn}✔${c_off} %s\n" "$*"; }
say_info() { printf "${c_blu}ℹ${c_off} %s\n" "$*"; }
say_warn() { printf "${c_yel}!${c_off} %s\n" "$*"; }
say_err()  { printf "${c_red}✘${c_off} %s\n" "$*"; }
say_dim()  { printf "${c_dim}  %s${c_off}\n" "$*"; }

# ---------------------------------------------------------------- 权限提升
# 机器没有免密 sudo，走系统原生授权弹窗（osascript + administrator privileges）。
# 生成一个临时 root 脚本 → 弹窗 → 执行 → 删除。避免任何引号转义地雷。
admin_run() {
    local payload="$1"     # 以 root 身份执行的 shell 片段
    local tmpdir tmp
    # 用 $HOME 下 0700 的私有目录，而不是 /tmp：
    # /tmp 里的文件其它本地用户可以在「生成 → 执行」之间调包，
    # 那就是白送的 root 代码执行。私有目录只有本人能改。
    mkdir -p "$MACLOC_HOME" 2>/dev/null
    chmod 700 "$MACLOC_HOME" 2>/dev/null
    tmpdir="$(mktemp -d "$MACLOC_HOME/tmp.XXXXXX" 2>/dev/null)"
    if [ -z "$tmpdir" ]; then
        tmpdir="$(mktemp -d /tmp/macloc-admin.XXXXXX)"
    fi
    chmod 700 "$tmpdir" 2>/dev/null
    tmp="$tmpdir/payload.sh"
    {
        echo '#!/bin/bash'
        echo 'set -u'
        echo "$payload"
    } > "$tmp"
    chmod 700 "$tmp"
    local out rc
    out="$(osascript -e "do shell script \"/bin/bash '$tmp'\" with administrator privileges" 2>&1)"
    rc=$?
    rm -rf "$tmpdir"
    # osascript 的 do shell script 会把 stdout 的 \n 转成 \r（AppleScript 用 CR 当行分隔符），
    # 不转回来的话多行输出会粘成一行，grep '^MACLOC_OK$' 之类的锚点匹配也全部失效。
    printf '%s\n' "$out" | tr '\r' '\n'
    return $rc
}

have_admin_prompt() { command -v osascript >/dev/null 2>&1; }

# ---------------------------------------------------------------- 偏好写入
# 把 "键 值类型 值" 写进一个 plist（root 身份执行）
plist_set() {
    local file="$1" key="$2" type="$3" val="$4"
    if [ ! -f "$file" ]; then return 1; fi
    if ! /usr/libexec/PlistBuddy -c "Set :$key $val" "$file" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Add :$key $type $val" "$file" >/dev/null 2>&1 || return 1
    fi
    return 0
}

plist_del() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    /usr/libexec/PlistBuddy -c "Delete :$key" "$file" >/dev/null 2>&1 || true
    return 0
}

# ---------------------------------------------------------------- 坐标规范化
# 只允许 [0-9.eE+-]，并做范围检查。输出规范化后的 "lat lon"（保证是纯数字串）。
# 用途：坐标会被拼进「以 root 执行的 shell 脚本」，必须先规范化，
#       否则 $(...) / 反引号 / 引号 breakout 就是 root 命令注入。
sanitize_coord() {
    local lat="$1" lon="$2"
    valid_coord "$lat" "$lon" || return 1
    awk -v a="$lat" -v b="$lon" 'BEGIN{
        a = a + 0; b = b + 0;
        if (a < -90 || a > 90 || b < -180 || b > 180) exit 1;
        printf "%.6f %.6f", a, b;
    }'
}

# ---------------------------------------------------------------- 状态检测
# 生成"写入模拟坐标"的 root 脚本片段
#
# 安全要点：
#   1. 坐标先经 sanitize_coord 规范化成 [0-9.-]，杜绝 shell 注入
#   2. 脚本里所有路径都是常量，不含任何用户可控字符串
#   3. 只处理 root 拥有的常规文件（跳过符号链接）
#   4. 首次修改前备份原偏好；关闭时恢复 LocationServicesEnabled 原值
#   5. 写完回读校验 + 确认 locationd 真的起来了，失败输出 MACLOC_FAIL
payload_write_coords() {
    local lat="${1:-0}" lon="${2:-0}" enable="${3:-1}"
    local norm slat slon
    # 坐标会被拼进「以 root 执行的 shell 脚本」，必须先规范化：
    # 否则 $(...) / 反引号 / 引号 breakout 就是 root 命令注入。
    if ! norm="$(sanitize_coord "$lat" "$lon")"; then
        printf 'echo "MACLOC_ERR 坐标不合法"\nexit 1\n'
        return 1
    fi
    slat="${norm%% *}"
    slon="${norm##* }"

    # 只把「规范化后的数字」交给 root 脚本；真正的逻辑在
    # lib/apply-coords.sh（路径全是常量，不含任何用户可控字符串）
    printf 'LAT="%s"\n' "$slat"
    printf 'LON="%s"\n' "$slon"
    printf 'ENABLE="%s"\n' "$enable"
    cat "$MACLOC_DIR/lib/apply-coords.sh"
}

# ---------------------------------------------------------------- 状态检测
sim_count() {   # 最近 N 秒内 @ClxSimulated 的条数
    local secs="${1:-10}"
    /usr/bin/log show --predicate 'process == "locationd"' --last "${secs}s" --style compact 2>/dev/null \
        | grep -c -i 'ClxSimulated'
}

read_state() {
    # 优先 daemon 的 root 状态文件（权威），回退用户域副本
    if [ -r "$DAEMON_STATE_FILE" ]; then
        . "$DAEMON_STATE_FILE" 2>/dev/null && return 0
    fi
    [ -f "$STATE_FILE" ] || return 1
    . "$STATE_FILE" 2>/dev/null || return 1
    return 0
}

save_state() {
    mkdir -p "$MACLOC_HOME"
    cat > "$STATE_FILE" <<EOF
MACLOC_LAT="$1"
MACLOC_LON="$2"
MACLOC_ON="$3"
MACLOC_AT="$(date '+%Y-%m-%d %H:%M:%S')"
EOF
}

valid_coord() {
    local lat="$1" lon="$2"
    case "$lat$lon" in
        *[!0-9.eE+-]*) return 1 ;;
    esac
    awk -v a="$lat" -v b="$lon" 'BEGIN{ if (a < -90 || a > 90 || b < -180 || b > 180) exit 1 }'
}
