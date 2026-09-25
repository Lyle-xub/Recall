import SwiftUI
import AppKit

struct AppTimeSegment: Identifiable, Sendable {
    let id: String
    let appName: String
    let bundleID: String
    let start: Date
    var end: Date
    var kind: AppUsageKind? = .application
    var duration: TimeInterval { max(0,end.timeIntervalSince(start)) }
}

struct TimelineBadgeCluster: Identifiable {
    var segments: [AppTimeSegment]
    var x: Double
    var id: String { segments[0].id }
}

enum TimelineGeometry {
    static func capsuleRect(start:Double,end:Double,baseline:Double,width:Double) -> CGRect {
        let left = max(-8,start),right = min(width+8,end)
        let span = max(1,right-left), inset = min(1.5,max(0,(span-2)/2))
        return CGRect(x:left+inset,y:baseline-3.5,width:max(1,span-inset*2),height:7)
    }
    static func legacySegments(_ moments:[CapturedAppMoment],interval:Double) -> [AppTimeSegment] {
        // Reuse the established continuity policy with a lightweight projection.
        segments(moments.map { moment in
            MemoryFrame(id:moment.id,timestamp:moment.timestamp,appName:moment.appName,bundleID:moment.bundleID,title:"",imagePath:"",text:"",regions:[],sessionID:moment.sessionID,continuityID:moment.continuityID)
        },interval:interval)
    }
    static func continuous(legacy:[AppTimeSegment],usage:[AppUsageInterval],range:DateInterval,cutover:Date?) -> [AppTimeSegment] {
        var source = legacy.compactMap { segment -> AppTimeSegment? in
            var item = segment
            if let cutover { item.end = min(item.end,cutover); guard item.start < cutover else { return nil } }
            return item
        }
        source += usage.map { AppTimeSegment(id:$0.id,appName:$0.app.name,bundleID:$0.app.bundleID,start:$0.start,end:$0.end,kind:$0.app.kind) }
        source.sort { $0.start < $1.start }
        var result:[AppTimeSegment] = [], edge = range.start
        for var item in source where item.end >= range.start && item.start <= range.end {
            if item.start > edge {
                result.append(AppTimeSegment(id:"gap-\(edge.timeIntervalSince1970)",appName:"No recording",bundleID:"",start:edge,end:min(item.start,range.end),kind:nil))
            }
            guard item.end >= edge else { continue }
            item = AppTimeSegment(id:item.id,appName:item.appName,bundleID:item.bundleID,start:max(edge,item.start),end:min(range.end,item.end),kind:item.kind)
            if let last = result.last,last.bundleID == item.bundleID,last.appName == item.appName,last.kind == item.kind,last.end == item.start {
                result[result.count-1].end = item.end
            } else { result.append(item) }
            edge = max(edge,item.end)
        }
        if edge < range.end { result.append(AppTimeSegment(id:"gap-\(edge.timeIntervalSince1970)",appName:"No recording",bundleID:"",start:edge,end:range.end,kind:nil)) }
        return result
    }
    static let badgeHitWidth = 44.0
    /// All badges share one baseline. Dense moments remain accessible in a
    /// cluster instead of overlapping, jumping lanes, or disappearing.
    static func badges(for segments: [AppTimeSegment], cursor: Date, scale: Double, width: Double) -> [TimelineBadgeCluster] {
        let left = badgeHitWidth / 2, right = width - 94
        guard right > left else { return [] }
        var result: [TimelineBadgeCluster] = []
        for segment in segments {
            let start = x(for:segment.start,cursor:cursor,scale:scale,width:width)
            let end = x(for:segment.end,cursor:cursor,scale:scale,width:width)
            guard end >= 0, start <= right else { continue }
            let center = max(left,min(right,(max(0,start)+min(right,end))/2))
            if let last = result.last, center - last.x < badgeHitWidth {
                let count = Double(last.segments.count)
                result[result.count-1].x = (last.x * count + center) / (count+1)
                result[result.count-1].segments.append(segment)
            } else {
                result.append(TimelineBadgeCluster(segments:[segment],x:center))
            }
        }
        return result
    }
    static func nearest(to date: Date, in frames: [MemoryFrame]) -> MemoryFrame? {
        guard !frames.isEmpty else { return nil }
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].timestamp < date { low = middle + 1 } else { high = middle }
        }
        if low == 0 { return frames[0] }
        if low == frames.count { return frames[frames.count - 1] }
        return date.timeIntervalSince(frames[low - 1].timestamp) <= frames[low].timestamp.timeIntervalSince(date) ? frames[low - 1] : frames[low]
    }
    static func segments(_ frames: [MemoryFrame], interval: Double) -> [AppTimeSegment] {
        var result: [AppTimeSegment] = []
        let gapLimit = max(15, interval * 4)
        for (index, frame) in frames.enumerated() {
            let next = index + 1 < frames.count ? frames[index + 1].timestamp : frame.timestamp.addingTimeInterval(interval)
            let nextFrame = index + 1 < frames.count ? frames[index + 1]:nil
            let continuous = frame.continuityID != nil && frame.continuityID == nextFrame?.continuityID && frame.sessionID == nextFrame?.sessionID
            let knownBreak = frame.continuityID != nil && nextFrame != nil && !continuous
            let end = knownBreak ? frame.timestamp:continuous ? next:min(next, frame.timestamp.addingTimeInterval(gapLimit))
            if let last = result.last, last.bundleID == frame.bundleID, last.appName == frame.appName,
               index > 0, frames[index-1].continuityID == frame.continuityID, frames[index-1].sessionID == frame.sessionID,
               frame.timestamp.timeIntervalSince(last.end) < 0.01 {
                result[result.count - 1].end = end
            } else {
                result.append(AppTimeSegment(id:frame.id, appName:frame.appName, bundleID:frame.bundleID, start:frame.timestamp, end:end))
            }
        }
        return result
    }
    static func x(for date: Date, cursor: Date, scale: Double, width: Double) -> Double {
        width / 2 + date.timeIntervalSince(cursor) * scale
    }
}

