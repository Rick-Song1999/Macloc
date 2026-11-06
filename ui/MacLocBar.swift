// MacLocBar.swift —— macloc 图形 UI（菜单栏 + 主窗口）
//
//  编译：xcrun swiftc -swift-version 5 -O MacLocBar.swift -o MacLocBar
//
//  两种形态：
//    · 菜单栏模式（默认）—— 状态栏蓝点图标 + 右键菜单，不占 Dock
//    · 主窗口模式         —— 点「打开主窗口」弹出完整面板，Dock 显示 App 图标
//
//  设置坐标的两条路：
//    1) root daemon 的 unix socket → 免密码、瞬时
//    2) 回退到 ~/macloc/set.sh → 弹系统管理员授权框
//
//  语言：
//    · 首次启动跟随系统语言（AppleLanguages）
//    · 之后按用户选择持久化（UserDefaults: macloc.lang）
//    · 主窗口右上角有中英分段开关，菜单栏里也有

import Cocoa

// MARK: - 常量

// daemon 的 unix socket 路径（可用 MACLOC_SOCKET 覆盖，方便测试回退分支）
let SOCKET_PATH = ProcessInfo.processInfo.environment["MACLOC_SOCKET"] ?? "/var/run/macloc.sock"

// MARK: - 语言

enum Lang: String {
    case zh = "zh"
    case en = "en"
}

/// 当前语言 + 持久化
enum Loc {
    private static let key = "macloc.lang"

    static var current: Lang = {
        if let saved = UserDefaults.standard.string(forKey: key), let l = Lang(rawValue: saved) {
            return l
        }
        // 首次启动：跟随系统语言
        let sys = Locale.preferredLanguages.first?.lowercased() ?? "zh"
        return sys.hasPrefix("zh") ? .zh : .en
    }()

    static func set(_ l: Lang) {
        current = l
        UserDefaults.standard.set(l.rawValue, forKey: key)
    }
}

/// 文案表。key 缺失时回退中文，再回退 key 本身。
let STRINGS: [Lang: [String: String]] = [
    .zh: [
        "panel.currentLocation": "当前位置",
        "panel.quickSwitch": "快速切换",
        "panel.customCoords": "自定义坐标",
        "panel.latitude": "纬度",
        "panel.longitude": "经度",
        "panel.apply": "应用",
        "panel.verify": "验证蓝点位置",
        "panel.maps": "打开地图",
        "panel.disable": "关闭模拟定位",
        "panel.status.on": "● 模拟定位生效中",
        "panel.status.off": "○ 模拟定位未开启",
        "panel.mode.daemon": "⚡ daemon 通道（免密码）",
        "panel.mode.prompt": "🔑 授权框通道",
        "panel.toast.updated": "已切换位置\n%@",
        "panel.toast.failed": "设置失败\n%@",
        "panel.toast.invalid": "坐标不合法\n纬度需在 -90..90，经度需在 -180..180",
        "panel.toast.noVerifyScript": "找不到 verify.sh\n%@",
        "panel.toast.verifying": "正在验证…",
        "panel.toast.noDot": "没找到蓝点\nMaps 可能被遮挡，或模拟尚未生效",
        "panel.toast.disabled": "模拟定位已关闭",
        "panel.toast.disableFailed": "关闭失败\n%@",
        "city.custom": "自定义",

        "menu.openPanel": "打开主窗口…",
        "menu.presets": "预设位置",
        "menu.custom": "自定义坐标…",
        "menu.verify": "验证当前蓝点位置",
        "menu.maps": "打开地图",
        "menu.disable": "关闭模拟定位",
        "menu.disabledAlready": "模拟定位（当前已关闭）",
        "menu.dock": "在 Dock 中显示图标",
        "menu.language": "语言",
        "menu.lang.zh": "中文",
        "menu.lang.en": "English",
        "menu.quit": "退出 MacLocBar",
        "menu.off": "📍 未开启",
        "tooltip": "MacLoc — 系统定位伪装",

        "alert.customTitle": "设置自定义坐标",
        "alert.customHint": "十进制度，例：51.49433, -0.08350",
        "alert.latRange": "纬度 (-90..90)",
        "alert.lonRange": "经度 (-180..180)",
        "alert.set": "设置",
        "alert.cancel": "取消",
        "alert.invalid": "坐标不合法",
        "alert.invalidDetail": "纬度需在 -90..90，经度需在 -180..180",
        "alert.updated": "已切换位置",
        "alert.failed": "设置失败",
        "alert.noVerifyScript": "找不到 verify.sh",
        "alert.noDot": "没找到蓝点",
        "alert.noDotDetail": "Maps 可能被遮挡，或模拟尚未生效",
        "alert.disableFailed": "关闭失败",
        "alert.ok": "好",

        "err.invalidcoord": "坐标不合法",
        "err.nopreffile": "找不到可用的 locationd 偏好文件",
        "err.unknowncmd": "未知命令",
        "err.permission": "权限不足",
        "err.writefailed": "写入 locationd 偏好失败",
        "err.badargs": "命令参数不对",
        "err.restartfailed": "locationd 重启失败",
        "err.verifyfailed": "回读校验失败",
        "err.scriptmissing": "找不到脚本",
        "err.authcancel": "授权被取消或脚本出错",
    ],
    .en: [
        "panel.currentLocation": "Current Location",
        "panel.quickSwitch": "Quick Switch",
        "panel.customCoords": "Custom Coordinates",
        "panel.latitude": "Latitude",
        "panel.longitude": "Longitude",
        "panel.apply": "Apply",
        "panel.verify": "Verify Blue Dot",
        "panel.maps": "Open Maps",
        "panel.disable": "Disable Simulation",
        "panel.status.on": "● Simulation active",
        "panel.status.off": "○ Simulation off",
        "panel.mode.daemon": "⚡ daemon channel (no password)",
        "panel.mode.prompt": "🔑 admin prompt channel",
        "panel.toast.updated": "Location updated\n%@",
        "panel.toast.failed": "Failed to set location\n%@",
        "panel.toast.invalid": "Invalid coordinates\nLatitude must be -90..90, longitude -180..180",
        "panel.toast.noVerifyScript": "verify.sh not found\n%@",
        "panel.toast.verifying": "Verifying…",
        "panel.toast.noDot": "Blue dot not found\nMaps may be covered, or the simulation is not active yet",
        "panel.toast.disabled": "Simulation disabled",
        "panel.toast.disableFailed": "Failed to disable\n%@",
        "city.custom": "Custom",

        "menu.openPanel": "Open Main Window…",
        "menu.presets": "Preset Locations",
        "menu.custom": "Custom Coordinates…",
        "menu.verify": "Verify Current Blue Dot",
        "menu.maps": "Open Maps",
        "menu.disable": "Disable Simulation",
        "menu.disabledAlready": "Simulation (currently off)",
        "menu.dock": "Show Icon in Dock",
        "menu.language": "Language",
        "menu.lang.zh": "中文",
        "menu.lang.en": "English",
        "menu.quit": "Quit MacLocBar",
        "menu.off": "📍 Off",
        "tooltip": "MacLoc — System-wide location spoofing",

        "alert.customTitle": "Set Custom Coordinates",
        "alert.customHint": "Decimal degrees, e.g. 51.49433, -0.08350",
        "alert.latRange": "Latitude (-90..90)",
        "alert.lonRange": "Longitude (-180..180)",
        "alert.set": "Set",
        "alert.cancel": "Cancel",
        "alert.invalid": "Invalid Coordinates",
        "alert.invalidDetail": "Latitude must be -90..90, longitude -180..180",
        "alert.updated": "Location Updated",
        "alert.failed": "Failed to Set Location",
        "alert.noVerifyScript": "verify.sh not found",
        "alert.noDot": "Blue Dot Not Found",
        "alert.noDotDetail": "Maps may be covered, or the simulation is not active yet",
        "alert.disableFailed": "Failed to Disable",
        "alert.ok": "OK",

        "err.invalidcoord": "Invalid coordinates",
        "err.nopreffile": "No usable locationd preference file",
        "err.unknowncmd": "Unknown command",
        "err.permission": "Permission denied",
        "err.writefailed": "Failed to write locationd preferences",
        "err.badargs": "Bad command arguments",
        "err.restartfailed": "locationd failed to restart",
        "err.verifyfailed": "Read-back verification failed",
        "err.scriptmissing": "script not found",
        "err.authcancel": "Authorization cancelled or script failed",
    ],
]

