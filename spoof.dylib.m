// spoof.dylib —— macOS 全系统定位伪装
//
// 原理：
//   CoreLocation.framework 私有类 CLSimulationManager 连到 locationd 的 mach service
//   "com.apple.locationd.simulation"。该服务校验客户端的 code signature，必须带
//   com.apple.locationd.simulation entitlement —— 全系统只有
//   /System/Library/CoreServices/CoreLocationAgent.app 拥有它。
//
//   所以路线是：把本 dylib 注入 CoreLocationAgent，以它的合法身份把模拟定位推进
//   locationd，locationd 随后 "setting simulation to 1 for all location providers"，
//   所有走 CoreLocation 的应用读到的都是假坐标。
//
// 关键细节：只在「第一次 start」时 locationd 会 "is notifying clients"。
//   改坐标必须先 stopLocationSimulation + clearSimulatedLocations（让
//   fSimulationRunning 从 1 回到 0），再 append + start，才会触发状态迁移，
//   把新坐标广播给所有已注册的 CoreLocation 客户端。
//
// 环境变量：
//   SPOOF_LAT / SPOOF_LON   直接给坐标（优先级高于配置文件）
//   SPOOF_RESET=1          stop+clear 后再 start（换坐标时必须）
//   SPOOF_STOP=1           不推定位，改为 stopLocationSimulation + clearSimulatedLocations
//   MACLOC_FORCE=1         允许在非 CoreLocationAgent 进程里执行
//
// 配置文件：~/.macloc/loc.conf  内容形如 "37.7749 -122.4194"
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdarg.h>
#import <dispatch/dispatch.h>

static double gLat = 0, gLon = 0;
static int    gHave = 0;
static int    gStop = 0;
static int    gReset = 1;
static NSString *gHome = nil;