struct TimelineView: View {
    @ObservedObject var model: AppModel
    @Binding var jumpOpen: Bool
    @State private var dragAnchor: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var cursor: Date { model.timelineDate }
    var body: some View {
        SwiftUI.TimelineView(.periodic(from:.now,by:1)) { tick in
            GeometryReader { geo in
                let segments = model.displayedTimeline(at:tick.date)
                ZStack(alignment:.bottom) {
                    input
                    TimelineRail(segments:segments,cursor:cursor,scale:model.timelineScale,span:model.timelineSpan)
                        .allowsHitTesting(false)
                    ForEach(TimelineGeometry.badges(for:segments.filter { $0.kind == .application || $0.kind == .recall },cursor:cursor,scale:model.timelineScale,width:geo.size.width)) { cluster in
                        TimelineAppBadge(cluster:cluster,select:{ segment in
                            model.window?.makeFirstResponder(nil); model.scrub(to:segment.start.addingTimeInterval(min(0.1,segment.duration/2)))
                        },focus:{
                            guard let first = cluster.segments.first,let last = cluster.segments.last else { return }
                            model.scrub(to:Date(timeIntervalSince1970:(first.start.timeIntervalSince1970+last.end.timeIntervalSince1970)/2))
                            model.setTimelineSpan(max(60,last.end.timeIntervalSince(first.start)*1.5))
                        })
                        .position(x:cluster.x,y:geo.size.height-39)
                        .simultaneousGesture(DragGesture(minimumDistance:3,coordinateSpace:.named("timeline"))
                            .onChanged { value in
                                model.window?.makeFirstResponder(nil)
                                if dragAnchor == nil { dragAnchor = cursor }
                                if let dragAnchor { model.scrub(to:dragAnchor.addingTimeInterval(-value.translation.width/model.timelineScale)) }
                            }.onEnded { _ in dragAnchor = nil })
                    }
                    playhead
                    HStack {
                        TimelineZoomControl(span:model.timelineSpan,setSpan:{ span in
                            withAnimation(reduceMotion ? nil:.snappy(duration:0.24)) { model.setTimelineSpan(span) }
                        })
                        Spacer()
                    }.padding(.horizontal,28).padding(.bottom,101)
                    HStack {
                        Spacer()
                        RoundButton(symbol:"arrow.right",label:"Return to live desktop") { model.returnToDesktop() }
                    }.padding(.horizontal,28).padding(.bottom,35)
                }.coordinateSpace(name:"timeline").clipped()
                    .onAppear { model.resizeTimeline(width:geo.size.width); model.refreshTimelineActivity(force:true) }
                    .onChange(of:geo.size.width) { _,width in model.resizeTimeline(width:width) }
                    .onChange(of:tick.date) { _,_ in model.refreshTimelineActivity() }
            }.frame(height:TimelinePanelController.height)
        }
        .accessibilityElement(children:.contain).accessibilityLabel("Timeline. Drag or scroll to rewind. Pinch to zoom.")
        .accessibilityAdjustableAction { direction in model.step(direction == .increment ? 1:-1) }
    }
    private var input: some View {
        TimelineInputSurface(pan:{ delta,began in
            model.window?.makeFirstResponder(nil)
            if began { dragAnchor = cursor }
            if let dragAnchor { model.scrub(to:dragAnchor.addingTimeInterval(-delta/model.timelineScale)) }
        },end:{ dragAnchor = nil },wheel:{ dx,dy,zoom in
            model.window?.makeFirstResponder(nil)
            if zoom { model.setTimelineSpan(model.timelineSpan * exp(dy*0.015)) }
            else { model.panTimeline(points:abs(dx) > abs(dy) ? dx:dy) }
        },magnify:{ amount in model.setTimelineSpan(model.timelineSpan / max(0.1,1+amount)) })
    }
    private var playhead: some View {
        VStack(spacing:7) {
            Button { jumpOpen = true } label: {
                Text(relativeTime).font(.system(size:13,weight:.semibold,design:.rounded))
                    .monospacedDigit().padding(.horizontal,22).frame(height:44).contentShape(Rectangle())
                    .liquidGlass(radius:20)
            }.buttonStyle(.plain).help(cursor.formatted(date:.complete,time:.standard))
                .popover(isPresented:$jumpOpen) {
                    VStack(spacing:16) {
                        DatePicker("Go to date",selection:$model.dateJump).datePickerStyle(.graphical)
                        Button("Rewind to this time") { model.jump(to:model.dateJump); jumpOpen = false }.buttonStyle(.borderedProminent)
                    }.padding(20).frame(width:330)
                }
            Capsule().fill(.white).frame(width:3,height:94).shadow(color:.black.opacity(0.2),radius:3).allowsHitTesting(false)
        }
    }
    private var relativeTime: String {
        guard let date = model.timelineCursor else { return "Now" }
        let seconds = max(0,Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) seconds ago" }
        if seconds < 3600 { let minutes = seconds/60; return "\(minutes) minute\(minutes == 1 ? "":"s") ago" }
        if seconds < 86400 { let hours = seconds/3600; return "\(hours) hour\(hours == 1 ? "":"s") ago" }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

private struct TimelineRail: View {
    let segments: [AppTimeSegment]
    let cursor: Date
    let scale: Double
    let span: Double
    var body: some View {
        Canvas { context,size in
            let baseline = size.height-39
            let rail = CGRect(x:-8,y:baseline-1.5,width:size.width+16,height:3)
            context.fill(Path(roundedRect:rail,cornerRadius:1.5),with:.color(.primary.opacity(0.07)))
            for segment in segments where segment.kind != nil {
                let x1 = TimelineGeometry.x(for:segment.start,cursor:cursor,scale:scale,width:size.width)
                let x2 = TimelineGeometry.x(for:segment.end,cursor:cursor,scale:scale,width:size.width)
                guard x2 >= 0,x1 <= size.width else { continue }
                let rect = TimelineGeometry.capsuleRect(start:x1,end:x2,baseline:baseline,width:size.width)
                context.fill(Path(roundedRect:rect,cornerRadius:rect.height/2),with:.color(TimelinePalette.color(for:segment)))
            }
        }
        .overlay {
            Canvas { context,size in
                let step = TimelineZoom.tickStep(for:span)
                let start = cursor.timeIntervalSince1970-span/2
                var time = ceil(start/step)*step
                while time <= start+span {
                    let date = Date(timeIntervalSince1970:time)
                    let x = TimelineGeometry.x(for:date,cursor:cursor,scale:scale,width:size.width)
                    if abs(x-size.width/2) > 34,x > 24,x < size.width-90 {
                        let label = span < 180 ? date.formatted(.dateTime.minute().second()):span < 86400 ? date.formatted(.dateTime.hour().minute()):date.formatted(.dateTime.month(.abbreviated).day().hour())
                        context.draw(Text(label).font(.system(size:10,weight:.medium,design:.rounded)).foregroundStyle(.secondary),at:CGPoint(x:x,y:size.height-76))
                        context.fill(Path(CGRect(x:x-0.5,y:size.height-64,width:1,height:5)),with:.color(.primary.opacity(0.16)))
                    }
                    time += step
                }
            }
        }
    }
}

private struct TimelineAppBadge: View {
    let cluster: TimelineBadgeCluster
    let select: (AppTimeSegment)->Void
    let focus: ()->Void
    @State private var expanded = false
    @State private var hovered = false
    private var names: String { Array(Set(cluster.segments.map(\.appName))).sorted().joined(separator:", ") }
    var body: some View {
        Button {
            if cluster.segments.count == 1 { select(cluster.segments[0]) } else { expanded = true }
        } label: {
            ZStack {
                if cluster.segments.count > 1 {
                    RoundedRectangle(cornerRadius:8).fill(.regularMaterial).frame(width:25,height:25).rotationEffect(.degrees(12)).offset(x:4,y:-3)
                }
                AppBadge(name:cluster.segments[0].appName,bundleID:cluster.segments[0].bundleID,size:26)
                    .overlay(alignment:.topTrailing) {
                        if cluster.segments.count > 1 {
                            Text("\(cluster.segments.count)").font(.system(size:9,weight:.semibold,design:.rounded))
                                .padding(.horizontal,4).frame(minWidth:16,minHeight:16).background(.regularMaterial,in:Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.45),lineWidth:0.5)).offset(x:9,y:-7)
                        }
                    }
            }.scaleEffect(hovered ? 1.10:1).frame(width:44,height:44).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.animation(.easeOut(duration:0.16),value:hovered)
            .accessibilityLabel(cluster.segments.count == 1 ? names : "\(cluster.segments.count) moments: \(names)")
            .help(cluster.segments.count == 1 ? names : "Show \(cluster.segments.count) moments · \(names)")
            .contextMenu { Button("Zoom into these apps",systemImage:"arrow.up.left.and.arrow.down.right",action:focus) }
            .popover(isPresented:$expanded,arrowEdge:.bottom) {
                TimelineActivityPopover(segments:cluster.segments,select:{ segment in expanded = false; select(segment) })
                    .presentationBackground(.regularMaterial)
            }
    }
}

private struct TimelineActivityPopover: View {
    let segments:[AppTimeSegment]
    let select:(AppTimeSegment)->Void
    var body: some View {
        ScrollView(showsIndicators:false) {
            LazyVStack(spacing:0) {
                ForEach(segments) { segment in TimelineActivityRow(segment:segment) { select(segment) } }
            }.padding(8)
        }
        .scrollIndicators(.never)
        // NSPopover owns the complete rounded surface, including its arrow.
        // An additional glass shape produced a second, mismatched set of corners.
        .frame(width:216,height:min(236,CGFloat(segments.count)*44+16))
    }
}

private struct TimelineActivityRow: View {
    let segment:AppTimeSegment
    let action:()->Void
    @State private var hovered = false
    var body: some View {
        Button(action:action) {
            HStack(spacing:10) {
                AppBadge(name:segment.appName,bundleID:segment.bundleID,size:23)
                Text(TimelineClock.range(segment.start,segment.end))
                    .font(.system(size:10,weight:.medium,design:.rounded)).monospacedDigit()
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength:0)
            }.padding(.horizontal,10).frame(height:44).contentShape(RoundedRectangle(cornerRadius:10))
                .background(TimelinePalette.color(for:segment).opacity(hovered ? 0.10:0),in:RoundedRectangle(cornerRadius:10))
        }.buttonStyle(.plain).onHover { hovered = $0 }.animation(.easeOut(duration:0.12),value:hovered)
            .help(segment.appName+" · "+segment.start.formatted(date:.abbreviated,time:.standard))
            .accessibilityLabel(segment.appName+", "+TimelineClock.range(segment.start,segment.end))
    }
}