/// 取文案（可选带参数，用 %@ 占位）
func t(_ key: String, _ args: CVarArg...) -> String {
    let s = STRINGS[Loc.current]?[key] ?? STRINGS[Lang.zh]?[key] ?? key
    if args.isEmpty { return s }
    return String(format: s, arguments: args)
}

/// daemon 返回的是 "ERR <CODE> [detail]"，把 CODE 映射成本地化文案
func localizeDaemonReply(_ reply: String) -> String {
    let parts = reply.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, parts[0] == "ERR" else { return reply }
    let key = "err." + parts[1].lowercased()
    let localized = STRINGS[Loc.current]?[key]
    guard let localized else { return reply }
    if parts.count >= 3, !parts[2].isEmpty {
        return localized + ": " + parts[2]
    }
    return localized
}

// MARK: - 城市

struct Place: Equatable {
    let zh: String        // 中文全名
    let en: String        // 英文全名
    let zhShort: String   // 中文短名（按钮）
    let enShort: String   // 英文短名（按钮）
    let lat: Double
    let lon: Double

    var name: String { Loc.current == .en ? en : zh }
    var short: String { Loc.current == .en ? enShort : zhShort }
}

let PLACES: [Place] = [
    Place(zh: "伦敦",    en: "London",        zhShort: "伦敦",   enShort: "London",     lat: 51.49433,   lon: -0.08350),
    Place(zh: "北京",    en: "Beijing",       zhShort: "北京",   enShort: "Beijing",    lat: 39.90420,   lon: 116.40740),
    Place(zh: "上海",    en: "Shanghai",      zhShort: "上海",   enShort: "Shanghai",   lat: 31.23040,   lon: 121.47370),
    Place(zh: "东京",    en: "Tokyo",         zhShort: "东京",   enShort: "Tokyo",      lat: 35.67620,   lon: 139.65030),
    Place(zh: "香港",    en: "Hong Kong",     zhShort: "香港",   enShort: "HK",         lat: 22.31930,   lon: 114.16940),
    Place(zh: "台北",    en: "Taipei",        zhShort: "台北",   enShort: "Taipei",     lat: 25.03300,   lon: 121.56540),
    Place(zh: "新加坡",  en: "Singapore",     zhShort: "新加坡", enShort: "Singapore",  lat: 1.35210,    lon: 103.81980),
    Place(zh: "京都",    en: "Kyoto",         zhShort: "京都",   enShort: "Kyoto",      lat: 35.01160,   lon: 135.76810),
    Place(zh: "纽约",    en: "New York",      zhShort: "纽约",   enShort: "New York",   lat: 40.71278,   lon: -74.00597),
    Place(zh: "旧金山",  en: "San Francisco", zhShort: "旧金山", enShort: "S.F.",       lat: 37.77490,   lon: -122.41940),
    Place(zh: "洛杉矶",  en: "Los Angeles",   zhShort: "洛杉矶", enShort: "L.A.",       lat: 34.05220,   lon: -118.24370),
    Place(zh: "西雅图",  en: "Seattle",       zhShort: "西雅图", enShort: "Seattle",    lat: 47.60620,   lon: -122.33210),
    Place(zh: "巴黎",    en: "Paris",         zhShort: "巴黎",   enShort: "Paris",      lat: 48.85661,   lon: 2.35222),
    Place(zh: "柏林",    en: "Berlin",        zhShort: "柏林",   enShort: "Berlin",     lat: 52.52000,   lon: 13.40500),
    Place(zh: "阿姆斯特丹", en: "Amsterdam",   zhShort: "阿姆",   enShort: "Amsterdam",  lat: 52.36760,   lon: 4.90410),
    Place(zh: "罗马",    en: "Rome",          zhShort: "罗马",   enShort: "Rome",       lat: 41.90280,   lon: 12.49640),
    Place(zh: "莫斯科",  en: "Moscow",        zhShort: "莫斯科", enShort: "Moscow",     lat: 55.75580,   lon: 37.61730),
    Place(zh: "迪拜",    en: "Dubai",         zhShort: "迪拜",   enShort: "Dubai",      lat: 25.20480,   lon: 55.27080),
    Place(zh: "利雅得",  en: "Riyadh",        zhShort: "利雅得", enShort: "Riyadh",     lat: 24.71360,   lon: 46.67530),
    Place(zh: "曼谷",    en: "Bangkok",       zhShort: "曼谷",   enShort: "Bangkok",    lat: 13.75630,   lon: 100.50180),
    Place(zh: "悉尼",    en: "Sydney",        zhShort: "悉尼",   enShort: "Sydney",     lat: -33.86880,  lon: 151.20930),
    Place(zh: "墨尔本",  en: "Melbourne",     zhShort: "墨尔本", enShort: "Melbourne",  lat: -37.81360,  lon: 144.96310),
    Place(zh: "奥克兰",  en: "Auckland",      zhShort: "奥克兰", enShort: "Auckland",   lat: -36.84850,  lon: 174.76330),
    Place(zh: "圣保罗",  en: "São Paulo",     zhShort: "圣保罗", enShort: "Sao Paulo",  lat: -23.55050,  lon: -46.63330),
    Place(zh: "墨西哥城", en: "Mexico City",  zhShort: "墨西哥", enShort: "Mexico",     lat: 19.43260,   lon: -99.13320),
]

