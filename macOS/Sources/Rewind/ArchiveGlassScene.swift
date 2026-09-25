import AppKit
import SceneKit
import SwiftUI
import simd

private final class ArchiveRecordControl: SCNNode {
    var recordID = ""
    var action = ""
}

/// Real, thick glass sheets in camera space. All racks share the same camera,
/// lighting and depth of field, so their edges converge consistently.
@MainActor final class ArchiveGlassScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private var nodes: [String:SCNNode] = [:]
    private struct Slot { let lane:Int; let depth:Double; let x:CGFloat; let z:CGFloat }
    private struct Extraction {
        var spring = ArchiveMotionSpring(value:0)
        var target:Double = 0
        let origin:SIMD3<Float>
        let destination:SIMD3<Float>
        let rotation:simd_quatf
    }
    private var slots:[String:Slot] = [:]
    private var heights:[String:ArchiveMotionSpring] = [:]
    private var extractions:[String:Extraction] = [:]
    private var coverTextures:[String:NSImage] = [:]
    private var currentID:String?
    private var frameKeys:[String] = []
    private var surfaceKeys:[String:String] = [:]
    private var night = false
    private var reducedMotion = false
    private var crest = ArchiveMotionSpring(value:0)
    private var crestTarget:Double = 0
    private var across = ArchiveMotionSpring(value:0)
    private var acrossTarget:Double = 0
    private var timer:Timer?
    private var previousTime:TimeInterval = 0
    private(set) var scrollOffset:CGFloat = 0
    private var horizontalOffset:CGFloat = 0
    private var maxScroll:CGFloat = 0
    var recordIDs:Set<String> { Set(nodes.keys) }
    var renderedCardCount:Int { scene.rootNode.childNode(withName:"racks",recursively:false)?.childNodes.count ?? 0 }
    private let cameraHome = SCNVector3(-12.9,17.7,22.2)
    private var target = SCNVector3(-1.9,5.4,0.2)

    init() {
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 4.5
        camera.zNear = 0.1; camera.zFar = 100
        camera.wantsHDR = true; camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.65
        camera.wantsDepthOfField = true
        camera.focusDistance = 33.5
        camera.fStop = 5.8
        camera.apertureBladeCount = 8
        camera.screenSpaceAmbientOcclusionIntensity = 0.5
        camera.screenSpaceAmbientOcclusionRadius = 0.2
        camera.bloomIntensity = 0.04; camera.bloomThreshold = 0.85; camera.bloomBlurRadius = 8
        cameraNode.camera = camera
        cameraNode.position = cameraHome
        cameraNode.look(at:target)
        scene.rootNode.addChildNode(cameraNode)
        let key = SCNNode(); key.light = SCNLight();key.light?.type = .directional
        key.light?.intensity = 850; key.light?.color = NSColor(red:1,green:0.95,blue:0.84,alpha:1)
        key.position = SCNVector3(-6,12,8); key.look(at:SCNVector3Zero)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .omni
        fill.light?.intensity = 260; fill.light?.color = NSColor(red:0.6,green:0.77,blue:1,alpha:1)
        fill.position = SCNVector3(10,7,-4);scene.rootNode.addChildNode(fill)
        let ambient = SCNNode();ambient.light = SCNLight();ambient.light?.type = .ambient
        ambient.light?.intensity = 320; ambient.light?.color = NSColor.white
        scene.rootNode.addChildNode(ambient)
        scene.lightingEnvironment.contents = Self.environment()
        scene.lightingEnvironment.intensity = 0.85
        scene.background.contents = NSColor.clear
        scene.fogStartDistance = 36; scene.fogEndDistance = 49
        scene.fogColor = NSColor(red:0.90,green:0.89,blue:0.86,alpha:1)
    }

    func update(frames:[MemoryFrame],images:[String:NSImage],appearance:OverlayAppearance,selected:String?,size:CGSize,reduced:Bool) {
        reducedMotion = reduced
        let isNight = appearance == .deepNight
        scene.fogColor = isNight ? NSColor(red:0.04,green:0.05,blue:0.07,alpha:1):NSColor(red:0.90,green:0.89,blue:0.86,alpha:1)
        let keys = frames.map { "\($0.id)|\($0.imagePath)|\($0.starred)|\(images[$0.imagePath] == nil ? 0:1)" }
        if keys != frameKeys || isNight != night {
            frameKeys = keys;night = isNight
            reconcile(frames:frames,images:images)
        }
        cameraNode.camera?.orthographicScale = 4.5*2.22/max(1,size.width/max(1,size.height))
        if selected != currentID {
            if let previous = currentID,var motion = extractions[previous] {
                motion.target = 0;extractions[previous] = motion
            }
            if let selected,let node = nodes[selected] {
                if var motion = extractions[selected] {
                    motion.target = 1;extractions[selected] = motion
                } else {
                    let destination = cameraNode.convertPosition(SCNVector3(0,0,-14),to:nil)
                    extractions[selected] = Extraction(target:1,origin:node.simdPosition,
                        destination:SIMD3(Float(destination.x),Float(destination.y),Float(destination.z)),rotation:cameraNode.simdOrientation)
                }
            }
            currentID = selected
            if reduced { advance(dt:1,immediate:true) } else { wake() }
        }
    }

    /// Reconcile by record ID. Loading thumbnails or starring a record must
    /// never replace its moving root node or restart an extraction.
    private func reconcile(frames:[MemoryFrame],images:[String:NSImage]) {
        SCNTransaction.begin();SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        let rack:SCNNode
        if let existing = scene.rootNode.childNode(withName:"racks",recursively:false) { rack = existing }
        else { rack = SCNNode();rack.name = "racks";scene.rootNode.addChildNode(rack) }
        let ids = Set(frames.map(\.id))
        for id in Array(nodes.keys) where !ids.contains(id) {
            nodes.removeValue(forKey:id)?.removeFromParentNode();slots[id] = nil;heights[id] = nil;extractions[id] = nil;surfaceKeys[id] = nil
        }
        let imageKeys = Set(images.values.flatMap { image in ["\(ObjectIdentifier(image))-true-\(night)","\(ObjectIdentifier(image))-false-\(night)"] })
        coverTextures = coverTextures.filter { imageKeys.contains($0.key) }
        let lanes = [0,-1,1,-2,2]
        maxScroll = max(0,CGFloat((frames.count-1)/5)-3)
        scrollOffset = min(scrollOffset,maxScroll)
        for (index,frame) in frames.enumerated() {
            let lane = lanes[index%5],row = index/5
            let depth = Double(row)-(lane == 0 ? 0:lane < 0 ? 3.5:1.5)
            let slot = Slot(lane:lane,depth:depth,x:CGFloat(lane)*(lane < 0 ? 5.65:6.25),z:CGFloat(depth)-5)
            slots[frame.id] = slot
            let surfaceKey = "\(frame.imagePath)|\(frame.starred)|\(night)|\(lane)|\(images[frame.imagePath].map { String(describing:ObjectIdentifier($0)) } ?? "pending")"
            guard surfaceKeys[frame.id] != surfaceKey else { continue }
            surfaceKeys[frame.id] = surfaceKey
            let surface = makeSheet(frame:frame,image:images[frame.imagePath],side:lane != 0,lane:lane)
            if let node = nodes[frame.id] {
                node.childNodes.forEach { $0.removeFromParentNode() }
                for child in surface.childNodes { child.removeFromParentNode();node.addChildNode(child) }
            } else {
                surface.name = frame.id;rack.addChildNode(surface);nodes[frame.id] = surface
                let height = ArchiveRidgeProfile.height(lane:Double(lane),depth:depth,crest:crest.value,across:across.value)
                heights[frame.id] = ArchiveMotionSpring(value:height)
                surface.position = SCNVector3(slot.x,CGFloat(height),slot.z)
            }
        }
        placeCamera()
    }

    func hover(_ id:String?) {
        guard !reducedMotion,currentID == nil else { return }
        if let id,let slot = slots[id] {
            crestTarget = slot.depth;acrossTarget = Double(slot.lane)
        } else { crestTarget = Double(scrollOffset);acrossTarget = 0 }
        wake()
    }
    func pointer(at point:CGPoint) {
        guard !reducedMotion,currentID == nil else { return }
        // Continuous input between card boundaries avoids a stepped hover wave.
        crestTarget = Double(scrollOffset)+Double(point.x-0.46)*8+Double(0.54-point.y)*5
        acrossTarget = Double(point.x-0.5)*3
        wake()
    }
    private func placeCamera() {
        let dx = horizontalOffset*0.894,dz = scrollOffset+horizontalOffset*0.447
        cameraNode.position = SCNVector3(cameraHome.x+dx,cameraHome.y,cameraHome.z+dz)
        cameraNode.look(at:SCNVector3(target.x+dx,target.y,target.z+dz))
    }
    func scroll(by delta:CGFloat,horizontal:CGFloat = 0,precise:Bool) {
        guard currentID == nil,extractions.isEmpty else { return }
        let next = min(maxScroll,max(0,scrollOffset+delta*(precise ? 0.018:0.42)))
        let nextHorizontal = min(8,max(-8,horizontalOffset+horizontal*(precise ? 0.018:0.42)))
        guard next != scrollOffset || nextHorizontal != horizontalOffset else { return }
        scrollOffset = next;horizontalOffset = nextHorizontal
        crestTarget = Double(next)+Double(delta)*(precise ? 0.025:0.16)
        acrossTarget = Double(nextHorizontal)*0.12
        SCNTransaction.begin();SCNTransaction.animationDuration = reducedMotion ? 0:precise ? 0.12:0.28
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name:.easeOut)
        placeCamera();SCNTransaction.commit()
        if reducedMotion { advance(dt:1,immediate:true) } else { wake() }
    }
    private func wake() {
        guard timer == nil else { return }
        previousTime = ProcessInfo.processInfo.systemUptime
        let source = Timer(timeInterval:1/60,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.advance(dt:min(1/20,max(1/240,now-self.previousTime)))
                self.previousTime = now
            }
        }
        timer = source;RunLoop.main.add(source,forMode:.common)
    }
    func stopMotion() { timer?.invalidate();timer = nil }

    /// One clock drives the ridge, the extraction and the return. Geometry,
    /// artwork and controls stay attached to the same opaque root throughout.
    func advance(dt:Double,immediate:Bool = false) {
        SCNTransaction.begin();SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        if immediate { crest = ArchiveMotionSpring(value:crestTarget);across = ArchiveMotionSpring(value:acrossTarget) }
        else { crest.step(to:crestTarget,frequency:8,dt:dt);across.step(to:acrossTarget,frequency:7,dt:dt) }
        var active = !crest.settled(at:crestTarget) || !across.settled(at:acrossTarget)
        var focus:Double = 0
        for (id,node) in nodes {
            guard let slot = slots[id],var height = heights[id] else { continue }
            let wanted = ArchiveRidgeProfile.height(lane:Double(slot.lane),depth:slot.depth,crest:crest.value,across:across.value)
            if extractions[id] == nil {
                if immediate { height = ArchiveMotionSpring(value:wanted) }
                else { height.step(to:wanted,frequency:9-Double(abs(slot.lane))*0.9,dt:dt) }
                node.position = SCNVector3(slot.x,CGFloat(height.value),slot.z)
                active = active || !height.settled(at:wanted)
                heights[id] = height
            }
            if var motion = extractions[id] {
                if immediate { motion.spring = ArchiveMotionSpring(value:motion.target) }
                else { motion.spring.step(to:motion.target,frequency:6.5,dt:dt) }
                let p = Float(max(0,min(1,motion.spring.value)))
                node.simdPosition = ArchiveExtractionPath.position(from:motion.origin,to:motion.destination,progress:p)
                let rotation = ArchiveExtractionPath.rotationProgress(p)
                node.simdOrientation = simd_slerp(simd_quatf(angle:0,axis:SIMD3(0,1,0)),motion.rotation,rotation)
                node.simdScale = SIMD3(repeating:1+0.12*rotation)
                focus = max(focus,Double(p))
                active = active || !motion.spring.settled(at:motion.target)
                if motion.target == 0,motion.spring.settled(at:0) {
                    node.simdPosition = motion.origin;node.simdOrientation = simd_quatf(angle:0,axis:SIMD3(0,1,0));node.simdScale = SIMD3(repeating:1)
                    heights[id] = ArchiveMotionSpring(value:Double(motion.origin.y));extractions[id] = nil
                    active = true
                } else { extractions[id] = motion }
            }
        }
        cameraNode.camera?.focusDistance = 33.5-19.5*focus
        cameraNode.camera?.fStop = 5.8+58.2*focus
        if !active { stopMotion() }
    }
    func action(at hit:SCNHitTestResult)->(String,String)? {
        guard let control = hit.node as? ArchiveRecordControl,control.recordID == currentID,
              (extractions[control.recordID]?.spring.value ?? 0) > 0.98 else { return nil }
        return (control.recordID,control.action)
    }

    private func makeSheet(frame:MemoryFrame,image:NSImage?,side:Bool,lane:Int)->SCNNode {
        let width:CGFloat = 5.35, height:CGFloat = 6.5
        let root = SCNNode()
        let glass = SCNBox(width:width,height:height,length:0.075,chamferRadius:0.025)
        let front = SCNMaterial()
        front.lightingModel = .physicallyBased
        front.diffuse.contents = Self.glassTexture(night:night,side:side,lane:lane)
        front.transparency = side ? 0.75:0.86; front.transparencyMode = .dualLayer
        front.metalness.contents = 0.12; front.roughness.contents = side ? 0.42:0.24
        front.specular.contents = NSColor.white
        front.fresnelExponent = 2.5
        let edge = SCNMaterial();edge.lightingModel = .physicallyBased
        edge.diffuse.contents = night ? NSColor(white:0.25,alpha:1):NSColor(red:0.83,green:0.84,blue:0.81,alpha:1)
        edge.metalness.contents = 0.35;edge.roughness.contents = 0.30
        glass.materials = [front,edge,front,edge,edge,edge]
        root.addChildNode(SCNNode(geometry:glass))
        // A fixed frosted finish softens the screenshot into its glass sleeve.
        // The same artwork remains attached during extraction and return.
        if let image {
            let art = SCNPlane(width:width*0.76,height:height*0.81)
            let material = SCNMaterial(); material.lightingModel = .constant
            let key = "\(ObjectIdentifier(image))-\(side)-\(night)"
            if coverTextures[key] == nil { coverTextures[key] = Self.expandedTexture(image,night:night,side:side) }
            material.diffuse.contents = coverTextures[key]
            material.isDoubleSided = false
            art.materials = [material]
            let node = SCNNode(geometry:art);node.position = SCNVector3(0,0.5,0.045)
            root.addChildNode(node)
        }
        let info = SCNPlane(width:4.62,height:1.35)
        let infoMaterial = SCNMaterial();infoMaterial.lightingModel = .constant
        infoMaterial.diffuse.contents = Self.informationTexture(frame,night:night)
        info.materials = [infoMaterial]
        let information = SCNNode(geometry:info);information.position = SCNVector3(0,-2.35,0.055)
        root.addChildNode(information)
        for (action,x,width) in [("star",-2.0,0.48),("copy",-1.35,0.48),("rewind",1.4,1.6),("close",2.0,0.48)] {
            let region = SCNPlane(width:width,height:action == "close" ? 0.40:0.44)
            let material = SCNMaterial();material.lightingModel = .constant
            material.diffuse.contents = NSColor.white.withAlphaComponent(0.001)
            material.writesToDepthBuffer = false;region.materials = [material]
            let control = ArchiveRecordControl();control.geometry = region
            control.position = SCNVector3(x,action == "close" ? -1.90:-2.84,0.07)
            control.recordID = frame.id;control.action = action
            root.addChildNode(control)
        }
        let rim = SCNBox(width:0.038,height:height-0.025,length:0.085,chamferRadius:0.014)
        let rimMaterial = SCNMaterial();rimMaterial.lightingModel = .constant
        rimMaterial.diffuse.contents = night ? NSColor(white:0.55,alpha:1):NSColor(white:1,alpha:1)
        rim.materials = [rimMaterial]
        let rimNode = SCNNode(geometry:rim);rimNode.position.x = -width/2+0.025;root.addChildNode(rimNode)
        return root
    }

    private static var textureCache: [String:NSImage] = [:]
    private static func glassTexture(night:Bool,side:Bool,lane:Int)->NSImage {
        let key = "\(night)-\(side)-\(lane > 0)"
        if let cached = textureCache[key] { return cached }
        let image = NSImage(size:NSSize(width:256,height:320),flipped:false) { rect in
            let colors:[NSColor]
            if night { colors = [NSColor(white:0.10,alpha:1),NSColor(white:0.2,alpha:1),NSColor(white:0.07,alpha:1),NSColor(white:0.36,alpha:1)] }
            else { colors = [NSColor(red:0.91,green:0.88,blue:0.78,alpha:1),NSColor(red:0.80,green:0.82,blue:0.80,alpha:1),lane > 0 ? NSColor(red:0.56,green:0.70,blue:0.82,alpha:1):NSColor(red:0.43,green:0.44,blue:0.47,alpha:1),NSColor(white:0.90,alpha:1)] }
            NSGradient(colorsAndLocations:(colors[0],0),(colors[1],0.65),(colors[2],0.95),(colors[3],1))!.draw(in:rect,angle:90)
            return true
        }
        textureCache[key] = image; return image
    }
    private static func expandedTexture(_ source:NSImage,night:Bool,side:Bool)->NSImage {
        NSImage(size:NSSize(width:1024,height:1200),flipped:false) { rect in
            (night ? NSColor(red:0.1,green:0.13,blue:0.18,alpha:1):NSColor(red:0.89,green:0.88,blue:0.82,alpha:1)).setFill();rect.fill()
            let scale = min(rect.width/source.size.width,rect.height/source.size.height)
            let width = source.size.width*scale,height = source.size.height*scale
            source.draw(in:NSRect(x:(rect.width-width)/2,y:rect.height-height,width:width,height:height),from:.zero,operation:.sourceOver,fraction:1)
            // Fixed frosted glazing travels with the artwork; opening never
            // substitutes another texture or fades a second card into place.
            let tint = night ? NSColor(white:0.14,alpha:1):NSColor(red:0.88,green:0.90,blue:0.90,alpha:1)
            NSGradient(colorsAndLocations:(tint.withAlphaComponent(side ? 0.48:0.12),0),(tint.withAlphaComponent(side ? 0.65:0.25),0.7),(tint.withAlphaComponent(0.75),1))!.draw(in:rect,angle:270)
            return true
        }
    }
    private static func informationTexture(_ frame:MemoryFrame,night:Bool)->NSImage {
        NSImage(size:NSSize(width:1024,height:300),flipped:false) { rect in
            let ink = night ? NSColor(white:0.92,alpha:1):NSColor(white:0.17,alpha:1)
            let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
            func text(_ value:String,x:CGFloat,y:CGFloat,width:CGFloat,size:CGFloat,bold:Bool = false) {
                (value as NSString).draw(in:NSRect(x:x,y:y,width:width,height:size*1.8),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:bold ? .semibold:.regular),.foregroundColor:ink,.paragraphStyle:paragraph])
            }
            text(frame.appName.uppercased(),x:18,y:225,width:820,size:22)
            text(frame.title.isEmpty ? frame.appName:frame.title,x:18,y:148,width:970,size:32,bold:true)
            text(frame.timeLabel,x:18,y:94,width:970,size:23)
            text("↗  回到此刻",x:690,y:16,width:310,size:25,bold:true)
            for (name,x,y) in [(frame.starred ? "star.fill":"star",CGFloat(36),CGFloat(22)),("doc.on.doc",CGFloat(180),CGFloat(22)),("arrow.up.left.and.arrow.down.right",CGFloat(942),CGFloat(232))] {
                let icon = NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:30,weight:.regular))
                icon?.draw(in:NSRect(x:x,y:y,width:36,height:36))
            }
            return true
        }
    }
    private static func environment()->NSImage {
        NSImage(size:NSSize(width:1024,height:512),flipped:false) { rect in
            NSColor(white:0.66,alpha:1).setFill();rect.fill()
            NSGradient(colors:[NSColor(white:0.20,alpha:1),NSColor(white:0.95,alpha:1),NSColor(white:0.6,alpha:1)])!.draw(in:rect,angle:90)
            NSColor.white.setFill();NSBezierPath(rect:NSRect(x:170,y:190,width:110,height:320)).fill()
            NSColor(red:0.56,green:0.70,blue:0.90,alpha:1).setFill();NSBezierPath(rect:NSRect(x:720,y:100,width:180,height:330)).fill()
            return true
        }
    }
}

