import AppKit
import SceneKit
import SwiftUI
import simd

/// Real, thick glass sheets in camera space. All racks share the same camera,
/// lighting and depth of field, so their edges converge consistently.
@MainActor final class ArchiveGlassScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private var nodes: [String:SCNNode] = [:]
    private var homes: [String:SCNVector3] = [:]
    private var coverTextures: [String:NSImage] = [:]
    private var originalCovers: [String:Any] = [:]
    private var sourceImages: [String:NSImage] = [:]
    private var hoveredID: String?
    private var reducedMotion = false
    private var currentID: String?
    private var frameKeys: [String] = []
    private var night = false
    private(set) var scrollOffset: CGFloat = 0
    private var maxScroll: CGFloat = 0
    private var horizontalOffset: CGFloat = 0
    var recordIDs: Set<String> { Set(nodes.keys) }
    var renderedCardCount: Int { scene.rootNode.childNode(withName:"racks",recursively:false)?.childNodes.count ?? 0 }
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
        camera.fStop = 10
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
        let keys = frames.map { $0.id+"|"+$0.imagePath+"|"+(images[$0.imagePath] == nil ? "0":"1") }
        let rebuilt = keys != frameKeys || isNight != night
        if rebuilt {
            frameKeys = keys;night = isNight
            rebuild(frames:frames,images:images)
            currentID = nil
        }
        let ratio = max(1,size.width/max(1,size.height))
        cameraNode.camera?.orthographicScale = 4.5 * 2.22/ratio
        // SceneKit's orthographicScale is the vertical visible span.
        if selected != currentID {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = reduced || rebuilt ? 0:0.85
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints:0.22,0.78,0.18,1)
            for (id,node) in nodes where id == selected || id == currentID {
                guard let home = homes[id] else { continue }
                let opening = id == selected
                let destination = opening ? cameraNode.convertPosition(SCNVector3(0,0,-14),to:nil):home
                let rotation = opening ? cameraNode.orientation:SCNQuaternion(0,0,0,1)
                if let material = node.childNodes.first(where: { $0.geometry is SCNPlane })?.geometry?.firstMaterial {
                    material.diffuse.contents = opening ? sourceImages[id].map { Self.expandedTexture($0,night:night) }:originalCovers[id]
                }
                slide(node,to:destination,orientation:rotation,expanded:opening,immediate:reduced || rebuilt)
            }
            cameraNode.camera?.wantsDepthOfField = selected == nil
            cameraNode.camera?.focusDistance = selected == nil ? 33.5:14
            SCNTransaction.commit()
            currentID = selected
        }
    }

    func hover(_ id:String?) {
        guard !reducedMotion,currentID == nil,id != hoveredID else { return }
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.32
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name:.easeOut)
        if let previous = hoveredID,let home = homes[previous] { nodes[previous]?.position = home }
        if let id,let home = homes[id] { nodes[id]?.position = SCNVector3(home.x,home.y+0.18,home.z) }
        SCNTransaction.commit();hoveredID = id
    }

    private func rebuild(frames:[MemoryFrame],images:[String:NSImage]) {
        scene.rootNode.childNodes.filter { $0.name == "racks" }.forEach { $0.removeFromParentNode() }
        nodes.removeAll(); homes.removeAll(); coverTextures.removeAll();originalCovers.removeAll();sourceImages.removeAll()
        let rack = SCNNode();rack.name = "racks";scene.rootNode.addChildNode(rack)
        // Every item is one distinct real screenshot. No decorative copies,
        // placeholder sleeves, generated records or repeated side-rack art.
        let lanes = [0,-1,1,-2,2]
        maxScroll = max(0,CGFloat((frames.count-1)/5)-3)
        scrollOffset = min(scrollOffset,maxScroll)
        for (index,frame) in frames.enumerated() {
            let lane = lanes[index%lanes.count], row = index/lanes.count
            let sheet = makeSheet(image:images[frame.imagePath],side:lane != 0,serial:row,lane:lane)
            let depth = CGFloat(row)-(lane == 0 ? 0:lane < 0 ? 3.5:6)
            let spacing:CGFloat = lane < 0 ? 5.65:6.25
            sheet.position = SCNVector3(CGFloat(lane)*spacing,lane == 0 ? 1.15:lane < 0 ? 0.35:-1.25,depth-5)
            if index == 0 { sheet.position.y = 2.65 }
            sheet.name = frame.id
            rack.addChildNode(sheet)
            nodes[frame.id] = sheet; homes[frame.id] = sheet.position
            sourceImages[frame.id] = images[frame.imagePath]
            originalCovers[frame.id] = sheet.childNodes.first(where: { $0.geometry is SCNPlane })?.geometry?.firstMaterial?.diffuse.contents
        }
        placeCamera()
    }

    private func placeCamera() {
        let dx = horizontalOffset*0.894,dz = scrollOffset+horizontalOffset*0.447
        cameraNode.position = SCNVector3(cameraHome.x+dx,cameraHome.y,cameraHome.z+dz)
        cameraNode.look(at:SCNVector3(target.x+dx,target.y,target.z+dz))
    }
    func scroll(by delta:CGFloat,horizontal:CGFloat = 0,precise:Bool) {
        guard currentID == nil else { return }
        hover(nil)
        let next = min(maxScroll,max(0,scrollOffset+delta*(precise ? 0.018:0.42)))
        let nextHorizontal = min(8,max(-8,horizontalOffset+horizontal*(precise ? 0.018:0.42)))
        guard next != scrollOffset || nextHorizontal != horizontalOffset else { return }
        scrollOffset = next;horizontalOffset = nextHorizontal
        SCNTransaction.begin()
        SCNTransaction.animationDuration = reducedMotion ? 0:precise ? 0.12:0.28
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name:.easeOut)
        placeCamera()
        SCNTransaction.commit()
    }

    /// Interrupt from the presentation transform, so reversing a half-finished
    /// slide never teleports back to either endpoint. Both paths clear the rack.
    private func slide(_ node:SCNNode,to end:SCNVector3,orientation:SCNQuaternion,expanded:Bool,immediate:Bool) {
        SCNTransaction.begin();SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        let start = node.presentation.simdPosition
        let rotation = node.presentation.simdOrientation
        let scale = node.presentation.simdScale
        node.removeAction(forKey:"archive-slide")
        node.simdPosition = start;node.simdOrientation = rotation;node.simdScale = scale
        let finish = SIMD3<Float>(Float(end.x),Float(end.y),Float(end.z))
        let finalRotation = simd_quatf(ix:Float(orientation.x),iy:Float(orientation.y),iz:Float(orientation.z),r:Float(orientation.w))
        let finalScale = SIMD3<Float>(repeating:expanded ? 1.12:1)
        if immediate { node.simdPosition = finish;node.simdOrientation = finalRotation;node.simdScale = finalScale;return }
        let first = start+SIMD3<Float>(0,expanded ? 1.6:0.6,expanded ? 2:-1)
        let second = finish+SIMD3<Float>(0,expanded ? 0.6:1.6,expanded ? -1:2)
        let action = SCNAction.customAction(duration:0.88) { node,elapsed in
            let time = min(1,Float(elapsed/0.88))
            let t = time*time*(3-2*time),u = 1-t
            node.simdPosition = u*u*u*start+3*u*u*t*first+3*u*t*t*second+t*t*t*finish
            node.simdOrientation = simd_slerp(rotation,finalRotation,t)
            node.simdScale = scale+(finalScale-scale)*t
        }
        node.runAction(action,forKey:"archive-slide")
    }

    private func makeSheet(image:NSImage?,side:Bool,serial:Int,lane:Int)->SCNNode {
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
        // The cover sits behind a second translucent diffusion layer. Its lower
        // half disappears into milk glass instead of reading as a flat poster.
        if let image {
            let art = SCNPlane(width:width*0.76,height:height*0.81)
            let material = SCNMaterial(); material.lightingModel = .constant
            let key = "\(ObjectIdentifier(image))-\(side)"
            if coverTextures[key] == nil { coverTextures[key] = Self.coverTexture(image,night:night,side:side) }
            material.diffuse.contents = coverTextures[key]
            material.isDoubleSided = false
            art.materials = [material]
            let node = SCNNode(geometry:art);node.position = SCNVector3(0,0.5,0.045)
            root.addChildNode(node)
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
    private static func coverTexture(_ source:NSImage,night:Bool,side:Bool)->NSImage {
        NSImage(size:NSSize(width:512,height:600),flipped:false) { rect in
            let cropWidth = min(source.size.width,source.size.height*rect.width/rect.height)
            let cropHeight = min(source.size.height,source.size.width*rect.height/rect.width)
            let crop = NSRect(x:(source.size.width-cropWidth)/2,y:source.size.height-cropHeight,width:cropWidth,height:cropHeight)
            source.draw(in:rect,from:crop,operation:.sourceOver,fraction:side ? 0.42:1)
            let milk = night ? NSColor(red:0.1,green:0.13,blue:0.18,alpha:1):NSColor(red:0.89,green:0.88,blue:0.82,alpha:1)
            NSGradient(colorsAndLocations:(milk.withAlphaComponent(0.98),0),(milk.withAlphaComponent(side ? 0.8:0.40),0.58),(milk.withAlphaComponent(0),0.94))!.draw(in:rect,angle:90)
            return true
        }
    }
    private static func expandedTexture(_ source:NSImage,night:Bool)->NSImage {
        NSImage(size:NSSize(width:1024,height:1200),flipped:false) { rect in
            (night ? NSColor(red:0.1,green:0.13,blue:0.18,alpha:1):NSColor(red:0.89,green:0.88,blue:0.82,alpha:1)).setFill();rect.fill()
            let scale = min(rect.width/source.size.width,rect.height/source.size.height)
            let width = source.size.width*scale,height = source.size.height*scale
            source.draw(in:NSRect(x:(rect.width-width)/2,y:rect.height-height,width:width,height:height),from:.zero,operation:.sourceOver,fraction:1)
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
    var onScroll: ((CGFloat,CGFloat,Bool)->Void)?
    private var pressPoint: CGPoint?
    private var dragged = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseMoved(with event:NSEvent) { onHover?(memoryID(at:convert(event.locationInWindow,from:nil))) }
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
        if !dragged { onSelect?(memoryID(at:convert(event.locationInWindow,from:nil))) }
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
    func makeCoordinator()->ArchiveGlassScene { ArchiveGlassScene() }
    func makeNSView(context:Context)->SCNView {
        let view = ArchiveSceneView()
        view.scene = context.coordinator.scene;view.pointOfView = context.coordinator.cameraNode
        view.backgroundColor = .clear;view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false;view.isPlaying = true
        view.onSelect = onSelect
        view.onHover = { [weak coordinator = context.coordinator] id in coordinator?.hover(id) }
        view.onScroll = { [weak coordinator = context.coordinator] delta,horizontal,precise in coordinator?.scroll(by:delta,horizontal:horizontal,precise:precise) }
        return view
    }
    func updateNSView(_ view:SCNView,context:Context) {
        (view as? ArchiveSceneView)?.onSelect = onSelect
        context.coordinator.update(frames:frames,images:images,appearance:appearance,selected:selected,size:size,reduced:reduced)
    }
}