let home = FileManager.default.homeDirectoryForCurrentUser
let maclocDir = home.appendingPathComponent("macloc")
// 状态有两个来源，优先级如下：
//   1) daemon 写的 /var/db/macloc/state  —— root 拥有、0644，权威
//   2) 用户域副本 ~/.macloc/state         —— 兜底（老版本或 daemon 没装）
let statePaths = [
    URL(fileURLWithPath: "/var/db/macloc/state"),
    home.appendingPathComponent(".macloc/state"),
]

// MARK: - 工具

struct LocState {
    var lat: Double = 0
    var lon: Double = 0
    var on: Bool = false
}

func readState() -> LocState {
    var st = LocState()
    var raw: String? = nil
    // 优先读 daemon 的 root 状态文件，读不到再回退用户域副本
    for p in statePaths {
        if let s = try? String(contentsOf: p, encoding: .utf8) {
            raw = s
            break
        }
    }
    guard let s = raw else { return st }
    for line in s.split(separator: "\n") {
        let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2 else { continue }
        let v = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        switch kv[0].trimmingCharacters(in: .whitespaces) {
        case "MACLOC_LAT": st.lat = Double(v) ?? 0
        case "MACLOC_LON": st.lon = Double(v) ?? 0
        case "MACLOC_ON":  st.on = (v == "1")
        default: break
        }
    }
    return st
}

func fmt(_ d: Double) -> String { String(format: "%.5f", d) }

func cityName(for lat: Double, lon: Double) -> String {
    var best = t("city.custom"), bestD = 1e9
    for p in PLACES {
        let d = (p.lat - lat) * (p.lat - lat) + (p.lon - lon) * (p.lon - lon)
        if d < bestD { bestD = d; best = p.name }
    }
    return best
}

// MARK: - unix socket 客户端

func socketCommand(_ cmd: String, timeout: TimeInterval = 30) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(SOCKET_PATH.utf8)
    guard path.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: path) }

    let rc = withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else { return nil }

    var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    _ = cmd.withCString { send(fd, $0, strlen($0), 0) }
    var buf = [UInt8](repeating: 0, count: 1024)
    let n = recv(fd, &buf, 1024, 0)
    guard n > 0 else { return nil }
    daemonTouched = true
    return String(decoding: buf[0..<n], as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// daemon 通道是否可用。
///
/// ★ 千万别用 PING 去探测！daemon 现在是 launchd socket 激活的**按需进程**：
/// 一连上来就被拉起。菜单栏每 6 秒刷一次状态，探一次就等于永远把它叫醒。
/// 只看 socket 文件在不在 —— launchd 一直守着这个 socket，
/// 真有客户端连的时候才拉起进程。
func daemonUp() -> Bool {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: SOCKET_PATH, isDirectory: &isDir)
    return exists && !isDir.boolValue
}

/// 本次运行里有没有真的叫醒过 daemon（退出时才知道该不该发 QUIT）
var daemonTouched = false

/// daemon 进程此刻是否还活着。
/// 只看 pid 文件，**不要去连 socket** —— 一连就会把它拉起来。
///
/// 注意：daemon 是 root 进程，普通用户对它 kill(pid, 0) 会返回 **EPERM**（不是 0），
/// 但那恰恰说明「进程还活着、只是我们没权限发信号」。
/// 所以 EPERM 要当成「活着」处理，否则永远判成「没了」。
func daemonAlive() -> Bool {
    let pidFile = "/var/db/macloc/maclocd.pid"
    guard let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
          let pid = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)),
          pid > 0 else { return false }
    if kill(pid_t(pid), 0) == 0 { return true }
    return errno == EPERM
}