static void LOGF(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = [gHome stringByAppendingPathComponent:@"spoof.log"];
    NSString *dir  = [gHome stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir])
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                 withIntermediateDirectories:YES attributes:nil error:nil];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[[NSString stringWithFormat:@"[%@ pid=%d] %@\n", [NSDate date], getpid(), s]
                    dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

#pragma mark - 配置读取
static void loadConf(void) {
    double lat = 0, lon = 0;
    int have = 0;
    NSString *conf = [gHome stringByAppendingPathComponent:@"loc.conf"];
    NSString *txt = [NSString stringWithContentsOfFile:conf
                                              encoding:NSUTF8StringEncoding error:NULL];
    if (txt) {
        NSArray *parts = [txt componentsSeparatedByCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        for (NSString *p in parts) {
            if (!p.length) continue;
            if (!have) { lat = p.doubleValue; have = 1; }
            else { lon = p.doubleValue; have = 2; break; }
        }
    }
    const char *el = getenv("SPOOF_LAT"), *eo = getenv("SPOOF_LON");
    if (el && eo) { lat = atof(el); lon = atof(eo); have = 2; }
    if (have == 2) { gLat = lat; gLon = lon; gHave = 1; }
}

#pragma mark - 客户端视角读回
@interface Verify : NSObject <CLLocationManagerDelegate>
@end
@implementation Verify
- (void)locationManager:(CLLocationManager *)m didUpdateLocations:(NSArray<CLLocation *> *)l {
    for (CLLocation *x in l)
        LOGF(@"VERIFY 客户端读回定位 = %.6f, %.6f (acc=%.1f)",
             x.coordinate.latitude, x.coordinate.longitude, x.horizontalAccuracy);
}
- (void)locationManager:(CLLocationManager *)m didFailWithError:(NSError *)e {
    LOGF(@"VERIFY 读取失败: %@", e.localizedDescription);
}
- (void)locationManager:(CLLocationManager *)m didChangeAuthorizationStatus:(CLAuthorizationStatus)s {
    LOGF(@"VERIFY 授权状态 = %d", (int)s);
    if (s == kCLAuthorizationStatusAuthorizedAlways || (int)s == 2) {
        [m requestLocation];
        [m startUpdatingLocation];
    } else if ((int)s == 0) {
        // macOS 上「定位服务」总开关从关变开后，所有客户端授权会被重置为 notDetermined，
        // 必须主动重新请求（系统 App 会静默通过）。
        LOGF(@"VERIFY 重新请求授权 (requestAlwaysAuthorization)");
        if ([m respondsToSelector:@selector(requestAlwaysAuthorization)])
            [m requestAlwaysAuthorization];
        [m requestLocation];
        [m startUpdatingLocation];
    }
}
@end

// CLLocationManager.delegate 是弱引用，必须自己强持有，否则回调永远不来
static Verify            *gVerify = nil;
static CLLocationManager *gManager = nil;

#pragma mark - XPC 发送 helpers
static id  send0r(id o, SEL s)        { return ((id (*)(id, SEL))objc_msgSend)(o, s); }
static void send1v(id o, SEL s, id a) { ((void (*)(id, SEL, id))objc_msgSend)(o, s, a); }
static void send0v(id o, SEL s)       { ((void (*)(id, SEL))objc_msgSend)(o, s); }

#pragma mark - 推送 / 停止
static void doStop(id mgr) {
    SEL stop = NSSelectorFromString(@"stopLocationSimulation");
    SEL clr  = NSSelectorFromString(@"clearSimulatedLocations");
    if ([mgr respondsToSelector:stop]) { send0v(mgr, stop); LOGF(@"已调用 stopLocationSimulation"); }
    else LOGF(@"!! 无 stopLocationSimulation");
    if ([mgr respondsToSelector:clr])  { send0v(mgr, clr);  LOGF(@"已调用 clearSimulatedLocations"); }
}

// 真正推一条
static void doPush(id mgr) {
    SEL app   = NSSelectorFromString(@"appendSimulatedLocation:");
    SEL appB  = NSSelectorFromString(@"appendSimulatedLocations:");
    SEL start = NSSelectorFromString(@"startLocationSimulation");
    SEL flush = NSSelectorFromString(@"flush");

    CLLocation *loc = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(gLat, gLon)
                                                       altitude:0
                                               horizontalAccuracy:5.0
                                                 verticalAccuracy:5.0
                                                             course:-1.0
                                                              speed:-1.0
                                                          timestamp:[NSDate date]];
    @try {
        if ([mgr respondsToSelector:app]) {
            send1v(mgr, app, loc);
        } else if ([mgr respondsToSelector:appB]) {
            send1v(mgr, appB, @[loc]);
        } else {
            LOGF(@"FAIL: 没有 appendSimulatedLocation:"); return;
        }
        if ([mgr respondsToSelector:start]) send0v(mgr, start);
        if ([mgr respondsToSelector:flush]) send0v(mgr, flush);
        LOGF(@"已推送模拟定位 %.6f, %.6f", gLat, gLon);
    } @catch (NSException *e) {
        LOGF(@"推送 EXC %@", e.reason);
    }
}

static void push(void) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/CoreLocation.framework/CoreLocation", RTLD_LAZY);
        Class c = NSClassFromString(@"CLSimulationManager");
        if (!c) { LOGF(@"FAIL: 找不到 CLSimulationManager"); return; }

        id mgr = nil;
        @try { mgr = [[c alloc] init]; }
        @catch (NSException *e) { LOGF(@"init EXC %@", e.reason); return; }
        if (!mgr) { LOGF(@"FAIL: mgr == nil"); return; }

        id proxy = nil;
        @try { proxy = send0r(mgr, NSSelectorFromString(@"daemonProxy")); }
        @catch (NSException *e) { LOGF(@"daemonProxy EXC %@", e.reason); }
        if (!proxy) { LOGF(@"FAIL: daemonProxy 为空"); return; }
        LOGF(@"daemonProxy = %@", NSStringFromClass(object_getClass(proxy)));

        if (gStop) { doStop(mgr); return; }
        if (!gHave) { LOGF(@"没有坐标配置（~/.macloc/loc.conf 或 SPOOF_LAT/SPOOF_LON），跳过推送"); return; }

        if (gReset) {
            // 关键：先 stop + clear，让 locationd 的 fSimulationRunning 从 1 回到 0，
            // 再重新 start —— 只有发生这个状态迁移，locationd 才会
            // "LocationProvider is notifying clients"，把新坐标推给所有已注册客户端。
            doStop(mgr);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                LOGF(@"reset 完成，重新 start simulation");
                doPush(mgr);
            });
            return;
        }
        doPush(mgr);
    }
}

#pragma mark - 入口
__attribute__((constructor)) static void macloc_init(void) {
    @autoreleasepool {
        const char *home = getenv("HOME");
        gHome = [NSString stringWithFormat:@"%s/.macloc", home ? home : "/tmp"];

        // 闸：默认只在 CoreLocationAgent 里干活（它是唯一持有 simulation entitlement 的进程）
        const char *pn = getprogname();
        NSString *proc = pn ? [NSString stringWithUTF8String:pn] : @"";
        int force = getenv("MACLOC_FORCE") ? 1 : 0;
        if (![proc isEqualToString:@"CoreLocationAgent"] && !force) return;

        gStop  = getenv("SPOOF_STOP")  ? 1 : 0;
        // 换坐标必须走 stop+clear+start，让 locationd 的 fSimulationRunning 发生 1->0->1
        // 的状态迁移，否则它不会向客户端广播新位置。默认开启，SPOOF_RESET=0 可关闭。
        gReset = getenv("SPOOF_RESET") ? (getenv("SPOOF_RESET")[0] == '0' ? 0 : 1) : 1;
        loadConf();
        LOGF(@"注入启动 pid=%d proc=%@ 坐标=%.6f,%.6f stop=%d reset=%d",
             getpid(), proc, gLat, gLon, gStop, gReset);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 关键时序：必须先订阅 locationd，再推模拟坐标。
            // 反过来（先推后订阅）客户端会拿到 kCLErrorLocationUnknown。
            gVerify = [Verify new];
            gManager = [[CLLocationManager alloc] init];
            gManager.delegate = gVerify;
            [gManager requestLocation];
            [gManager startUpdatingLocation];
            LOGF(@"已订阅 locationd（等待推送）");
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            push();
        });
    }
}