private final class ArchiveSceneView: SCNView {
    var onSelect: ((String?)->Void)?
    var onHover: ((String?)->Void)?
    var onPointer: ((CGPoint)->Void)?
    var onAction: ((SCNHitTestResult)->Bool)?
    var onScroll: ((CGFloat,CGFloat,Bool)->Void)?
    private var pressPoint: CGPoint?
    private var dragged = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseMoved(with event:NSEvent) {
        let p = convert(event.locationInWindow,from:nil)
        onPointer?(CGPoint(x:p.x/max(1,bounds.width),y:p.y/max(1,bounds.height)))
    }
    override func mouseExited(with event:NSEvent) { onHover?(nil) }
    override func scrollWheel(with event:NSEvent) {
        onScroll?(-event.scrollingDeltaY,-event.scrollingDeltaX,event.hasPreciseScrollingDeltas)
    }
    override func mouseDown(with event:NSEvent) { pressPoint = event.locationInWindow;dragged = false }
    override func mouseDragged(with event:NSEvent) {
        guard let previous = pressPoint else { return }
        let p = event.locationInWindow
        if dragged || hypot(p.x-previous.x,p.y-previous.y) > 4 {
            dragged = true;onScroll?(p.y-previous.y,previous.x-p.x,true);pressPoint = p
        }
    }
    override func mouseUp(with event:NSEvent) {
        if !dragged {
            let point = convert(event.locationInWindow,from:nil)
            let hit = hitTest(point,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue]).first
            if let hit,onAction?(hit) == true { } else { onSelect?(memoryID(at:point)) }
        }
        pressPoint = nil;dragged = false
    }
    private func memoryID(at p:CGPoint)->String? {
        for result in hitTest(p,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue]) {
            var node:SCNNode? = result.node
            while let current = node {
                if let id = current.name,id != "racks" { return id }
                node = current.parent
            }
        }
        return nil
    }
}

