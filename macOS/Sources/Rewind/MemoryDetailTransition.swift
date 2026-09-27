import SwiftUI
import AppKit

struct MemoryImageTransitionSource {
    let id:String
    let image:NSImage
    let rectInWindow:CGRect
    var radius:CGFloat=19
}

/// Window coordinates allow SwiftUI grid thumbnails and SceneKit artwork to
/// hand off to the same native surface without guessing toolbar/padding sizes.
@MainActor final class MemoryImageAnchorView:NSView {
    var onRect:((CGRect)->Void)?
    private var lastRect:CGRect?
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func layout() {super.layout();report()}
    override func viewDidMoveToWindow() {super.viewDidMoveToWindow();report()}
    func imageRect(_ image:NSImage)->CGRect {convert(Self.fit(image.size,in:bounds),to:nil)}
    private func report() {
        guard window != nil,bounds.width>0,bounds.height>0 else {return}
        let rect=convert(bounds,to:nil)
        guard rect != lastRect else {return};lastRect=rect
        DispatchQueue.main.async { [weak self] in guard let self,self.window != nil,self.lastRect == rect else {return};self.onRect?(rect) }
    }
    static func fit(_ image:CGSize,in bounds:CGRect)->CGRect {
        let ratio=max(0.01,image.width/max(1,image.height))
        let width=min(bounds.width,bounds.height*ratio),height=width/ratio
        return CGRect(x:bounds.midX-width/2,y:bounds.midY-height/2,width:width,height:height)
    }
}
struct MemoryImageAnchor:NSViewRepresentable {
    let view:MemoryImageAnchorView
    var onRect:((CGRect)->Void)?
    func makeNSView(context:Context)->MemoryImageAnchorView {view}
    func updateNSView(_ native:MemoryImageAnchorView,context:Context) {native.onRect=onRect;native.needsLayout=true}
}

struct MemoryImageFlight {
    var from:CGRect
    var to:CGRect
    var fromRadius:CGFloat
    var toRadius:CGFloat
    var elapsed=0.0
    static let duration=0.48
    var finished:Bool {elapsed >= Self.duration}
    var progress:CGFloat {
        let t=min(1,max(0,elapsed/Self.duration))
        // A normalized, critically damped response reaches the exact geometry
        // in a finite animation, with no delayed navigation callback or sleep.
        return CGFloat((1-(1+9*t)*exp(-9*t))/(1-10*exp(-9)))
    }
    var rect:CGRect {
        let p=progress
        return CGRect(x:from.minX+(to.minX-from.minX)*p,y:from.minY+(to.minY-from.minY)*p,
            width:from.width+(to.width-from.width)*p,height:from.height+(to.height-from.height)*p)
    }
    var radius:CGFloat {fromRadius+(toRadius-fromRadius)*progress}
}

