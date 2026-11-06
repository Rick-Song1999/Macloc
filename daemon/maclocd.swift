// maclocd.swift —— root 守护进程：监听 unix socket，提供「免密码改坐标」通道
//
//  运行方式：**按需运行**（launchd socket 激活）
//    launchd 只创建 socket，不常驻进程；
//    有客户端连上来才拉起本进程，处理完空闲 20 秒自动退出。
//    也就是说：没打开 App 时，系统里一个 macloc 进程都没有。
//
//  协议（一行一条，\n 结尾）：
//    PING              -> PONG
//    SET <lat> <lon>   -> OK <lat> <lon>   /  ERR <CODE> [detail]
//    OFF               -> OK off            /  ERR <CODE> [detail]
//    SYNC <lat> <lon> <on>  -> OK sync       （只更新状态文件，不动偏好）
//    STATUS            -> ON <lat> <lon>   /  OFF
//    QUIT              -> OK quit           （让 daemon 收工退出）
//
//  错误码（UI 侧按 CODE 做中英文本地化，detail 一律英文）：
//    INVALID_COORD  坐标越界
//    NO_PREF_FILE   找不到可用的 locationd 偏好文件
//    UNKNOWN_CMD    未知命令
//    PERMISSION     权限不足
//    WRITE_FAILED   写入 locationd 偏好 / 状态文件失败
//    BAD_ARGS       命令参数不对
//    RESTART_FAILED locationd 重启后没起来
//    VERIFY_FAILED  回读校验不一致
//
//  只接受 uid == 控制台用户的连接（getpeereid）。
//  以 root 运行，直接改 locationd 的 ByHost 偏好 + MCX，再重启 locationd。
//
//  安全边界（重要）：
//   * 绝不以 root 身份写用户家目录（~/.macloc 等）。
//     用户家目录可被换成符号链接，root 对着链接路径 chown 会把目标目录的所有者
//     改成用户 → 本地提权。所有状态只写 root 拥有的路径。
//   * 只处理 root 拥有的常规文件；符号链接一律跳过。
//   * 关闭时恢复 LocationServicesEnabled 的原始值（首次启用前先备份）。
//   * 每一步都检查返回值：写失败 / locationd 没起来 / 回读不一致 → 返回 ERR，
//     绝不假装成功。

import Foundation
import SystemConfiguration

let SOCKET_PATH = ProcessInfo.processInfo.environment["MACLOC_SOCKET"] ?? "/var/run/macloc.sock"
let BYHOST_DIR = ProcessInfo.processInfo.environment["MACLOC_BYHOST"] ?? "/var/db/locationd/Library/Preferences/ByHost"
let MCX_FILE = ProcessInfo.processInfo.environment["MACLOC_MCX"] ?? "/Library/Managed Preferences/com.apple.locationd.plist"
let STATE_DIR = ProcessInfo.processInfo.environment["MACLOC_STATE_DIR"] ?? "/var/db/macloc"
let STATE_FILE = ProcessInfo.processInfo.environment["MACLOC_STATE_FILE"] ?? "/var/db/macloc/state"
let BACKUP_DIR = ProcessInfo.processInfo.environment["MACLOC_BACKUP_DIR"] ?? "/var/db/macloc/backup"
let DAEMON_LOG = ProcessInfo.processInfo.environment["MACLOC_LOG"] ?? "/var/log/maclocd.log"

// MARK: - 按需运行（launchd socket 激活）
//
// 本 daemon 由 launchd 以「launch on demand socket」的方式托管：
//   1) launchd 建好 /var/run/macloc.sock（0666），但**不启动进程**
//   2) 客户端连上来，launchd 才拉起 maclocd
//   3) 进程用 launch_activate_socket(3) 取回已经 listen 好的 fd
// 于是「没人用的时候一个 macloc 进程都没有」——只有打开 App 并操作时才短暂存在。
// socket 名字必须和 plist 里 Sockets 字典的 key 一致。
let SOCKET_NAME = ProcessInfo.processInfo.environment["MACLOC_SOCKET_NAME"] ?? "com.macloc.sock"
// 空闲多少秒后自杀（秒）
let IDLE_TIMEOUT = Int(ProcessInfo.processInfo.environment["MACLOC_IDLE_TIMEOUT"] ?? "20") ?? 20
// launchd 的 minimum runtime 是 10s：进程活不到 10s 就退出会被当成 crash 而触发节流，
// 下一次连接要等好几秒才拉得起来。所以退出前至少活满 11s。
let MIN_LIFETIME: Double = 11

