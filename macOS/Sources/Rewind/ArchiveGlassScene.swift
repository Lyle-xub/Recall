import AppKit
import SceneKit
import SwiftUI
import simd
import Combine

private final class ArchiveRecordControl: SCNNode {
    var recordID = ""
    var action = ""
}

@MainActor private final class ArchiveFrameClock:NSObject {
    weak var archive:ArchiveGlassScene?
    @objc func tick(_ link:CADisplayLink) { archive?.advanceFrame(at:link.targetTimestamp) }
}

/// Real, thick glass sheets in camera space. All racks share the same camera,
/// lighting and depth of field, so their edges converge consistently.
@MainActor final class ArchiveGlassScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private var nodes: [String:SCNNode] = [:]
    private var positions:[String:SCNVector3] = [:]
    private struct Slot { let lane:Int; let depth:Double; let x:CGFloat; let z:CGFloat }
    private struct Extraction {
        var spring = ArchiveMotionSpring(value:0)
        var target:Double = 0
        let origin:SIMD3<Float>
        var destination:SIMD3<Float>
        let rotation:simd_quatf
    }
    private var slots:[String:Slot] = [:]
    private var heights:[String:ArchiveMotionSpring] = [:]
    private var depths:[String:ArchiveMotionSpring] = [:]
    private var laterals:[String:ArchiveMotionSpring] = [:]
    private var extractions:[String:Extraction] = [:]
    private var framesByID:[String:MemoryFrame] = [:]
    private var imageAspects:[String:CGFloat] = [:]
    private var blankIDs = Set<String>()
    private var anchorDay:Date?
    private var viewport = CGSize(width:2000,height:876)
    private var verticalSpan:CGFloat = 9
    private var cameraTransform = matrix_identity_float4x4
    private var cameraScroll=ArchiveMotionSpring(value:0)
    private var cameraAcross=ArchiveMotionSpring(value:0)
    private var cameraFrequency=22.0
    var onPresentationChanged:(()->Void)?
    /// Opt-in instrumentation for native interaction benchmarks. No samples
    /// or timestamps are collected in the normal application path.
    var onWorkMeasured:((String,Duration)->Void)?
    private(set) var dayColumns:[ArchiveDayColumn] = []
    private var currentID:String?
    private(set) var hoveredID:String?
    private var focalDistance = ArchiveMotionSpring(value:33.5)
    private var aperture = ArchiveMotionSpring(value:5.8)
    private var frameKeys:[String] = []
    private var surfaceKeys:[String:String] = [:]
    private var night = false
    private var reducedMotion = false
    private var crest = ArchiveMotionSpring(value:0)
    private var crestTarget:Double = 0
    private var across = ArchiveMotionSpring(value:0)
    private var acrossTarget:Double = 0
    private var timer:Timer?
    private var displayLink:CADisplayLink?
    private weak var animationView:NSView?
    private let frameClock = ArchiveFrameClock()
    private(set) var isActive = true
    var isAnimating:Bool { timer != nil || displayLink != nil }
    private var previousTime:TimeInterval = 0
    private(set) var scrollOffset:CGFloat = 0
    private var horizontalOffset:CGFloat = 0
    private var navigationDate:Date?
    private var layoutRevision = 0
    private var navigationRevision = -1
    private var imageKeys:[String:ObjectIdentifier] = [:]
    private struct ShapeKey:Equatable { let width:CGFloat;let height:CGFloat;let aspect:CGFloat }
    private var shapeKeys:[String:ShapeKey] = [:]
    private var informationAspects:[String:CGFloat] = [:]
    private var dayLabelKeys:[String] = []
    private let footerLoader=ArchiveFooterLoader()
    var pendingFooterCount:Int {footerLoader.pendingCount}
    var inFlightFooterCount:Int {footerLoader.inFlightCount}
    var maximumFooterConcurrency:Int {footerLoader.maximumConcurrency}
    func waitForFooters() async {await footerLoader.waitUntilIdle()}
    private var sheetGeometries:[String:(SCNGeometry,SCNGeometry,SCNGeometry)] = [:]
    private lazy var actionGeometry:SCNPlane = {
        let plane=SCNPlane(width:0.48,height:0.26),material=SCNMaterial()
        material.lightingModel = .constant;material.diffuse.contents=NSColor.white.withAlphaComponent(0.001)
        material.writesToDepthBuffer=false;plane.materials=[material];return plane
    }()
    private(set) var shapeUpdateCount = 0
    private(set) var positionUpdateCount = 0
    private(set) var surfaceBuildCount = 0
    private(set) var textureUpdateCount = 0
    private(set) var layoutUpdateCount = 0
    private(set) var informationTextureBuildCount = 0
    fileprivate weak var workBudget:ForegroundWorkBudget?
    private var budgetSubscription:AnyCancellable?
    private var activityLease:UUID?
    private var memoryPressureLimited=false
    func bind(to budget:ForegroundWorkBudget) {
        guard workBudget !== budget else {return}
        workBudget?.endActivity(activityLease);activityLease=nil;workBudget=budget
        applyBudget(budget.state,force:true)
        budgetSubscription=budget.changes.sink { [weak self] state in self?.applyBudget(state) }
        if isAnimating {activityLease=budget.beginActivity()}
    }
    private func applyBudget(_ state:ForegroundWorkBudget.State,force:Bool = false) {
        if state.stopped {setActive(false);return}
        let limited=state.pressure != .normal
        guard force || memoryPressureLimited != limited else {return}
        memoryPressureLimited=limited
        // Ordinary input keeps the appearance stable. Only memory-pressure
        // edges change this pass, without starting another motion lease.
        SCNTransaction.begin();SCNTransaction.disableActions=true
        cameraNode.camera?.wantsDepthOfField = !memoryPressureLimited && (currentID.flatMap {extractions[$0]?.spring.value} ?? 0) < 0.995
        SCNTransaction.commit();animationView?.needsDisplay=true
    }
    private var navigationTarget:Double?
    private var resolvedNavigation:ArchiveNavigationTarget?
    private var reportedNavigationGeneration:Int?
    private var timelineNavigation=false
    var onNavigationSettled:((ArchiveNavigationTarget)->Void)?
    var onNavigationWindowDemand:((Double,ArchiveNavigationTarget)->Void)?
    private var navigationMotion = ArchiveMotionSpring(value:0)
    private var maxScroll:CGFloat = 0
    private var minScroll:CGFloat = 0
    private var dataWindow:ArchiveWindow?
    private var windowEpoch:Int?
    private var windowKeys:[String] = []
    private var retainedFrames:[MemoryFrame] = []
    private var retainedImages:[String:NSImage] = [:]
    private var virtualBucket:Int?
    var onWindowDemand:((Double)->Void)?
    var residentNodeCount:Int {nodes.count}
    var recordIDs:Set<String> { Set(framesByID.keys) }
    var renderedCardCount:Int { nodes.count-blankIDs.count }
    func hasPreparedImage(at path:String)->Bool {retainedImages[path] != nil}
    var blankCardCount:Int { blankIDs.count }
    private let cameraHome = SCNVector3(-12.9,17.7,22.2)
    private var target = SCNVector3(-1.9,5.4,0.2)

    init() {
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 4.5
        camera.zNear = 0.1; camera.zFar = 100
        // Recorded UI is already display-referred. HDR tone mapping and
        // negative exposure turned source whites grey, including the footer.
        camera.wantsHDR = false; camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0
        camera.wantsDepthOfField = true
        camera.focusDistance = 33.5
        camera.fStop = 5.8
        camera.apertureBladeCount = 8
        // Reflections and the physical rim supply the glass highlights without
        // full-screen bloom / ambient-occlusion passes over screenshot pixels.
        camera.screenSpaceAmbientOcclusionIntensity = 0
        camera.bloomIntensity = 0
        cameraNode.camera = camera
        cameraNode.position = cameraHome
        cameraNode.look(at:target)
        cameraTransform = cameraNode.simdWorldTransform
        scene.rootNode.addChildNode(cameraNode)
        let key = SCNNode(); key.light = SCNLight();key.light?.type = .directional
        key.light?.intensity = 360; key.light?.color = NSColor(red:1,green:0.95,blue:0.84,alpha:1)
        key.position = SCNVector3(-6,12,8); key.look(at:SCNVector3Zero)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .omni
        fill.light?.intensity = 110; fill.light?.color = NSColor(red:0.6,green:0.77,blue:1,alpha:1)
        fill.position = SCNVector3(10,7,-4);scene.rootNode.addChildNode(fill)
        let ambient = SCNNode();ambient.light = SCNLight();ambient.light?.type = .ambient
        ambient.light?.intensity = 135; ambient.light?.color = NSColor.white
        scene.rootNode.addChildNode(ambient)
        scene.lightingEnvironment.contents = Self.environment()
        // Balance the lit glass for SDR separately from the unlit screenshots.
        scene.lightingEnvironment.intensity = 0.36
        scene.background.contents = NSColor.clear
        scene.fogStartDistance = 36; scene.fogEndDistance = 49
        scene.fogColor = NSColor(red:0.90,green:0.89,blue:0.86,alpha:1)
        frameClock.archive = self
    }

    func update(frames:[MemoryFrame],images:[String:NSImage],appearance:OverlayAppearance,selected:String?,size:CGSize,reduced:Bool,day:Date? = nil,timelinePosition:Date? = nil,window:ArchiveWindow? = nil,navigation:ArchiveNavigationTarget? = nil) {
        let started=onWorkMeasured == nil ? nil:ContinuousClock.now
        defer {if let started {onWorkMeasured?("update",started.duration(to:.now))}}
        let resized = viewport != size
        reducedMotion = reduced;viewport = size
        verticalSpan = 9*2.22/max(1,size.width/max(1,size.height))
        if resized || layoutRevision == 0 {cameraNode.camera?.orthographicScale = verticalSpan/2}
        if resized {
            for id in Array(extractions.keys) { extractions[id]?.destination = extractionDestination() }
        }
        let isNight = appearance == .deepNight
        if isNight != night {scene.fogColor = isNight ? NSColor(red:0.04,green:0.05,blue:0.07,alpha:1):NSColor(red:0.90,green:0.89,blue:0.86,alpha:1)}
        let center = Calendar.current.startOfDay(for:day ?? frames.max(by: { $0.timestamp < $1.timestamp })?.timestamp ?? Date())
        let suppliedWindow=window?.columns.isEmpty == false ? window:nil
        timelineNavigation=timelinePosition != nil
        let nextWindowKeys=suppliedWindow?.columns.map { "\($0.day)|\($0.startIndex)|\($0.totalCount)|\($0.origin)" } ?? []
        if let suppliedWindow,windowEpoch != suppliedWindow.epoch {
            // A near-time page resolves a destination; it must never teleport
            // the displayed camera before the navigation spring can run.
            if !timelineNavigation {
                scrollOffset=CGFloat(suppliedWindow.focusRow ?? 0);navigationTarget=nil
                cameraScroll=ArchiveMotionSpring(value:Double(scrollOffset));cameraAcross=ArchiveMotionSpring(value:Double(horizontalOffset))
            }
            windowEpoch=suppliedWindow.epoch;virtualBucket=nil
        }
        dataWindow=suppliedWindow;retainedFrames=frames;retainedImages=images
        let keys = frames.map { "\($0.id)|\($0.imagePath)|\($0.starred)|\($0.regions.count)|\($0.ocrKey ?? "")" }
        if keys != frameKeys || nextWindowKeys != windowKeys || isNight != night || anchorDay != center || virtualBucket == nil {
            frameKeys = keys;windowKeys=nextWindowKeys;night = isNight;anchorDay = center
            reconcile(frames:frames,images:images)
        }
        updateImages(images)
        if selected != currentID {
            if selected != nil {freezeScrolling()}
            hoveredID = nil
            onPresentationChanged?()
            if let previous = currentID,var motion = extractions[previous] {
                motion.target = 0;extractions[previous] = motion
            }
            if let selected,let node = nodes[selected] {
                if var motion = extractions[selected] {
                    motion.target = 1;extractions[selected] = motion
                } else {
                    extractions[selected] = Extraction(target:1,origin:node.simdPosition,
                        destination:extractionDestination(),rotation:cameraNode.simdOrientation)
                }
            }
            currentID = selected
            footerLoader.prioritize(selected:selected,center:Double(scrollOffset))
            if reduced { advance(dt:1,immediate:true) } else { wake() }
        }
        if let currentID,let node = nodes[currentID] { shape(node,id:currentID,progress:Float(extractions[currentID]?.spring.value ?? 0)) }
        navigateArchive(to:timelinePosition,resolved:navigation)
        if resized,!extractions.isEmpty {
            if reducedMotion { advance(dt:1,immediate:true) } else { wake() }
        }
        onPresentationChanged?()
    }

    private func extractionDestination()->SIMD3<Float> {
        let center = ArchiveViewportLayout.extractionCenterY(in:viewport,verticalSpan:CGFloat(cameraNode.camera?.orthographicScale ?? 4.5)*2)
        let point = cameraNode.convertPosition(SCNVector3(0,center,-14),to:nil)
        return SIMD3(Float(point.x),Float(point.y),Float(point.z))
    }

    private func navigateArchive(to date:Date?,resolved:ArchiveNavigationTarget?) {
        let revision=resolved?.generation ?? dataWindow?.epoch ?? layoutRevision
        guard date != navigationDate || navigationRevision != revision else { return }
        navigationDate = date;navigationRevision = revision
        resolvedNavigation=resolved;reportedNavigationGeneration=nil
        if let resolved {
            navigationMotion=ArchiveMotionSpring(value:cameraScroll.value,velocity:navigationMotion.velocity)
            scrollOffset=CGFloat(cameraScroll.value)
            navigationTarget=resolved.row
            crestTarget=resolved.row;acrossTarget=0;hoveredID=resolved.recordID
            if reducedMotion {advance(dt:1,immediate:true)} else {wake()}
            return
        }
        guard let date,let column = dayColumns.first(where:{ Calendar.current.isDate($0.day,inSameDayAs:date) }),!column.records.isEmpty else {
            navigationTarget = nil;return
        }
        let records = column.records
        var row = Double(records.count-1)
        if date >= records[0].timestamp { row = 0 }
        else if records.count > 1 {
            for index in 0..<(records.count-1) where records[index].timestamp >= date && records[index+1].timestamp <= date {
                let span = records[index].timestamp.timeIntervalSince(records[index+1].timestamp)
                row = Double(index)+records[index].timestamp.timeIntervalSince(date)/max(0.001,span);break
            }
        }
        let depth = row+Double(column.origin+column.startIndex)-(column.lane == 0 ? 0:column.lane < 0 ? 3.5:1.5)
        navigationMotion = ArchiveMotionSpring(value:cameraScroll.value,velocity:navigationMotion.velocity)
        navigationTarget = max(Double(minScroll),min(Double(maxScroll),depth))
        crestTarget = depth;acrossTarget = Double(column.lane)
        hoveredID = records.min(by:{ abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) })?.id
        if reducedMotion { advance(dt:1,immediate:true) } else { wake() }
    }

    /// Reconcile by record ID. Loading thumbnails or starring a record must
    /// never replace its moving root node or restart an extraction.
    private func reconcile(frames:[MemoryFrame],images:[String:NSImage],placeView:Bool = true,animate:Bool = true) {
        SCNTransaction.begin();SCNTransaction.disableActions = true
        defer {SCNTransaction.commit()}
        let rack:SCNNode
        if let existing = scene.rootNode.childNode(withName:"racks",recursively:false) { rack = existing }
        else { rack = SCNNode();rack.name = "racks";scene.rootNode.addChildNode(rack) }
        layoutRevision += 1;layoutUpdateCount += 1
        let updates=Dictionary(uniqueKeysWithValues:frames.map {($0.id,$0)})
        dayColumns=dataWindow?.columns.map { column in
            ArchiveDayColumn(day:column.day,lane:column.lane,records:column.records.map {updates[$0.id] ?? $0},startIndex:column.startIndex,totalCount:column.totalCount,origin:column.origin)
        } ?? ArchiveDayLayout.columns(frames:frames,around:anchorDay ?? Date())
        let oldFrames=framesByID
        framesByID=Dictionary(uniqueKeysWithValues:dayColumns.flatMap(\.records).map {($0.id,$0)})
        let rowCount=max(20,dayColumns.map {$0.origin+$0.totalCount}.max() ?? 0,
            timelineNavigation ? Int(ceil(Double(scrollOffset)))+ArchiveDayLayout.renderedRows/2:0)
        minScroll=CGFloat(min(0,dayColumns.map(\.origin).min() ?? 0))
        maxScroll=max(17,CGFloat(dayColumns.map {Double($0.origin+$0.totalCount-1)-($0.lane == 0 ? 0:$0.lane < 0 ? 3.5:1.5)}.max() ?? 0))
        if !timelineNavigation {scrollOffset=max(minScroll,min(scrollOffset,maxScroll))}
        let bucket=Int(floor(Double(scrollOffset)/8))*8
        virtualBucket=bucket
        var entries:[(String,MemoryFrame?,Int,Double)]=[]
        blankIDs.removeAll()
        for column in dayColumns {
            let lower=max(column.origin-2,bucket-24)
            let upper=min(max(rowCount,column.origin+20)+2,lower+ArchiveDayLayout.renderedRows)
            guard lower < upper else {continue}
            for row in lower..<upper {
                let index=row-column.origin-column.startIndex
                let frame=column.records.indices.contains(index) ? column.records[index]:nil
                let id=frame?.id ?? "blank:\(column.day.timeIntervalSince1970):\(row)"
                if frame == nil {blankIDs.insert(id)}
                entries.append((id,frame,column.lane,Double(row)))
            }
        }
        // Keep the open sheet and at most one returning sheet even if a newer
        // metadata page arrives. Identity and native footer actions stay intact.
        let protected=([currentID].compactMap {$0}+extractions.keys.sorted()).reduce(into:[String]()) { if !$0.contains($1),$0.count < 2 {$0.append($1)} }
        for id in protected where !entries.contains(where:{$0.0 == id}) {
            if let frame=oldFrames[id],let slot=slots[id] {
                framesByID[id]=frame
                let row=slot.depth+(slot.lane == 0 ? 0:slot.lane < 0 ? 3.5:1.5)
                entries.append((id,frame,slot.lane,row))
            }
        }
        if let hoveredID,!entries.contains(where:{$0.0 == hoveredID}) {self.hoveredID=nil}
        for pin in dataWindow?.pins ?? [] where !entries.contains(where:{$0.0 == pin.frame.id}) && protected.contains(pin.frame.id) {
            framesByID[pin.frame.id]=pin.frame
            entries.append((pin.frame.id,pin.frame,pin.lane,Double(pin.row)))
        }
        let ids = Set(entries.map { $0.0 })
        footerLoader.retain(ids)
        for id in Array(nodes.keys) where !ids.contains(id) {
            nodes.removeValue(forKey:id)?.removeFromParentNode();positions[id] = nil;slots[id] = nil;heights[id] = nil;depths[id] = nil;laterals[id] = nil;extractions[id] = nil;surfaceKeys[id] = nil;imageAspects[id] = nil;imageKeys[id] = nil;shapeKeys[id] = nil;informationAspects[id] = nil
        }
        for (id,frame,lane,row) in entries {
            let depth = row-(lane == 0 ? 0:lane < 0 ? 3.5:1.5)
            let slot = Slot(lane:lane,depth:depth,x:CGFloat(lane)*(lane < 0 ? 5.65:6.25),z:CGFloat(depth)-5)
            slots[id] = slot
            let image = frame.flatMap { images[$0.imagePath] }
            imageAspects[id] = image.map { $0.size.width/max(1,$0.size.height) } ?? imageAspects[id] ?? 1.6
            let surfaceKey = "\(frame?.imagePath ?? "empty")|\(frame?.starred ?? false)|\(night)|\(lane)"
            guard surfaceKeys[id] != surfaceKey else { continue }
            surfaceKeys[id] = surfaceKey
            shapeKeys[id] = nil
            informationAspects[id] = nil
            surfaceBuildCount += 1
            let surface = makeSheet(frame:frame,image:image,side:lane != 0,lane:lane)
            imageKeys[id] = image.map(ObjectIdentifier.init)
            if let node = nodes[id] {
                if let previous=node.childNode(withName:"information",recursively:false)?.geometry?.firstMaterial {
                    surface.childNode(withName:"information",recursively:false)?.geometry?.materials=[previous]
                }
                node.childNodes.forEach { $0.removeFromParentNode() }
                for child in surface.childNodes { child.removeFromParentNode();node.addChildNode(child) }
            } else {
                surface.name = id;rack.addChildNode(surface);nodes[id] = surface
                let height = ArchiveRidgeProfile.height(lane:Double(lane),depth:depth,crest:crest.value,across:across.value)
                heights[id] = ArchiveMotionSpring(value:height)
                depths[id] = ArchiveMotionSpring(value:Double(slot.z))
                laterals[id] = ArchiveMotionSpring(value:Double(slot.x))
                surface.position = SCNVector3(slot.x,CGFloat(height),slot.z)
                positions[id] = surface.position
            }
            if let node = nodes[id] { shape(node,id:id,progress:Float(extractions[id]?.spring.value ?? 0)) }
        }
        footerLoader.prioritize(selected:currentID,center:Double(scrollOffset))
        updateDayLabels()
        if placeView {placeCamera()}
        if animate {if reducedMotion { advance(dt:1,immediate:true) } else { wake() }}
    }

    /// Image arrivals only replace the artwork texture. Glass geometry, labels,
    /// metadata textures and the spring-driven root stay intact.
    private func updateImages(_ images:[String:NSImage]) {
        let started=onWorkMeasured == nil ? nil:ContinuousClock.now
        defer {if let started {onWorkMeasured?("images",started.duration(to:.now))}}
        let changes=framesByID.compactMap { id,frame -> (String,NSImage?,SCNNode,SCNNode)? in
            let image=images[frame.imagePath]
            guard image.map(ObjectIdentifier.init) != imageKeys[id],let node=nodes[id],
                  let artwork=node.childNode(withName:"artwork",recursively:false) else {return nil}
            return (id,image,node,artwork)
        }
        // Even an empty SceneKit transaction takes the render lock on commit.
        // Model/loading publications often change no screenshot textures.
        guard !changes.isEmpty else {return}
        SCNTransaction.begin();SCNTransaction.disableActions = true
        defer {SCNTransaction.commit()}
        for (id,image,node,artwork) in changes {
            imageKeys[id] = image.map(ObjectIdentifier.init);textureUpdateCount += 1
            artwork.geometry?.firstMaterial?.diffuse.contents = image
            artwork.isHidden = image == nil
            if let image { imageAspects[id] = image.size.width/max(1,image.size.height) }
            shape(node,id:id,progress:Float(extractions[id]?.spring.value ?? 0))
        }
    }

    func hover(_ id:String?) {
        let next = currentID == nil ? id.flatMap { framesByID[$0] == nil ? nil:$0 }:nil
        guard hoveredID != next else { return }
        hoveredID = next
        // Focus is useful even when Reduce Motion disables the wave.
        if reducedMotion { advance(dt:1,immediate:true) } else { wake() }
    }
    var canHitRestingSheets:Bool { extractions.isEmpty }
    /// Orthographic picking needs only the camera pose and view size. Native
    /// unprojectPoint can flush/wait for the renderer even with cached bounds.
    /// The frame clock moves the actual camera and this cache together, so
    /// picking never targets a future implicit-animation destination.
    func ray(at point:CGPoint,in size:CGSize)->(SCNVector3,SCNVector3)? {
        guard size == viewport,size.width > 0,size.height > 0 else { return nil }
        let x = Float((point.x/size.width-0.5)*verticalSpan*size.width/size.height)
        let y = Float((point.y/size.height-0.5)*verticalSpan)
        let near = cameraTransform*SIMD4<Float>(x,y,-0.1,1)
        let far = cameraTransform*SIMD4<Float>(x,y,-100,1)
        return (SCNVector3(CGFloat(near.x),CGFloat(near.y),CGFloat(near.z)),SCNVector3(CGFloat(far.x),CGFloat(far.y),CGFloat(far.z)))
    }
    /// Rack sheets are parallel rectangles. Intersect their cached bounds on
    /// the UI thread instead of synchronizing with SceneKit's mesh hit tester.
    /// Rotating/extracted sheets still use native hit testing for their actions.
    func record(at near:SCNVector3,toward far:SCNVector3)->String? {
        guard canHitRestingSheets,abs(far.z-near.z) > 0.00001 else { return nil }
        var closest:CGFloat = .infinity,result:String?
        for id in framesByID.keys {
            guard let position = positions[id] else { continue }
            let t = (position.z+0.065/2-near.z)/(far.z-near.z)
            guard t >= 0,t <= 1,t < closest else { continue }
            let x = near.x+(far.x-near.x)*t-position.x
            let y = near.y+(far.y-near.y)*t-position.y
            if abs(x) <= 5.35/2,abs(y) <= 6.5/2 { closest = t;result = id }
        }
        return result
    }
    func pointer(at point:CGPoint) {
        guard !reducedMotion,currentID == nil else { return }
        // Intersect the camera ray with the crest's top plane. Screen-space
        // guesses drift away from the mouse as the camera scrolls sideways.
        let span = CGFloat(cameraNode.camera?.orthographicScale ?? 4.5)*2
        let x = (point.x-0.5)*span*viewport.width/max(1,viewport.height)
        let y = (point.y-0.5)*span
        let near = cameraNode.convertPosition(SCNVector3(x,y,-0.1),to:nil)
        let far = cameraNode.convertPosition(SCNVector3(x,y,-100),to:nil)
        pointer(rayNear:near,rayFar:far)
    }
    func pointer(rayNear near:SCNVector3,rayFar far:SCNVector3,recordID:String? = nil) {
        guard currentID == nil else { return }
        if let recordID,let slot = slots[recordID],framesByID[recordID] != nil {
            // Use the actual hit sheet, including its lane offset and row
            // spacing, rather than a guessed plane above the mountain.
            hover(recordID)
            guard !reducedMotion else { return }
            acrossTarget = Double(slot.lane);crestTarget = slot.depth;wake();return
        }
        hover(nil)
        guard !reducedMotion,abs(far.y-near.y) > 0.0001 else { return }
        let t = (5.9-near.y)/(far.y-near.y)
        let x = near.x+(far.x-near.x)*t,z = near.z+(far.z-near.z)*t
        acrossTarget = max(-2,min(2,Double(x/(x < 0 ? 5.65:6.25))))
        crestTarget = max(-5.5,min(Double(maxScroll)+3,Double(z+5)))
        wake()
    }
    func viewportRecords(in renderer:SCNSceneRenderer)->ArchiveViewportRecords {
        let started=onWorkMeasured == nil ? nil:ContinuousClock.now
        defer {if let started {onWorkMeasured?("viewport",started.duration(to:.now))}}
        let visible = Set(framesByID.keys.filter { id in
            guard let node = nodes[id] else { return false }
            return renderer.isNode(node,insideFrustumOf:cameraNode)
        })
        let visibleSlots = visible.compactMap { slots[$0] }
        guard let first = visibleSlots.map(\.depth).min(),let last = visibleSlots.map(\.depth).max() else {
            return ArchiveViewportRecords(visible:visible)
        }
        let lanes = Set(visibleSlots.map(\.lane))
        let nearby = Set(framesByID.keys.filter { id in
            guard let slot = slots[id] else { return false }
            return lanes.contains(slot.lane) && slot.depth >= first-5 && slot.depth <= last+5
        })
        return ArchiveViewportRecords(visible:visible,nearby:nearby)
    }
    private func placeCamera() {
        let dx=CGFloat(cameraAcross.value)*0.894,dz=CGFloat(cameraScroll.value)+CGFloat(cameraAcross.value)*0.447
        let position = SCNVector3(cameraHome.x+dx,cameraHome.y,cameraHome.z+dz)
        if abs(cameraNode.position.x-position.x)+abs(cameraNode.position.z-position.z) > 0.00001 {
            cameraNode.position = position
            cameraTransform.columns.3 = SIMD4(Float(position.x),Float(position.y),Float(position.z),1)
            // Translation leaves the view direction unchanged.
        }
    }
    func freezeScrolling(report:Bool = false) {
        // Selection belongs to the displayed camera, not an unrendered input
        // destination. Otherwise a newly extracted card drifts during its turn.
        scrollOffset=CGFloat(cameraScroll.value);horizontalOffset=CGFloat(cameraAcross.value)
        cameraScroll.velocity=0;cameraAcross.velocity=0;navigationTarget=nil
        if report {onWindowDemand?(Double(scrollOffset))}
    }
    func scroll(by delta:CGFloat,horizontal:CGFloat = 0,precise:Bool) {
        let started=onWorkMeasured == nil ? nil:ContinuousClock.now
        defer {if let started {onWorkMeasured?("scroll",started.duration(to:.now))}}
        guard currentID == nil,extractions.isEmpty else { return }
        navigationTarget = nil
        let next = min(maxScroll,max(minScroll,scrollOffset+delta*(precise ? 0.018:0.42)))
        let nextHorizontal = min(8,max(-8,horizontalOffset+horizontal*(precise ? 0.018:0.42)))
        guard next != scrollOffset || nextHorizontal != horizontalOffset else { return }
        hover(nil)
        scrollOffset = next;horizontalOffset = nextHorizontal
        if virtualBucket != Int(floor(Double(next)/8))*8 {reconcile(frames:retainedFrames,images:retainedImages,placeView:false)}
        onWindowDemand?(Double(next))
        crestTarget = Double(next)+Double(delta)*(precise ? 0.025:0.16)
        acrossTarget = Double(nextHorizontal)*0.12
        // Input only accumulates a destination. The existing display clock
        // commits camera and ridge together once, rather than contending with
        // the renderer for a second transaction on every wheel/drag event.
        cameraFrequency=precise ? 22:12
        if reducedMotion { advance(dt:1,immediate:true) } else { wake() }
    }
    func attachAnimation(to view:NSView) {
        guard animationView !== view else { return }
        let running = isAnimating
        stopMotion();animationView = view
        if running { wake() }
    }
    private func wake() {
        guard isActive,!isAnimating else { return }
        activityLease=workBudget?.beginActivity()
        previousTime = ProcessInfo.processInfo.systemUptime
        if let animationView {
            let link = animationView.displayLink(target:frameClock,selector:#selector(ArchiveFrameClock.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum:60,maximum:60,preferred:60)
            displayLink = link;link.add(to:.main,forMode:.common)
            return
        }
        // Headless renderers have no display; tests can also advance directly.
        let source = Timer(timeInterval:1/60,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceFrame(at:ProcessInfo.processInfo.systemUptime)
            }
        }
        timer = source;RunLoop.main.add(source,forMode:.common)
    }
    fileprivate func advanceFrame(at now:TimeInterval) {
        advance(dt:min(1/20,max(1/240,now-previousTime)))
        previousTime = now
    }
    func stopMotion() {
        timer?.invalidate();timer=nil;displayLink?.invalidate();displayLink=nil
        let lease=activityLease;activityLease=nil;workBudget?.endActivity(lease)
    }
    func setActive(_ active:Bool) {
        let active=active && workBudget?.state.stopped != true
        guard active != isActive else { return }
        isActive = active
        if active {
            footerLoader.resume()
            for (id,node) in nodes {shape(node,id:id,progress:Float(extractions[id]?.spring.value ?? 0))}
        } else {footerLoader.stop();resolvedNavigation=nil;navigationTarget=nil;navigationDate=nil}
        if active { wake() } else { stopMotion() }
    }

    /// One clock drives the ridge, the extraction and the return. Geometry,
    /// artwork and controls stay attached to the same opaque root throughout.
    func advance(dt:Double,immediate:Bool = false) {
        let started=onWorkMeasured == nil ? nil:ContinuousClock.now
        defer {if let started {onWorkMeasured?("advance",started.duration(to:.now))}}
        guard isActive else { return }
        // Commit the actual camera with its picking transform before another
        // input event. Leaving this implicit can expose a stale native camera.
        SCNTransaction.begin();SCNTransaction.disableActions = true
        var settledNavigation:ArchiveNavigationTarget?
        defer {
            SCNTransaction.commit()
            if let settledNavigation {onNavigationSettled?(settledNavigation)}
        }
        if immediate { crest = ArchiveMotionSpring(value:crestTarget);across = ArchiveMotionSpring(value:acrossTarget) }
        else { crest.step(to:crestTarget,frequency:8,dt:dt);across.step(to:acrossTarget,frequency:7,dt:dt) }
        var active = !crest.settled(at:crestTarget) || !across.settled(at:acrossTarget)
        if let navigationTarget,currentID == nil,extractions.isEmpty {
            if immediate { navigationMotion = ArchiveMotionSpring(value:navigationTarget) }
            else { navigationMotion.step(to:navigationTarget,frequency:10,dt:dt) }
            scrollOffset = CGFloat(navigationMotion.value)
            if immediate {cameraAcross=ArchiveMotionSpring(value:0)} else {cameraAcross.step(to:0,frequency:10,dt:dt)}
            horizontalOffset=CGFloat(cameraAcross.value)
            cameraScroll=ArchiveMotionSpring(value:Double(scrollOffset))
            active = active || !navigationMotion.settled(at:navigationTarget) || !cameraAcross.settled(at:0)
            if virtualBucket != Int(floor(Double(scrollOffset)/8))*8 {
                reconcile(frames:retainedFrames,images:retainedImages,placeView:false,animate:false)
                if let resolvedNavigation {onNavigationWindowDemand?(Double(scrollOffset),resolvedNavigation)}
            }
        } else {
            if immediate || abs(cameraScroll.value-Double(scrollOffset)) > Double(ArchiveDayLayout.renderedRows)/2 {
                cameraScroll=ArchiveMotionSpring(value:Double(scrollOffset));cameraAcross=ArchiveMotionSpring(value:Double(horizontalOffset))
            } else {
                cameraScroll.step(to:Double(scrollOffset),frequency:cameraFrequency,dt:dt)
                cameraAcross.step(to:Double(horizontalOffset),frequency:cameraFrequency,dt:dt)
            }
            active = active || !cameraScroll.settled(at:Double(scrollOffset)) || !cameraAcross.settled(at:Double(horizontalOffset))
        }
        placeCamera()
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
                var lateral=laterals[id] ?? ArchiveMotionSpring(value:Double(node.position.x))
                if immediate {lateral=ArchiveMotionSpring(value:Double(slot.x))}
                else {lateral.step(to:Double(slot.x),frequency:9,dt:dt)}
                laterals[id]=lateral
                let position = SCNVector3(CGFloat(lateral.value),CGFloat(height.value),CGFloat(depth.value))
                let previous = positions[id] ?? position
                if abs(previous.x-position.x)+abs(previous.y-position.y)+abs(previous.z-position.z) > 0.00001 {
                    node.position = position;positions[id] = position;positionUpdateCount += 1
                }
                active = active || !depth.settled(at:Double(slot.z))
                active = active || !lateral.settled(at:Double(slot.x))
                active = active || !height.settled(at:wanted)
                heights[id] = height
            }
            if var motion = extractions[id] {
                if immediate { motion.spring = ArchiveMotionSpring(value:motion.target) }
                else { motion.spring.step(to:motion.target,frequency:6.5,dt:dt) }
                let p = Float(max(0,min(1,motion.spring.value)))
                node.simdPosition = ArchiveExtractionPath.position(from:motion.origin,to:motion.destination,progress:p)
                positions[id] = node.position
                let rotation = ArchiveExtractionPath.rotationProgress(p)
                node.simdOrientation = simd_slerp(simd_quatf(angle:0,axis:SIMD3(0,1,0)),motion.rotation,rotation)
                shape(node,id:id,progress:p)
                focus = max(focus,Double(p))
                active = active || !motion.spring.settled(at:motion.target)
                if motion.target == 0,motion.spring.settled(at:0) {
                    node.simdPosition = motion.origin;node.simdOrientation = simd_quatf(angle:0,axis:SIMD3(0,1,0));node.simdScale = SIMD3(repeating:1)
                    positions[id] = node.position
                    shape(node,id:id,progress:0)
                    heights[id] = ArchiveMotionSpring(value:Double(motion.origin.y));extractions[id] = nil
                    active = true
                } else { extractions[id] = motion }
            }
        }
        // Focus in camera space, so the hovered screenshot stays sharp as
        // the wave moves it or scrolling changes the camera position.
        let hovered = hoveredID.flatMap { nodes[$0] }
        let distance = hovered.map { node in
            Double(-cameraNode.convertPosition(node.worldPosition,from:nil).z)
        } ?? 33.5
        let desiredDistance = distance+(14-distance)*focus
        let idleAperture = hovered == nil ? 5.8:18.0
        let desiredAperture = idleAperture+(64-idleAperture)*focus
        // An opened card is flat and in focus; the blur pass adds no detail.
        let blur = !memoryPressureLimited && focus < 0.995
        if cameraNode.camera?.wantsDepthOfField != blur { cameraNode.camera?.wantsDepthOfField = blur }
        if immediate {
            focalDistance = ArchiveMotionSpring(value:desiredDistance)
            aperture = ArchiveMotionSpring(value:desiredAperture)
        } else {
            focalDistance.step(to:desiredDistance,frequency:12,dt:dt)
            aperture.step(to:desiredAperture,frequency:12,dt:dt)
        }
        if abs((cameraNode.camera?.focusDistance ?? 0)-focalDistance.value) > 0.00001 { cameraNode.camera?.focusDistance = focalDistance.value }
        if abs((cameraNode.camera?.fStop ?? 0)-CGFloat(aperture.value)) > 0.00001 { cameraNode.camera?.fStop = CGFloat(aperture.value) }
        active = active || !focalDistance.settled(at:desiredDistance) || !aperture.settled(at:desiredAperture)
        if !active,let resolvedNavigation,reportedNavigationGeneration != resolvedNavigation.generation,
           currentID == nil,extractions.isEmpty,navigationTarget != nil,
           resolvedNavigation.recordID.map({nodes[$0] != nil}) ?? true {
            reportedNavigationGeneration=resolvedNavigation.generation;settledNavigation=resolvedNavigation
        }
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
        if let frame = framesByID[id],let information = node.childNode(withName:"information",recursively:false) {
            let footer = progress > 0 ? open.footer:ArchiveCardMetrics.make(width:5.35,height:6.5,aspect:aspect).footer
            let informationAspect = footer.width/footer.height
            let key="\(surfaceKeys[id] ?? "")|\(frame.title)|\(frame.timestamp)|\(informationAspect)"
            if isActive,!footerLoader.contains(id:id,key:key) {
                informationAspects[id]=informationAspect;informationTextureBuildCount += 1
                footerLoader.request(ArchiveFooterRequest(id:id,key:key,frame:frame,night:night,aspect:informationAspect,row:slots[id]?.depth ?? 0)) { [weak self,weak information] prepared in
                    guard let self,self.isActive,let information,self.nodes[id]?.childNode(withName:"information",recursively:false) === information else {return}
                    information.geometry?.materials=[prepared.material]
                    self.onPresentationChanged?()
                }
            }
        }

        for control in node.childNodes.compactMap({ $0 as? ArchiveRecordControl }) { control.isHidden = progress <= 0.98 }
        let key = ShapeKey(width:width,height:height,aspect:aspect)
        guard shapeKeys[id] != key else { return }
        shapeKeys[id] = key;shapeUpdateCount += 1
        let layout = ArchiveCardMetrics.make(width:width,height:height,aspect:aspect)
        // Keep the mesh immutable during the spring. Changing SCNBox/SCNPlane
        // dimensions made SceneKit tessellate and upload new buffers each tick.
        if let body = node.childNode(withName:"glass",recursively:false) {
            body.scale = SCNVector3(width/5.35,height/6.5,1)
        }
        if let art = node.childNode(withName:"artwork",recursively:false) {
            art.scale = SCNVector3(layout.artwork.width/4.87,layout.artwork.height/3,1)
            art.position = SCNVector3(layout.artwork.midX,layout.artwork.midY,0.055)
        }
        if let info = node.childNode(withName:"information",recursively:false) {
            info.scale = SCNVector3(layout.footer.width/4.85,layout.footer.height,1)
            info.position = SCNVector3(layout.footer.midX,layout.footer.midY,0.065)
        }
        for child in node.childNodes {
            if child.name == "rim" { child.scale.y = (height-0.025)/(6.5-0.025);child.position.x = -width/2+0.025 }
            if child.name == "top-edge" { child.scale.x = width/5.35;child.position.y = height/2-0.01 }
            if let control = child as? ArchiveRecordControl {
                if let button = ArchiveFooterLayout.buttons(in:layout.footer.size).first(where: { $0.action == control.action }) {
                    control.position = SCNVector3(layout.footer.minX+button.rect.midX,layout.footer.minY+button.rect.midY,0.08)
                    control.scale = SCNVector3(button.rect.width/0.48,button.rect.height/0.26,1)
                }
            }
        }
    }
    private func updateDayLabels() {
        let keys=dayColumns.map {"\($0.day)|\($0.totalCount)|\($0.origin)|\(night)"}
        guard keys != dayLabelKeys else {return}
        dayLabelKeys=keys
        scene.rootNode.childNode(withName:"dates",recursively:false)?.removeFromParentNode()
        let labels = SCNNode();labels.name = "dates";scene.rootNode.addChildNode(labels)
        let isNight = night
        for column in dayColumns {
            let image = NSImage(size:NSSize(width:800,height:80),flipped:false) { _ in
                let label = column.day.recallFormatted(.dateTime.month(.twoDigits).day(.twoDigits))+"  ·  "+(column.totalCount == 0 ? "No memories":"\(column.totalCount) memories")
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
        let geometryKey="\(night)|\(lane)"
        if sheetGeometries[geometryKey] == nil {
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
            let rim = SCNBox(width:0.026,height:height-0.025,length:0.075,chamferRadius:0.012)
            let highlight = SCNMaterial();highlight.lightingModel = .constant
            highlight.diffuse.contents = NSColor(white:0.88,alpha:0.48);highlight.emission.contents = NSColor.black;highlight.roughness.contents = 0.08;highlight.metalness.contents = 0.25
            rim.materials = [highlight]
            let top = SCNBox(width:width,height:0.016,length:0.075,chamferRadius:0.007);top.materials = [highlight]
            sheetGeometries[geometryKey]=(glass,rim,top)
        }
        let shared=sheetGeometries[geometryKey]!
        let body = SCNNode(geometry:shared.0);body.name = "glass";root.addChildNode(body)
        if frame != nil {
            let art = SCNPlane(width:4.87,height:3.0),material = SCNMaterial();material.lightingModel = .constant
            // Actual source pixels, without an opaque portrait canvas or tint.
            material.diffuse.contents = image;art.materials = [material]
            material.diffuse.intensity = ArchiveImageTone.intensity(night:night)
            let node = SCNNode(geometry:art);node.name = "artwork";node.isHidden = image == nil;root.addChildNode(node)
        }
        if let frame {
            let info = SCNPlane(width:4.85,height:1.0),material = SCNMaterial();material.lightingModel = .constant
            // shape() supplies a compact footer, upgrading only the extracted
            // card instead of allocating expanded textures for the entire rack.
            info.materials = [material]
            let information = SCNNode(geometry:info);information.name = "information";root.addChildNode(information)
            for action in ["star","copy","rewind","close"] {
                let control = ArchiveRecordControl();control.geometry = actionGeometry;control.recordID = frame.id;control.action = action;root.addChildNode(control)
            }
        }
        let rimNode=SCNNode(geometry:shared.1);rimNode.name="rim";root.addChildNode(rimNode)
        let topNode=SCNNode(geometry:shared.2);topNode.name="top-edge";root.addChildNode(topNode)
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
    static func informationTexture(_ frame:MemoryFrame,night:Bool,aspect:CGFloat)->NSImage {
        ArchiveInformationRenderer.informationTexture(frame,night:night,aspect:aspect)
    }
    static func footerSymbol(_ name:String,ink:NSColor)->NSImage? {
        NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize:32,weight:.semibold).applying(.init(paletteColors:[ink])))
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

final class ArchiveSceneView: SCNView {
    let textOverlay = IndexedTextOverlay()
    var selectedRegions:[TextRegion] = []
    weak var archive:ArchiveGlassScene?
    private let pointerScheduler:ArchivePointerScheduler
    private lazy var pointerSamples=ArchivePointerCoalescer(scheduler:pointerScheduler) { [weak self] point in
        self?.updatePointer(at:point)
    }
    override convenience init(frame:NSRect,options:[String:Any]? = nil) {
        self.init(frame:frame,pointerScheduler:.continuous,options:options)
    }
    init(frame:NSRect,pointerScheduler:ArchivePointerScheduler,options:[String:Any]? = nil) {
        self.pointerScheduler=pointerScheduler
        super.init(frame:frame,options:options)
        textOverlay.isHidden = true;addSubview(textOverlay)
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout();updateTextSelection();refreshViewport(force:true) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow();window?.acceptsMouseMovedEvents = true
        if window == nil {cancelPendingInteraction()}
    }
    var onViewportChange:((ArchiveViewportRecords)->Void)?
    private var lastViewport = ArchiveViewportRecords()
    private var lastViewportTime:TimeInterval = 0
    private var viewportDelivery:Task<Void,Never>?
    private var viewportRefresh:Task<Void,Never>?
    func refreshViewport(force:Bool = false) {
        guard bounds.width > 0,bounds.height > 0,let archive,archive.isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !force,now-lastViewportTime < 0.1 {
            // Keep a trailing check: the final sliver of a card can enter the
            // viewport after the last throttled check, just as the wave settles.
            if viewportRefresh == nil {
                let delay = 0.1-(now-lastViewportTime)
                viewportRefresh = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for:.seconds(delay)) } catch { return }
                    self?.viewportRefresh = nil;self?.refreshViewport(force:true)
                }
            }
            return
        }
        viewportRefresh?.cancel();viewportRefresh = nil
        lastViewportTime = now
        let records = archive.viewportRecords(in:self)
        guard records != lastViewport else { return }
        lastViewport = records
        viewportDelivery?.cancel()
        viewportDelivery = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.onViewportChange?(records)
        }
    }
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
    func selectedImageRectInWindow()->CGRect? {
        guard let (_,art,rect)=archive?.selectionSurface() else {return nil}
        let points=[CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.maxY)]
            .map {projectPoint(art.convertPosition(SCNVector3($0.x,$0.y,0),to:nil))}
        let xs=points.map(\.x),ys=points.map(\.y)
        let projected=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
        return convert(projected,to:nil)
    }
    var onSelect: ((String?)->Void)?
    var onHover: ((String?)->Void)?
    var onPointer: ((SCNVector3,SCNVector3,String?)->Void)?
    var onAction: ((SCNHitTestResult)->Bool)?
    var onScroll: ((CGFloat,CGFloat,Bool)->Void)?
    private var pressPoint: CGPoint?
    private var dragged = false
    private var pointerTracking:NSTrackingArea?
    private var aimedID:String?
    private var aimPoint:CGPoint?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard pointerTracking == nil else { return }
        let area = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        pointerTracking = area;addTrackingArea(area)
    }
    override func mouseEntered(with event:NSEvent) { mouseMoved(with:event) }
    override func mouseMoved(with event:NSEvent) {
        guard !isHidden,archive?.isActive != false else {return}
        pointerSamples.submit(convert(event.locationInWindow,from:nil))
    }
    private func updatePointer(at point:CGPoint) {
        guard !isHidden,archive?.isActive != false else {return}
        aimPoint = point
        let (near,far) = pointerRay(at:point)
        let previous = aimedID
        aimedID = archive?.canHitRestingSheets == true ? archive?.record(at:near,toward:far):memoryID(at:point)
        onPointer?(near,far,aimedID)
        if previous != aimedID { onHover?(aimedID) }
    }
    func pointerRay(at point:CGPoint)->(SCNVector3,SCNVector3) {
        archive?.ray(at:point,in:bounds.size) ?? (unprojectPoint(SCNVector3(point.x,point.y,0)),unprojectPoint(SCNVector3(point.x,point.y,1)))
    }
    private func clearPointerAim() {
        pointerSamples.cancel()
        aimedID = nil;aimPoint = nil;onHover?(nil)
    }
    func cancelPendingInteraction() {
        clearPointerAim()
        viewportDelivery?.cancel();viewportDelivery = nil
        viewportRefresh?.cancel();viewportRefresh = nil
    }
    override func mouseExited(with event:NSEvent) { clearPointerAim() }
    override func scrollWheel(with event:NSEvent) {
        clearPointerAim()
        onScroll?(-event.scrollingDeltaY,-event.scrollingDeltaX,event.hasPreciseScrollingDeltas)
    }
    override func mouseDown(with event:NSEvent) {
        pointerSamples.flush(at:convert(event.locationInWindow,from:nil))
        pressPoint = event.locationInWindow;dragged = false
    }
    override func mouseDragged(with event:NSEvent) {
        guard let previous = pressPoint else { return }
        let p = event.locationInWindow
        if dragged || hypot(p.x-previous.x,p.y-previous.y) > 4 {
            clearPointerAim()
            dragged = true;onScroll?(p.y-previous.y,previous.x-p.x,true);pressPoint = p
        }
    }
    override func mouseUp(with event:NSEvent) {
        if !dragged {
            let point = convert(event.locationInWindow,from:nil)
            let hit = hitTest(point,options:[.searchMode:SCNHitTestSearchMode.closest.rawValue,.categoryBitMask:1]).first
            if let hit,onAction?(hit) == true { } else {
                // The wave can move geometry beneath a stationary mouse. Click
                // the hovered sheet, not a newly exposed neighbour.
                let stable = aimPoint.map { hypot(point.x-$0.x,point.y-$0.y) <= 8 } ?? false
                let aimed = aimedID.flatMap { archive?.hoveredID == $0 && archive?.recordIDs.contains($0) == true ? $0:nil }
                archive?.freezeScrolling(report:true)
                onSelect?(stable ? aimed ?? memoryID(at:point):memoryID(at:point))
            }
        }
        pressPoint = nil;dragged = false
    }
    private func memoryID(at p:CGPoint)->String? {
        if let archive,archive.canHitRestingSheets {
            let (near,far) = pointerRay(at:p)
            return archive.record(at:near,toward:far)
        }
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
    var timelinePosition:Date? = nil
    var regions:[TextRegion] = []
    let size:CGSize
    let reduced:Bool
    var active:Bool = true
    let onSelect:(String?)->Void
    let onRecordAction:(String,String)->Void
    var onHoverRecord:((String?)->Void)? = nil
    var onViewportChange:((ArchiveViewportRecords)->Void)? = nil
    var window:ArchiveWindow? = nil
    var onWindowDemand:((Double)->Void)? = nil
    var navigation:ArchiveNavigationTarget? = nil
    var onNavigationSettled:((ArchiveNavigationTarget)->Void)? = nil
    var onNavigationWindowDemand:((Double,ArchiveNavigationTarget)->Void)? = nil
    var onRewindOrigin:((String,CGRect?)->Void)? = nil
    var workBudget:ForegroundWorkBudget? = nil
    func makeCoordinator()->ArchiveGlassScene { ArchiveGlassScene() }
    func makeNSView(context:Context)->SCNView {
        if let workBudget {context.coordinator.bind(to:workBudget)}
        let view = ArchiveSceneView(frame:.zero)
        view.archive = context.coordinator
        context.coordinator.attachAnimation(to:view)
        context.coordinator.onPresentationChanged = { [weak view] in
            view?.updateTextSelection();view?.refreshViewport();view?.needsDisplay = true
        }
        view.scene = context.coordinator.scene;view.pointOfView = context.coordinator.cameraNode
        view.backgroundColor = .clear;view.antialiasingMode = .multisampling2X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false;view.isPlaying = false
        view.onViewportChange = onViewportChange
        context.coordinator.onWindowDemand=onWindowDemand
        context.coordinator.onNavigationSettled=onNavigationSettled
        context.coordinator.onNavigationWindowDemand=onNavigationWindowDemand
        view.onSelect = onSelect
        view.onHover = { [weak coordinator = context.coordinator] id in coordinator?.hover(id);onHoverRecord?(id) }
        view.onPointer = { [weak coordinator = context.coordinator] near,far,id in coordinator?.pointer(rayNear:near,rayFar:far,recordID:id) }
        view.onAction = { [weak coordinator = context.coordinator,weak view] hit in
            guard let (id,action) = coordinator?.action(at:hit) else { return false }
            if action == "rewind",let onRewindOrigin {onRewindOrigin(id,view?.selectedImageRectInWindow());return true}
            onRecordAction(id,action);return true
        }
        view.onScroll = { [weak coordinator = context.coordinator] delta,horizontal,precise in coordinator?.workBudget?.interaction();coordinator?.scroll(by:delta,horizontal:horizontal,precise:precise) }
        return view
    }
    static func dismantleNSView(_ view:SCNView,coordinator:ArchiveGlassScene) {
        (view as? ArchiveSceneView)?.cancelPendingInteraction()
        coordinator.setActive(false);coordinator.stopMotion();coordinator.onPresentationChanged = nil
    }
    func updateNSView(_ view:SCNView,context:Context) {
        if let workBudget {context.coordinator.bind(to:workBudget)}
        context.coordinator.onWindowDemand=onWindowDemand
        context.coordinator.onNavigationSettled=onNavigationSettled
        context.coordinator.onNavigationWindowDemand=onNavigationWindowDemand
        context.coordinator.setActive(active)
        view.isHidden = !active
        guard active else { (view as? ArchiveSceneView)?.cancelPendingInteraction();return }
        (view as? ArchiveSceneView)?.onSelect = onSelect
        (view as? ArchiveSceneView)?.onViewportChange = onViewportChange
        (view as? ArchiveSceneView)?.selectedRegions = regions
        (view as? ArchiveSceneView)?.onHover = { [weak coordinator = context.coordinator] id in coordinator?.hover(id);onHoverRecord?(id) }
        (view as? ArchiveSceneView)?.onAction = { [weak coordinator = context.coordinator,weak view] hit in
            guard let (id,action) = coordinator?.action(at:hit) else { return false }
            if action == "rewind",let onRewindOrigin {onRewindOrigin(id,(view as? ArchiveSceneView)?.selectedImageRectInWindow());return true}
            onRecordAction(id,action);return true
        }
        context.coordinator.update(frames:frames,images:images,appearance:appearance,selected:selected,size:size,reduced:reduced,day:day,timelinePosition:timelinePosition,window:window,navigation:navigation)
        (view as? ArchiveSceneView)?.refreshViewport()
    }
}
