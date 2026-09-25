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
    private var depths:[String:ArchiveMotionSpring] = [:]
    private var extractions:[String:Extraction] = [:]
    private var framesByID:[String:MemoryFrame] = [:]
    private var imageAspects:[String:CGFloat] = [:]
    private var blankIDs = Set<String>()
    private var anchorDay:Date?
    private var viewport = CGSize(width:2000,height:876)
    var onPresentationChanged:(()->Void)?
    private(set) var dayColumns:[ArchiveDayColumn] = []
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
    var recordIDs:Set<String> { Set(framesByID.keys) }
    var renderedCardCount:Int { nodes.count-blankIDs.count }
    var blankCardCount:Int { blankIDs.count }
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
        camera.screenSpaceAmbientOcclusionIntensity = 0.22
        camera.screenSpaceAmbientOcclusionRadius = 0.2
        camera.bloomIntensity = 0.045; camera.bloomThreshold = 0.85; camera.bloomBlurRadius = 8
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

    func update(frames:[MemoryFrame],images:[String:NSImage],appearance:OverlayAppearance,selected:String?,size:CGSize,reduced:Bool,day:Date? = nil) {
        reducedMotion = reduced;viewport = size
        cameraNode.camera?.orthographicScale = 4.5*2.22/max(1,size.width/max(1,size.height))
        let isNight = appearance == .deepNight
        scene.fogColor = isNight ? NSColor(red:0.04,green:0.05,blue:0.07,alpha:1):NSColor(red:0.90,green:0.89,blue:0.86,alpha:1)
        let center = Calendar.current.startOfDay(for:day ?? frames.max(by: { $0.timestamp < $1.timestamp })?.timestamp ?? Date())
        let keys = frames.map { "\($0.id)|\($0.imagePath)|\($0.starred)|\($0.regions.count)|\($0.ocrKey ?? "")|\(images[$0.imagePath].map { String(describing:ObjectIdentifier($0)) } ?? "pending")" }
        if keys != frameKeys || isNight != night || anchorDay != center {
            frameKeys = keys;night = isNight;anchorDay = center
            reconcile(frames:frames,images:images)
        }
        if selected != currentID {
            onPresentationChanged?()
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
        if let currentID,let node = nodes[currentID] { shape(node,id:currentID,progress:Float(extractions[currentID]?.spring.value ?? 0)) }
        onPresentationChanged?()
    }

    /// Reconcile by record ID. Loading thumbnails or starring a record must
    /// never replace its moving root node or restart an extraction.
    private func reconcile(frames:[MemoryFrame],images:[String:NSImage]) {
        SCNTransaction.begin();SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        let rack:SCNNode
        if let existing = scene.rootNode.childNode(withName:"racks",recursively:false) { rack = existing }
        else { rack = SCNNode();rack.name = "racks";scene.rootNode.addChildNode(rack) }
        dayColumns = ArchiveDayLayout.columns(frames:frames,around:anchorDay ?? Date())
        framesByID = Dictionary(uniqueKeysWithValues:dayColumns.flatMap(\.records).map { ($0.id,$0) })
        let rowCount = max(20,dayColumns.map { $0.records.count }.max() ?? 0)
        var entries:[(String,MemoryFrame?,Int,Double)] = []
        blankIDs.removeAll()
        for column in dayColumns {
            for row in -2..<(rowCount+2) {
                let frame = column.records.indices.contains(row) ? column.records[row]:nil
                let id = frame?.id ?? "blank:\(column.day.timeIntervalSince1970):\(row)"
                if frame == nil { blankIDs.insert(id) }
                entries.append((id,frame,column.lane,Double(row)))
            }
        }
        let ids = Set(entries.map { $0.0 })
        for id in Array(nodes.keys) where !ids.contains(id) {
            nodes.removeValue(forKey:id)?.removeFromParentNode();slots[id] = nil;heights[id] = nil;depths[id] = nil;extractions[id] = nil;surfaceKeys[id] = nil;imageAspects[id] = nil
        }
        maxScroll = max(0,CGFloat(rowCount)-3)
        scrollOffset = min(scrollOffset,maxScroll)
        for (id,frame,lane,row) in entries {
            let depth = row-(lane == 0 ? 0:lane < 0 ? 3.5:1.5)
            let slot = Slot(lane:lane,depth:depth,x:CGFloat(lane)*(lane < 0 ? 5.65:6.25),z:CGFloat(depth)-5)
            slots[id] = slot
            let image = frame.flatMap { images[$0.imagePath] }
            imageAspects[id] = image.map { $0.size.width/max(1,$0.size.height) } ?? imageAspects[id] ?? 1.6
            let surfaceKey = "\(frame?.imagePath ?? "empty")|\(frame?.starred ?? false)|\(night)|\(lane)|\(image.map { String(describing:ObjectIdentifier($0)) } ?? "pending")"
            guard surfaceKeys[id] != surfaceKey else { continue }
            surfaceKeys[id] = surfaceKey
            let surface = makeSheet(frame:frame,image:image,side:lane != 0,lane:lane)
            if let node = nodes[id] {
                node.childNodes.forEach { $0.removeFromParentNode() }
                for child in surface.childNodes { child.removeFromParentNode();node.addChildNode(child) }
            } else {
                surface.name = id;rack.addChildNode(surface);nodes[id] = surface
                let height = ArchiveRidgeProfile.height(lane:Double(lane),depth:depth,crest:crest.value,across:across.value)
                heights[id] = ArchiveMotionSpring(value:height)
                depths[id] = ArchiveMotionSpring(value:Double(slot.z))
                surface.position = SCNVector3(slot.x,CGFloat(height),slot.z)
            }
            if let node = nodes[id] { shape(node,id:id,progress:Float(extractions[id]?.spring.value ?? 0)) }
        }
        updateDayLabels()
        placeCamera()
        if reducedMotion { advance(dt:1,immediate:true) } else { wake() }
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
                var depth = depths[id] ?? ArchiveMotionSpring(value:Double(slot.z))
                if immediate { depth = ArchiveMotionSpring(value:Double(slot.z)) }
                else { depth.step(to:Double(slot.z),frequency:9,dt:dt) }
                depths[id] = depth
                node.position = SCNVector3(slot.x,CGFloat(height.value),CGFloat(depth.value))
                active = active || !depth.settled(at:Double(slot.z))
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
                shape(node,id:id,progress:p)
                focus = max(focus,Double(p))
                active = active || !motion.spring.settled(at:motion.target)
                if motion.target == 0,motion.spring.settled(at:0) {
                    node.simdPosition = motion.origin;node.simdOrientation = simd_quatf(angle:0,axis:SIMD3(0,1,0));node.simdScale = SIMD3(repeating:1)
                    shape(node,id:id,progress:0)
                    heights[id] = ArchiveMotionSpring(value:Double(motion.origin.y));extractions[id] = nil
                    active = true
                } else { extractions[id] = motion }
            }
        }
        cameraNode.camera?.focusDistance = 33.5-19.5*focus
        cameraNode.camera?.fStop = 5.8+58.2*focus
        onPresentationChanged?()
        if !active { stopMotion() }
    }
    func action(at hit:SCNHitTestResult)->(String,String)? {
        guard let control = hit.node as? ArchiveRecordControl,control.recordID == currentID,
              (extractions[control.recordID]?.spring.value ?? 0) > 0.98 else { return nil }
        return (control.recordID,control.action)
    }

    /// Native text selection uses these projected corners only when the same
    /// 3D artwork has finished rotating. No duplicate image overlay is needed.
    func selectionSurface()->(MemoryFrame,SCNNode,CGRect)? {
        guard let id = currentID,let frame = framesByID[id],let node = nodes[id],
              let motion = extractions[id],motion.target == 1,motion.spring.settled(at:1),
              let art = node.childNode(withName:"artwork",recursively:false),let plane = art.geometry as? SCNPlane else { return nil }
        return (frame,art,CGRect(x:-plane.width/2,y:-plane.height/2,width:plane.width,height:plane.height))
    }
    private func shape(_ node:SCNNode,id:String,progress:Float) {
        let aspect = imageAspects[id] ?? 1.6
        let t = CGFloat(ArchiveExtractionPath.smooth((progress-0.3)/0.7))
        let open = ArchiveCardMetrics.expanded(aspect:aspect,viewport:viewport,verticalSpan:CGFloat(cameraNode.camera?.orthographicScale ?? 4.5)*2)
        let width = 5.35+(open.width-5.35)*t,height = 6.5+(open.height-6.5)*t
        let layout = ArchiveCardMetrics.make(width:width,height:height,aspect:aspect)
        if let body = node.childNode(withName:"glass",recursively:false)?.geometry as? SCNBox { body.width = width;body.height = height }
        if let art = node.childNode(withName:"artwork",recursively:false),let plane = art.geometry as? SCNPlane {
            plane.width = layout.artwork.width;plane.height = layout.artwork.height
            art.position = SCNVector3(layout.artwork.midX,layout.artwork.midY,0.055)
        }
        if let info = node.childNode(withName:"information",recursively:false),let plane = info.geometry as? SCNPlane {
            plane.width = width-0.5;plane.height = 1.0;info.position = SCNVector3(0,-height/2+0.57,0.065)
        }
        for child in node.childNodes {
            if child.name == "rim",let box = child.geometry as? SCNBox { box.height = height-0.025;child.position.x = -width/2+0.025 }
            if child.name == "top-edge",let box = child.geometry as? SCNBox { box.width = width;child.position.y = height/2-0.01 }
            if let control = child as? ArchiveRecordControl {
                let w = width-0.5
                if let button = ArchiveFooterLayout.buttons(in:CGSize(width:w,height:1.0)).first(where: { $0.action == control.action }) {
                    control.position = SCNVector3(-w/2+button.rect.midX,-height/2+0.07+button.rect.midY,0.08)
                    (control.geometry as? SCNPlane)?.width = button.rect.width
                    (control.geometry as? SCNPlane)?.height = button.rect.height
                }
            }
        }
    }
    private func updateDayLabels() {
        scene.rootNode.childNode(withName:"dates",recursively:false)?.removeFromParentNode()
        let labels = SCNNode();labels.name = "dates";scene.rootNode.addChildNode(labels)
        let isNight = night
        for column in dayColumns {
            let image = NSImage(size:NSSize(width:800,height:80),flipped:false) { _ in
                let label = column.day.formatted(.dateTime.month(.twoDigits).day(.twoDigits))+"  ·  "+(column.records.isEmpty ? "暂无记录":"\(column.records.count) 张截图")
                (label as NSString).draw(at:NSPoint(x:12,y:22),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:27,weight:.medium),.foregroundColor:isNight ? NSColor.white:NSColor.darkGray])
                return true
            }
            let plane = SCNPlane(width:4.3,height:0.43),material = SCNMaterial();material.lightingModel = .constant;material.diffuse.contents = image;material.writesToDepthBuffer = false;plane.materials = [material]
            let label = SCNNode(geometry:plane);label.categoryBitMask = 2
            let lane = column.lane,depth = -(lane == 0 ? 0.0:lane < 0 ? 3.5:1.5)
            label.position = SCNVector3(CGFloat(lane)*(lane < 0 ? 5.65:6.25),CGFloat(ArchiveRidgeProfile.height(lane:Double(lane),depth:depth,crest:0))+3.65,CGFloat(depth)-5)
            label.orientation = cameraNode.orientation;labels.addChildNode(label)
        }
    }
    private func makeSheet(frame:MemoryFrame?,image:NSImage?,side:Bool,lane:Int)->SCNNode {
        let width:CGFloat = 5.35,height:CGFloat = 6.5
        let root = SCNNode()
        let glass = SCNBox(width:width,height:height,length:0.065,chamferRadius:0.022)
        let front = SCNMaterial();front.lightingModel = .physicallyBased
        front.diffuse.contents = Self.glassTexture(night:night,side:side,lane:lane)
        front.transparency = side ? 0.50:0.58;front.transparencyMode = .dualLayer
        front.metalness.contents = 0.04;front.roughness.contents = side ? 0.27:0.16
        front.specular.contents = NSColor.white;front.fresnelExponent = 4.0
        front.writesToDepthBuffer = false
        let edge = SCNMaterial();edge.lightingModel = .physicallyBased
        edge.diffuse.contents = night ? NSColor(white:0.6,alpha:0.7):NSColor(red:0.78,green:0.82,blue:0.84,alpha:0.48)
        edge.metalness.contents = 0.12;edge.roughness.contents = 0.12;edge.transparency = 0.5;edge.writesToDepthBuffer = false
        glass.materials = [front,edge,front,edge,edge,edge]
        let body = SCNNode(geometry:glass);body.name = "glass";root.addChildNode(body)
        if let image {
            let art = SCNPlane(width:4.87,height:3.0),material = SCNMaterial();material.lightingModel = .constant
            // Actual source pixels, without an opaque portrait canvas or tint.
            material.diffuse.contents = image;art.materials = [material]
            let node = SCNNode(geometry:art);node.name = "artwork";root.addChildNode(node)
        }
        if let frame {
            let info = SCNPlane(width:4.85,height:1.0),material = SCNMaterial();material.lightingModel = .constant
            let expanded = ArchiveCardMetrics.expanded(aspect:image.map { $0.size.width/max(1,$0.size.height) } ?? 1.6,viewport:viewport,verticalSpan:CGFloat(cameraNode.camera?.orthographicScale ?? 4.5)*2)
            material.diffuse.contents = Self.informationTexture(frame,night:night,aspect:(expanded.width-0.5)/1.0);info.materials = [material]
            let information = SCNNode(geometry:info);information.name = "information";root.addChildNode(information)
            for action in ["star","copy","rewind","close"] {
                let region = SCNPlane(width:0.48,height:0.26),material = SCNMaterial();material.lightingModel = .constant
                material.diffuse.contents = NSColor.white.withAlphaComponent(0.001);material.writesToDepthBuffer = false;region.materials = [material]
                let control = ArchiveRecordControl();control.geometry = region;control.recordID = frame.id;control.action = action;root.addChildNode(control)
            }
        }
        let rim = SCNBox(width:0.026,height:height-0.025,length:0.075,chamferRadius:0.012)
        let highlight = SCNMaterial();highlight.lightingModel = .constant
        highlight.diffuse.contents = NSColor(white:0.88,alpha:0.48);highlight.emission.contents = NSColor.black;highlight.roughness.contents = 0.08;highlight.metalness.contents = 0.25
        rim.materials = [highlight]
        let rimNode = SCNNode(geometry:rim);rimNode.name = "rim";root.addChildNode(rimNode)
        let top = SCNBox(width:width,height:0.016,length:0.075,chamferRadius:0.007);top.materials = [highlight]
        let topNode = SCNNode(geometry:top);topNode.name = "top-edge";root.addChildNode(topNode)
        if frame == nil { root.enumerateChildNodes { child,_ in child.categoryBitMask = 2 };root.categoryBitMask = 2 }
        return root
    }

    private static var textureCache: [String:NSImage] = [:]
    private static func glassTexture(night:Bool,side:Bool,lane:Int)->NSImage {
        let key = "\(night)-\(side)-\(lane > 0)"
        if let cached = textureCache[key] { return cached }
        let image = NSImage(size:NSSize(width:256,height:320),flipped:false) { rect in
            let colors:[NSColor]
            if night { colors = [NSColor(white:0.10,alpha:1),NSColor(white:0.2,alpha:1),NSColor(white:0.07,alpha:1),NSColor(white:0.36,alpha:1)] }
            else { colors = [NSColor(red:0.78,green:0.77,blue:0.71,alpha:0.5),NSColor(red:0.62,green:0.67,blue:0.70,alpha:0.22),lane > 0 ? NSColor(red:0.46,green:0.59,blue:0.70,alpha:0.55):NSColor(red:0.40,green:0.43,blue:0.49,alpha:0.5),NSColor(white:0.82,alpha:0.7)] }
            NSGradient(colorsAndLocations:(colors[0],0),(colors[1],0.65),(colors[2],0.95),(colors[3],1))!.draw(in:rect,angle:90)
            return true
        }
        textureCache[key] = image; return image
    }
    private static func informationTexture(_ frame:MemoryFrame,night:Bool,aspect:CGFloat)->NSImage {
        NSImage(size:NSSize(width:190*aspect,height:190),flipped:false) { rect in
            (night ? NSColor(white:0.10,alpha:0.65):NSColor(white:0.98,alpha:0.65)).setFill();rect.fill()
            let ink = night ? NSColor(white:0.94,alpha:1):NSColor(white:0.16,alpha:1)
            let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
            func text(_ value:String,x:CGFloat,y:CGFloat,width:CGFloat,size:CGFloat,bold:Bool = false) {
                (value as NSString).draw(in:NSRect(x:x,y:y,width:width,height:size*1.6),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:bold ? .semibold:.regular),.foregroundColor:ink,.paragraphStyle:paragraph])
            }
            text(frame.title.isEmpty ? frame.appName:frame.title,x:rect.width*0.016,y:119,width:rect.width*0.53,size:34,bold:true)
            text(frame.timeLabel,x:rect.width*0.60,y:121,width:rect.width*0.38,size:29)
            for button in ArchiveFooterLayout.buttons(in:rect.size) {
                let label:String,symbol:String
                switch button.action {
                case "star":label = frame.starred ? "已收藏":"收藏";symbol = frame.starred ? "star.fill":"star"
                case "copy":label = "复制文字";symbol = "doc.on.doc"
                case "rewind":label = "回到此刻";symbol = "arrow.up.right"
                default:label = "收起";symbol = "arrow.up.left.and.arrow.down.right"
                }
                let path = NSBezierPath(roundedRect:button.rect,xRadius:button.rect.height*0.28,yRadius:button.rect.height*0.28)
                (night ? NSColor.white.withAlphaComponent(0.06):NSColor.white.withAlphaComponent(0.36)).setFill();path.fill()
                ink.withAlphaComponent(0.13).setStroke();path.lineWidth = 1.5;path.stroke()
                let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:31,weight:.medium),.foregroundColor:ink]
                let labelSize = (label as NSString).size(withAttributes:attributes)
                let left = button.rect.midX-(labelSize.width+48)/2
                NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:32,weight:.regular))?.draw(in:NSRect(x:left,y:button.rect.midY-16,width:32,height:32))
                (label as NSString).draw(at:NSPoint(x:left+48,y:button.rect.midY-labelSize.height/2),withAttributes:attributes)
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
    let textOverlay = IndexedTextOverlay()
    var selectedRegions:[TextRegion] = []
    weak var archive:ArchiveGlassScene?
    override init(frame:NSRect,options:[String:Any]? = nil) {
        super.init(frame:frame,options:options)
        textOverlay.isHidden = true;addSubview(textOverlay)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout();updateTextSelection() }
    func updateTextSelection() {
        guard let (frame,art,rect) = archive?.selectionSurface() else { textOverlay.isHidden = true;return }
        let a = projectPoint(art.convertPosition(SCNVector3(rect.minX,rect.minY,0),to:nil))
        let b = projectPoint(art.convertPosition(SCNVector3(rect.maxX,rect.maxY,0),to:nil))
        let projected = NSRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y))
        CATransaction.begin();CATransaction.setDisableActions(true)
        textOverlay.frame = projected;textOverlay.imageSize = projected.size
        textOverlay.setRegions(selectedRegions.isEmpty ? frame.regions:selectedRegions)
        textOverlay.isHidden = false;CATransaction.commit()
    }
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
            let hit = hitTest(point,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue,.categoryBitMask:1]).first
            if let hit,onAction?(hit) == true { } else { onSelect?(memoryID(at:point)) }
        }
        pressPoint = nil;dragged = false
    }
    private func memoryID(at p:CGPoint)->String? {
        for result in hitTest(p,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue,.categoryBitMask:1]) {
            var node:SCNNode? = result.node
            while let current = node {
                if current.parent?.name == "racks",let id = current.name,!id.hasPrefix("blank:") { return id }
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
    var day:Date? = nil
    var regions:[TextRegion] = []
    let size:CGSize
    let reduced:Bool
    let onSelect:(String?)->Void
    let onRecordAction:(String,String)->Void
    func makeCoordinator()->ArchiveGlassScene { ArchiveGlassScene() }
    func makeNSView(context:Context)->SCNView {
        let view = ArchiveSceneView(frame:.zero)
        view.archive = context.coordinator
        context.coordinator.onPresentationChanged = { [weak view] in view?.updateTextSelection() }
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
    static func dismantleNSView(_ view:SCNView,coordinator:ArchiveGlassScene) { coordinator.stopMotion();coordinator.onPresentationChanged = nil }
    func updateNSView(_ view:SCNView,context:Context) {
        (view as? ArchiveSceneView)?.onSelect = onSelect
        (view as? ArchiveSceneView)?.selectedRegions = regions
        (view as? ArchiveSceneView)?.onAction = { [weak coordinator = context.coordinator] hit in
            guard let (id,action) = coordinator?.action(at:hit) else { return false }
            onRecordAction(id,action);return true
        }
        context.coordinator.update(frames:frames,images:images,appearance:appearance,selected:selected,size:size,reduced:reduced,day:day)
    }
}
