import AppKit
import CoreGraphics
import Foundation

// A macOS app icon has to survive at 16x16, so the mark is deliberately simple:
// a rounded square with a gradient, and a bold arrow pointing down onto a line --
// "save the clipboard to a file".
//
// Optical weight is keyed on the *point* size, not the pixel count. Two slots
// that share a pixel count but not a point size (16@2x and 32@1x are both 32px)
// must not rasterize identically, or the asset catalog dedupes them and the
// larger representations never reach the .icns.

func makeIcon(pixels: CGFloat, points: CGFloat) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: Int(pixels), height: Int(pixels),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.scaleBy(x: pixels / 1024.0, y: pixels / 1024.0)

    // Small icons need proportionally heavier marks to survive rasterization;
    // large icons can carry more delicate detail.
    let k: CGFloat
    switch points {
    case ...16: k = 1.55
    case ...32: k = 1.28
    case ...128: k = 1.10
    case ...256: k = 1.0
    default: k = 0.94
    }

    // A stroke thinner than a device pixel disappears, so floor it in pixel space.
    let hairline: CGFloat = 1024.0 / pixels * 0.85

    let inset: CGFloat = 100
    let body = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let radius: CGFloat = 180
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.36, green: 0.62, blue: 0.98, alpha: 1),
            CGColor(red: 0.24, green: 0.40, blue: 0.86, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: 1024),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
    let sheen = CGGradient(
        colorsSpace: space,
        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.30),
                 CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: 0, y: 1024),
                           end: CGPoint(x: 0, y: 512),
                           options: [])
    ctx.restoreGState()

    // Rounded-square border for separation from light backgrounds.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(red: 0.12, green: 0.22, blue: 0.50, alpha: 0.35))
    ctx.setLineWidth(max(10 * k, hairline))
    ctx.strokePath()
    ctx.restoreGState()

    // Arrow pointing down.
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.setFillColor(white)

    let shaftBase = CGRect(x: 452, y: 600, width: 120, height: 230)
    let dw = shaftBase.width * (k - 1) / 2
    let shaft = shaftBase.insetBy(dx: -dw, dy: 0)
    ctx.addPath(CGPath(roundedRect: shaft, cornerWidth: 34 * k, cornerHeight: 34 * k, transform: nil))
    ctx.fillPath()

    // Triangular head, grown about its tip so small icons gain length and width.
    let tip = CGPoint(x: 512, y: 386)
    func head(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: 512 + (x - 512) * k, y: tip.y + (y - tip.y) * k)
    }
    ctx.move(to: head(352, 620))
    ctx.addLine(to: head(672, 620))
    ctx.addLine(to: head(512, 386))
    ctx.closePath()
    ctx.fillPath()

    // The line it lands on -- the "file".
    let baseBase = CGRect(x: 340, y: 300, width: 344, height: 44)
    let bdx = baseBase.width * (k - 1) / 2
    let bdy = max(baseBase.height * (k - 1) / 2, (hairline - baseBase.height) / 2)
    let base = baseBase.insetBy(dx: -bdx, dy: -bdy)
    ctx.addPath(CGPath(roundedRect: base, cornerWidth: base.height / 2, cornerHeight: base.height / 2, transform: nil))
    ctx.fillPath()

    return ctx.makeImage()
}

// Returns the encoded bytes so the caller can assert that no two slots collide.
func write(_ image: CGImage, to path: String) -> Data? {
    let url = URL(fileURLWithPath: path)
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else {
        print("cannot encode \(path)")
        return nil
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        print("cannot finalize \(path)")
        return nil
    }
    do {
        try (data as Data).write(to: url)
    } catch {
        print("cannot write \(path): \(error)")
        return nil
    }
    print("wrote \(url.lastPathComponent) \(image.width)x\(image.height)")
    return data as Data
}

// Output goes to the appiconset by default; pass a directory to write elsewhere.
let outDir: String
if CommandLine.arguments.count > 1 {
    outDir = CommandLine.arguments[1]
} else {
    outDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Clipboard_saver/Assets.xcassets/AppIcon.appiconset")
        .path
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// The 1024 preview is for inspection only and is not part of the appiconset.
if CommandLine.arguments.count > 1, let big = makeIcon(pixels: 1024, points: 512) {
    _ = write(big, to: "\(outDir)/preview-1024.png")
}

let slots: [(String, CGFloat, CGFloat)] = [
    ("icon_16x16", 16, 16), ("icon_16x16@2x", 32, 16),
    ("icon_32x32", 32, 32), ("icon_32x32@2x", 64, 32),
    ("icon_128x128", 128, 128), ("icon_128x128@2x", 256, 128),
    ("icon_256x256", 256, 256), ("icon_256x256@2x", 512, 256),
    ("icon_512x512", 512, 512), ("icon_512x512@2x", 1024, 512),
]
var written = 0
var digests = Set<Data>()
for (name, px, pt) in slots {
    guard let image = makeIcon(pixels: px, points: pt),
          let data = write(image, to: "\(outDir)/\(name).png") else { continue }
    written += 1
    digests.insert(data)
}

// Slots that share a pixel count but not a point size (16@2x and 32@1x are both
// 32 px) must not rasterise identically: the asset catalog drops colliding
// files, and the affected representations never reach the .icns.
if written != slots.count {
    print("error: only \(written)/\(slots.count) slots rendered")
    exit(1)
}
if digests.count != slots.count {
    print("error: \(slots.count - digests.count) slot(s) are byte-identical to another")
    exit(1)
}
print("ok: \(written) slots, \(digests.count) distinct rasters")
