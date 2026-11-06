# macloc — macOS 全系统定位伪装

在 Apple Silicon Mac 上把 **系统级**定位伪装到任意经纬度。系统地图、Safari、微信、任何走 CoreLocation 的 App 读到的都是假坐标。

验证机型：MacBook Pro (M2) / macOS 26.5 (25F71) / Apple Silicon。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 快速开始

```bash
git clone https://github.com/andyscott/macloc.git
cd macloc

# 1) 装模拟定位通道（弹一次管理员授权框，写偏好 + 重启 locationd）
./install.sh 39.904200 116.407400        # 北京

# 2) 装免密码的 daemon 通道（再弹一次授权框，之后改坐标不用输密码）
./install-daemon.sh

# 3) 编译图形 UI（装到 /Applications，免密）
./build-ui.sh
open /Applications/MacLocBar.app          # 点一个城市按钮，3~6 秒生效
```

不想装 UI，只想命令行改：

```bash
./loc.sh 35.676200 139.650300             # 东京（daemon 装了就不弹密码框）
./status.sh                               # 看当前状态
./stop.sh                                 # 关掉模拟定位，恢复原状
```

## 系统要求

- macOS 13+，Apple Silicon（arm64 / arm64e）
- Xcode Command Line Tools（`xcode-select --install`）—— 编译 daemon 和 UI 要用
- **主通道不需要关 SIP**；只有可选的 XPC 实时通道需要
- 改坐标需要管理员权限（装的时候输一次密码）

## ⚠️ 它会动系统

- 写 `/var/db/locationd/Library/Preferences/ByHost/com.apple.locationd.*.plist`（系统定位偏好）
- 重启 `locationd`
- 装一个 root 的 launchd 任务 `com.macloc.agent`（**按需运行**：socket 激活，没连接就不驻留）
- 装一个 `~/Library/LaunchAgents/com.macloc.bar` 的开机自启 —— **默认不装**，`./install-login.sh` 想要再装

全部是可逆的：`./stop.sh` 关掉模拟并恢复备份，`./install-login.sh --remove` 卸掉自启，
`rm /Library/LaunchDaemons/com.macloc.agent.plist && launchctl bootout system/com.macloc.agent` 卸掉 daemon。

> 仓库里 `tools/loctest-app.sh` 是**验证探针**：它会往自己的 TCC 数据库插一条「定位服务=允许」，
> 好让一个第三方 App 能读到位置用来验证全局性。只对自己机器上的探针 App 生效，别的 App 碰不到。
> 验证完可以 `./tools/loctest-app.sh clean` 清掉。

请只在自己有权限的机器上使用。

---

## 一、为什么 iOS 的 Shadowrocket 方案在 Mac 上无效

你在 iOS 上用的那套（改写 `https://gsp-ssl.ls.apple.com/clls/wloc`）在 macOS 上根本不是一个可选项，原因是三条硬的：

### 1. macOS 上根本没有 `dispatcher.arpc` 这个东西

```
$ grep -rl --binary-files=text "dispatcher.arpc" /usr/libexec /System/Library/PrivateFrameworks /System/Library/Frameworks
(空)
```

`dispatcher.arpc` 是 **ARPC**（Apple 私有 RPC）框架的端点，跑在 iOS/macOS 的 `geod` / GeoServices 那一侧，用来做**逆地理编码、国家/时区判定、服务分发**这类查询 —— 它**不是定位链路**。就算你把它劫持了，回包也只能影响「这个坐标属于哪个国家」，不会产生一个位置 fix。

### 2. macOS 的「网络位置」请求在 locationd 自己身上，而且是另一个 URL

`/usr/libexec/locationd` 里内置的 Apple 地理服务端点：

| URL | 用途 |
|---|---|
| `https://gsp10-ssl.apple.com/hcy/pbcwloc` | **Wi-Fi 位置估计**（macOS 对应 iOS `/clls/wloc` 的那个） |
| `https://gsp10-ssl.ls.apple.com/hvr/aploc` | 粗略位置 |
| `https://gsp10-carry.ls.apple.com/hvr/alt` | 海拔 |
| `https://gsp10-ssl.apple.com/hvr/trc` / `hvr/ion` | 轨迹 / 电离层 |
| `https://gsp10-ssl.apple.com/pds/pd`、`/incs`、`/pbu`、`/psr` | 反查、兴趣点、POI |

grep 全系统只有 `pbcwloc` 存在于 `locationd` 一个二进制里，`dispatcher.arpc` 零命中。

### 3. 就算你去劫持 `pbcwloc`，也还是改不动蓝点

- **数据链路是 HTTPS + 设备绑定**。MITM 代理要重写响应，得让 locationd 信任你的证书；macOS 上给系统守护进程装根证书即使做成了，locationd 的请求还带设备/账号维度的绑定信息。
- **只影响「网络估计」，不影响最终 fix**。`CLNetworkLocationProvider` 的结果只是 `CLLocationCalculator` 众多输入之一，和 GPS provider、Wi-Fi 指纹库、蜂窝、行为模型一起做融合；改一个估计值会被融合算法稀释掉。
- **前提条件就不满足**。`CLNetworkLocationProvider` 需要**附近真的有 Wi-Fi AP 且能关联**。本机实测：`@ClxSnapshot: WifiOff / NoReach / Unassociated` —— 没有任何 Wi-Fi 位置源，这条路一开始就是死的。

### macOS 上的正解：走系统自带的模拟通道

`locationd` 内置了一个 **`CLSimulatedLocationProvider`**，日志里会打 `Using simulated location from defaults`。
它在启动时从**自己的偏好域**读四个键：

```
/var/db/locationd/Library/Preferences/ByHost/com.apple.locationd.<hostUUID>.plist
    AllowSimulatedLocations      = true
    SimulatedLocationLatitude    = <lat>
    SimulatedLocationLongitude   = <lon>
    SimulatedLocationAccuracy    = 5
```

命中后 locationd 会 `@ClxProvider, start, simulated`，然后每秒产一条 `@ClxSimulated` fix，**优先级高于所有真实 provider**，并广播给所有已注册的 CoreLocation 客户端。

> 注意：`~/Library/Preferences/com.apple.locationd.plist`（用户域）里的同名键 **locationd 不读**。必须写 `/var/db/locationd/Library/Preferences/ByHost/` 下面那两份（普通 + `.notbackedup.`）。