// MARK: - 设置坐标（两条通道）

enum ApplyResult {
    case ok(String)
    case fail(String)
}

/// 改坐标。优先 daemon（免密码），回退 set.sh（弹授权框）。
func applyLocation(lat: Double, lon: Double, title: String, completion: @escaping (ApplyResult) -> Void) {
    let latS = String(format: "%.6f", lat)
    let lonS = String(format: "%.6f", lon)

    // 通道 1：root daemon
    if let resp = socketCommand("SET \(latS) \(lonS)\n") {
        DispatchQueue.main.async {
            if resp.hasPrefix("OK") { completion(.ok("\(title)\n\(latS), \(lonS)")) }
            else { completion(.fail(localizeDaemonReply(resp))) }
        }
        return
    }

    // 通道 2：set.sh（弹系统管理员授权框）
    let script = maclocDir.appendingPathComponent("set.sh")
    guard FileManager.default.isExecutableFile(atPath: script.path) else {
        DispatchQueue.main.async { completion(.fail("\(t("err.scriptmissing"))\n\(script.path)")) }
        return
    }
    NSApp.activate(ignoringOtherApps: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script.path, latS, lonS]
    let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("macloc-set-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    let outHandle = FileHandle(forWritingAtPath: outURL.path)!
    p.standardOutput = outHandle
    p.standardError = outHandle
    p.terminationHandler = { proc in
        try? outHandle.close()
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: outURL)
        DispatchQueue.main.async {
            if proc.terminationStatus == 0 {
                completion(.ok("\(title)\n\(latS), \(lonS)"))
            } else {
                completion(.fail(out.isEmpty ? t("err.authcancel") : out))
            }
        }
    }
    try? p.run()
}

func disableSimulation(completion: @escaping (ApplyResult) -> Void) {
    if let resp = socketCommand("OFF\n") {
        DispatchQueue.main.async {
            if resp.hasPrefix("OK") { completion(.ok(t("panel.toast.disabled"))) }
            else { completion(.fail(localizeDaemonReply(resp))) }
        }
        return
    }
    let script = maclocDir.appendingPathComponent("stop.sh")
    guard FileManager.default.isExecutableFile(atPath: script.path) else {
        DispatchQueue.main.async { completion(.fail("\(t("err.scriptmissing"))\n\(script.path)")) }
        return
    }
    NSApp.activate(ignoringOtherApps: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script.path]
    // 收集输出：失败时把原因带回来，别只说「授权被取消」
    let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("macloc-stop-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    let outHandle = FileHandle(forWritingAtPath: outURL.path)!
    p.standardOutput = outHandle
    p.standardError = outHandle
    p.terminationHandler = { proc in
        try? outHandle.close()
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: outURL)
        DispatchQueue.main.async {
            // 必须看退出码：取消授权 / 脚本失败都会是非 0，
            // 之前这里无条件报「模拟定位已关闭」，是假成功。
            if proc.terminationStatus == 0 {
                completion(.ok(t("panel.toast.disabled")))
            } else {
                let msg = out.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(.fail(msg.isEmpty ? "\(t("err.authcancel"))（exit \(proc.terminationStatus)）" : msg))
            }
        }
    }
    try? p.run()
}

// MARK: - 图标

/// 状态栏用的「地图蓝点」小图标
func makeDotIcon() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let img = NSImage(size: size, flipped: false) { rect in
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let halo = NSBezierPath(ovalIn: NSRect(x: c.x - 8.5, y: c.y - 8.5, width: 17, height: 17))
        NSColor.white.setFill()
        halo.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 5.2, y: c.y - 5.2, width: 10.4, height: 10.4))
        NSColor(srgbRed: 0.0, green: 145.0 / 255.0, blue: 1.0, alpha: 1.0).setFill()
        dot.fill()
        let hl = NSBezierPath(ovalIn: NSRect(x: c.x - 2.6, y: c.y + 0.8, width: 2.6, height: 2.6))
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85).setFill()
        hl.fill()
        return true
    }
    img.isTemplate = false
    return img
}

/// 主窗口用的大图标：优先读 App bundle 里的 AppIcon.icns
func makeAppIcon(size: CGFloat) -> NSImage {
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let img = NSImage(contentsOf: url) {
        img.size = NSSize(width: size, height: size)
        return img
    }
    // 兜底：画一个
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let r = NSRect(origin: .zero, size: rect.size).insetBy(dx: size * 0.06, dy: size * 0.06)
        let sq = NSBezierPath(roundedRect: r, xRadius: size * 0.22, yRadius: size * 0.22)
        NSColor(srgbRed: 0.16, green: 0.62, blue: 0.98, alpha: 1).setFill()
        sq.fill()
        let p = NSBezierPath(ovalIn: NSRect(x: rect.midX - size * 0.16, y: rect.midY - size * 0.16,
                                            width: size * 0.32, height: size * 0.32))
        NSColor.white.setFill()
        p.fill()
        return true
    }
    return img
}

// MARK: - 主窗口

final class PanelController: NSObject, NSWindowDelegate {

    let window: NSWindow
    private let statusLabel = NSTextField(labelWithString: "")
    private let cityLabel = NSTextField(labelWithString: "")
    private let coordLabel = NSTextField(labelWithString: "")
    private let modeLabel = NSTextField(labelWithString: "")
    private let latField = NSTextField(string: "")
    private let lonField = NSTextField(string: "")
    private let toastLabel = NSTextField(labelWithString: "")
    private var cityButtons: [NSButton] = []

