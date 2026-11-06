// click.m —— 在指定屏幕逻辑坐标点击 / 发 ESC 键（用于自动化测试菜单栏图标）
// 用法: ./click X Y      点击
//       ./click esc      发 ESC
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "用法: click X Y | click esc\n"); return 1; }
        if (strcmp(argv[1], "esc") == 0) {
            CGEventRef k = CGEventCreateKeyboardEvent(NULL, 53, true);
            CGEventPost(kCGHIDEventTap, k);
            CGEventRef ku = CGEventCreateKeyboardEvent(NULL, 53, false);
            CGEventPost(kCGHIDEventTap, ku);
            printf("esc\n");
            return 0;
        }
        if (strcmp(argv[1], "move") == 0 && argc >= 3) {
            double mx = atof(argv[2]), my = atof(argv[3]);
            CGEventRef m = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGPointMake(mx, my), kCGMouseButtonLeft);
            CGEventPost(kCGHIDEventTap, m);
            printf("moved %.0f,%.0f\n", mx, my);
            return 0;
        }
        if (argc < 3) { fprintf(stderr, "用法: click X Y\n"); return 1; }
        double x = atof(argv[1]), y = atof(argv[2]);
        CGEventRef m = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, CGPointMake(x, y), kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, m);
        usleep(150000);
        CGEventRef d = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, CGPointMake(x, y), kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, d);
        usleep(80000);
        CGEventRef u = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, CGPointMake(x, y), kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, u);
        printf("clicked %.0f,%.0f\n", x, y);
    }
    return 0;
}