---

## 二、三条通道

| | **偏好通道**（默认） | **daemon 通道**（免密码） | **XPC 通道**（实时） |
|---|---|---|---|
| 脚本 | `install.sh` / `set.sh` / `stop.sh` | `install-daemon.sh` / `loc.sh` | `xpc-push.sh` |
| 需要管理员密码 | 是（每次弹窗） | **只装一次** | 否 |
| 需要关 SIP | **否** | **否** | 是 |
| 需要注入 App | 否 | 否 | 注入 `CoreLocationAgent.app` |
| 换坐标耗时 | ≈ 2 s（重启 locationd） | ≈ 2 s | 即时 |
| 图形 UI | 无 | **有（MacLocBar.app）** | 无 |
| 稳定性 | 高 | 高 | 高 |

### 通道 A：偏好通道（默认）

写 locationd 自己的偏好 → 重启 locationd → 全系统生效。
**不需要关 SIP、不需要注入、不需要任何第三方二进制。**

### 通道 B：daemon 通道（免密码 + 图形 UI）

在通道 A 之上加一个 root 守护进程，通过 unix socket 接收改坐标指令。
装好之后：改坐标**不再弹密码框**，并且有 **MacLocBar.app** 菜单栏 UI。

守护进程是**按需运行**的（launchd socket 激活）：平时系统里一个 macloc 进程都没有，
有客户端连上才拉起，干完活空闲 20 秒自己退。见「装 daemon」一节的「按需运行」。

见下文「四、日常使用」与「四之二、图形 UI」。

### 通道 C：XPC 通道（实时切换，免 root）

CoreLocation.framework 私有类 `CLSimulationManager` → mach service `com.apple.locationd.simulation`。
该服务会校验客户端签名，必须带 `com.apple.locationd.simulation` entitlement —— 全系统**只有** `/System/Library/CoreServices/CoreLocationAgent.app` 拥有它。

所以做法是：把 `spoof.dylib`（arm64e）注入 CoreLocationAgent，以它的合法身份把模拟坐标推进 locationd。
`locationd` 那边会打 `Setting simulation to 1 for all location providers`，并把位置投递给 `com.apple.Maps` 等客户端。

细节（都是实测踩出来的）：

- dylib **必须编成 arm64e**。平台二进制是 arm64e，注入 arm64 会被 dyld 直接拒。
- dylib 必须**原子替换**（`cp x.new && mv`）。原地 `cp` 覆盖仍被映射的 inode 会让 AMFI 报 `SIGKILL (Code Signature Invalid)`，CoreLocationAgent 崩溃循环。
- 换坐标必须**先 `stopLocationSimulation` + `clearSimulatedLocations` 再 `append` + `start`**。否则 locationd 的 `fSimulationRunning` 一直是 1，不会触发 `LocationProvider is notifying clients`，客户端收不到新位置。
- `launchctl debug <job> --environment` 需要 root；用 `launchctl setenv`（不需要 root）+ 短暂注入窗口 + 立即 `unsetenv` + `kickstart -k` 来撤除。

---

## 三、安装

```bash
cd ~/macloc
./install.sh 39.9042 116.4074      # 经度 纬度（北京），弹管理员授权框
```

install.sh 做四件事：

1. 检查环境（arm64 / SIP 状态）
2. 打开 macOS **「定位服务」总开关** —— `LocationServicesEnabled`
   > 这一步不做的话，模拟 fix 照跑，但所有客户端只会拿到 `kCLErrorDomain error 1`（LocationUnknown），蓝点不动。locationd 日志里的 `location disabled system-wide` 就是这个开关。
3. 打开 `AllowSimulatedLocations` 并写入坐标（同时写 ByHost + `/Library/Managed Preferences/` 两处，保持同步）
4. 重启 locationd 并验证 `@ClxSimulated` 计数

> `locationd` 进程属主是 `_locationd`（家目录 `/var/db/locationd`），它只读**自己**的偏好。

---

## 四、日常使用

### 命令行

```bash
./loc.sh 35.6762 139.6503      # 改成东京（装了 daemon 就免密码，没装自动回退授权框）
./set.sh 39.9042 116.4074      # 改成北京（永远走授权框通道）
./status.sh                    # 看当前状态（含 daemon 通道状态）
./verify.sh                    # 自动验证：开图 → 截图 → 找出蓝点 → 存特写
./stop.sh                      # 关掉模拟定位，恢复原状
open -a Maps                   # 手动验证：蓝点应该在目标位置
```

`verify.sh` 会在 `~/macloc/verify.png` 生成一张蓝点特写（Apple 地图「当前位置」蓝点实测颜色是 RGB(0,145,255)`，`tools/finddot` 靠这个颜色做聚类定位）。

### 图形 UI：MacLocBar.app

**这是日常用的主入口。** 菜单栏右侧会出现一个**蓝色地图定位点**图标，点它展开菜单：

```
📍 伦敦 London
   51.49433, -0.08350
   ⚡ daemon 通道（免密码）
────────────────────────
预设位置 ▸        （伦敦 / 北京 / 上海 / 东京 / 香港 / 台北 / 新加坡 /
                    京都 / 纽约 / 旧金山 / 洛杉矶 / 西雅图 / 巴黎 / 柏林 /
                    阿姆斯特丹 / 罗马 / 莫斯科 / 迪拜 / 利雅得 / 悉尼 /
                    墨尔本 / 奥克兰 / 曼谷 / 圣保罗 / 墨西哥城）
