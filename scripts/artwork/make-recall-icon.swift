import AppKit
import CoreImage

let destination = URL(fileURLWithPath:CommandLine.arguments[1])
let assets = destination.appendingPathComponent("Recall.icon/Assets")
try FileManager.default.createDirectory(at:assets,withIntermediateDirectories:true)
guard let glassTexture = NSImage(contentsOf:destination.appendingPathComponent("IridescentGlass.png")) else {
    fatalError("Missing IridescentGlass.png in the artwork directory")
}
func color(_ r:CGFloat,_ g:CGFloat,_ b:CGFloat,_ a:CGFloat = 1)->NSColor { NSColor(srgbRed:r,green:g,blue:b,alpha:a) }
func shadow(_ opacity:CGFloat,_ radius:CGFloat,_ y:CGFloat) { let s = NSShadow();s.shadowColor = .black.withAlphaComponent(opacity);s.shadowBlurRadius = radius;s.shadowOffset = NSSize(width:0,height:y);s.set() }
func prism() {
    let pane = NSRect(x:148,y:148,width:728,height:728)
    let shape = NSBezierPath(roundedRect:pane,xRadius:164,yRadius:164)
    NSGraphicsContext.saveGraphicsState();shape.addClip()
    // Reference-derived material, with its original saturation and panel structure.
    let textureFrame = pane.insetBy(dx:-pane.width*0.175,dy:-pane.height*0.175)
    glassTexture.draw(in:textureFrame,from:.zero,operation:.sourceOver,fraction:1)
    NSColor.white.withAlphaComponent(0.15).setFill();shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.80).setStroke();shape.lineWidth = 3;shape.stroke()
}
func haloPath()->NSBezierPath {
    let path = NSBezierPath(ovalIn:NSRect(x:239,y:324,width:546,height:376))
    var tilt = AffineTransform();tilt.translate(x:512,y:512);tilt.rotate(byDegrees:-30);tilt.translate(x:-512,y:-512)
    path.transform(using:tilt);return path
}
func haloGradient(width:CGFloat,colors:[NSColor],angle:CGFloat) {
    let context = NSGraphicsContext.current!.cgContext
    context.saveGState()
    context.addPath(haloPath().cgPath.copy(strokingWithWidth:width,lineCap:.round,lineJoin:.round,miterLimit:10));context.clip()
    NSGradient(colors:colors)!.draw(in:NSRect(x:205,y:215,width:614,height:594),angle:angle)
    context.restoreGState()
}
func makeHaloGlow()->NSImage {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    haloGradient(width:64,colors:[.white.withAlphaComponent(0),.white.withAlphaComponent(0.09),.white.withAlphaComponent(0.65)],angle:135)
    NSGraphicsContext.restoreGraphicsState()
    let input = CIImage(cgImage:bitmap.cgImage!)
    let glow = input.applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:23])
    let output = CIContext().createCGImage(glow,from:input.extent)!
    return NSImage(cgImage:output,size:NSSize(width:1024,height:1024))
}
let haloGlow = makeHaloGlow()
func halo(template:Bool = false) {
    if template {
        let shape = haloPath();shape.lineWidth = 65;NSColor.black.setStroke();shape.stroke();return
    }
    // Sharp lower-right rim, diffused upper-left light, and a completely open centre.
    haloGlow.draw(in:NSRect(x:-12,y:15,width:1024,height:1024),from:.zero,operation:.sourceOver,fraction:1)
    haloGradient(width:30,colors:[.white.withAlphaComponent(0),.white.withAlphaComponent(0.06),.white.withAlphaComponent(0.94),.white],angle:-45)
    haloGradient(width:12,colors:[.white.withAlphaComponent(0),.white.withAlphaComponent(0.04),.white],angle:-45)
}
func render(_ pixels:Int,layer:String = "complete")->Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    (AffineTransform(scale:CGFloat(pixels)/1024) as NSAffineTransform).concat();NSGraphicsContext.current?.imageInterpolation = .high
    if layer == "complete" {
        let tile = NSBezierPath(roundedRect:NSRect(x:66,y:66,width:892,height:892),xRadius:202,yRadius:202)
        NSGraphicsContext.saveGraphicsState();shadow(0.22,22,-10);NSColor.white.setFill();tile.fill();NSGraphicsContext.restoreGraphicsState()
        NSGradient(colors:[color(0.93,0.94,0.96),.white,.white])!.draw(in:tile,angle:80)
        NSColor.white.setStroke();tile.lineWidth = 3;tile.stroke()
    }
    if layer == "complete" || layer == "prism" { prism() }
    if layer == "complete" || layer == "halo" { halo() }
    if layer == "template" {
        (AffineTransform(scale:1.28) as NSAffineTransform).concat()
        (AffineTransform(translationByX:-112,byY:-112) as NSAffineTransform).concat()
        halo(template:true)
    }
    NSGraphicsContext.restoreGraphicsState();return rep.representation(using:.png,properties:[:])!
}
let iconset = destination.appendingPathComponent("Recall.iconset")
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    try render(size).write(to:iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size*2).write(to:iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
try render(1024).write(to:destination.appendingPathComponent("Recall-1024.png"))
try render(1024,layer:"prism").write(to:assets.appendingPathComponent("Prism.png"))
try render(1024,layer:"halo").write(to:assets.appendingPathComponent("Halo.png"))
try render(18,layer:"template").write(to:destination.appendingPathComponent("RecallTemplate.png"))
try render(36,layer:"template").write(to:destination.appendingPathComponent("RecallTemplate@2x.png"))
