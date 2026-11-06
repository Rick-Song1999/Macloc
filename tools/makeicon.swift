// makeicon.swift —— 生成 MacLocBar 的 App 图标（1024×1024 PNG）
//
//   ./makeicon out.png dark     深蓝地图风（默认）
//   ./makeicon out.png light    浅色地图风
//   ./makeicon out.png neon     高饱和渐变风
//
// 纯 CoreGraphics 绘制，无外部依赖。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 基础形状

/// Apple 风格的连续圆角矩形（superellipse），n=5
func squirclePath(_ rect: CGRect, n: CGFloat = 5.0) -> CGPath {
    let p = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2.0 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2.0 / n), st)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
        else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

/// 定位针 SVG 取景框：x ∈ [5,19]，y ∈ [2,22]（y 向下）
private let pinBoxX0: CGFloat = 5, pinBoxX1: CGFloat = 19
private let pinBoxY0: CGFloat = 2, pinBoxY1: CGFloat = 22

/// 把 SVG 坐标映射到目标 rect（注意翻转：CoreGraphics 的 y 向上，SVG 的 y 向下）
private func svgPoint(_ x: CGFloat, _ y: CGFloat, _ r: CGRect) -> CGPoint {
    let sx = r.width / (pinBoxX1 - pinBoxX0)
    let sy = r.height / (pinBoxY1 - pinBoxY0)
    return CGPoint(x: r.minX + (x - pinBoxX0) * sx,
                   y: r.maxY - (y - pinBoxY0) * sy)
}

private func svgCurve(_ p: CGMutablePath,
                      _ c1: (CGFloat, CGFloat), _ c2: (CGFloat, CGFloat),
                      _ e: (CGFloat, CGFloat), _ r: CGRect) {
    p.addCurve(to: svgPoint(e.0, e.1, r),
               control1: svgPoint(c1.0, c1.1, r),
               control2: svgPoint(c2.0, c2.1, r))
}

/// 经典地图定位针（尖端朝下），基于标准 24×24 SVG path
/// M12 2 C8.13 2 5 5.13 5 9 C5 14.25 7 18 12 22 C17 18 19 14.25 19 9 C19 5.13 15.87 2 12 2 Z
/// r 为该 SVG 视图整体所占的 rect（24×22 的取景框）
func pinPath(in r: CGRect) -> CGPath {
    let p = CGMutablePath()
    p.move(to: svgPoint(12, 2, r))
    svgCurve(p, (8.13, 2), (5, 5.13), (5, 9), r)
    svgCurve(p, (5, 14.25), (7, 18), (12, 22), r)
    svgCurve(p, (17, 18), (19, 14.25), (19, 9), r)
    svgCurve(p, (19, 5.13), (15.87, 2), (12, 2), r)
    p.closeSubpath()
    return p
}

// MARK: - 调色板

struct Palette {
    let top: (CGFloat, CGFloat, CGFloat)
    let bottom: (CGFloat, CGFloat, CGFloat)
    let road: (CGFloat, CGFloat, CGFloat)
    let roadAlpha: CGFloat
    let pin: (CGFloat, CGFloat, CGFloat)
    let pinCore: (CGFloat, CGFloat, CGFloat)
}

func cg(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1) -> CGColor {
    CGColor(red: c.0, green: c.1, blue: c.2, alpha: a)
}

// MARK: - 绘制