自定义坐标…       （弹两个输入框填经纬度）
────────────────────────
验证当前蓝点位置   （开图 → 截图 → 找蓝点 → 弹出特写图）
打开地图
────────────────────────
关闭模拟定位
在 Dock 中显示图标
语言 ▸              （中文 / English）
────────────────────────
退出 MacLocBar
```

安装 / 启动：

```bash
./build-ui.sh          # 编译并安装到 /Applications/MacLocBar.app
open /Applications/MacLocBar.app
```

> 2026-11 起 App 装在 **`/Applications/`**（跟别的 App 待一起），老的 `~/Applications/MacLocBar.app` 已删。
> `/Applications` 是 `775 root:admin`，你在 `admin` 组里，所以 `./build-ui.sh` **默认免密**；
> 实在不行（权限被改过）才会弹一次系统授权框。

图标是**自绘的地图蓝点**（RGB 0,145,255 + 白色光晕），一眼就能在菜单栏里认出来。
菜单里的通道标签会实时显示当前走的是 `⚡ daemon 通道（免密码）` 还是 `🔑 授权框通道`。

#### 傻瓜式用法（就三步）

```
① 双击 MacLocBar.app          → 主窗口直接弹出来
② 点一个城市按钮（伦敦/上海…） → 3~6 秒生效，不弹任何密码框
③ 完事。Maps 蓝点已经挪过去了
```

**App 是「打开才跑」，默认不开机自启。** 关掉就彻底没进程了（daemon 也会顺手收工）。

想开机就有这个图标（后台常驻、不弹窗）：

```bash
./install-login.sh          # 装开机自启（LaunchAgent com.macloc.bar）
./install-login.sh --remove # 卸掉（默认状态）
```

装完的效果：开机后菜单栏一直有个蓝色地图点；随时**双击 App 打开的主窗口**
或**点菜单栏图标 → 「打开主窗口…」** 都能操作，两者是同一个进程，不会重复开。

> 坐标生效要 3~6 秒：daemon 会重启 `locationd`，模拟 provider 起来之后才推位置。
> 如果 daemon 没装，App 会自动回退到 `set.sh`，这时会弹一次系统管理员授权框。

#### 主窗口模式

菜单里点「**打开主窗口…**」（或者命令行 `open -a /Applications/MacLocBar.app --args --panel`），
弹出一个完整面板：

```
┌──────────────────────────────────────────┐
│  [App 图标]  MacLoc                       │
│              ● 模拟定位生效中             │
│              ⚡ daemon 通道（免密码）     │
│                                          │
│  当前位置                                 │
│  伦敦 London                              │
│  51.49433, -0.08350                       │
│                                          │
│  快速切换                                 │
│  ✓伦敦 北京 上海 东京 香港 台北           │
│   新加坡 京都 纽约 旧金山 洛杉矶 西雅图   │
│   巴黎 柏林 阿姆 罗马 莫斯科 迪拜         │
│   利雅得 曼谷 悉尼 墨尔本 奥克兰 圣保罗   │
│   墨西哥                                  │
│                                          │
│  自定义坐标  [51.49433] [-0.08350] [应用] │
│  [验证蓝点位置] [打开地图] [关闭模拟定位]  │
│  ✓ 已切换位置  伦敦 London                │  ← 行内提示，3.5s 自动消失
└──────────────────────────────────────────┘
```

- 点城市按钮 = 走 daemon 通道改坐标，**免密码**，3~6 秒生效；
- 关掉窗口 App 仍在后台跑，菜单栏图标继续用；
- 主窗口打开时 App 会临时切成 `.regular`，**Dock 里出现带图标的 App 图标**，
  关窗后自动退回菜单栏模式（菜单里「在 Dock 中显示图标」可以常驻）。

#### 中英文切换（i18n）

界面**中英双语**，两处都能切：

| 位置 | 说明 |
|---|---|
| 主窗口右上角 | `中文 │ EN` 分段开关，一点立刻整窗换语言 |
| 菜单栏 →「语言 ▸」 | 中文 / English，当前语言带 ✓ |

- **首次启动跟随系统语言**：读 `AppleLanguages`（本机是 `en-GB` → 默认英文）；
  之后按你选的记住，存在 `UserDefaults: <bundle id> / macloc.lang`（bundle id 默认 `com.andyscott.macloc`，可用 `MACLOC_BUNDLE_ID=…` 改）。
- 切换是**纯文案替换**，不重启进程、不改坐标、不影响 daemon 连接。
- 城市按钮在中文模式下显示「伦敦」，英文模式下显示「London」（不是「伦敦 London」混排）。

实现方式（`ui/MacLocBar.swift`）：

```swift
enum Lang { case zh, en }

enum Loc {                       // 当前语言 + 持久化
    static var current: Lang      // 首次：Locale.preferredLanguages；有存档：UserDefaults
    static func set(_ l: Lang)
}

let STRINGS: [Lang: [String: String]] = [ .zh: [...], .en: [...] ]   // 文案表
func t(_ key: String, _ args: CVarArg...) -> String                  // 取文案 + 格式化
```

daemon 回来的错误是**机器可读的错误码**（`ERR <CODE> [detail]`），UI 按 CODE 本地化：

| CODE | 含义 | 中文文案 | English |
|---|---|---|---|
| `INVALID_COORD` | 坐标越界 | 坐标不合法 | Invalid coordinates |
| `NO_PREF_FILE` | 找不到 locationd 偏好 | 找不到可用的 locationd 偏好文件 | No usable locationd preference file |
| `UNKNOWN_CMD` | 未知命令 | 未知命令 | Unknown command |
| `PERMISSION` | 非授权用户 | 权限不足 | Permission denied |
| `WRITE_FAILED` | 写偏好/状态失败 | 写入 locationd 偏好失败 | Failed to write locationd preferences |
| `BAD_ARGS` | 参数个数不对 | 命令参数不对 | Bad command arguments |
| `RESTART_FAILED` | locationd 没起来 | locationd 重启失败 | locationd failed to restart |
| `VERIFY_FAILED` | 回读校验不一致 | 回读校验失败 | Read-back verification failed |

```bash
printf 'SET 999 999\n' | nc -U /var/run/macloc.sock
# ERR INVALID_COORD latitude must be -90..90, longitude -180..180
```

#### App 图标

`AppIcon.icns` 是纯 CoreGraphics 画出来的（`tools/makeicon.swift`），没有用任何外部素材：

- Apple 风格连续圆角矩形（superellipse n=5）+ 投影 + 内描边
- 蓝色渐变底板 + 白色路网 + 街区网格
- 标准 24×24 地图定位针 path（`M12 2 C8.13 2 5 5.13 5 9 …`），白色针体 + 蓝针芯 + 针内高光

```bash
./build-icon.sh dark      # 深蓝地图风（默认，已装）
./build-icon.sh light     # 浅色地图风
./build-icon.sh neon      # 高饱和渐变风
./build-icon.sh dark && ./build-ui.sh    # 换完图标要重新打包
```

预览图会写到 `ui/AppIcon-preview-<style>.png`。

### 装 daemon（改坐标免密码）

```bash
./install-daemon.sh    # 弹一次管理员授权框，之后再也不用了
```

装的东西：

| 路径 | 作用 |
|---|---|
| `/Library/LaunchDaemons/com.macloc.agent.plist` | launchd 配置（**socket 激活，按需运行**，见下节） |
| `/usr/local/libexec/macloc/maclocd` | 守护进程本体 |
| `/var/run/macloc.sock` | unix socket（0666，launchd 建的） |
| `/var/db/macloc/maclocd.pid` | daemon 进程号（退出时自动删除） |

socket 协议（一行一条，`\n` 结尾）：

| 命令 | 返回 |
|---|---|
| `PING` | `PONG` |
| `SET <lat> <lon>` | `OK <lat> <lon>` / `ERR <CODE> [detail]` |
| `OFF` | `OK off` / `ERR <CODE> [detail]` |
| `SYNC <lat> <lon> <on>` | `OK sync`（只更新状态文件，不动偏好） |
| `STATUS` | `ON <lat> <lon>` / `OFF` |
| `QUIT` | `OK quit`（App 退出时用，让 daemon 收工） |

错误码见上文「中英文切换」一节的表格。

```bash
printf 'SET 51.49433 -0.08350\n' | nc -U /var/run/macloc.sock
printf 'PING\n' | nc -U /var/run/macloc.sock
```

daemon 只接受 **控制台登录用户** 或 root 的连接（`getpeereid` 校验）。

daemon 日志 `/var/log/maclocd.log` 里每条命令都带**对端进程号**，出问题能直接看出是谁发的：

```
2026-11-06 06:38:01 cmd [pid=53144 uid=501] QUIT
2026-11-06 06:38:01 quit
```

### 按需运行：socket 激活（2026-11 起）

**没有常驻进程。** plist 里 `RunAtLoad=false` + `KeepAlive=false`，再挂一个 `Sockets` 字典：

```xml
<key>Sockets</key>
<dict>
  <key>com.macloc.sock</key>
  <dict>
    <key>SockPathName</key>  <string>/var/run/macloc.sock</string>
    <key>SockPathMode</key>  <integer>438</integer>   <!-- 0666 -->
    <key>SockFamily</key>    <string>Unix</string>
  </dict>
