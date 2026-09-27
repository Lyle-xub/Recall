import AppKit
import SceneKit

/// Prepared materials cross to MainActor exactly once. The worker never
/// touches a material after handing it to the scene.
final class ArchivePreparedFooter:@unchecked Sendable {
    let material:SCNMaterial
    init(_ material:SCNMaterial) {self.material=material}
}
private final class ArchiveFooterBaseCache:@unchecked Sendable {
    private let lock=NSLock()
    private var images:[String:CGImage]=[:],order:[String]=[]
    func get(_ key:String)->CGImage? {lock.lock();defer {lock.unlock()};return images[key]}
    func put(_ image:CGImage,key:String) {
        lock.lock();defer {lock.unlock()}
        order.removeAll {$0 == key};order.append(key);images[key]=image
        while order.count > 12 {images[order.removeFirst()]=nil}
    }
}
enum ArchiveInformationRenderer {
    static func prepare(_ request:ArchiveFooterRequest)->ArchivePreparedFooter? {
        autoreleasepool {
            guard let pixels=informationPixels(request.frame,night:request.night,aspect:request.aspect) else {return nil}
            let material=SCNMaterial();material.lightingModel = .constant
            material.diffuse.contents=pixels
            return ArchivePreparedFooter(material)
        }
    }
    private static let baseCache=ArchiveFooterBaseCache()
    static func informationTexture(_ frame:MemoryFrame,night:Bool,aspect:CGFloat)->NSImage {
        guard let pixels=informationPixels(frame,night:night,aspect:aspect) else {return NSImage(size:NSSize(width:190*aspect,height:190))}
        return NSImage(cgImage:pixels,size:NSSize(width:190*aspect,height:190))
    }
    static func informationPixels(_ frame:MemoryFrame,night:Bool,aspect:CGFloat)->CGImage? {
        let size=NSSize(width:190*aspect,height:190),starred=frame.starred
        let key="\(night)|\(starred)|\(aspect)"
        let base:CGImage
        if let cached=baseCache.get(key) {base=cached}
        else {
            guard let drawing=informationCanvas(size:size,draw:{ _,rect in
            (night ? NSColor(white:0.075,alpha:0.96):NSColor(white:0.98,alpha:0.94)).setFill();rect.fill()
            let ink = night ? NSColor(white:0.98,alpha:1):NSColor(white:0.10,alpha:1)
            for button in ArchiveFooterLayout.buttons(in:rect.size) {
                let label:String,symbol:String
                switch button.action {
                case "star":label = starred ? "Starred":"Star";symbol = starred ? "star.fill":"star"
                case "copy":label = "Copy Text";symbol = "doc.on.doc"
                case "rewind":label = "Rewind";symbol = "arrow.up.right"
                default:label = "Collapse";symbol = "arrow.up.left.and.arrow.down.right"
                }
                let path = NSBezierPath(roundedRect:button.rect,xRadius:button.rect.height*0.28,yRadius:button.rect.height*0.28)
                (night ? NSColor.white.withAlphaComponent(0.09):NSColor.white.withAlphaComponent(0.68)).setFill();path.fill()
                ink.withAlphaComponent(0.24).setStroke();path.lineWidth = 1.5;path.stroke()
                let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:31,weight:.medium),.foregroundColor:ink]
                let labelSize = (label as NSString).size(withAttributes:attributes)
                let left = button.rect.midX-(labelSize.width+48)/2
                NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:32,weight:.semibold).applying(.init(paletteColors:[ink])))?.draw(in:NSRect(x:left,y:button.rect.midY-16,width:32,height:32))
                (label as NSString).draw(at:NSPoint(x:left+48,y:button.rect.midY-labelSize.height/2),withAttributes:attributes)
            }
            }) else {return nil}
            base=drawing
            baseCache.put(base,key:key)
        }
        let title=frame.title.isEmpty ? frame.appName:frame.title,time=frame.timeLabel
        return informationCanvas(size:size) { context,rect in
            context.draw(base,in:rect)
            let ink=night ? NSColor(white:0.98,alpha:1):NSColor(white:0.10,alpha:1)
            let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in:NSRect(x:rect.width*0.016,y:119,width:rect.width*0.53,height:34*1.6),withAttributes:[.font:NSFont.systemFont(ofSize:34,weight:.semibold),.foregroundColor:ink,.paragraphStyle:paragraph])
            (time as NSString).draw(in:NSRect(x:rect.width*0.60,y:121,width:rect.width*0.38,height:29*1.6),withAttributes:[.font:NSFont.systemFont(ofSize:29,weight:.regular),.foregroundColor:ink,.paragraphStyle:paragraph])
        }
    }
    private static func informationCanvas(size:CGSize,draw:(CGContext,CGRect)->Void)->CGImage? {
        let width=max(1,Int(ceil(size.width))),height=max(1,Int(ceil(size.height)))
        // An implicit NSImage drawing context may use extended 16-bit float
        // color. SceneKit then converts every footer through ColorSync/vImage
        // on the main thread. This UI artwork is SDR; rasterize directly in
        // explicit 8-bit linear sRGB and keep its pixels immutable for material upload.
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.linearSRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {return nil}
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
        draw(context,CGRect(origin:.zero,size:size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
