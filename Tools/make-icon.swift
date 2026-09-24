// Draws AIrlock's app icon, an airlock hatch, and writes every size into the asset catalog.
// Usage: swift Tools/make-icon.swift   (from the repository root)

import AppKit

let size: CGFloat = 1024
let out = "AIrlock/Assets.xcassets/AppIcon.appiconset"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func disk(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

/// Fills a path with a vertical gradient (top colour first).
func fill(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor]) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let box = path.boundingBox
    ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
    ctx.restoreGState()
}

func draw(_ ctx: CGContext) {
    let c = CGPoint(x: size / 2, y: size / 2)

    // The body: macOS's rounded square on the standard grid, with its drop shadow.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(color(0x173556))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, body, [color(0x2F6199), color(0x163A63), color(0x0C1E36)])
    // Soft light from above.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)]),
                           startCenter: CGPoint(x: c.x, y: 900), startRadius: 0, endCenter: CGPoint(x: c.x, y: 900), endRadius: 520, options: [])
    ctx.restoreGState()

    // The frame: a thick metal ring around a dark recess.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
    ctx.addPath(disk(c, 318))
    ctx.setFillColor(color(0xC9D3E0))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, disk(c, 318), [color(0xF7F9FC), color(0xC6D0DD), color(0x94A3B8)])
    fill(ctx, disk(c, 272), [color(0x0A1628), color(0x173050)])

    // Bolts around the frame, and a green light at the top: sealed.
    for i in 0..<12 where i != 3 {
        let a = CGFloat(i) * .pi / 6
        let p = CGPoint(x: c.x + 295 * cos(a), y: c.y + 295 * sin(a))
        fill(ctx, disk(p, 10), [color(0x7D8CA3), color(0x5B6A80)])
        fill(ctx, disk(CGPoint(x: p.x - 2, y: p.y + 3), 4), [color(0xFFFFFF, 0.8), color(0xFFFFFF, 0.2)])
    }
    let lamp = CGPoint(x: c.x, y: c.y + 295)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: color(0x3CE07A, 0.9))
    fill(ctx, disk(lamp, 17), [color(0x7CF2A4), color(0x22B55A)])
    ctx.restoreGState()
    fill(ctx, disk(CGPoint(x: lamp.x - 4, y: lamp.y + 6), 6), [color(0xFFFFFF, 0.9), color(0xFFFFFF, 0.3)])

    // The door, casting a shadow into the recess.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.55))
    ctx.addPath(disk(c, 252))
    ctx.setFillColor(color(0xDDE4EE))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, disk(c, 252), [color(0xEEF2F7), color(0xC3CDDA), color(0x9AA9BD)])
    // A faint seam just inside the door's edge.
    ctx.addPath(disk(c, 226))
    ctx.setStrokeColor(color(0x6F7F96, 0.35))
    ctx.setLineWidth(4)
    ctx.strokePath()

    // The wheel: rim, four spokes, handles and hub.
    let wheel = color(0x1B3556)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: color(0x000000, 0.35))
    ctx.setStrokeColor(wheel)
    ctx.setLineCap(.round)
    ctx.setLineWidth(28)
    ctx.addPath(disk(c, 118))
    ctx.strokePath()
    ctx.setLineWidth(24)
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2 + .pi / 4
        ctx.move(to: c)
        ctx.addLine(to: CGPoint(x: c.x + 160 * cos(a), y: c.y + 160 * sin(a)))
    }
    ctx.strokePath()
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 2 + .pi / 4
        ctx.addPath(disk(CGPoint(x: c.x + 166 * cos(a), y: c.y + 166 * sin(a)), 22))
    }
    ctx.setFillColor(wheel)
    ctx.fillPath()
    ctx.addPath(disk(c, 46))
    ctx.fillPath()
    ctx.restoreGState()
    fill(ctx, disk(c, 20), [color(0xE9EEF5), color(0x9AA9BD)])
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / size, y: CGFloat(px) / size)
    draw(ctx)
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
        images.append(#"    { "idiom" : "mac", "size" : "\#(points)x\#(points)", "scale" : "\#(scale)x", "filename" : "\#(name)" }"#)
    }
}
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(toFile: "\(out)/Contents.json", atomically: true, encoding: .utf8)
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(toFile: "AIrlock/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
print("Wrote \(out)")