</dict>
```

于是：

| 时刻 | 系统里有什么 |
|---|---|
| 平时（没开 App） | **一个 macloc 进程都没有**，只有 launchd 守着的那个 socket 文件 |
| 有客户端连上 | launchd 才拉起 `maclocd`（root），`runs` 计数 +1 |
| 干完活 | 空闲 **20 秒**后 daemon 自己退出 |
| App 退出 | 发 `QUIT`，daemon 协作式退场（没命令在飞才退），再活满 11 秒才真正退出 |

三个必须知道的细节：

- **`Sockets` 里不能用 `Path`**。写 `Path` 会 `error = 3`，socket 根本建不出来，只能用 `SockPathName`。
- **进程要用 `launch_activate_socket(3)` 取 fd**，`LISTEN_FDS` 环境变量**不存在**（那是 xinetd 风格）。头文件里原型是 `int **fds`，返回数组布局有歧义 —— 所以用 `daemon/LaunchShim.h` 这个 C shim 在运行时用 `fstat`+`S_ISSOCK` 自适应两种布局，别在 Swift 里猜指针层级。
- **launchd 的 minimum runtime 是 10 秒**：进程活不到 10 秒就退会被当成 crash 节流。所以 daemon 退出前至少活满 `MIN_LIFETIME=11`，并且退出是**协作式**的（先确认没有命令在飞，不会把写到一半的请求砍掉）。

验证：

```bash
launchctl print system/com.macloc.agent | grep -E "state =|runs =|last exit"
# state = not running      ← 平时就是这个
# runs = 12                ← 每次有人连接 +1
# last exit code = 0       ← 干净退出，没被节流
```

### 实时切换（需 SIP 关闭，免密码）

```bash
./xpc-push.sh 22.3193 114.1694     # 立刻切到香港
./xpc-push.sh --watch               # 常驻；之后直接改坐标文件即可
echo "35.6762 139.6503" > ~/.macloc/loc.conf
./xpc-push.sh --stop                # 停掉
```

---

## 五、作用范围：全局，不是只有 Maps

**结论：凡是拿到「定位服务」授权的 App，看到的都是模拟坐标，不是真实坐标。**

因为改的是 **`locationd` 自己的模拟 provider**（`AllowSimulatedLocations` + 坐标写进
locationd 的 ByHost 偏好）。macOS 上所有用 CoreLocation 的程序都只能从 `locationd`
取位置，没有第二条数据通路。

### 证据 1：locationd 的客户端投递名单

```
Sending location to client  →  root:.../WirelessDiagnostics.framework:.../CoreWLAN.framework   2452 次
                               root:.../LocationBundles/CountryTracker.bundle                     14 次
                               root:.../LocationBundles/Routine.bundle                            11 次
                               root:.../LocationBundles/DestinationdLocationBundleiOS.bundle        8 次  (iCloud 查找)
                               com.apple.Maps                                                       5 次
                               com.openai.codex                                                     3 次  (第三方进程)
