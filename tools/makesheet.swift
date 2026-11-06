// makesheet.swift —— 把多种图标风格拼成一张对比图
//   ./makesheet out.png dark.png light.png neon.png
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else { exit(1) }
let out = args[1]
let paths = Array(args[2...])

func load(_ p: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

guard let first = load(paths[0]) else { exit(1) }
let cell = first.width
let gap = 40
let label = 60
let W = paths.count * cell + (paths.count + 1) * gap
let H = cell + label + gap

let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

let names = ["dark", "light", "neon"]
let cf = CTFontCreateWithName("Helvetica-Bold" as CFString, 28, nil)
let attrs: [NSAttributedString.Key: Any] = [
    .font: cf,
    .foregroundColor: CGColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 1)
]

for (i, p) in paths.enumerated() {
    guard let img = load(p) else { continue }
    let x = gap + i * (cell + gap)
    // CG 坐标 y 向上，图标放在下方，标签在上
    ctx.draw(img, in: CGRect(x: x, y: gap, width: cell, height: cell))
    let s = NSAttributedString(string: names[i], attributes: attrs)
    let line = CTLineCreateWithAttributedString(s)
    let tx: CGFloat = CGFloat(x) + CGFloat(cell) / 2 - 34
    let ty: CGFloat = CGFloat(cell) + CGFloat(gap) + 16
    ctx.textPosition = CGPoint(x: tx, y: ty)
    CTLineDraw(line, ctx)
}

let img = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                           UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)  \(W)x\(H)")