/// 进程启动时刻（判断是否活够 MIN_LIFETIME）
let spawnTime = Date()

/// 活动状态（受锁保护）
private let activityLock = NSLock()
private var lastActivity = Date()
private var busyCount = 0
private var quitWanted = false

func touchActivity() {
    activityLock.lock()
    lastActivity = Date()
    activityLock.unlock()
}

/// 有命令在处理中（退场前必须确认没有命令在飞，否则会把写到一半的请求砍掉）
func beginCommand() {
    activityLock.lock()
    busyCount += 1
    lastActivity = Date()
    activityLock.unlock()
}

func endCommand() {
    activityLock.lock()
    busyCount = max(0, busyCount - 1)
    lastActivity = Date()
    activityLock.unlock()
}

func idleSeconds() -> TimeInterval {
    activityLock.lock()
    defer { activityLock.unlock() }
    return Date().timeIntervalSince(lastActivity)
}

func busyNow() -> Bool {
    activityLock.lock()
    defer { activityLock.unlock() }
    return busyCount > 0
}

func requestQuit() {
    activityLock.lock()
    quitWanted = true
    activityLock.unlock()
}

func quitRequested() -> Bool {
    activityLock.lock()
    defer { activityLock.unlock() }
    return quitWanted
}

/// launchd 托管时：取回监听 fd（已经是 listen 状态）
/// 返回 nil 表示「不是被 launchd 拉起来的」（手动跑），走自己 bind 的老路。
func launchdListenSocket() -> Int32? {
    // C shim 里已经处理了 launchd 返回数组的两种布局
    let fd = macloc_activate_socket(SOCKET_NAME)
    return fd >= 0 ? fd : nil
}

/// 拿到监听 socket：优先用 launchd 的，其次自己 bind
/// 返回 (fd, socketOwnedByLaunchd)
func acquireListenSocket() -> (fd: Int32, ownedByLaunchd: Bool) {
    if let fd = launchdListenSocket() {
        return (fd, true)
    }
    // 手动运行：自己 bind
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { exit(1) }
    unlink(SOCKET_PATH)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let p = Array(SOCKET_PATH.utf8)
    guard p.count < MemoryLayout.size(ofValue: addr.sun_path) else { exit(1) }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: p) }
    let rc = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard rc == 0 else {
        FileHandle.standardError.write("bind 失败: \(String(cString: strerror(errno)))\n".data(using: .utf8)!)
        exit(1)
    }
    chmod(SOCKET_PATH, 0o666)
    listen(fd, 16)
    return (fd, false)
}

/// 空闲看门狗：没人用了就自杀，不留常驻进程
func startIdleWatchdog() {
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 2)
            // 有命令在飞 → 不动（免得把写到一半的请求砍掉）
            if busyNow() { continue }
            let idle = idleSeconds()
            let alive = Date().timeIntervalSince(spawnTime)
            // launchd 的 minimum runtime 是 10s：活不到 10s 就退会被当 crash 节流
            if alive < MIN_LIFETIME { continue }
            if idle > Double(IDLE_TIMEOUT) || (quitRequested() && idle > 1.0) {
                appendLog("\(dateStamp()) idle \(Int(idle))s -> exit")
                exit(0)
            }
        }
    }
}

// MARK: - 小工具

