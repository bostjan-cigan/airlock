// Makes the 1600×840 cover image: a window screenshot (with its shadow) centred on the app
// icon's navy gradient.
//   swift Tools/make-cover.swift <window.png> <cover.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let window = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: swift Tools/make-cover.swift <window.png> <cover.png>")
    exit(2)
}

let size = CGSize(width: 1600, height: 840)
let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Top to bottom, lighter to darker, like the icon's body.
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0x4F86C6), color(0x1E4475)] as CFArray, locations: nil)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])

// The capture includes the shadow, so it's a little wider than the window itself.
let width = size.width * 0.74
let height = width * CGFloat(window.height) / CGFloat(window.width)
let top: CGFloat = 62
ctx.interpolationQuality = .high
ctx.draw(window, in: CGRect(x: (size.width - width) / 2, y: size.height - top - height, width: width, height: height))

let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("Wrote \(args[2])")