```

系统 Wi-Fi 栈、国家判定、位置自动化、Find My、第三方 App —— 全都收到同一条模拟位置。

### 证据 2：黑盒 —— 造一个全新的第三方 App

`tools/loctest-app.sh` 编译出 `/tmp/Loctest.app`（bundle id `com.macloc.loctest`），
它从没在这台机器上用过定位：

```bash
./tools/loctest-app.sh build
./tools/loctest-app.sh grant    # 插一条 TCC 定位授权（可选，实测 macOS 直接给了 authorizedAlways）
./tools/loctest-app.sh run
```

```
PROBE pid=79620 bundle=com.macloc.loctest
AUTH_CHANGE=3
UPDATE lat=51.49433135986328 lon=-0.08349999785423279 hAcc=5.0
```

### 证据 3：A/B 对照（同一个 App，开/关模拟）

| 模拟状态 | 第三方 App 读到的 | `@ClxSimulated` |
|---|---|---|
| 开（伦敦） | `51.49433, -0.08350`（hAcc=5.0） | 每秒一条 |
| 关 | `kCLErrorDomain error 0`（读不到任何位置） | 0 条 |

> 注意：这台 Mac **没有真实定位源**（无 Wi-Fi 关联、无 GPS），所以关掉模拟不是「变回真位置」，
> 而是「什么都读不到」。

### 三条边界（要知道）

1. **App 自己得有「定位服务」授权**（TCC `kTCCServiceLocation`）。
   没授权 → `kCLErrorDomain error 1`。
   系统 bundle（Wi-Fi 栈 / CountryTracker / Find My）不受这个限制。
2. **IP 网络位置是另一条链路，不受模拟影响**。
   日志里 `got response from GeoServices about IP-based country` —— 那条按 **IP + Wi-Fi 指纹**
   判国家，仍然是真实网络所在地。所以拿 IP 反查地理位置的服务（很多风控）骗不到。
3. **时区/区域设置不是模拟写出来的**。当前 `/etc/localtime` 是 `Europe/London`
   （`TimeZone.bundle` 也在消费 locationd 的位置），长期开着模拟有可能让系统自动跟着漂。

---

## 六、安全加固（2026-11-02 四条审计意见的修复）

外部审计提了 4 条问题，**逐条复核后全部属实**，已全部修复并复测。

### 6.1 根 daemon 的符号链接提权

**原问题**：daemon 以 root 身份对 `~/.macloc` 做 `chown`。
用户把 `~/.macloc` 换成指向 `/etc` 的符号链接，root 就顺着链接把
`/etc` 的属主改成用户 → **本地提权**。同一目录下的 root 日志写入同样没处理。

**修法**：

| 项 | 之前 | 现在 |
|---|---|---|
| root 写用户家目录 | 写 `~/.macloc/state`、`~/.macloc/macloc.log` | **完全不写** |
| 权威状态 | — | `/var/db/macloc/state`（`root:wheel 0644`） |
| 偏好备份 | — | `/var/db/macloc/backup`（`root:wheel 0700`） |
| daemon 日志 | — | `/var/log/maclocd.log`（`root:wheel 0644`） |
| 处理偏好文件 | 无属主校验 | `lstat` 排除符号链接 + 只接受 `root` / `_locationd` 拥有的常规文件 |
| MCX 文件 | 无校验 | 符号链接直接拒绝写入 |

用户域的 `~/.macloc/state` 降级为**只读回退副本**，只由用户自己的 shell 进程写。

### 6.2 `install.sh` 的 root 命令注入

**原问题**：坐标参数直接拼进「以 root 执行的 shell 脚本」：

```bash
PlistBuddy -c "Set :SimulatedLocationLatitude $lat" "$F"     # lat = '$(id > /tmp/PWN)'
```

`$(...)` 会以 root 身份展开。PoC 已复现。

**修法**：

1. `sanitize_coord()` 先把坐标规范化成 `%.6f %.6f` 的纯数字串，
   范围检查不通过直接拒绝（`$(...)`、反引号、`;`、引号 breakout 全部被挡）；
2. root 脚本里坐标只以 `LAT="51.494330"` 形式出现，**不参与任何命令拼接**；
3. 真正的写盘逻辑抽到 `lib/apply-coords.sh`，路径全是常量，
   不含任何用户可控字符串；
4. `admin_run()` 的临时脚本从 `/tmp` 挪到 `~/.macloc/tmp.XXXXXX`（0700 私有目录），
   堵掉「生成 → 执行」之间被别的本地用户调包的路子。

### 6.3 关闭 / 恢复行为不可靠

**原问题**：daemon 在 OFF 时仍把 `LocationServicesEnabled` 强行设成 `true`，
不备份原值；所有 `plistSet` / `killall` 的返回值被丢弃，最后照样返回 `OK`。

**修法**：

- 首次修改前把原偏好备份到 `/var/db/macloc/backup`（0700 root）；
- OFF 时**从备份恢复** `LocationServicesEnabled` 的原始值（没有备份就不动它），
  不再强行设 `true`；
- 每一步都查返回值，失败打印 `MACLOC_STEP_FAIL: <具体哪一步>` 并置 `fail=1`；
- 写完**回读校验**（容差 1e-4，float32 精度够用）+ 确认 `locationd` 真的起来了；
- 任何一步不行 → `MACLOC_FAIL`，**绝不谎报 OK**；
- shell 侧的成功判据从 `grep "locationd restarted"` 改成 `grep -q "^MACLOC_OK$"`。

### 6.4 UI 忽略脚本退出码

**原问题**：`disableSimulation()` 的回退分支无条件报「模拟定位已关闭」——
取消管理员授权、脚本失败，全都显示成功。

**修法**：检查 `Process.terminationStatus`，非 0 就把脚本输出原样带回来：

```
✘ 关闭失败  STUB_FAIL_MARKER: 模拟的 stop.sh 故意失败（exit 3）
```

成功分支仍然是 `✓ 模拟定位已关闭`。

### 6.5 顺带修掉的其它坑

| 问题 | 原因 | 修法 |
|---|---|---|
| `MACLOC_OK` 判据永远不成立 | `osascript do shell script` 把 stdout 的 `\n` 转成 `\r`，多行输出粘成一行 | `admin_run()` 输出统一 `tr '\r' '\n'` |
| `（当前 $NOW）` 报 unbound variable | bash 在 UTF-8 locale 下把全角 `）` 并进变量名 | 全项目改写成 `${NOW}`，并加了扫描脚本 |
| `MACLOC_DIR` 算成 `/Users/<你的用户名>` | zsh 里 `BASH_SOURCE[0]` 是空的 | `BASH_SOURCE` 优先，回退 `pwd` 并校验 `lib/macloc.sh` 存在 |
| daemon 报「找不到可用的 locationd 偏好文件」 | 属主校验写死成「必须 root 拥有」，实际是 `_locationd` 拥有 | 接受 `root` 或 `_locationd` |
| 手动跑 `set.sh` 后 UI 显示旧坐标 | daemon 的权威状态没被更新 | 新增 `SYNC` 命令（只更新状态，不重启 locationd），`set.sh`/`stop.sh`/`install.sh` 改完都同步 |
| 菜单里的「预设位置 / 语言」子菜单点不开 | 定时器每 6 秒把 `statusItem.menu` **整个换成新对象**，正在跟踪的菜单被换走 | 菜单结构只建一次（`buildMenu()`），之后只原地改标题/勾选（`refreshMenu()`）
| 城市按钮排成一列、窗口被撑到 1211pt 高 | `NSStackView.alignment` 的轴和 `orientation` 不匹配时，AppKit 会**把 stack 翻转方向** | 横向 row 不设 `.leading`（那是 x 轴属性）；按钮改用固定宽度 80pt + 网格左对齐 |

### 6.5.1 改成「按需运行」之后踩的坑

| 问题 | 原因 | 修法 |
|---|---|---|
| plist 里写了 `Path` → launchd `error = 3`，socket 建不出来 | `Sockets` 字典只认 `SockPathName` / `SockFamily` / `SockPathMode` | 改用 `SockPathName` + `SockPathMode 438`（=0666）+ `SockFamily Unix` |
| daemon 起来但收不到连接 | `LISTEN_FDS` 环境变量**不存在**（那是 xinetd 风格） | 用 `launch_activate_socket(3)` 取 fd |
| `launch_activate_socket` 返回的数组指针层级搞错 | 头文件原型是 `int **fds`，实际返回布局有两种 | 收到 C shim `daemon/LaunchShim.h` 里，运行时 `fstat` + `S_ISSOCK` 自适应 |
| `launchctl remove <label>` 之后 bootstrap 一律 EIO | `launchctl remove` 会把 job 置成 **disabled** | 装之前先 `launchctl enable system/com.macloc.agent` |
| daemon 退得太快 → 下次拉起被节流 | launchd 的 **minimum runtime = 10 秒**，活不到就当 crash | 退出前至少活满 `MIN_LIFETIME=11`，且用协作式退出（有命令在飞不退） |
| App 退出时 QUIT 发不出去 | `kill(pid, 0)` 对 **root 进程返回 EPERM**，被当成「进程没了」 | `errno == EPERM` 视为「活着」（没权限 ≠ 不存在） |
| 无脑发 QUIT 会把已退的 daemon 又拉起来 | 发 QUIT 本身就连了一次 socket，launchd 会再 spawn 一个 | 退出前先读 pid 文件判活（`daemonAlive()`），活着才发 |
| 菜单栏 6 秒刷新把 daemon 一直叫醒 | 刷新时用 PING 探活 = 每次都连一次 socket | `daemonUp()` 改成**只看 socket 文件存在**，绝不 PING |
| App 点了城市，daemon 收到两条 SET | 自动化用合成鼠标点击，窗口动画期间 AX 报的是**旧位置**，点到了隔壁按钮 | 改用 **AXPress** 直接触发按钮（不经过坐标），并加「点完校验坐标，不符重试」 |
| 点「Paris」结果选中了 London | 激活 App 会触发 `centerOnScreen()` **移动窗口**，AX 读到旧位置 | AXPress 为主 + 等窗口几何稳定 + 点完校验目标坐标 |
| 脚本 `（当前 $NOW）` unbound variable | bash 把全角 `）` 并进变量名 | 全部改 `${NOW}`，并加扫描脚本 |

### 6.6 复测记录

| 项目 | 结果 |
|---|---|
| `payload_write_coords '$(id > /tmp/PWN)'` | 只输出 `MACLOC_ERR 坐标不合法`，生成物里**无** `$(` ✅ |
| 引号 breakout 载荷 | 同上，无 breakout ✅ |
| daemon 运行中 `~/.macloc/state` 的 mtime | **完全没被碰**（daemon 不再写用户家目录）✅ |
| daemon `SET` 后 | `/var/db/macloc/state` 更新，探针读到新坐标 ✅ |
| daemon `OFF` 后 | `AllowSimulatedLocations=false`、坐标键删除、`@ClxSimulated` 归零 ✅ |
| daemon `OFF` 后 `LocationServicesEnabled` | 从备份恢复，不是强行设 true ✅ |
| `/var/db/macloc/backup` 权限 | `root:wheel 0700` ✅ |
| UI 回退分支（桩脚本 exit 3） | 显示 `✘ 关闭失败 …（exit 3）`，**不再谎报成功** ✅ |
| UI 回退分支（桩脚本 exit 0） | 显示 `✓ 模拟定位已关闭` ✅ |
| `set.sh` 走 `admin_run` | `MACLOC_OK` + `locationd restarted` ✅ |
| `stop.sh` 走 daemon 通道 | 免密码，状态 `off`，探针读不到位置 ✅ |
| `set.sh` → `SYNC` | daemon 权威状态同步为同一坐标 ✅ |
| 首次启动（系统 `en-GB`） | 界面默认**英文** ✅ |
| 主窗口右上角 `中文 │ EN` | 一点整窗切换，坐标/daemon 状态不受影响 ✅ |
| 菜单栏 →「语言 ▸」 | 切中文成功，菜单标题全部变中文 ✅ |
| 语言持久化 | 杀进程重开后仍是上次选的语言（`UserDefaults: macloc.lang`）✅ |
| daemon 错误码 | `SET 999 999` → `ERR INVALID_COORD …`；`BADCMD` → `ERR UNKNOWN_CMD …` ✅ |
| `tools/uitest.sh 上海` | AX 读真实按钮位置 → AXPress → 6 秒内状态更新为 `31.230400 / 121.473700` ✅ |
| 探针（第三方 App） | `51.49433135986328, -0.08349999785423279`（伦敦）✅ |
| `tools/uitest.sh` 连点 5 个城市 | 旧金山/纽约/曼谷/迪拜/悉尼 **全部一次命中**，每个城市只发 1 条 SET ✅ |
| 打开 App（不点任何城市） | **不拉起 daemon**，系统里零 macloc 进程 ✅ |
| 点城市 → 退出 App | daemon 日志出现 `cmd [pid=…] QUIT` + `quit`，16 秒后**零 macloc 进程** ✅ |
| `launchctl print system/com.macloc.agent` | `state = not running` / `runs = 12` / `last exit code = 0`（干净退出，未被节流）✅ |
| 空闲 20 秒后 | daemon 自己退出，日志 `idle 20s -> exit`，pid 文件自动删除 ✅ |
| `./build-ui.sh` 重复执行 | **免密**（`/Applications` 是 775 root:admin），3.9 秒，不弹授权框 ✅ |

---

## 七、日志判据

```bash
# 用 /usr/bin/log（zsh 内建 log 会冲突）
/usr/bin/log show --predicate 'process == "locationd"' --last 2m --style compact | grep -i simul
```

| 日志 | 含义 |
|---|---|
| `Using simulated location from defaults` | 偏好通道生效 |
| `@ClxProvider, start, simulated` | 模拟 provider 已启动 |
| `@ClxSimulated, Fix, ...` | 正在产出模拟位置（每秒一条） |
| `@ClxClient, Fix, ...` | 位置已投递给客户端 |
| `Sending location to client ... com.apple.Maps` | 蓝点已更新 |
| `Setting simulation to 1 for all location providers` | XPC 通道生效 |
| `location disabled system-wide` | **「定位服务」总开关关着** |
| `unentitled client attempting to simulate location` | entitlement 校验失败 |
| `kCLErrorDomain error 1` | 客户端拿到 LocationUnknown（通常是总开关关着） |

坐标在日志里是 `<private>` / `<redacted>`，**只能靠 Maps 蓝点截图验证**：

```bash
open -a Maps; sleep 8; screencapture -x /tmp/m.png
```

---

## 八、回滚

```bash
./stop.sh
```

会把 `AllowSimulatedLocations` 置 false 并删掉坐标键，重启 locationd。
「定位服务」总开关保持打开（方便以后再用），需要彻底恢复的话手动去
「系统设置 → 隐私与安全性 → 定位服务」关掉即可。

---

## 九、文件

```
macloc/
├── install.sh          一键安装（打开定位服务总开关 + 写坐标）
├── set.sh              改坐标（重启 locationd，弹授权框）
├── loc.sh              改坐标（自动选通道：daemon 优先，否则回退授权框）
├── stop.sh             关闭模拟（自动选通道）
├── status.sh           状态（含 daemon 通道状态）
├── verify.sh           自动验证（开图 + 找蓝点 + 存特写）
├── xpc-push.sh         XPC 实时通道
├── build-ui.sh         构建 MacLocBar.app（菜单栏 UI + 主窗口，装到 /Applications）
├── build-icon.sh       生成 App 图标 .icns（dark / light / neon）
├── install-login.sh    开机自启（LaunchAgent com.macloc.bar）—— **默认不装**，App 是「打开才跑」
├── install-daemon.sh   安装 root daemon（免密码通道，socket 激活按需运行）
├── lib/macloc.sh       公共库（提权 / 坐标规范化 / 状态检测）
├── lib/apply-coords.sh 以 root 写 locationd 偏好的核心逻辑（常量路径，可单测）
├── spoof.dylib.m       XPC 注入 dylib 源码（arm64e）
├── ui/MacLocBar.swift  UI 源码（NSStatusItem + 主窗口 PanelController + i18n 中英切换）
├── ui/AppIcon.icns     App 图标（1024×1024 起，10 个尺寸）
├── daemon/maclocd.swift root daemon 源码（unix socket 服务 + 按需运行 + 空闲自杀 + QUIT）
├── daemon/LaunchShim.h  C shim：`macloc_activate_socket()` 取 launchd 传入的 socket fd
├── tools/makeicon.swift App 图标生成器（纯 CoreGraphics）
├── tools/finddot.m     截图中定位「当前位置」蓝点
├── tools/winid.m       打印 App 的 CGWindowNumber（精确截窗口用）
├── tools/click.m       模拟点击 / ESC（自动化测试用）
├── tools/uitest.sh     端到端 UI 测试：激活 → 点城市 → 轮询状态
├── tools/menubarpos.m  在截屏菜单栏里定位 MacLoc 蓝点图标
├── tools/loctest.swift 第三方 App 视角的定位探针（验证全局性）
├── tools/loctest-app.sh 把探针打成 .app、授/撤 TCC、跑一次
└── README.md
```

运行时状态在 `~/.macloc/`：`loc.conf`（坐标）、`state`（**只读回退副本**）、`macloc.log`（操作日志）。
daemon 侧状态在 `/var/db/macloc/state`（`root:wheel 0644`，**权威来源**），
原偏好备份在 `/var/db/macloc/backup`（`root:wheel 0700`），日志在 `/var/log/maclocd.log`。

---

## 十、实测记录（本机）

| 操作 | 结果 |
|---|---|
| 写偏好 + 重启 locationd | `Using simulated location from defaults` → Maps 蓝点落在北京 ✅ |
| 同上，换香港 | 蓝点精确落在 22.3193, 114.1694 ✅ |
| 注入 CoreLocationAgent 推东京 | `Setting simulation to 1 for all location providers` → 蓝点落在东京 ✅ |
| `xpc-push.sh` 推上海（偏好通道同时开着且指向香港） | 蓝点落在**上海** → **XPC 通道覆盖偏好通道** ✅ |
| 改坐标但不重启 locationd | 坐标**不生效**（simulated provider 缓存了旧值）❌ |
| post `com.apple.ManagedConfiguration.profileListChanged` | 只重载 Country 设置（`settings updated`），坐标仍不生效 ❌ |
| `sudo -u _locationd defaults write ...` | 写到 `/var/db/locationd/Library/Preferences/com.apple.locationd.plist`（非 ByHost），locationd 不读 ❌ |
| `log config --mode "private_data:on"` | 无效 —— 坐标用的是 `Encrypted_CLLocationCoordinate2D` 私有标记，日志里存的是密文，不是打码 ❌ |
| CLI 客户端（`CLLocationManager` 直连） | `AUTH-STATUS 0` + `kCLErrorDomain error 1` —— 未授权客户端拿不到位置，必须靠有 TCC 授权的 App 验证 ⚠️ |
| 全局 `DYLD_INSERT_LIBRARIES` 注入 hardened 第三方 App | SIP 关闭时不死（LV 校验随 SIP 失效）；但仍用完立刻 `unsetenv` 缩小窗口 ✅ |
| daemon 通道 `SET 35.67620 139.65030` | `OK 35.676200 139.650300`，日志出现 `Using simulated location from defaults` ✅ |
| MacLocBar UI 点「上海 Shanghai」 | state 变 31.2304, 121.4737，**免密码** ✅ |
| MacLocBar UI 点「伦敦 London」 | state 变 51.49433, -0.08350 ✅ |
| **主窗口**点「上海」按钮 | state 变 31.23040, 121.47370，耗时 **3s**，无授权框 ✅ |
| **主窗口**点「伦敦」按钮 | state 变 51.49433, -0.08350，耗时 **6s** ✅ |
| 改坐标（daemon 通道）后 locationd 日志 | `Using simulated location from defaults` + `setting simulation to 1 for all location providers` ✅ |
| `ui/AppIcon.icns` 装进 App | `CFBundleIconFile=AppIcon`，Dock / 弹窗 / 窗口头部三处都渲染出新图标 ✅ |
| `NSWindow.center()` 定位 | 无 key window 时跑到屏幕外（y=-115）→ 改成按 `NSScreen.main.visibleFrame` 显式居中 ✅ |
| 后台常驻实例 + 双击 App | 同一个进程收到 reopen → 主窗口弹出，**不新建进程**（进程数恒为 1）✅ |
| 开机自启 `com.macloc.bar` | 已按需卸载（App 改成「打开才跑」）；`launchctl list \| grep macloc` 为空 ✅ |
| `launchctl bootstrap` 报 EIO | 之前跑过 legacy `launchctl load -w` 留下了覆盖 → 先 `launchctl remove <label>` 再 bootstrap ✅ |
| plist 里 `<key>LimitLoadToSessionType</string>` | 闭合标签写错 → plist 语法错误，launchd 直接不认（`plutil -lint` 能查出来）✅ |
| **第三方 App**（全新 bundle `com.macloc.loctest`）首次请求定位 | 直接读到 `51.49433135986328, -0.08349999785423279`（hAcc=5.0）→ **模拟是全局的** ✅ |
| 同上，模拟关闭后 | `kCLErrorDomain error 0`（读不到任何位置），`@ClxSimulated` 归零 ✅ |
| 同上，重新打开模拟 | 又读到伦敦，`@ClxSimulated` 每秒恢复 ✅ |
| daemon `OFF` 后 ByHost 偏好 | `AllowSimulatedLocations=false` + 坐标键被删 ✅ |
| 残留 maclocd 实例 | 5 小时前两个开发副本还活着（用 `MACLOC_SOCKET` 测过）→ 已清掉，现在只有 `/usr/local/libexec/macloc/maclocd` 一个 ✅ |
| `CoreLocationAgent` 是否还挂着注入 dylib | `lsof` 查不到任何 spoof/macloc dylib → XPC 通道当前**没在跑**，模拟纯靠偏好通道 ✅ |
| `tools/finddot` 收紧到精确色 `g∈[136,156]` | 不再把 RGB(0,122,255) 的地球图标误判成蓝点 ✅ |
| `tools/winid` 打印 Maps 窗口 ID | `Maps window #14273 area=791817` ✅ |
| **审计修复后**daemon `SET 伦敦` | `OK 51.494330 -0.083500`，`/var/db/macloc/state` 更新，探针读到 `51.49433135986328, -0.08349999785423279` ✅ |
| **审计修复后**daemon `OFF` | `AllowSimulatedLocations=false` + 坐标键删除 + `LocationServicesEnabled` 从备份恢复 + `@ClxSimulated` 归零 ✅ |
| **审计修复后**daemon 跑着时 `~/.macloc/state` | **完全没被碰** —— daemon 不再以 root 身份写用户家目录 ✅ |
| **审计修复后**`set.sh` 走 `admin_run` | `locationd restarted` + `MACLOC_OK`，`locationd` 10 秒内 10 条模拟定位 ✅ |
| **审计修复后**`stop.sh` 走 daemon 通道 | 免密码，状态 `off`，探针 `kCLErrorDomain error 0` ✅ |
| **审计修复后**UI 回退分支（桩 exit 3） | `✘ 关闭失败 STUB_FAIL_MARKER: …（exit 3）` ✅ |
| **审计修复后**UI 回退分支（桩 exit 0） | `✓ 模拟定位已关闭` ✅ |
| `osascript do shell script` 的换行 | stdout 的 `\n` 被转成 `\r` → 多行输出粘成一行、`^MACLOC_OK$` 永远匹配不上 → `admin_run()` 里 `tr '\r' '\n'` ✅ |
| bash 变量名跟全角字符 | `（当前 $NOW）` 在 UTF-8 locale 下报 unbound variable → 全项目改 `${NOW}` ✅ |
| zsh 下 `BASH_SOURCE[0]` | 为空 → `MACLOC_DIR` 算错 → 改用 `${BASH_SOURCE[0]:-$0}` + `pwd` 兜底 + 校验 ✅ |
| **socket 激活**（launchd 托管 socket，按需 spawn） | `state = not running` / `runs` 按需递增 / 连接即拉起 / 空闲 20s 自杀 / 退出后可再拉起 ✅ |
| 冷启动 SET（daemon 不在） | `OK 39.904200 116.407400`，耗时 **5s**（按需拉起只比热启动多 ~1s）✅ |
| 热启动 SET（daemon 在） | 耗时 **4s** ✅ |
| `QUIT` 协议 | daemon 回 `OK quit`，日志出现 `cmd [pid=…] QUIT` + `quit`，随后 `idle 1s -> exit` ✅ |
| daemon 空闲自杀 | 日志 `idle 20s -> exit`，pid 文件自动删除，socket 文件**保留**（launchd 的）✅ |
| App 退出后系统里 macloc 进程 | **一个都没有** ✅ |
| 用户域 launchd | 无任何 macloc 项（`com.macloc.bar` 已卸载）✅ |

---

## 十一、本机当前状态

**位置：最后一次实测为 北京 39.90420° N, 116.40740° E**（状态文件 `/var/db/macloc/state` 为准）

- **没有常驻进程。** daemon 是 launchd **socket 激活**的按需进程：平时系统里零 macloc 进程，
  有客户端连上才拉起，干完活空闲 20 秒自己退。
- **App 装在 `/Applications/MacLocBar.app`**（775 root:admin），旧的 `~/Applications/` 副本已删。
  「打开才跑」—— 想开机就有图标再跑 `./install-login.sh`（默认不装）。
- 自绘 App 图标（`AppIcon.icns`，dark 风格），菜单栏 + 主窗口双形态。
- `com.macloc.agent`（system 域）：`state = not running`，`runs` 按需递增，`last exit code = 0`。

---

## 十二、许可证

MIT —— 见 [LICENSE](LICENSE)。

用在自己有权限的机器上。改坐标这件事本身不违法，但**别拿去影响别人**：
模拟定位会让所有基于 CoreLocation 的 App（打卡、签到、风控、轨迹记录）拿到假位置，
在别人不知情的情况下用是不道德的，也可能违反服务条款。