func run(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// 系统受信任的属主：root，或 locationd 自己的账号 _locationd
/// （ByHost 偏好正常就是 _locationd:staff 600，写完会 chown 回去）
func trustedOwnerUIDs() -> Set<uid_t> {
    var ids: Set<uid_t> = [0]
    if let pw = getpwnam("_locationd") { ids.insert(pw.pointee.pw_uid) }
    return ids
}

/// 用 lstat 判断路径本身是不是符号链接（不跟随）
func isSymlink(_ path: String) -> Bool {
    var st = stat()
    guard lstat(path, &st) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFLNK
}

/// 只信任「系统账号拥有的常规文件」：
///   * 符号链接一律拒绝（用户可以把路径换成指向 /etc 的链接来骗 root）
///   * 用户拥有的文件一律拒绝（用户能改属主的路径一律不信）
///   * 只接受 root 或 _locationd 拥有
func isTrustedSystemFile(_ path: String) -> Bool {
    if isSymlink(path) { return false }
    guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
    guard let t = a[.type] as? FileAttributeType, t == .typeRegular else { return false }
    guard let uid = a[.ownerAccountID] as? NSNumber else { return false }
    return trustedOwnerUIDs().contains(uid_t(uid.intValue))
}

func plistSet(_ file: String, _ key: String, _ type: String, _ val: String) -> Bool {
    guard FileManager.default.fileExists(atPath: file) else { return false }
    let (c1, _) = run("/usr/libexec/PlistBuddy", ["-c", "Set :\(key) \(val)", file])
    if c1 == 0 { return true }
    let (c2, _) = run("/usr/libexec/PlistBuddy", ["-c", "Add :\(key) \(type) \(val)", file])
    return c2 == 0
}

func plistGet(_ file: String, _ key: String) -> String? {
    guard FileManager.default.fileExists(atPath: file) else { return nil }
    let (code, out) = run("/usr/libexec/PlistBuddy", ["-c", "Print :\(key)", file])
    guard code == 0 else { return nil }
    let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return v.isEmpty ? nil : v
}

func plistDel(_ file: String, _ key: String) {
    guard FileManager.default.fileExists(atPath: file) else { return }
    _ = run("/usr/libexec/PlistBuddy", ["-c", "Delete :\(key)", file])
}

/// 控制台登录用户：名字 / uid / home 目录
func consoleUser() -> (name: String, uid: uid_t, home: String) {
    var name = ""
    // SCDynamicStore 给控制台用户的短用户名
    if let store = SCDynamicStoreCreate(nil, "MacLoc" as CFString, nil, nil),
       let n = SCDynamicStoreCopyConsoleUser(store, nil, nil) as String? {
        name = n
    }
    if name.isEmpty { name = NSUserName() }

    var uid = getuid()
    var home = NSHomeDirectory()
    if let pw = getpwnam(name) {
        uid = pw.pointee.pw_uid
        home = String(cString: pw.pointee.pw_dir)
    }
    return (name, uid, home)
}

// MARK: - 备份 / 恢复

/// 首次修改前把原始偏好备份到 root 私有目录（0700）
func backupPrefs(_ files: [String]) {
    try? FileManager.default.createDirectory(atPath: BACKUP_DIR, withIntermediateDirectories: true)
    _ = run("/bin/chmod", ["700", BACKUP_DIR])
    _ = run("/usr/sbin/chown", ["root:wheel", BACKUP_DIR])
    for f in files {
        let base = URL(fileURLWithPath: f).lastPathComponent
        let dst = "\(BACKUP_DIR)/\(base)"
        if FileManager.default.fileExists(atPath: dst) { continue }
        if (try? FileManager.default.copyItem(atPath: f, toPath: dst)) != nil {
            _ = run("/bin/chmod", ["600", dst])
        }
    }
}

/// 关闭时把 LocationServicesEnabled 恢复成备份里的原始值（没有备份就不动它）
func restoreLocationServices(_ file: String) {
    let base = URL(fileURLWithPath: file).lastPathComponent
    let b = "\(BACKUP_DIR)/\(base)"
    guard let v = plistGet(b, "LocationServicesEnabled") else { return }
    let lower = v.lowercased()
    guard lower == "true" || lower == "false" else { return }
    _ = plistSet(file, "LocationServicesEnabled", "bool", lower)
}

/// 状态落盘 —— 只写 root 拥有的路径（绝不碰用户家目录）
@discardableResult
func writeStateFile(lat: String, lon: String, on: Bool) -> Bool {
    try? FileManager.default.createDirectory(atPath: STATE_DIR, withIntermediateDirectories: true)
    _ = run("/bin/chmod", ["755", STATE_DIR])
    _ = run("/usr/sbin/chown", ["root:wheel", STATE_DIR])
    let stamp = dateStamp()
    let body = """
    MACLOC_LAT="\(on ? lat : "")"
    MACLOC_LON="\(on ? lon : "")"
    MACLOC_ON="\(on ? "1" : "0")"
    MACLOC_AT="\(stamp)"

    """
    do {
        try body.write(toFile: STATE_FILE, atomically: true, encoding: .utf8)
        _ = run("/bin/chmod", ["644", STATE_FILE])
        _ = run("/usr/sbin/chown", ["root:wheel", STATE_FILE])
        return true
    } catch {
        return false
    }
}

/// 追加一行到 root 拥有的日志文件（绝不写用户家目录）
func appendLog(_ line: String) {
    guard isTrustedSystemFile(DAEMON_LOG) else { return }
    guard let fh = FileHandle(forWritingAtPath: DAEMON_LOG) else { return }
    defer { try? fh.close() }
    fh.seekToEndOfFile()
    fh.write((line + "\n").data(using: .utf8)!)
}

// MARK: - 核心：写坐标

func writeCoords(lat: String, lon: String, enable: Bool) -> String {
    // 错误码化：统一返回 "ERR <CODE> [detail]"，UI 侧按 CODE 做本地化
    var errors: [String] = []
    var errCode = ""
    func fail(_ code: String, _ detail: String) {
        if errCode.isEmpty { errCode = code }
        errors.append(detail)
    }

    // 1. ByHost 偏好（locationd 真正读的）—— 只认系统账号拥有的常规文件
    var files: [String] = []
    var skipped: [String] = []
    let items = ((try? FileManager.default.contentsOfDirectory(atPath: BYHOST_DIR)) ?? []).sorted()
    for f in items where f.hasPrefix("com.apple.locationd.") && f.hasSuffix(".plist") {
        let full = "\(BYHOST_DIR)/\(f)"
        guard isTrustedSystemFile(full) else {
            skipped.append(full)
            continue
        }
        files.append(full)
    }
    if files.isEmpty {
        return "ERR NO_PREF_FILE no trusted locationd preference file found"
    }
    if !skipped.isEmpty {
        appendLog("\(dateStamp()) 跳过 \(skipped.count) 个非系统属主的偏好文件：\(skipped.joined(separator: ","))")
    }

    // 2. 首次启用前备份原偏好
    if enable { backupPrefs(files) }

    // 3. 写入
    for f in files {
        if enable {
            if !plistSet(f, "AllowSimulatedLocations", "bool", "true") {
                fail("WRITE_FAILED", "AllowSimulatedLocations write failed: \(f)")
            }
            if !plistSet(f, "SimulatedLocationLatitude", "real", lat) {
                fail("WRITE_FAILED", "SimulatedLocationLatitude write failed: \(f)")
            }
            if !plistSet(f, "SimulatedLocationLongitude", "real", lon) {
                fail("WRITE_FAILED", "SimulatedLocationLongitude write failed: \(f)")
            }
            if !plistSet(f, "SimulatedLocationAccuracy", "real", "5") {
                fail("WRITE_FAILED", "SimulatedLocationAccuracy write failed: \(f)")
            }
            if !plistSet(f, "SimulatedLocationType", "integer", "1") {
                fail("WRITE_FAILED", "SimulatedLocationType write failed: \(f)")
            }
            if !plistSet(f, "LocationServicesEnabled", "bool", "true") {
                fail("WRITE_FAILED", "LocationServicesEnabled write failed: \(f)")
            }
        } else {
            // 关闭：先恢复总开关原值，再清坐标
            restoreLocationServices(f)
            if !plistSet(f, "AllowSimulatedLocations", "bool", "false") {
                fail("WRITE_FAILED", "AllowSimulatedLocations=false write failed: \(f)")
            }
            plistDel(f, "SimulatedLocationLatitude")
            plistDel(f, "SimulatedLocationLongitude")
        }
        _ = run("/usr/sbin/chown", ["_locationd:staff", f])
        _ = run("/bin/chmod", ["600", f])
    }

    // 4. MCX 兜底
    if !FileManager.default.fileExists(atPath: MCX_FILE) {
        try? FileManager.default.createDirectory(atPath: "/Library/Managed Preferences",
                                                 withIntermediateDirectories: true)
        let stub = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict/></plist>\n"
        try? stub.write(toFile: MCX_FILE, atomically: true, encoding: .utf8)
        _ = run("/bin/chmod", ["755", "/Library/Managed Preferences"])
    }
    if enable {
        if !plistSet(MCX_FILE, "AllowSimulatedLocations", "bool", "true") {
            fail("WRITE_FAILED", "MCX AllowSimulatedLocations write failed")
        }
        if !plistSet(MCX_FILE, "SimulatedLocationLatitude", "real", lat) {
            fail("WRITE_FAILED", "MCX SimulatedLocationLatitude write failed")
        }
        if !plistSet(MCX_FILE, "SimulatedLocationLongitude", "real", lon) {
            fail("WRITE_FAILED", "MCX SimulatedLocationLongitude write failed")
        }
        if !plistSet(MCX_FILE, "SimulatedLocationAccuracy", "real", "5") {
            fail("WRITE_FAILED", "MCX SimulatedLocationAccuracy write failed")
        }
        if !plistSet(MCX_FILE, "SimulatedLocationType", "integer", "1") {
            fail("WRITE_FAILED", "MCX SimulatedLocationType write failed")
        }
        if !plistSet(MCX_FILE, "LocationServicesEnabled", "bool", "true") {
            fail("WRITE_FAILED", "MCX LocationServicesEnabled write failed")
        }
    } else {
        if !plistSet(MCX_FILE, "AllowSimulatedLocations", "bool", "false") {
            fail("WRITE_FAILED", "MCX AllowSimulatedLocations=false write failed")
        }
        plistDel(MCX_FILE, "SimulatedLocationLatitude")
        plistDel(MCX_FILE, "SimulatedLocationLongitude")
    }
    _ = run("/usr/sbin/chown", ["root:wheel", MCX_FILE])
    _ = run("/bin/chmod", ["644", MCX_FILE])

    // 5. 重启 locationd（改坐标必须走这个状态迁移）
    _ = run("/usr/bin/killall", ["cfprefsd"])
    usleep(800_000)
    _ = run("/usr/bin/killall", ["-u", "_locationd", "locationd"])
    usleep(2_500_000)
    let (pgrepRC, _) = run("/usr/bin/pgrep", ["-x", "locationd"])
    if pgrepRC != 0 { fail("RESTART_FAILED", "locationd did not come back after restart") }

    // 6. 回读校验：写进去的必须读得回来
    if enable {
        for f in files {
            if let v = plistGet(f, "SimulatedLocationLatitude"),
               let d = Double(v), let want = Double(lat), abs(d - want) < 0.0001 {
                // OK
            } else {
                fail("VERIFY_FAILED", "latitude read-back mismatch: \(f)")
            }
            if let v = plistGet(f, "SimulatedLocationLongitude"),
               let d = Double(v), let want = Double(lon), abs(d - want) < 0.0001 {
                // OK
            } else {
                fail("VERIFY_FAILED", "longitude read-back mismatch: \(f)")
            }
        }
    }

    // 7. 状态落盘 —— 只写 root 拥有的路径
    if !writeStateFile(lat: lat, lon: lon, on: enable) {
        fail("WRITE_FAILED", "cannot write state file \(STATE_FILE)")
    }

    // 8. 日志 —— 只写 root 拥有的日志文件
    appendLog("\(dateStamp()) daemon \(enable ? "\(lat),\(lon)" : "off")")

    if !errors.isEmpty {
        return "ERR \(errCode.isEmpty ? "WRITE_FAILED" : errCode) " + errors.joined(separator: " | ")
    }
    return enable ? "OK \(lat) \(lon)" : "OK off"
}

func dateStamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
}

