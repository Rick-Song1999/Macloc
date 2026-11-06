#!/bin/bash
# macloc build-ui —— 构建 MacLocBar.app（菜单栏 UI）
#
#   ./build-ui.sh              构建并安装到 /Applications/MacLocBar.app
#   ./build-ui.sh --no-install 只构建，不安装
#   ./build-ui.sh --local      安装到 ~/Applications（老位置，调试用）
#
# 产物：
#   ~/macloc/MacLocBar.app     构建产物（可双击启动的菜单栏 App，LSUIElement）
#   /Applications/MacLocBar.app  正式安装位置（和其它 App 待一起）

set -u
cd "$(dirname "$0")"
. ./lib/macloc.sh

SRC="$MACLOC_DIR/ui/MacLocBar.swift"
APP="$MACLOC_DIR/MacLocBar.app"
APPS="/Applications"
LOCAL_APPS="$HOME/Applications"

# App 的 bundle id：改它会换掉 UserDefaults（语言偏好）和「隐私与安全性」里的条目。
# 想改成自己的：MACLOC_BUNDLE_ID=com.yourname.macloc ./build-ui.sh
BUNDLE_ID="${MACLOC_BUNDLE_ID:-com.andyscott.macloc}"

say_info "编译 MacLocBar…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BUILD_LOG="$(mktemp /tmp/macloc-swift.XXXXXX.log)"
xcrun swiftc -swift-version 5 -O "$SRC" -o "$APP/Contents/MacOS/MacLocBar" > "$BUILD_LOG" 2>&1
if [ ! -x "$APP/Contents/MacOS/MacLocBar" ]; then
    say_err "编译失败（需要 Xcode Command Line Tools: xcode-select --install）"
    sed 's/^/  /' "$BUILD_LOG" | head -20
    rm -f "$BUILD_LOG"
    exit 1
fi
rm -f "$BUILD_LOG"

# Info.plist 用 PlistBuddy 生成（手写 XML 容易把 </key> 写成 </string>）
PB=/usr/libexec/PlistBuddy
plutil -create xml1 "$APP/Contents/Info.plist"
"$PB" -c "Add :CFBundleName string MacLocBar"                 "$APP/Contents/Info.plist"
"$PB" -c "Add :CFBundleDisplayName string MacLoc"              "$APP/Contents/Info.plist"
"$PB" -c "Add :CFBundleIdentifier string $BUNDLE_ID"        "$APP/Contents/Info.plist"
"$PB" -c "Add :CFBundleExecutable string MacLocBar"            "$APP/Contents/Info.plist"
"$PB" -c "Add :CFBundlePackageType string APPL"                "$APP/Contents/Info.plist"
"$PB" -c "Add :CFBundleShortVersionString string 1.1"          "$APP/Contents/Info.plist"
"$PB" -c "Add :CFBundleVersion string 2"                       "$APP/Contents/Info.plist"
"$PB" -c "Add :CFBundleIconFile string AppIcon"                "$APP/Contents/Info.plist"
"$PB" -c "Add :LSMinimumSystemVersion string 13.0"            "$APP/Contents/Info.plist"
"$PB" -c "Add :LSUIElement bool true"                         "$APP/Contents/Info.plist"
"$PB" -c "Add :NSHighResolutionCapable bool true"              "$APP/Contents/Info.plist"
"$PB" -c "Add :NSHumanReadableCopyright string local"          "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || { say_err "plist 生成失败"; exit 1; }

cp "$MACLOC_DIR/ui/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null \
    || say_warn "没有 ui/AppIcon.icns（先跑 ./build-icon.sh）"

codesign -s - -f --deep "$APP" >/dev/null 2>&1
say_ok "已构建 $APP"

if [ "${1:-}" = "--no-install" ]; then
    say_dim "跳过安装"
    exit 0
fi

if [ "${1:-}" = "--local" ]; then
    # 调试用：装到 ~/Applications（免授权）
    mkdir -p "$LOCAL_APPS"
    rm -rf "$LOCAL_APPS/MacLocBar.app"
    cp -R "$APP" "$LOCAL_APPS/MacLocBar.app"
    say_ok "已安装到 $LOCAL_APPS/MacLocBar.app（调试位置）"
    say_dim "启动：open $LOCAL_APPS/MacLocBar.app"
    echo
    exit 0
fi

# 正式安装：/Applications 需要管理员权限。
# 但 /Applications 是 775 root:admin，admin 组本来就能在里面增删条目 ——
# 所以先试免密安装（把 App 包权限放开给 admin 组之后，重编译就不用再输密码），
# 失败了才弹系统授权框。
install_payload() {
    rm -rf "$APPS/MacLocBar.app" 2>/dev/null || return 1
    cp -R "$APP" "$APPS/MacLocBar.app" 2>/dev/null || return 1
    chmod -R u+rwX,g+rwX,go+rX "$APPS/MacLocBar.app" 2>/dev/null || true
    chown -R root:admin "$APPS/MacLocBar.app" 2>/dev/null || true
    rm -rf "$LOCAL_APPS/MacLocBar.app" 2>/dev/null || true
    return 0
}

if install_payload && [ -d "$APPS/MacLocBar.app" ]; then
    say_ok "已安装到 $APPS/MacLocBar.app（免密）"
else
    say_info "安装到 ${APPS}（会弹管理员授权框）…"
    PAYLOAD=$(cat <<EOF
set -u
rm -rf "$APPS/MacLocBar.app"
cp -R "$APP" "$APPS/MacLocBar.app"
chown -R root:admin "$APPS/MacLocBar.app"
chmod -R u+rwX,g+rwX,go+rX "$APPS/MacLocBar.app"
rm -rf "$LOCAL_APPS/MacLocBar.app"
EOF
)
    OUT="$(admin_run "$PAYLOAD")"
    RC=$?
    printf '%s\n' "$OUT" | sed 's/^/  /'
    if [ $RC -ne 0 ]; then
        say_err "安装失败（授权被取消）"
        exit 1
    fi
fi

if [ -d "$APPS/MacLocBar.app" ]; then
    say_ok "已安装到 $APPS/MacLocBar.app"
    if [ -d "$LOCAL_APPS/MacLocBar.app" ]; then
        say_warn "旧副本还在 $LOCAL_APPS/MacLocBar.app（可手动删）"
    else
        say_dim "旧位置 $LOCAL_APPS/MacLocBar.app 已清理"
    fi
    say_dim "启动：open $APPS/MacLocBar.app"
else
    say_err "安装后没看到 $APPS/MacLocBar.app"
    exit 1
fi
echo