func drawIcon(_ ctx: CGContext, size: CGFloat, style: String) {
    let S = size
    let full = CGRect(x: 0, y: 0, width: S, height: S)
    let body = full.insetBy(dx: S * 0.045, dy: S * 0.045)

    let pal: Palette
    switch style {
    case "light":
        pal = Palette(top: (0.995, 0.995, 1.0), bottom: (0.855, 0.895, 0.955),
                      road: (0.30, 0.38, 0.52), roadAlpha: 0.14,
                      pin: (0.0, 0.35, 0.88), pinCore: (1, 1, 1),
                      )
    case "neon":
        pal = Palette(top: (0.42, 0.78, 1.0), bottom: (0.13, 0.20, 0.86),
                      road: (1, 1, 1), roadAlpha: 0.20,
                      pin: (1, 1, 1), pinCore: (0.16, 0.48, 1.0))
    default:  // dark
        pal = Palette(top: (0.20, 0.65, 0.99), bottom: (0.015, 0.22, 0.72),
                      road: (1, 1, 1), roadAlpha: 0.19,
                      pin: (1, 1, 1), pinCore: (0.0, 0.55, 1.0))
    }

    // ---- 投影 ----
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.024),
                  blur: S * 0.050,
                  color: cg((0, 0, 0), 0.28))
    ctx.setFillColor(cg((0, 0, 0), 1))
    ctx.addPath(squirclePath(body.offsetBy(dx: 0, dy: -S * 0.010), n: 5.0))
    ctx.fillPath()
    ctx.restoreGState()

    // ---- 底板 ----
    ctx.saveGState()
    ctx.addPath(squirclePath(body, n: 5.0))
    ctx.clip()

    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [cg(pal.top), cg(pal.bottom)] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY),
                           options: [])

    // 顶部柔光
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [cg((1, 1, 1), 0.24), cg((1, 1, 1), 0.0)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(hl,
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.midY + S * 0.06),
                           options: [])

    // ---- 路网 ----
    if pal.roadAlpha > 0 {
        ctx.setStrokeColor(cg(pal.road, pal.roadAlpha))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // 主干道（横）
        ctx.setLineWidth(S * 0.030)
        let p1 = CGMutablePath()
        p1.move(to: CGPoint(x: body.minX - S * 0.03, y: body.minY + S * 0.235))
        p1.addCurve(to: CGPoint(x: body.maxX + S * 0.03, y: body.minY + S * 0.330),
                    control1: CGPoint(x: body.minX + S * 0.28, y: body.minY + S * 0.185),
                    control2: CGPoint(x: body.minX + S * 0.66, y: body.minY + S * 0.375))
        ctx.addPath(p1); ctx.strokePath()

        // 主干道（纵）
        ctx.setLineWidth(S * 0.026)
        let p2 = CGMutablePath()
        p2.move(to: CGPoint(x: body.minX + S * 0.145, y: body.maxY + S * 0.03))
        p2.addCurve(to: CGPoint(x: body.minX + S * 0.255, y: body.minY - S * 0.03),
                    control1: CGPoint(x: body.minX + S * 0.085, y: body.midY),
                    control2: CGPoint(x: body.minX + S * 0.360, y: body.minY + S * 0.135))
        ctx.addPath(p2); ctx.strokePath()

        // 次级路
        ctx.setLineWidth(S * 0.014)
        for i in 0..<3 {
            let yy = body.minY + body.height * (0.615 + CGFloat(i) * 0.115)
            let p3 = CGMutablePath()
            p3.move(to: CGPoint(x: body.minX - S * 0.03, y: yy))
            p3.addCurve(to: CGPoint(x: body.maxX + S * 0.03, y: yy + S * 0.045),
                        control1: CGPoint(x: body.minX + S * 0.32, y: yy - S * 0.050),
                        control2: CGPoint(x: body.minX + S * 0.62, y: yy + S * 0.085))
            ctx.addPath(p3); ctx.strokePath()
        }

        // 街区网格（细）
        ctx.setLineWidth(S * 0.006)
        ctx.setStrokeColor(cg(pal.road, pal.roadAlpha * 0.55))
        for i in 0..<5 {
            let xx = body.minX + body.width * (0.34 + CGFloat(i) * 0.115)
            let g = CGMutablePath()
            g.move(to: CGPoint(x: xx, y: body.minY - S * 0.02))
            g.addLine(to: CGPoint(x: xx + S * 0.045, y: body.maxY + S * 0.02))
            ctx.addPath(g); ctx.strokePath()
        }
    }

    // ---- 定位针 ----
    // SVG 取景框：宽 14 高 20（内容 bbox），整体居中偏上
    let pinH = S * 0.50
    let pinW = pinH * 14.0 / 20.0
    let pinRect = CGRect(x: body.midX - pinW / 2,
                         y: body.minY + body.height * 0.245,
                         width: pinW, height: pinH)
    let pin = pinPath(in: pinRect)

    // 针的投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.014),
                  blur: S * 0.032,
                  color: cg((0, 0, 0), 0.38))
    ctx.setFillColor(cg(pal.pin))
    ctx.addPath(pin)
    ctx.fillPath()
    ctx.restoreGState()

    // 针内竖向高光
    ctx.saveGState()
    ctx.addPath(pin)
    ctx.clip()
    let phl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [cg((1, 1, 1), 0.32), cg((1, 1, 1), 0.0)] as CFArray,
                         locations: [0, 1])!
    ctx.drawLinearGradient(phl,
                           start: CGPoint(x: 0, y: pinRect.maxY),
                           end: CGPoint(x: 0, y: pinRect.minY),
                           options: [])
    ctx.restoreGState()

    // 针芯（SVG 里的小圆：中心 (12,13)，半径 2）
    let coreC = svgPoint(12, 13, pinRect)
    let coreR = 2.15 * (pinRect.width / (pinBoxX1 - pinBoxX0))
    ctx.setFillColor(cg(pal.pinCore))
    ctx.addEllipse(in: CGRect(x: coreC.x - coreR, y: coreC.y - coreR,
                              width: coreR * 2, height: coreR * 2))
    ctx.fillPath()

    ctx.restoreGState()   // 解除 clip

    // ---- 内描边 ----
    ctx.setStrokeColor(cg((1, 1, 1), 0.15))
    ctx.setLineWidth(S * 0.005)
    ctx.addPath(squirclePath(body.insetBy(dx: S * 0.0025, dy: S * 0.0025), n: 5.0))
    ctx.strokePath()
}

// MARK: - 主流程

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "icon.png"
let style = args.count > 2 ? args[2] : "dark"
let size: CGFloat = args.count > 3 ? CGFloat(Double(args[3]) ?? 1024) : 1024

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil,
                          width: Int(size), height: Int(size),
                          bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write("无法创建绘图上下文\n".data(using: .utf8)!)
    exit(1)
}
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

drawIcon(ctx, size: size, style: style)

guard let img = ctx.makeImage() else { exit(1) }
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("无法创建 PNG 输出\n".data(using: .utf8)!)
    exit(1)
}
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outPath)  \(Int(size))x\(Int(size))  style=\(style)")