struct ArchiveGlassRenderer: NSViewRepresentable {
    let frames:[MemoryFrame]
    let images:[String:NSImage]
    let appearance:OverlayAppearance
    let selected:String?
    let size:CGSize
    let reduced:Bool
    let onSelect:(String?)->Void
    let onRecordAction:(String,String)->Void
    func makeCoordinator()->ArchiveGlassScene { ArchiveGlassScene() }
    func makeNSView(context:Context)->SCNView {
        let view = ArchiveSceneView()
        view.scene = context.coordinator.scene;view.pointOfView = context.coordinator.cameraNode
        view.backgroundColor = .clear;view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false;view.isPlaying = true
        view.onSelect = onSelect
        view.onHover = { [weak coordinator = context.coordinator] id in coordinator?.hover(id) }
        view.onPointer = { [weak coordinator = context.coordinator] point in coordinator?.pointer(at:point) }
        view.onAction = { [weak coordinator = context.coordinator] hit in
            guard let (id,action) = coordinator?.action(at:hit) else { return false }
            onRecordAction(id,action);return true
        }
        view.onScroll = { [weak coordinator = context.coordinator] delta,horizontal,precise in coordinator?.scroll(by:delta,horizontal:horizontal,precise:precise) }
        return view
    }
    static func dismantleNSView(_ view:SCNView,coordinator:ArchiveGlassScene) { coordinator.stopMotion() }
    func updateNSView(_ view:SCNView,context:Context) {
        (view as? ArchiveSceneView)?.onSelect = onSelect
        (view as? ArchiveSceneView)?.onAction = { [weak coordinator = context.coordinator] hit in
            guard let (id,action) = coordinator?.action(at:hit) else { return false }
            onRecordAction(id,action);return true
        }
        context.coordinator.update(frames:frames,images:images,appearance:appearance,selected:selected,size:size,reduced:reduced)
    }
}