// MARK: - socket 服务

func handle(_ fd: Int32) {
    var buf = Data()
    var euid = uid_t(0)
    var egid = gid_t(0)
    if getpeereid(fd, &euid, &egid) != 0 { close(fd); return }
    let allowed = consoleUser().uid
    if euid != 0 && euid != allowed {
        _ = "ERR PERMISSION\n".withCString { send(fd, $0, strlen($0), 0) }
        close(fd); return
    }

    // 对端进程号：出问题时能直接看出「这条命令是谁发的」（同一个 App 发两遍、
    // 还是别的进程偷偷发的，靠猜没意义）。LOCAL_PEERPID 直接给对端 pid。
    var peerPid = Int32(0)
    var peerPidValue = pid_t(0)
    var peerPidLen = socklen_t(MemoryLayout<pid_t>.size)
    if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPidValue, &peerPidLen) == 0 {
        peerPid = peerPidValue
    }
    let peerTag = "pid=\(peerPid) uid=\(euid)"

    while true {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &chunk, 4096, 0)
        if n <= 0 { break }
        buf.append(contentsOf: chunk[0..<n])
        while let idx = buf.firstIndex(of: 0x0A) {
            let lineData = buf[buf.startIndex..<idx]
            buf = buf[buf.index(after: idx)...]
            let line = String(data: Data(lineData), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if line.isEmpty { continue }
            beginCommand()
            appendLog("\(dateStamp()) cmd [\(peerTag)] \(line)")
            let reply: String
            let parts = line.split(separator: " ").map(String.init)
            switch parts[0].uppercased() {
            case "PING":
                reply = "PONG"
            case "STATUS":
                var lat = "", lon = "", on = "0"
                if let s = try? String(contentsOfFile: STATE_FILE, encoding: .utf8) {
                    for l in s.split(separator: "\n") {
                        let kv = l.split(separator: "=", maxSplits: 1).map(String.init)
                        guard kv.count == 2 else { continue }
                        let v = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        switch kv[0] {
                        case "MACLOC_LAT": lat = v
                        case "MACLOC_LON": lon = v
                        case "MACLOC_ON":  on = v
                        default: break
                        }
                    }
                }
                reply = on == "1" ? "ON \(lat) \(lon)" : "OFF"
            case "SET":
                guard parts.count == 3,
                      let la = Double(parts[1]), let lo = Double(parts[2]),
                      la >= -90, la <= 90, lo >= -180, lo <= 180 else {
                    reply = "ERR INVALID_COORD latitude must be -90..90, longitude -180..180"
                    break
                }
                reply = writeCoords(lat: String(format: "%.6f", la), lon: String(format: "%.6f", lo), enable: true)
            case "OFF":
                reply = writeCoords(lat: "", lon: "", enable: false)
            case "SYNC":
                // 只同步状态文件（不碰偏好、不重启 locationd）。
                // 供 set.sh / stop.sh 在绕过 daemon 直接改完偏好后调用，
                // 免得 daemon 的权威状态变旧。
                guard parts.count == 4 else {
                    reply = "ERR BAD_ARGS SYNC requires <lat> <lon> <on>"
                    break
                }
                let sOn = (parts[3] == "1")
                if sOn {
                    guard let la = Double(parts[1]), let lo = Double(parts[2]),
                          la >= -90, la <= 90, lo >= -180, lo <= 180 else {
                        reply = "ERR INVALID_COORD latitude must be -90..90, longitude -180..180"
                        break
                    }
                    if writeStateFile(lat: String(format: "%.6f", la),
                                      lon: String(format: "%.6f", lo), on: true) {
                        appendLog("\(dateStamp()) sync \(parts[1]),\(parts[2]) on")
                        reply = "OK sync"
                    } else {
                        reply = "ERR WRITE_FAILED cannot write state file"
                    }
                } else {
                    if writeStateFile(lat: "", lon: "", on: false) {
                        appendLog("\(dateStamp()) sync off")
                        reply = "OK sync off"
                    } else {
                        reply = "ERR WRITE_FAILED cannot write state file"
                    }
                }
            case "QUIT":
                // App 退出时调用：让 daemon 收工。
                // 不在这里直接 exit —— 万一此刻还有命令在飞，会把请求砍在半路；
                // 交给看门狗：确认没有命令在飞、且活够 MIN_LIFETIME 再退。
                requestQuit()
                reply = "OK quit"
            default:
                reply = "ERR UNKNOWN_CMD supported: PING STATUS SET OFF SYNC QUIT"
            }
            _ = (reply + "\n").withCString { send(fd, $0, strlen($0), 0) }
            if reply == "OK quit" {
                appendLog("\(dateStamp()) quit")
            }
            endCommand()
        }
    }
    close(fd)
}

