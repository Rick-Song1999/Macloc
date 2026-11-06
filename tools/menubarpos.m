// menubarpos.m —— 在截屏顶部菜单栏里找「MacLoc 蓝点图标」，输出其逻辑坐标
// 用法: ./menubarpos shot.png
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "用法: menubarpos shot.png\n"); return 1; }
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[1])], NULL);
        if (!src) { fprintf(stderr, "打不开 %s\n", argv[1]); return 1; }
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        size_t W = CGImageGetWidth(img), H = CGImageGetHeight(img);
        unsigned char *buf = (unsigned char *)malloc(W * H * 4);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), img);

        long sx = 0, sy = 0; int k = 0;
        size_t ybot = H < 120 ? H : 120;
        for (size_t y = 0; y < ybot; y++) {
            for (size_t x = 0; x < W; x++) {
                unsigned char *p = buf + (y * W + x) * 4;
                // MacLoc 图标：纯蓝 RGB(0,145,255)
                if (p[0] < 30 && p[1] > 135 && p[1] < 160 && p[2] > 240) { sx += x; sy += y; k++; }
            }
        }
        if (k < 20) { fprintf(stderr, "没在菜单栏找到 MacLoc 蓝点（命中 %d px）\n", k); return 2; }
        double cx = (double)sx / k, cy = (double)sy / k;
        // 截图像素是物理像素(2x)，CGEvent 用逻辑点
        printf("PIX %.0f %.0f  count=%d\n", cx, cy, k);
        printf("LOGICAL %.1f %.1f\n", cx / 2.0, cy / 2.0);
    }
    return 0;
}
