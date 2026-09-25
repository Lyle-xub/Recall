import AppKit

let root = URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
func render(scale:CGFloat)->NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(720*scale),pixelsHigh:Int(440*scale),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    (AffineTransform(scale:scale) as NSAffineTransform).concat()
    let bounds = NSRect(x:0,y:0,width:720,height:440)
    NSGradient(starting:NSColor(calibratedRed:0.96,green:0.95,blue:0.93,alpha:1),ending:.white)!.draw(in:bounds,angle:90)
    func label(_ text:String,y:CGFloat,size:CGFloat,weight:NSFont.Weight,color:NSColor) {
        let value = NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color])
        value.draw(at:NSPoint(x:(720-value.size().width)/2,y:y))
    }
    let ink = NSColor(calibratedRed:0.22,green:0.24,blue:0.26,alpha:1)
    label("Recall",y:343,size:32,weight:.semibold,color:ink)
    label("Your day. Within reach.",y:316,size:14,weight:.regular,color:ink.withAlphaComponent(0.62))
    // Finder supplies the actual app and Applications icons at (190, 220) / (530, 220).
    let arrow = NSBezierPath();arrow.move(to:NSPoint(x:335,y:220));arrow.line(to:NSPoint(x:385,y:220))
    arrow.move(to:NSPoint(x:376,y:229));arrow.line(to:NSPoint(x:385,y:220));arrow.line(to:NSPoint(x:376,y:211))
    arrow.lineWidth = 1.7;arrow.lineCapStyle = .round;arrow.lineJoinStyle = .round
    ink.withAlphaComponent(0.33).setStroke();arrow.stroke()
    label("Drag Recall into Applications",y:88,size:14,weight:.medium,color:ink.withAlphaComponent(0.8))
    label("Then open Recall to get started.",y:63,size:12,weight:.regular,color:ink.withAlphaComponent(0.48))
    NSGraphicsContext.restoreGraphicsState();bitmap.size = NSSize(width:720,height:440);return bitmap
}
let standard = render(scale:1),retina = render(scale:2)
try retina.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("Installer-background@2x.png"))
try NSBitmapImageRep.representationOfImageReps(in:[standard,retina],using:.tiff,properties:[:])!.write(to:root.appendingPathComponent("Installer-background.tiff"))
