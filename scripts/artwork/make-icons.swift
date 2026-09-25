import AppKit
let destination = URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let scale = CGFloat(size)/1024;let transform = AffineTransform(scale:scale);(transform as NSAffineTransform).concat()
    NSColor(calibratedRed:0.16,green:0.14,blue:0.30,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:65,y:65,width:894,height:894),xRadius:200,yRadius:200).fill()
    NSColor(calibratedRed:0.94,green:0.93,blue:1,alpha:1).setFill()
    for x: CGFloat in [252,494] {let shape = NSBezierPath();shape.move(to:NSPoint(x:x,y:512));shape.line(to:NSPoint(x:x+258,y:692));shape.line(to:NSPoint(x:x+258,y:332));shape.close();shape.fill()}
    NSGraphicsContext.restoreGraphicsState();return bitmap.representation(using:.png,properties:[:])!
}
let iconset = destination.appendingPathComponent("AppIcon.iconset");try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {try render(size).write(to:iconset.appendingPathComponent("icon_\(size)x\(size).png"));try render(size*2).write(to:iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))}
let png = render(256);var ico = Data([0,0,1,0,1,0,0,0,0,0,1,0,32,0])
func integer(_ value:UInt32)->Data {var v = value.littleEndian;return withUnsafeBytes(of:&v){Data($0)}}
ico.append(integer(UInt32(png.count)));ico.append(integer(22));ico.append(png);try ico.write(to:destination.appendingPathComponent("AppIcon.ico"))
