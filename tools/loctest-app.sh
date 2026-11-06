#!/bin/bash
# loctest-app.sh —— 造一个第三方 .app，用来验证「模拟定位是否全局」
#
#   ./loctest-app.sh build     编译成 /tmp/Loctest.app
#   ./loctest-app.sh run       跑一次，结果在 /tmp/loctest.out
#   ./loctest-app.sh grant     给它插一条 TCC「定位服务=允许」（需管理员）
#   ./loctest-app.sh revoke    删掉那条 TCC 记录
#   ./loctest-app.sh clean     删掉 TCC 记录 + app

set -u
APP=/tmp/Loctest.app
BUNDLE_ID=com.macloc.loctest
SRC="$(dirname "$0")/loctest.swift"
TCCDB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

case "${1:-run}" in
build)
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"
    if ! xcrun swiftc -swift-version 5 -O "$SRC" -o "$APP/Contents/MacOS/Loctest" 2>/tmp/loctest.build.log; then
        echo "编译失败:"; head -20 /tmp/loctest.build.log; exit 1
    fi
    # 用 PlistBuddy 生成 plist（手写 XML 容易把 </key> 写成 </string>）
    PB=/usr/libexec/PlistBuddy
    plutil -create xml1 "$APP/Contents/Info.plist"
    "$PB" -c "Add :CFBundleName string Loctest"                 "$APP/Contents/Info.plist"
    "$PB" -c "Add :CFBundleIdentifier string $BUNDLE_ID"        "$APP/Contents/Info.plist"
    "$PB" -c "Add :CFBundleExecutable string Loctest"           "$APP/Contents/Info.plist"
    "$PB" -c "Add :CFBundlePackageType string APPL"             "$APP/Contents/Info.plist"
    "$PB" -c "Add :CFBundleShortVersionString string 1.0"       "$APP/Contents/Info.plist"
    "$PB" -c "Add :NSLocationWhenInUseUsageDescription string 定位测试" "$APP/Contents/Info.plist"
    "$PB" -c "Add :NSLocationAlwaysAndWhenInUseUsageDescription string 定位测试" "$APP/Contents/Info.plist"
    "$PB" -c "Add :NSHighResolutionCapable bool true"          "$APP/Contents/Info.plist"
    plutil -lint "$APP/Contents/Info.plist" >/dev/null || { echo "plist 生成失败"; exit 1; }
    codesign -s - -f "$APP" >/dev/null 2>&1
    echo "built $APP"
    ;;
run)
    rm -f /tmp/loctest.out
    open "$APP"
    sleep 16
    echo "--- /tmp/loctest.out ---"
    cat /tmp/loctest.out 2>&1
    ;;
grant)
    cat > /tmp/tccgrant.sh <<'INNER'
#!/bin/bash
DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
cp -n "$DB" "$DB.macloc.bak" 2>/dev/null
sqlite3 "$DB" "delete from access where service='kTCCServiceLocation' and client='com.macloc.loctest';"
sqlite3 "$DB" "insert into access (service, client, client_type, auth_value, auth_reason, auth_version, flags, last_modified, indirect_object_identifier_type, indirect_object_identifier, csreq)
 values ('kTCCServiceLocation','com.macloc.loctest',0,2,4,1,0,'',0,'file:///tmp/Loctest.app',NULL);"
sqlite3 "$DB" "select service, client, auth_value from access where service='kTCCServiceLocation';"
INNER
    osascript -e 'do shell script "/bin/bash /tmp/tccgrant.sh" with administrator privileges' 2>&1
    ;;
revoke)
    cat > /tmp/tccrevoke.sh <<'INNER'
#!/bin/bash
DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
sqlite3 "$DB" "delete from access where service='kTCCServiceLocation' and client='com.macloc.loctest';"
sqlite3 "$DB" "select count(*) from access where service='kTCCServiceLocation';"
INNER
    osascript -e 'do shell script "/bin/bash /tmp/tccrevoke.sh" with administrator privileges' 2>&1
    ;;
clean)
    "$0" revoke >/dev/null 2>&1
    rm -rf "$APP" /tmp/loctest.out /tmp/tccgrant.sh /tmp/tccrevoke.sh
    echo "cleaned"
    ;;
*)
    echo "用法: $0 {build|run|grant|revoke|clean}"; exit 1
    ;;
esac
