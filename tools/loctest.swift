// loctest.swift —— 第三方 App 视角：读一次定位，把结果写到 /tmp/loctest.out
//
//  目的：证明「模拟定位是全局的」——
//        凡是拿到系统「定位服务」授权的 App，都拿到模拟出来的坐标。
//
//  编译：xcrun swiftc -swift-version 5 loctest.swift -o Loctest
//  运行：必须以 .app bundle 形式跑（TCC 按 bundle id 授权）

import Cocoa
import CoreLocation

final class Probe: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    let m = CLLocationManager()
    var got = false

    override init() {
        super.init()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyBest
    }

    func log(_ s: String) {
        print(s)
        let line = s + "\n"
        if let fh = FileHandle(forWritingAtPath: "/tmp/loctest.out") {
            fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); try? fh.close()
        } else {
            try? line.write(toFile: "/tmp/loctest.out", atomically: true, encoding: .utf8)
        }
    }

    func go() {
        log("PROBE pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "nil")")
        log("AUTH_BEFORE=\(m.authorizationStatus.rawValue)")
        m.requestWhenInUseAuthorization()
        m.startUpdatingLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            self.log("DONE got=\(self.got)")
            NSApp.terminate(nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        log("AUTH_CHANGE=\(m.authorizationStatus.rawValue)")
        if m.authorizationStatus == .authorizedAlways {
            m.startUpdatingLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        got = true
        for l in locs {
            log("UPDATE lat=\(l.coordinate.latitude) lon=\(l.coordinate.longitude) hAcc=\(l.horizontalAccuracy) ts=\(l.timestamp.timeIntervalSince1970)")
        }
    }

    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) {
        let ns = e as NSError
        log("FAIL domain=\(ns.domain) code=\(ns.code) msg=\(e.localizedDescription)")
    }
}

let app = NSApplication.shared
let p = Probe()
app.delegate = p
p.go()
app.run()
