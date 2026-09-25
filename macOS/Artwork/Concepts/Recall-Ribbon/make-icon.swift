import AppKit
import CoreGraphics

let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}
func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func drawStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat, colors: [CGColor], positions: [CGFloat], from: CGPoint, to: CGPoint, shadow: Bool = false) {
    ctx.saveGState()
    if shadow {
        ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 26, color: rgb(0.16, 0.23, 0.49, 0.19))
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(rgb(0.58, 0.55, 0.9, 0.62))
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0)
    }
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(gradient(colors, positions), start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}
func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gfx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gfx
    let ctx = gfx.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let tile = roundedRect(CGRect(x: 64, y: 64, width: 896, height: 896), radius: 202)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -13), blur: 34, color: rgb(0.22, 0.25, 0.42, 0.20))
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0.99, 0.995, 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(1, 1, 1), rgb(0.955, 0.975, 1)], [0, 1]), start: CGPoint(x: 210, y: 936), end: CGPoint(x: 890, y: 60), options: [])
    ctx.setBlendMode(.normal)
    ctx.drawRadialGradient(gradient([rgb(0.51, 0.88, 1, 0.17), rgb(0.51, 0.88, 1, 0)], [0, 1]), startCenter: CGPoint(x: 680, y: 748), startRadius: 0, endCenter: CGPoint(x: 680, y: 748), endRadius: 575, options: [])
    ctx.drawRadialGradient(gradient([rgb(1, 0.58, 0.82, 0.15), rgb(1, 0.58, 0.82, 0)], [0, 1]), startCenter: CGPoint(x: 316, y: 305), startRadius: 0, endCenter: CGPoint(x: 316, y: 305), endRadius: 460, options: [])
    ctx.restoreGState()

    let spine = CGMutablePath()
    spine.move(to: CGPoint(x: 318, y: 283))
    spine.addCurve(to: CGPoint(x: 324, y: 718), control1: CGPoint(x: 318, y: 433), control2: CGPoint(x: 318, y: 584))
    drawStroke(ctx, spine, width: 128, colors: [rgb(0.58, 0.47, 0.95), rgb(0.20, 0.78, 0.98)], positions: [0, 1], from: CGPoint(x: 318, y: 260), to: CGPoint(x: 324, y: 800), shadow: true)

    let loop = CGMutablePath()
    loop.move(to: CGPoint(x: 324, y: 718))
    loop.addCurve(to: CGPoint(x: 643, y: 708), control1: CGPoint(x: 415, y: 755), control2: CGPoint(x: 553, y: 760))
    loop.addCurve(to: CGPoint(x: 665, y: 530), control1: CGPoint(x: 746, y: 647), control2: CGPoint(x: 743, y: 568))
    loop.addCurve(to: CGPoint(x: 330, y: 489), control1: CGPoint(x: 585, y: 474), control2: CGPoint(x: 445, y: 476))
    drawStroke(ctx, loop, width: 128, colors: [rgb(0.37, 0.91, 0.93), rgb(0.14, 0.63, 0.98), rgb(0.71, 0.58, 0.99)], positions: [0, 0.55, 1], from: CGPoint(x: 290, y: 765), to: CGPoint(x: 778, y: 428), shadow: true)

    let leg = CGMutablePath()
    leg.move(to: CGPoint(x: 505, y: 472))
    leg.addCurve(to: CGPoint(x: 730, y: 284), control1: CGPoint(x: 578, y: 410), control2: CGPoint(x: 674, y: 332))
    drawStroke(ctx, leg, width: 127, colors: [rgb(0.48, 0.58, 0.99), rgb(0.93, 0.51, 0.87), rgb(1, 0.72, 0.66)], positions: [0, 0.56, 1], from: CGPoint(x: 501, y: 493), to: CGPoint(x: 773, y: 230), shadow: true)

    // Fine glass glints add depth at full size without carrying the silhouette.
    ctx.saveGState()
    let glint = CGMutablePath()
    glint.move(to: CGPoint(x: 372, y: 770))
    glint.addCurve(to: CGPoint(x: 615, y: 747), control1: CGPoint(x: 445, y: 795), control2: CGPoint(x: 544, y: 794))
    ctx.addPath(glint)
    ctx.setLineWidth(15)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.58))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.91))
    ctx.setLineWidth(3)
    ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for size in [1024, 512, 256, 128, 64, 32] {
    try render(size).write(to: output.appendingPathComponent("Recall-Ribbon-\(size).png"))
}