    // 需要随语言切换更新的静态文案视图
    private let cityCap = NSTextField(labelWithString: "")
    private let gridCap = NSTextField(labelWithString: "")
    private let customCap = NSTextField(labelWithString: "")
    private let applyBtn = NSButton(title: "", target: nil, action: nil)
    private let verifyBtn = NSButton(title: "", target: nil, action: nil)
    private let mapsBtn = NSButton(title: "", target: nil, action: nil)
    private let offBtn = NSButton(title: "", target: nil, action: nil)
    private let langSeg = NSSegmentedControl(labels: ["中文", "EN"],
                                            trackingMode: .selectOne,
                                            target: nil, action: nil)

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 508),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "MacLoc"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 480)
        buildUI()
        applyLanguage()
        centerOnScreen()
        refresh()
    }

    /// 显式居中到主屏可见区域（不能用 center()，无 key window 时会跑偏）
    private func centerOnScreen() {
        guard let scr = NSScreen.main else { return }
        let vf = scr.visibleFrame
        var f = window.frame
        f.size.width  = min(f.size.width,  vf.width  - 60)
        f.size.height = min(f.size.height, vf.height - 60)
        f.origin.x = vf.midX - f.size.width / 2
        f.origin.y = vf.midY - f.size.height / 2
        window.setFrame(f, display: true)
    }

    // ---- 界面搭建 ----

    private func buildUI() {
        let root = NSView(frame: window.contentLayoutRect)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        // 头部：图标 + 标题 + 状态 + 语言开关
        let iconView = NSImageView(frame: .zero)
        iconView.image = makeAppIcon(size: 64)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "MacLoc")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        modeLabel.font = .systemFont(ofSize: 11)
        modeLabel.textColor = .secondaryLabelColor

        let headText = NSStackView(views: [titleLabel, statusLabel, modeLabel])
        headText.orientation = .vertical
        headText.alignment = .leading
        headText.spacing = 3
        headText.translatesAutoresizingMaskIntoConstraints = false

        langSeg.segmentStyle = .rounded
        langSeg.setTag(0, forSegment: 0)   // 中文
        langSeg.setTag(1, forSegment: 1)   // EN
        langSeg.target = self
        langSeg.action = #selector(langChanged(_:))
        langSeg.setToolTip(t("menu.language"), forSegment: 0)
        langSeg.setToolTip(t("menu.language"), forSegment: 1)
        langSeg.translatesAutoresizingMaskIntoConstraints = false

        // 头部不用 stack：语言开关钉在右缘，切换语言时它不会左右跳
        let head = NSView()
        head.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(iconView)
        head.addSubview(headText)
        head.addSubview(langSeg)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),

            langSeg.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            langSeg.centerYAnchor.constraint(equalTo: head.centerYAnchor),

            headText.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            headText.trailingAnchor.constraint(lessThanOrEqualTo: langSeg.leadingAnchor, constant: -14),
            headText.centerYAnchor.constraint(equalTo: head.centerYAnchor),
        ])

        // 当前位置
        cityCap.font = .systemFont(ofSize: 11, weight: .semibold)
        cityCap.textColor = .secondaryLabelColor
        cityLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        coordLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        coordLabel.textColor = .secondaryLabelColor

        let curStack = NSStackView(views: [cityCap, cityLabel, coordLabel])
        curStack.orientation = .vertical
        curStack.alignment = .leading
        curStack.spacing = 4
        curStack.translatesAutoresizingMaskIntoConstraints = false

        // 城市网格
        gridCap.font = .systemFont(ofSize: 11, weight: .semibold)
        gridCap.textColor = .secondaryLabelColor

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.spacing = 7
        grid.alignment = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false
        // 按钮宽度固定（≈ 整行均分时的宽度），最后一行只有 1 个按钮时也不会被拉满整行
        let btnW: CGFloat = 80
        for chunk in stride(from: 0, to: PLACES.count, by: 6) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 7
            // 注意：不要给横向 stack 设 .leading —— AppKit 会因 alignment 轴与
            // orientation 不匹配把 stack 翻转成纵向（按钮会排成一列）
            for p in PLACES[chunk..<min(chunk + 6, PLACES.count)] {
                let b = NSButton(title: p.short, target: self, action: #selector(cityClicked(_:)))
                b.bezelStyle = .rounded
                b.tag = PLACES.firstIndex(of: p) ?? 0
                b.font = .systemFont(ofSize: 12)
                b.translatesAutoresizingMaskIntoConstraints = false
                b.heightAnchor.constraint(equalToConstant: 26).isActive = true
                b.widthAnchor.constraint(equalToConstant: btnW).isActive = true
                cityButtons.append(b)
                row.addArrangedSubview(b)
            }
            grid.addArrangedSubview(row)
        }

        // 自定义坐标
        customCap.font = .systemFont(ofSize: 11, weight: .semibold)
        customCap.textColor = .secondaryLabelColor

        latField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        lonField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        latField.target = self
        lonField.target = self
        latField.action = #selector(customApplied(_:))
        lonField.action = #selector(customApplied(_:))
        latField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        lonField.widthAnchor.constraint(equalToConstant: 110).isActive = true

        applyBtn.target = self
        applyBtn.action = #selector(customApplied(_:))
        applyBtn.bezelStyle = .rounded

        let customRow = NSStackView(views: [latField, lonField, applyBtn])
        customRow.orientation = .horizontal
        customRow.spacing = 8
        customRow.translatesAutoresizingMaskIntoConstraints = false

        // 底部按钮
        verifyBtn.target = self
        verifyBtn.action = #selector(verifyClicked(_:))
        mapsBtn.target = self
        mapsBtn.action = #selector(mapsClicked(_:))
        offBtn.target = self
        offBtn.action = #selector(offClicked(_:))
        for b in [verifyBtn, mapsBtn, offBtn] { b.bezelStyle = .rounded }

        let footer = NSStackView(views: [verifyBtn, mapsBtn, offBtn])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.distribution = .fillEqually
        footer.translatesAutoresizingMaskIntoConstraints = false

        // 行内提示（替代模态弹窗，不挡操作）
        toastLabel.font = .systemFont(ofSize: 12, weight: .medium)
        toastLabel.textColor = .secondaryLabelColor
        toastLabel.alignment = .center
        toastLabel.lineBreakMode = .byTruncatingTail
        toastLabel.maximumNumberOfLines = 2
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.heightAnchor.constraint(equalToConstant: 18).isActive = true

        let all = NSStackView(views: [head, curStack, gridCap, grid, customCap, customRow, footer, toastLabel])
        all.orientation = .vertical
        all.alignment = .leading
        all.spacing = 14
        all.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(all)

        NSLayoutConstraint.activate([
            all.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            all.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            all.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            all.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18),
            head.widthAnchor.constraint(equalTo: all.widthAnchor),
            curStack.widthAnchor.constraint(equalTo: all.widthAnchor),
            grid.widthAnchor.constraint(equalTo: all.widthAnchor),
            customRow.widthAnchor.constraint(equalTo: all.widthAnchor),
            footer.widthAnchor.constraint(equalTo: all.widthAnchor),
            toastLabel.widthAnchor.constraint(equalTo: all.widthAnchor),
            gridCap.widthAnchor.constraint(equalTo: all.widthAnchor),
            customCap.widthAnchor.constraint(equalTo: all.widthAnchor),
        ])
    }

    // ---- 语言 ----

    /// 把所有静态文案按当前语言刷新一遍
    func applyLanguage() {
        cityCap.stringValue = t("panel.currentLocation")
        gridCap.stringValue = t("panel.quickSwitch")
        customCap.stringValue = t("panel.customCoords")
        latField.placeholderString = t("panel.latitude")
        lonField.placeholderString = t("panel.longitude")
        applyBtn.title = t("panel.apply")
        verifyBtn.title = t("panel.verify")
        mapsBtn.title = t("panel.maps")
        offBtn.title = t("panel.disable")
        langSeg.selectSegment(withTag: Loc.current == .en ? 1 : 0)
        langSeg.setToolTip(t("menu.language"), forSegment: 0)
        langSeg.setToolTip(t("menu.language"), forSegment: 1)
    }

    @objc private func langChanged(_ sender: NSSegmentedControl) {
        Loc.set(sender.selectedSegment == 1 ? .en : .zh)
        applyLanguage()
        refresh()
        onLanguageChanged?()
    }

    /// 外部（AppDelegate 的菜单）改语言时调用
    func setLanguage(_ l: Lang) {
        Loc.set(l)
        applyLanguage()
        refresh()
    }

    /// 菜单栏切换语言后让面板跟着更新
    var onLanguageChanged: (() -> Void)?

    // ---- 状态刷新 ----

    func refresh() {
        let st = readState()
        if st.on {
            statusLabel.stringValue = t("panel.status.on")
            statusLabel.textColor = .systemGreen
            cityLabel.stringValue = cityName(for: st.lat, lon: st.lon)
            coordLabel.stringValue = "\(fmt(st.lat)), \(fmt(st.lon))"
            // 坐标框只在用户没在编辑时跟随当前定位
            if window.firstResponder !== latField { latField.stringValue = fmt(st.lat) }
            if window.firstResponder !== lonField { lonField.stringValue = fmt(st.lon) }
        } else {
            statusLabel.stringValue = t("panel.status.off")
            statusLabel.textColor = .secondaryLabelColor
            cityLabel.stringValue = "—"
            coordLabel.stringValue = "—"
        }
        modeLabel.stringValue = daemonUp() ? t("panel.mode.daemon") : t("panel.mode.prompt")

        for b in cityButtons {
            let p = PLACES[b.tag]
            let isCur = st.on && abs(p.lat - st.lat) < 0.002 && abs(p.lon - st.lon) < 0.002
            b.title = isCur ? "✓ \(p.short)" : p.short
            b.contentTintColor = isCur ? .systemBlue : nil
        }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
        window.makeKeyAndOrderFront(nil)
        centerOnScreen()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 关窗口只是隐藏，不退出 App（菜单栏图标继续用）
        if !dockAlwaysVisible { NSApp.setActivationPolicy(.accessory) }
        sender.orderOut(nil)
        return false
    }

    var dockAlwaysVisible = false

    // ---- 动作 ----

    @objc private func cityClicked(_ sender: NSButton) {
        let p = PLACES[sender.tag]
        sender.title = "…"
        applyLocation(lat: p.lat, lon: p.lon, title: p.name) { [weak self] res in
            guard let self = self else { return }
            self.refresh()
            switch res {
            case .ok(let m): self.showToast(t("panel.toast.updated", m), ok: true)
            case .fail(let m): self.showToast(t("panel.toast.failed", m), ok: false)
            }
        }
    }

    @objc private func customApplied(_ sender: Any?) {
        guard let la = Double(latField.stringValue.trimmingCharacters(in: .whitespaces)),
              let lo = Double(lonField.stringValue.trimmingCharacters(in: .whitespaces)),
              la >= -90, la <= 90, lo >= -180, lo <= 180 else {
            showToast(t("panel.toast.invalid"), ok: false)
            return
        }
        applyLocation(lat: la, lon: lo, title: t("city.custom")) { [weak self] res in
            guard let self = self else { return }
            self.refresh()
            switch res {
            case .ok(let m): self.showToast(t("panel.toast.updated", m), ok: true)
            case .fail(let m): self.showToast(t("panel.toast.failed", m), ok: false)
            }
        }
    }

    @objc private func offClicked(_ sender: Any?) {
        disableSimulation { [weak self] res in
            guard let self = self else { return }
            self.refresh()
            switch res {
            case .ok(let m): self.showToast(m, ok: true)
            case .fail(let m): self.showToast(t("panel.toast.disableFailed", m), ok: false)
            }
        }
    }

    @objc private func verifyClicked(_ sender: Any?) {
        let script = maclocDir.appendingPathComponent("verify.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            showToast(t("panel.toast.noVerifyScript", script.path), ok: false)
            return
        }
        showToast(t("panel.toast.verifying"), ok: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                let shot = home.appendingPathComponent(".macloc/verify.png")
                if FileManager.default.fileExists(atPath: shot.path) {
                    NSWorkspace.shared.open(shot)
                } else {
                    self.showToast(t("panel.toast.noDot"), ok: false)
                }
            }
        }
        try? p.run()
    }

    @objc private func mapsClicked(_ sender: Any?) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Maps.app"))
    }

    /// 行内提示，3.5 秒后自动淡掉
    private func showToast(_ msg: String, ok: Bool) {
        toastLabel.stringValue = (ok ? "✓ " : "✕ ") + msg.replacingOccurrences(of: "\n", with: "  ")
        toastLabel.textColor = ok ? .systemGreen : .systemRed
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(clearToast), object: nil)
        perform(#selector(clearToast), with: nil, afterDelay: 3.5)
    }

    @objc private func clearToast() {
        toastLabel.stringValue = ""
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var menuOpen = false
    private var timer: Timer?
    private var busy = false
    private var panel: PanelController?

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = makeDotIcon()
        statusItem.button?.toolTip = t("tooltip")

        panel = PanelController()
        panel?.onLanguageChanged = { [weak self] in self?.refreshMenu() }

        // 默认直接开主窗口（傻瓜式：双击就能点）
        //   --background  只驻留菜单栏，不弹窗口（开机自启用这个）
        //   --panel       等同默认，显式指定
        let args = CommandLine.arguments
        if args.contains("--background") {
            // 菜单栏常驻模式，不弹窗
        } else {
            panel?.show()
        }

        buildMenu()
        refreshMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            if !s.busy { s.refreshMenu() }
            s.panel?.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return true
    }

    func applicationWillTerminate(_ note: Notification) {
        timer?.invalidate()
        // 让 daemon 收工，别在后台留着。
        // 三个条件都满足才发：本次运行叫醒过它、它此刻还活着、socket 通道在。
        // （不能无脑发 —— 发 QUIT 本身就连了一次 socket，会把已退的 daemon 重新拉起来）
        // daemon 收到后会再活满 11 秒才退（launchd minimum runtime 保护，免得被当 crash 节流）。
        let touched = daemonTouched
        let alive = daemonAlive()
        let up = daemonUp()
        FileHandle.standardError.write(Data(
            "macloc: terminate touched=\(touched) alive=\(alive) up=\(up)\n".utf8))
        if touched && alive && up {
            let r = socketCommand("QUIT\n", timeout: 2)
            FileHandle.standardError.write(Data("macloc: quit reply=\(r ?? "nil")\n".utf8))
        }
    }

    // MARK: 菜单构建

    private var menu = NSMenu()
    private var miHead: NSMenuItem!
    private var miCoord: NSMenuItem!
    private var miMode: NSMenuItem!
    private var miOpenPanel: NSMenuItem!
    private var miPresets: NSMenuItem!
    private var miCustom: NSMenuItem!
    private var miVerify: NSMenuItem!
    private var miMaps: NSMenuItem!
    private var miOff: NSMenuItem!
    private var miDock: NSMenuItem!
    private var miLang: NSMenuItem!
    private var miQuit: NSMenuItem!
    private var presetItems: [NSMenuItem] = []
    private var langItems: [NSMenuItem] = []

    /// 菜单结构只建一次。
    /// 千万别中途把 statusItem.menu 换成新对象 —— 正在跟踪的菜单一旦被换走，
    /// 它的子菜单就再也弹不开了（实测：Preset / Language 子菜单点不开）。
    private func buildMenu() {
        menu.autoenablesItems = false

        func mk(_ title: String, _ action: Selector?) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
            if let action { it.target = self }
            return it
        }

        miHead = mk("", nil);   miHead.isEnabled = false
        miCoord = mk("", nil);  miCoord.isEnabled = false
        miMode = mk("", nil);   miMode.isEnabled = false

        miOpenPanel = mk(t("menu.openPanel"), #selector(openPanel(_:)))
        miPresets = mk(t("menu.presets"), nil)
        miCustom = mk(t("menu.custom"), #selector(pickCustom(_:)))
        miVerify = mk(t("menu.verify"), #selector(runVerify(_:)))
        miMaps = mk(t("menu.maps"), #selector(openMaps(_:)))
        miOff = mk(t("menu.disable"), #selector(turnOff(_:)))
        miDock = mk(t("menu.dock"), #selector(toggleDock(_:)))
        miLang = mk(t("menu.language"), nil)
        miQuit = mk(t("menu.quit"), #selector(quit(_:)))
        miQuit.keyEquivalent = "q"

        // 预设城市子菜单
        let presetMenu = NSMenu()
        presetMenu.autoenablesItems = false
        for (i, p) in PLACES.enumerated() {
            let it = NSMenuItem(title: p.name, action: #selector(pickPlace(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            presetItems.append(it)
            presetMenu.addItem(it)
        }
        miPresets.submenu = presetMenu

        // 语言子菜单
        let langMenu = NSMenu()
        langMenu.autoenablesItems = false
        for (i, l) in [Lang.zh, .en].enumerated() {
            let it = NSMenuItem(title: l == .zh ? t("menu.lang.zh") : t("menu.lang.en"),
                                action: #selector(pickLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            langItems.append(it)
            langMenu.addItem(it)
        }
        miLang.submenu = langMenu

        menu.addItem(miHead)
        menu.addItem(miCoord)
        menu.addItem(miMode)
        menu.addItem(.separator())
        menu.addItem(miOpenPanel)
        menu.addItem(miPresets)
        menu.addItem(miCustom)
        menu.addItem(.separator())
        menu.addItem(miVerify)
        menu.addItem(miMaps)
        menu.addItem(.separator())
        menu.addItem(miOff)
        menu.addItem(miDock)
        menu.addItem(miLang)
        menu.addItem(.separator())
        menu.addItem(miQuit)

        statusItem.menu = menu
    }

    /// 只原地改标题 / 勾选状态，不动菜单结构（菜单开着的时候也安全）
    private func refreshMenu() {
        let st = readState()
        miHead.title = st.on ? "📍 \(cityName(for: st.lat, lon: st.lon))" : t("menu.off")
        miCoord.title = st.on ? "   \(fmt(st.lat)), \(fmt(st.lon))" : "   —"
        miMode.title = "   " + (daemonUp() ? t("panel.mode.daemon") : t("panel.mode.prompt"))
        miOpenPanel.title = t("menu.openPanel")
        miPresets.title = t("menu.presets")
        miCustom.title = t("menu.custom")
        miVerify.title = t("menu.verify")
        miMaps.title = t("menu.maps")
        miOff.title = st.on ? t("menu.disable") : t("menu.disabledAlready")
        miOff.isEnabled = st.on
        miDock.title = t("menu.dock")
        miDock.state = (panel?.dockAlwaysVisible ?? false) ? .on : .off
        miLang.title = t("menu.language")
        miQuit.title = t("menu.quit")

        for (i, it) in presetItems.enumerated() {
            let p = PLACES[i]
            it.title = p.name
            it.state = (st.on && abs(p.lat - st.lat) < 0.002 && abs(p.lon - st.lon) < 0.002) ? .on : .off
        }
        for (i, it) in langItems.enumerated() {
            it.title = i == 0 ? t("menu.lang.zh") : t("menu.lang.en")
            it.state = (Loc.current == (i == 0 ? .zh : .en)) ? .on : .off
        }

        statusItem.button?.toolTip = t("tooltip")
    }

    // MARK: NSMenuDelegate（菜单开着的时候别重建，否则子菜单会打不开）

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        refreshMenu()
    }

    // MARK: 动作

    @objc private func openPanel(_ sender: Any?) {
        panel?.show()
    }

    @objc private func toggleDock(_ sender: Any?) {
        let show = !(panel?.dockAlwaysVisible ?? false)
        panel?.dockAlwaysVisible = show
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show { panel?.show() }
        refreshMenu()
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        let l: Lang = sender.tag == 1 ? .en : .zh
        Loc.set(l)
        panel?.setLanguage(l)
        refreshMenu()
    }

    @objc private func pickPlace(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < PLACES.count else { return }
        let p = PLACES[sender.tag]
        busy = true
        applyLocation(lat: p.lat, lon: p.lon, title: p.name) { [weak self] res in
            guard let self = self else { return }
            self.busy = false
            self.refreshMenu()
            switch res {
            case .ok(let m): self.alert(t("alert.updated"), m)
            case .fail(let m): self.alert(t("alert.failed"), localizeDaemonReply(m))
            }
        }
    }

    @objc private func pickCustom(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = t("alert.customTitle")
        alert.informativeText = t("alert.customHint")
        let latF = NSTextField(string: fmt(readState().lat))
        let lonF = NSTextField(string: fmt(readState().lon))
        latF.placeholderString = t("alert.latRange")
        lonF.placeholderString = t("alert.lonRange")
        let grid = NSGridView(numberOfColumns: 2, rows: 2)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [NSTextField(labelWithString: t("panel.latitude")), latF])
        grid.addRow(with: [NSTextField(labelWithString: t("panel.longitude")), lonF])
        alert.accessoryView = grid
        alert.addButton(withTitle: t("alert.set"))
        alert.addButton(withTitle: t("alert.cancel"))

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let la = Double(latF.stringValue.trimmingCharacters(in: .whitespaces)),
              let lo = Double(lonF.stringValue.trimmingCharacters(in: .whitespaces)),
              la >= -90, la <= 90, lo >= -180, lo <= 180 else {
            self.alert(t("alert.invalid"), t("alert.invalidDetail"))
            return
        }
        busy = true
        applyLocation(lat: la, lon: lo, title: t("city.custom")) { [weak self] res in
            guard let self = self else { return }
            self.busy = false
            self.refreshMenu()
            switch res {
            case .ok(let m): self.alert(t("alert.updated"), m)
            case .fail(let m): self.alert(t("alert.failed"), localizeDaemonReply(m))
            }
        }
    }

    @objc private func runVerify(_ sender: Any?) {
        let script = maclocDir.appendingPathComponent("verify.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            self.alert(t("alert.noVerifyScript"), script.path)
            return
        }
        busy = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.busy = false
                self?.refreshMenu()
                let shot = home.appendingPathComponent(".macloc/verify.png")
                if FileManager.default.fileExists(atPath: shot.path) {
                    NSWorkspace.shared.open(shot)
                } else {
                    self?.alert(t("alert.noDot"), t("alert.noDotDetail"))
                }
            }
        }
        try? p.run()
    }

    @objc private func openMaps(_ sender: Any?) {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Maps.app"))
    }

    @objc private func turnOff(_ sender: Any?) {
        busy = true
        disableSimulation { [weak self] res in
            guard let self = self else { return }
            self.busy = false
            self.refreshMenu()
            switch res {
            case .ok(let m): self.alert("MacLoc", m)
            case .fail(let m): self.alert(t("alert.disableFailed"), localizeDaemonReply(m))
            }
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func alert(_ title: String, _ msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.addButton(withTitle: t("alert.ok"))
        a.runModal()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