/// socket 是否由 launchd 托管（托管的话退出时**不能**删 socket 文件 —— 那是 launchd 的）
var socketOwnedByLaunchd = false

/// 删掉自己的 pid 文件
func removePidFile() {
    let lockPath = "\(STATE_DIR)/maclocd.pid"
    if let cur = try? String(contentsOfFile: lockPath, encoding: .utf8),
       Int(cur.trimmingCharacters(in: .whitespacesAndNewlines)) == Int(getpid()) {
        try? FileManager.default.removeItem(atPath: lockPath)
    }
}

func main() {
    try? FileManager.default.createDirectory(atPath: STATE_DIR, withIntermediateDirectories: true)
    _ = run("/bin/chmod", ["755", STATE_DIR])

    // 监听 socket：launchd 托管 = on-demand 拉起；手动跑 = 自己 bind
    let (fd, owned) = acquireListenSocket()
    socketOwnedByLaunchd = owned

    let lockPath = "\(STATE_DIR)/maclocd.pid"
    try? "\(getpid())".write(toFile: lockPath, atomically: true, encoding: .utf8)

    FileHandle.standardError.write(
        "maclocd listening on \(SOCKET_PATH) (launchd=\(owned)) pid=\(getpid())\n".data(using: .utf8)!)
    signal(SIGTERM) { _ in
        if !socketOwnedByLaunchd { unlink(SOCKET_PATH) }
        removePidFile()
        exit(0)
    }
    signal(SIGINT) { _ in
        if !socketOwnedByLaunchd { unlink(SOCKET_PATH) }
        removePidFile()
        exit(0)
    }
    atexit { removePidFile() }

    startIdleWatchdog()

    while true {
        let c = accept(fd, nil, nil)
        if c < 0 { continue }
        DispatchQueue.global().async { handle(c) }
    }
}

main()
