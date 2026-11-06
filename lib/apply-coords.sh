#!/bin/bash
# macloc apply-coords.sh —— 以 root 身份把模拟坐标写进 locationd
#
# 由 lib/macloc.sh 的 payload_write_coords() 内联进 root 脚本执行，
# 不要直接运行它。
#
# 环境变量：
#   LAT     纬度（纯数字，已由 sanitize_coord 规范化）
#   LON     经度（纯数字，已由 sanitize_coord 规范化）
#   ENABLE  1=开启模拟 0=关闭
#
# 安全要点：
#   * 只处理系统账号（root / _locationd）拥有的常规文件；符号链接一律跳过
#     （用户能把路径换成指向 /etc 的链接，root 顺着写就是本地提权）
#   * 关闭时恢复 LocationServicesEnabled 的原始值（来自首次备份），不强行设 true
#   * 每一步都查返回值，失败打印 MACLOC_STEP_FAIL 并置 fail=1
#   * 写完回读校验 + 确认 locationd 真的起来了；任何一步不行都不许报 OK

set -u

BYHOST_DIR="/var/db/locationd/Library/Preferences/ByHost"
MCX_DIR="/Library/Managed Preferences"
MCX_FILE="/Library/Managed Preferences/com.apple.locationd.plist"
BACKUP_DIR="/var/db/macloc/backup"

fail=0
step_fail() { echo "MACLOC_STEP_FAIL: $*"; fail=1; }

# pb_set <file> <key> <type> <value>  —— 先 Set，key 不存在再 Add，两步都失败才报错
pb_set() {
    /usr/libexec/PlistBuddy -c "Set :$2 $4" "$1" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add :$2 $3 $4" "$1" >/dev/null 2>&1 \
        || step_fail "写 $2 到 $1"
}
# pb_get <file> <key>
pb_get() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null | head -1
}
pb_del() {
    /usr/libexec/PlistBuddy -c "Delete :$2" "$1" >/dev/null 2>&1 || true
}

mkdir -p "$MCX_DIR" 2>/dev/null; chmod 755 "$MCX_DIR" 2>/dev/null
mkdir -p "$BACKUP_DIR" 2>/dev/null; chmod 700 "$BACKUP_DIR" 2>/dev/null
chown root:wheel "$BACKUP_DIR" 2>/dev/null

if [ ! -e "$MCX_FILE" ]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$MCX_FILE" \
        || step_fail "创建 MCX"
fi
# MCX 也不许是符号链接（否则 root 会顺着链接写到别处）
if [ -L "$MCX_FILE" ]; then
    echo "MACLOC_FAIL MCX 是符号链接，拒绝写入"
    exit 1
fi

LOCD_UID="$(id -u _locationd 2>/dev/null || echo 205)"
touched=0
for F in "$BYHOST_DIR"/com.apple.locationd.*.plist; do
    [ -f "$F" ] || continue
    [ -L "$F" ] && continue                      # 符号链接一律跳过
    # 只处理系统账号拥有的文件（root 或 _locationd）。
    # 用户能改属主的路径一律不信 —— 那正是 root 提权漏洞的入口。
    OWNER="$(stat -f '%u' "$F" 2>/dev/null)"
    case "$OWNER" in
        0|"$LOCD_UID") ;;
        *) continue ;;
    esac
    touched=$((touched+1))

    # 首次修改前备份原文件（之后不再覆盖，备份的就是「最初的样子」）
    B="$BACKUP_DIR/$(basename "$F")"
    [ -f "$B" ] || cp -p "$F" "$B" 2>/dev/null || true

    if [ "$ENABLE" = "1" ]; then
        pb_set "$F" LocationServicesEnabled bool true
        pb_set "$F" AllowSimulatedLocations bool true
        pb_set "$F" SimulatedLocationLatitude real "$LAT"
        pb_set "$F" SimulatedLocationLongitude real "$LON"
        pb_set "$F" SimulatedLocationAccuracy real 5
        pb_set "$F" SimulatedLocationType integer 1
    else
        # 关闭：先恢复总开关原值，再清坐标
        if [ -f "$B" ]; then
            OLD="$(pb_get "$B" LocationServicesEnabled)"
            case "$OLD" in
                true|false) pb_set "$F" LocationServicesEnabled bool "$OLD" ;;
            esac
        fi
        pb_set "$F" AllowSimulatedLocations bool false
        pb_del "$F" SimulatedLocationLatitude
        pb_del "$F" SimulatedLocationLongitude
    fi
    chown _locationd:staff "$F" >/dev/null 2>&1
    chmod 600 "$F" >/dev/null 2>&1
done
[ "$touched" -gt 0 ] || { echo "MACLOC_FAIL 没有找到 locationd 偏好文件"; exit 1; }

# MCX 兜底（保持与 ByHost 一致）
if [ "$ENABLE" = "1" ]; then
    pb_set "$MCX_FILE" AllowSimulatedLocations bool true
    pb_set "$MCX_FILE" SimulatedLocationLatitude real "$LAT"
    pb_set "$MCX_FILE" SimulatedLocationLongitude real "$LON"
    pb_set "$MCX_FILE" SimulatedLocationAccuracy real 5
    pb_set "$MCX_FILE" SimulatedLocationType integer 1
    pb_set "$MCX_FILE" LocationServicesEnabled bool true
else
    pb_set "$MCX_FILE" AllowSimulatedLocations bool false
    pb_del "$MCX_FILE" SimulatedLocationLatitude
    pb_del "$MCX_FILE" SimulatedLocationLongitude
fi
chown root:wheel "$MCX_FILE" >/dev/null 2>&1
chmod 644 "$MCX_FILE" >/dev/null 2>&1

# 回读校验：写进去的必须读得回来（容差 1e-4，float32 精度够用）
if [ "$ENABLE" = "1" ]; then
    for F in "$BYHOST_DIR"/com.apple.locationd.*.plist; do
        [ -f "$F" ] || continue
        [ -L "$F" ] && continue
        V="$(pb_get "$F" SimulatedLocationLatitude)"
        W="$(pb_get "$F" SimulatedLocationLongitude)"
        awk -v a="$V" -v b="$LAT" 'BEGIN{d=a-b; if(d<0)d=-d; exit(d>0.0001?1:0)}' \
            || step_fail "纬度回读不一致：$F 读到 [$V] 期望 [$LAT]"
        awk -v a="$W" -v b="$LON" 'BEGIN{d=a-b; if(d<0)d=-d; exit(d>0.0001?1:0)}' \
            || step_fail "经度回读不一致：$F 读到 [$W] 期望 [$LON]"
    done
fi

killall cfprefsd >/dev/null 2>&1
sleep 1
killall -u _locationd locationd >/dev/null 2>&1
sleep 3
if pgrep -x locationd >/dev/null 2>&1; then
    echo "locationd restarted pid=$(pgrep -x locationd | head -1)"
else
    echo "locationd FAILED to restart"
    fail=1
fi
if [ "$fail" = "0" ]; then echo "MACLOC_OK"; else echo "MACLOC_FAIL"; fi
