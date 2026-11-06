// finddot.m —— 在截图中找出 Apple 地图「当前位置」蓝点，输出像素坐标并裁出特写
// 用法: ./finddot shot.png [out.png]
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static int cmpd(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (y * 100000 + x) - (*(const int *)b * 100000 + *(const int *)a);
}

// 苹果地图「当前位置」蓝点 = RGB(0,145,255)。
// 其它 App 的地球图标/系统蓝 = RGB(0,122,255)，靠 g 通道区分（145 vs 122）。
static inline int isDot(unsigned char r, unsigned char g, unsigned char b) {
    return b > 240 && b - r > 150 && g >= 136 && g <= 156 && r < 40;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "用法: finddot shot.png [out.png]\n"); return 1; }
        NSString *in  = [NSString stringWithUTF8String:argv[1]];
        NSString *out = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;

        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:in], NULL);
        if (!src) { fprintf(stderr, "打不开 %s\n", argv[1]); return 1; }
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        size_t W = CGImageGetWidth(img), H = CGImageGetHeight(img);
        unsigned char *buf = (unsigned char *)malloc(W * H * 4);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), img);

        // 收集「苹果地图蓝点」的候选像素：亮蓝、饱和度高
        int n = 0, cap = 1 << 20;
        int *pts = (int *)malloc(sizeof(int) * 2 * cap);
        size_t ytop = 90, ybot = H > 260 ? H - 260 : H;   // 排除菜单栏与 Dock
        for (size_t y = ytop; y < ybot; y++) {
            unsigned char *row = buf + y * W * 4;
            for (size_t x = 0; x < W; x++) {
                int r = row[x*4], g = row[x*4+1], b = row[x*4+2];
                // 地图「当前位置」蓝点实测颜色 = RGB(0,145,255)
                if (isDot(r, g, b)) {
                    if (n < cap) { pts[n*2] = (int)x; pts[n*2+1] = (int)y; n++; }
                }
            }
        }
        if (n == 0) { fprintf(stderr, "没找到蓝点\n"); return 2; }

        // 找出最大的「纯蓝连通块」——地图蓝点是一整块实心圆盘，
        // 而地球图标/按钮等是带纹理或镂空的，不会形成大块纯色。
        int *lab = (int *)malloc(sizeof(int) * (size_t)W * H);
        memset(lab, 0, sizeof(int) * (size_t)W * H);
        int *stack = (int *)malloc(sizeof(int) * cap * 2);
        int bestArea = 0, bestSeed = -1;
        for (size_t y = ytop; y < ybot; y++) {
            for (size_t x = 0; x < W; x++) {
                size_t idx = y * W + x;
                if (lab[idx]) continue;
                unsigned char *p = buf + idx * 4;
                int r = p[0], g = p[1], b = p[2];
                if (!isDot(p[0], p[1], p[2])) { lab[idx] = -1; continue; }
                // BFS
                int sp = 0, area = 0, seed = (int)idx;
                stack[sp*2] = (int)x; stack[sp*2+1] = (int)y; sp++;
                lab[idx] = 1;
                while (sp > 0) {
                    sp--;
                    int cx = stack[sp*2], cy = stack[sp*2+1];
                    area++;
                    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                        if (!dx && !dy) continue;
                        int nx = cx + dx, ny = cy + dy;
                        if (nx < 0 || ny < 0 || nx >= (int)W || ny >= (int)H) continue;
                        size_t ni = (size_t)ny * W + nx;
                        if (lab[ni]) continue;
                        unsigned char *q = buf + ni * 4;
                        if (isDot(q[0], q[1], q[2])) {
                            lab[ni] = 1;
                            stack[sp*2] = nx; stack[sp*2+1] = ny; sp++;
                            if (sp >= cap) sp = cap - 1;
                        }
                    }
                }
                if (area > bestArea) { bestArea = area; bestSeed = seed; }
            }
        }
        if (bestArea < 60) { fprintf(stderr, "没找到蓝点（最大纯蓝连通块 %d px）\n", bestArea); return 2; }

        // 质心
        long sx = 0, sy = 0; int k = 0;
        int sx0 = bestSeed % (int)W, sy0 = bestSeed / (int)W;
        for (int dy = -40; dy <= 40; dy++) for (int dx = -40; dx <= 40; dx++) {
            int nx = sx0 + dx, ny = sy0 + dy;
            if (nx < 0 || ny < 0 || nx >= (int)W || ny >= (int)H) continue;
            unsigned char *q = buf + ((size_t)ny * W + nx) * 4;
            if (isDot(q[0], q[1], q[2])) { sx += nx; sy += ny; k++; }
        }
        double cx = k ? (double)sx / k : sx0, cy = k ? (double)sy / k : sy0;

        printf("SCREEN %zux%zu\n", W, H);
        printf("DOT_PX %.0f %.0f\n", cx, cy);
        printf("DOT_AREA %d\n", bestArea);

        if (out) {
            size_t cw = 360, ch = 360;
            double x0 = cx - cw/2, y0 = cy - ch/2;
            if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0;
            if (x0 + cw > W) cw = W - (size_t)x0;
            if (y0 + ch > H) ch = H - (size_t)y0;
            CGImageRef sub = CGImageCreateWithImageInRect(img, CGRectMake(x0, y0, cw, ch));
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
                (__bridge CFURLRef)[NSURL fileURLWithPath:out],
                (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
            CGImageDestinationAddImage(dst, sub, NULL);
            CGImageDestinationFinalize(dst);
            printf("CROP %s  %.0f %.0f %zu %zu\n", argv[2], x0, y0, cw, ch);
        }
    }
    return 0;
}
