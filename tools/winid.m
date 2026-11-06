// winid.m —— 打印指定 App 的窗口 ID（CGWindowNumber），供 `screencapture -l<id>` 精确截取
// 用法: ./winid Maps
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *want = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"Maps";
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                     kCGNullWindowID);
        if (!list) { fprintf(stderr, "拿不到窗口列表\n"); return 1; }
        NSArray *arr = (__bridge NSArray *)list;
        double bestArea = 0; uint32_t bestID = 0; NSString *bestName = nil;
        for (NSDictionary *d in arr) {
            NSString *owner = d[(id)kCGWindowOwnerName];
            if (![owner isEqualToString:want]) continue;
            NSNumber *layerNum = d[(id)kCGWindowLayer];
            if (layerNum && layerNum.integerValue != 0) continue;         // 只看正常窗口层
            NSDictionary *bd = d[(id)kCGWindowBounds];
            if (!bd) continue;
            CGRect r = CGRectZero;
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bd, &r);
            double area = r.size.width * r.size.height;
            if (area <= 0) continue;
            NSNumber *num = d[(id)kCGWindowNumber];
            if (area > bestArea) {
                bestArea = area;
                bestID = num.unsignedIntValue;
                bestName = d[(id)kCGWindowName];
            }
        }
        if (bestID == 0) { fprintf(stderr, "没找到 %s 的窗口（可能没开）\n", want.UTF8String); return 2; }
        printf("%u\n", bestID);
        fprintf(stderr, "%s window #%u  area=%.0f  name=%s\n", want.UTF8String, bestID, bestArea, bestName.UTF8String ?: "-");
    }
    return 0;
}