private struct TimelineZoomControl: View {
    let span:Double
    let setSpan:(Double)->Void
    @State private var choosingSpan = false
    var body: some View {
        HStack(spacing:0) {
            Button { setSpan(span*2) } label: { Image(systemName:"minus").frame(width:44,height:44).contentShape(Rectangle()) }
                .disabled(span >= TimelineZoom.maximum).help("Zoom out · Option-scroll or pinch").accessibilityLabel("Zoom out timeline")
            Button { choosingSpan.toggle() } label: {
                HStack(spacing:6) { Text(TimelineZoom.durationLabel(span)).monospacedDigit(); Image(systemName:"chevron.down").font(.system(size:8,weight:.bold)) }
                    .frame(minWidth:66,minHeight:44).contentShape(Rectangle())
            }.accessibilityLabel("Visible timeline span").help("Time shown across the screen")
                .popover(isPresented:$choosingSpan,arrowEdge:.bottom) {
                    ScrollView(showsIndicators:false) {
                        VStack(spacing:2) {
                            ForEach(TimelineZoom.presets,id:\.self) { value in
                                Button { choosingSpan = false; setSpan(value) } label: {
                                    HStack {
                                        Text(TimelineZoom.durationLabel(value))
                                        Spacer()
                                        if abs(span-value) < 1 { Image(systemName:"checkmark").foregroundStyle(.blue) }
                                    }.padding(.horizontal,12).frame(height:34).contentShape(RoundedRectangle(cornerRadius:9))
                                        .background(abs(span-value) < 1 ? Color.blue.opacity(0.08):.clear,in:RoundedRectangle(cornerRadius:9))
                                }.buttonStyle(.plain)
                            }
                        }.padding(8)
                    }.frame(width:160,height:min(260,CGFloat(TimelineZoom.presets.count)*36+16))
                        .presentationBackground(.regularMaterial)
                }
            Button { setSpan(span/2) } label: { Image(systemName:"plus").frame(width:44,height:44).contentShape(Rectangle()) }
                .disabled(span <= TimelineZoom.minimum).help("Zoom in · Option-scroll or pinch").accessibilityLabel("Zoom in timeline")
        }.font(.system(size:11,weight:.medium)).foregroundStyle(Color.overlayControl).buttonStyle(.plain).liquidGlass(radius:18)
    }
}