@MainActor final class MemoryImageTransitionView:NSView {
    let image=LiveTextImageView()
    private(set) var flight:MemoryImageFlight?
    private(set) var revision=0
    var presentedFrame:CGRect {flight?.rect ?? image.frame}
    var presentedCornerRadius:CGFloat {flight?.radius ?? image.cornerRadius}
    private var clock:CADisplayLink?
    weak var workBudget:ForegroundWorkBudget?
    private var activityLease:UUID?
    private var previousTime:TimeInterval=0
    private var key:String?
    private var target:CGRect?
    private var pendingUpdate:(()->Void)?
    var onSettled:((Int)->Void)?
    var onMotionChanged:((Int,Bool)->Void)?
    var interactionEnabled=true
    /// Optional native benchmark instrumentation; no clock reads in ordinary use.
    var onFrameMeasured:((Double,Double)->Void)?
    private var measuredPrevious:TimeInterval?
    override var isFlipped:Bool {true}
    override init(frame:NSRect) {
        super.init(frame:frame);image.wantsLayer=true
        image.layer?.backgroundColor=NSColor.black.withAlphaComponent(0.08).cgColor
        image.layer?.borderColor=NSColor.white.withAlphaComponent(0.7).cgColor
        image.layer?.borderWidth=1.5;image.layer?.shadowColor=NSColor.black.cgColor
        image.layer?.shadowOpacity=0.26;image.layer?.shadowRadius=28;image.layer?.shadowOffset=CGSize(width:0,height:-12)
        addSubview(image)
    }
    required init?(coder:NSCoder) {fatalError("init(coder:) has not been implemented")}
    override func hitTest(_ point:NSPoint)->NSView? {
        let local=convert(point,from:superview)
        guard interactionEnabled,presentedFrame.contains(local) else {return nil}
        // OCR hit rectangles describe the stable backing surface during flight.
        // Consume its clicks until it lands, then restore native text selection.
        return flight == nil ? super.hitTest(point):self
    }
    func update(id:String,url:URL,regions:[TextRegion],destination:CGRect,inWindow:Bool = false,source:MemoryImageTransitionSource?,radius:CGFloat,reduced:Bool) {
        guard workBudget?.state.stopped != true else {stop();return}
        guard window != nil else {
            pendingUpdate={ [weak self] in self?.update(id:id,url:url,regions:regions,destination:destination,inWindow:inWindow,source:source,radius:radius,reduced:reduced) };return
        }
        let destination=inWindow ? convert(destination,from:nil):destination
        if key != id {
            stop(cancelImage:false);key=id;target=nil
            if let source,source.id == id {
                image.seed(source.image,for:url);image.frame=convert(source.rectInWindow,from:nil);image.cornerRadius=source.radius
            } else {image.frame=destination;image.cornerRadius=radius}
            image.layer?.cornerRadius=image.cornerRadius
            image.layer?.shadowPath=CGPath(roundedRect:image.bounds,cornerWidth:image.cornerRadius,cornerHeight:image.cornerRadius,transform:nil)
            image.layoutSubtreeIfNeeded()
        }
        image.load(url,regions:regions,maxPixels:3072)
        guard destination.width>0,destination.height>0 else {return}
        if target == destination,flight?.toRadius == radius || (flight == nil && image.cornerRadius == radius) {
            if flight == nil {onMotionChanged?(revision,false);onSettled?(revision)}
            return
        }
        let from=presentedFrame,fromRadius=presentedCornerRadius
        target=destination;revision += 1
        flight=MemoryImageFlight(from:from,to:destination,fromRadius:fromRadius,toRadius:radius)
        // Lay out at the larger endpoint exactly once, so shrinking flights do
        // not magnify a thumbnail-sized backing store. Only layer composition
        // changes per frame; AppKit image drawing and OCR geometry stay stable.
        CATransaction.begin();CATransaction.setDisableActions(true)
        image.layer?.transform=CATransform3DIdentity
        image.frame=CGRect(origin:destination.origin,size:CGSize(width:max(from.width,destination.width),height:max(from.height,destination.height)))
        image.cornerRadius=radius;image.layoutSubtreeIfNeeded()
        image.layer?.shadowPath=CGPath(roundedRect:image.bounds,cornerWidth:radius,cornerHeight:radius,transform:nil)
        compose(rect:from,radius:fromRadius)
        CATransaction.commit()
        if activityLease == nil {activityLease=workBudget?.beginActivity()}
        onMotionChanged?(revision,true)
        if reduced {advance(by:MemoryImageFlight.duration)}
        else {start()}
    }
    private func start() {
        guard clock == nil else {return}
        measuredPrevious=nil
        previousTime=ProcessInfo.processInfo.systemUptime
        let link=displayLink(target:self,selector:#selector(tick(_:)))
        let maximum=Float(window?.screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange=CAFrameRateRange(minimum:min(60,maximum),maximum:maximum,preferred:maximum)
        clock=link;link.add(to:.main,forMode:.common)
    }
    @objc private func tick(_ link:CADisplayLink) {
        let now=link.targetTimestamp
        let began=onFrameMeasured == nil ? nil:ProcessInfo.processInfo.systemUptime
        advance(by:max(0,min(0.05,now-previousTime)));previousTime=now
        if let began {
            if let measuredPrevious {onFrameMeasured?((began-measuredPrevious)*1000,(ProcessInfo.processInfo.systemUptime-began)*1000)}
            measuredPrevious=began
        }
    }
    func advance(by duration:TimeInterval) {
        guard var flight else {return}
        flight.elapsed += duration
        CATransaction.begin();CATransaction.setDisableActions(true)
        if flight.finished {land(rect:flight.to,radius:flight.toRadius)}
        else {compose(rect:flight.rect,radius:flight.radius)}
        CATransaction.commit()
        self.flight=flight
        if flight.finished {self.flight=nil;clock?.invalidate();clock=nil;releaseActivity();onMotionChanged?(revision,false);onSettled?(revision)}
    }
    private func compose(rect:CGRect,radius:CGFloat) {
        let sx=rect.width/max(1,image.frame.width),sy=rect.height/max(1,image.frame.height)
        if let layer=image.layer {
            // AppKit uses a bottom-left anchor for this backing layer, and its
            // parent layer need not share the flipped NSView coordinate space.
            var destination=rect
            if isFlipped != (layer.superlayer?.isGeometryFlipped ?? false) {destination.origin.y=bounds.height-rect.maxY}
            let tx=destination.minX+layer.anchorPoint.x*destination.width-layer.position.x
            let ty=destination.minY+layer.anchorPoint.y*destination.height-layer.position.y
            layer.setAffineTransform(CGAffineTransform(a:sx,b:0,c:0,d:sy,tx:tx,ty:ty))
        }
        let scale=max(0.01,min(sx,sy))
        image.setCompositedCornerRadius(radius/scale)
        image.layer?.cornerRadius=radius/scale
        image.layer?.borderWidth=1.5/scale
        image.layer?.shadowRadius=28/scale
        image.layer?.shadowOffset=CGSize(width:0,height:-12/scale)
    }
    private func land(rect:CGRect,radius:CGFloat) {
        image.layer?.transform=CATransform3DIdentity
        image.frame=rect;image.cornerRadius=radius;image.layoutSubtreeIfNeeded()
        image.setCompositedCornerRadius(nil)
        image.layer?.cornerRadius=radius;image.layer?.borderWidth=1.5
        image.layer?.shadowRadius=28;image.layer?.shadowOffset=CGSize(width:0,height:-12)
        image.layer?.shadowPath=CGPath(roundedRect:image.bounds,cornerWidth:radius,cornerHeight:radius,transform:nil)
    }
    private func releaseActivity() {let lease=activityLease;activityLease=nil;workBudget?.endActivity(lease)}
    func stop(cancelImage:Bool = true) {
        releaseActivity()
        if let flight {
            CATransaction.begin();CATransaction.setDisableActions(true)
            land(rect:flight.rect,radius:flight.radius);CATransaction.commit()
        }
        revision += 1;clock?.invalidate();clock=nil;flight=nil;pendingUpdate=nil
        if cancelImage {image.cancelAnalysis()}
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {stop()} else {let pending=pendingUpdate;pendingUpdate=nil;pending?()}
    }
}

private struct MemoryMovingImage:NSViewRepresentable {
    let id:String
    let url:URL
    let regions:[TextRegion]
    let destination:CGRect
    var destinationInWindow=false
    let source:MemoryImageTransitionSource?
    let radius:CGFloat
    let reduced:Bool
    let interactive:Bool
    let workBudget:ForegroundWorkBudget
    let onSize:(CGSize)->Void
    let onMotionChanged:(Bool)->Void
    let onOpen:(()->Void)?
    func makeNSView(context:Context)->MemoryImageTransitionView {MemoryImageTransitionView()}
    func updateNSView(_ native:MemoryImageTransitionView,context:Context) {
        native.workBudget=workBudget
        native.image.onImageSize=onSize;native.image.onOpen=onOpen;native.interactionEnabled=interactive
        native.onMotionChanged={ [weak native] revision,moving in
            DispatchQueue.main.async {guard native?.revision == revision else {return};onMotionChanged(moving)}
        }
        native.update(id:id,url:url,regions:regions,destination:destination,inWindow:destinationInWindow,source:source,radius:radius,reduced:reduced)
    }
    static func dismantleNSView(_ native:MemoryImageTransitionView,coordinator:()) {native.onMotionChanged=nil;native.onSettled=nil;native.stop()}
}

struct MemoryDetailStage:View {
    private struct Presentation:Equatable {let id:String;let detail:Bool}
    @ObservedObject var model:AppModel
    let frame:MemoryFrame
    let screen:CGSize
    let topInset:CGFloat
    let source:MemoryImageTransitionSource?
    let onOpen:()->Void
    var onChromeChanged:((Bool)->Void)?
    var reducedMotionOverride:Bool?
    @State private var imageSize:CGSize?
    @State private var destinationInWindow:CGRect?
    @State private var detailAnchor=MemoryImageAnchorView()
    @State private var settledPresentation:Presentation?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion:Bool {reducedMotionOverride ?? systemReduceMotion}
    private var isDetail:Bool {model.inspectorOpen}
    private var presentation:Presentation {Presentation(id:frame.id,detail:isDetail)}
    private var showsChrome:Bool {isDetail && settledPresentation == presentation}
    var body:some View {
        let presentation=presentation
        let size=imageSize ?? (source?.id == frame.id ? source?.image.size:nil) ?? screen
        let history=HistoryPreviewGeometry.rect(screen:screen,image:size,topInset:topInset)
        let detail=destinationInWindow.map {MemoryImageAnchorView.fit(size,in:$0)}
        let path=isDetail && model.meetingView ? frame.meetingImagePath ?? frame.imagePath:frame.imagePath
        ZStack(alignment:.topLeading) {
            MemoryMovingImage(id:frame.id,url:model.store.root.appendingPathComponent(path),regions:isDetail && model.meetingView ? frame.meetingRegions:frame.regions,
                destination:isDetail ? detail ?? history:history,destinationInWindow:isDetail && detail != nil,source:source,radius:isDetail ? 14:22,reduced:reduceMotion,
                interactive:!model.videoReady,workBudget:model.foregroundWork,onSize:{imageSize=$0},onMotionChanged:{moving in
                    guard model.inspectorOpen == presentation.detail,model.selected?.id == presentation.id else {return}
                    if moving {if settledPresentation == presentation {settledPresentation=nil}}
                    else if settledPresentation != presentation {settledPresentation=presentation}
                },onOpen:isDetail ? nil:onOpen)
            DetailView(model:model,frame:frame,showsPoster:false,imageAnchor:detailAnchor,onImageBounds:{destinationInWindow=$0})
                .padding(.horizontal,40).padding(.top,topInset+110).padding(.bottom,32)
                .opacity(showsChrome ? 1:0)
                .allowsHitTesting(showsChrome)
                .accessibilityHidden(!showsChrome)
                .animation(reduceMotion ? nil:.easeOut(duration:0.16),value:showsChrome)
        }
        .transaction {$0.animation=nil}
        .onChange(of:isDetail) {_,_ in settledPresentation=nil}
        .onChange(of:frame.id) {_,_ in settledPresentation=nil;imageSize=nil}
        .onChange(of:showsChrome) {_,visible in onChromeChanged?(visible)}
    }
}
