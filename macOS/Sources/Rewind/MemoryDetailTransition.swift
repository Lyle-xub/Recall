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
    private var clock:CADisplayLink?
    private var previousTime:TimeInterval=0
    private var key:String?
    private var target:CGRect?
    private var pendingUpdate:(()->Void)?
    var onSettled:((Int)->Void)?
    var onMotionChanged:((Int,Bool)->Void)?
    var interactionEnabled=true
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
        guard interactionEnabled,image.frame.contains(local) else {return nil}
        return super.hitTest(point)
    }
    func update(id:String,url:URL,regions:[TextRegion],destination:CGRect,inWindow:Bool = false,source:MemoryImageTransitionSource?,radius:CGFloat,reduced:Bool) {
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
        target=destination;revision += 1
        flight=MemoryImageFlight(from:image.frame,to:destination,fromRadius:image.cornerRadius,toRadius:radius)
        onMotionChanged?(revision,true)
        if reduced {advance(by:MemoryImageFlight.duration)}
        else {start()}
    }
    private func start() {
        guard clock == nil else {return}
        previousTime=ProcessInfo.processInfo.systemUptime
        let link=displayLink(target:self,selector:#selector(tick(_:)))
        link.preferredFrameRateRange=CAFrameRateRange(minimum:60,maximum:60,preferred:60)
        clock=link;link.add(to:.main,forMode:.common)
    }
    @objc private func tick(_ link:CADisplayLink) {
        let now=link.targetTimestamp
        advance(by:max(0,min(0.05,now-previousTime)));previousTime=now
    }
    func advance(by duration:TimeInterval) {
        guard var flight else {return}
        flight.elapsed += duration
        CATransaction.begin();CATransaction.setDisableActions(true)
        image.frame=flight.rect;image.cornerRadius=flight.radius;image.layoutSubtreeIfNeeded()
        image.layer?.cornerRadius=flight.radius
        image.layer?.shadowPath=CGPath(roundedRect:image.bounds,cornerWidth:flight.radius,cornerHeight:flight.radius,transform:nil)
        CATransaction.commit()
        self.flight=flight
        if flight.finished {self.flight=nil;clock?.invalidate();clock=nil;onMotionChanged?(revision,false);onSettled?(revision)}
    }
    func stop(cancelImage:Bool = true) {
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
    let onSize:(CGSize)->Void
    let onMotionChanged:(Bool)->Void
    let onOpen:(()->Void)?
    func makeNSView(context:Context)->MemoryImageTransitionView {MemoryImageTransitionView()}
    func updateNSView(_ native:MemoryImageTransitionView,context:Context) {
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
                interactive:!model.videoReady,onSize:{imageSize=$0},onMotionChanged:{moving in
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