/// A real AppKit event surface consumes the complete strip, including transparent
/// pixels. Its native strip window defines the protected rectangle; the input
/// handling and visual desktop blur are independent of one another.
struct TimelineInputSurface: NSViewRepresentable {
    let pan: (Double,Bool)->Void
    let end: ()->Void
    let wheel: (Double,Double,Bool)->Void
    let magnify: (Double)->Void
    func makeNSView(context:Context)->TimelineInputView { let view = TimelineInputView(); configure(view); return view }
    func updateNSView(_ view:TimelineInputView,context:Context) { configure(view) }
    private func configure(_ view:TimelineInputView) { view.pan = pan; view.end = end; view.wheel = wheel; view.zoom = magnify }
}
final class TimelineInputView: NSView {
    var pan: ((Double,Bool)->Void)?
    var end: (()->Void)?
    var wheel: ((Double,Double,Bool)->Void)?
    var zoom: ((Double)->Void)?
    private var anchor: CGFloat?
    private var dragging = false
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard tracking == nil else { return }
        let area = NSTrackingArea(rect:.zero,options:[.activeAlways,.inVisibleRect,.mouseEnteredAndExited,.mouseMoved,.cursorUpdate],owner:self)
        addTrackingArea(area); tracking = area
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
    override func cursorUpdate(with event:NSEvent) { (dragging ? NSCursor.closedHand:NSCursor.openHand).set() }
    override func mouseEntered(with event:NSEvent) { NSCursor.openHand.set() }
    override func mouseMoved(with event:NSEvent) { NSCursor.openHand.set() }
    override func mouseExited(with event:NSEvent) { if !dragging { NSCursor.arrow.set() } }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { true }
    override func mouseDown(with event:NSEvent) { anchor = event.locationInWindow.x; dragging = false }
    override func mouseDragged(with event:NSEvent) {
        guard let anchor else { return }
        let delta = event.locationInWindow.x-anchor
        guard abs(delta) >= 2 || dragging else { return }
        pan?(delta,!dragging); dragging = true; NSCursor.closedHand.set()
    }
    override func mouseUp(with event:NSEvent) { if dragging { end?() }; anchor = nil; dragging = false; NSCursor.openHand.set() }
    override func rightMouseDown(with event:NSEvent) {}
    override func otherMouseDown(with event:NSEvent) {}
    override func scrollWheel(with event:NSEvent) { wheel?(event.scrollingDeltaX,event.scrollingDeltaY,event.modifierFlags.contains(.option)) }
    override func magnify(with event:NSEvent) { zoom?(event.magnification) }
    override func hitTest(_ point:NSPoint)->NSView? { bounds.contains(convert(point,from:superview)) ? self:nil }
}
