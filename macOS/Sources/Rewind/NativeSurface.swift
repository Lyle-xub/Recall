import SwiftUI
import AppKit
import ImageIO

/// The window is a transparent desktop overlay; only its controls draw material.
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if #available(macOS 26.0, *) { safeAreaRegions = [] }
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

/// A single native editor owns text, composition and its placeholder. Opting
/// out of vibrancy keeps AppKit from darkening placeholder ink inside glass.
struct NativeSearchField:NSViewRepresentable {
    @Binding var text:String
    @Binding var focused:Bool
    var placeholder:String
    var fontSize:CGFloat
    var onSubmit:()->Void
    @Environment(\.colorScheme) private var scheme
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeNSView(context:Context)->Field {
        let field = Field()
        field.isBordered = false;field.drawsBackground = false;field.focusRingType = .none
        field.cell?.wraps = false;field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        field.delegate = context.coordinator
        field.didFocus = { [weak coordinator = context.coordinator] in coordinator?.parent.focused = true }
        field.setAccessibilityLabel("Search memories")
        return field
    }
    func updateNSView(_ field:Field,context:Context) {
        context.coordinator.parent = self
        field.appearance = NSAppearance(named:scheme == .dark ? .darkAqua:.aqua)
        field.font = .systemFont(ofSize:fontSize)
        field.textColor = scheme == .dark ? .white:.black
        field.placeholderAttributedString = NSAttributedString(string:placeholder,attributes:[
            .font:NSFont.systemFont(ofSize:fontSize),
            .foregroundColor:NSColor(white:scheme == .dark ? 0.78:0.40,alpha:1)])
        let editor = field.currentEditor() as? NSTextView
        if field.stringValue != text,editor?.hasMarkedText() != true { field.stringValue = text }
        if let editor { editor.insertionPointColor = scheme == .dark ? .white:.black }
        let needsFocus = focused
        DispatchQueue.main.async { [weak field] in
            guard let field,let window = field.window,
                  context.coordinator.parent.focused == needsFocus else { return }
            if needsFocus,field.currentEditor() == nil { window.makeFirstResponder(field) }
            else if !needsFocus,field.currentEditor() != nil { window.makeFirstResponder(nil) }
        }
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:Field,context:Context)->CGSize? {
        CGSize(width:proposal.width ?? 200,height:ceil(NSFont.systemFont(ofSize:fontSize).boundingRectForFont.height))
    }
    final class Field:NSTextField {
        var didFocus:(()->Void)?
        override var allowsVibrancy:Bool { false }
        override func becomeFirstResponder()->Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { didFocus?() }
            return accepted
        }
    }
    final class Coordinator:NSObject,NSTextFieldDelegate {
        var parent:NativeSearchField
        init(_ parent:NativeSearchField) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification:Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification:Notification) { parent.focused = false }
        func controlTextDidChange(_ notification:Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.text = field.stringValue
        }
        func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit();return true
        }
    }
}

/// A nonzero-alpha surface keeps WindowServer from passing transparent-pixel
/// clicks into other apps. Controls and Live Text are layered above this view.
struct DesktopClickShield: View {
    var dismiss: () -> Void
    var body: some View {
        // Keep dismissal in SwiftUI's hit-test tree. A full-window native NSView
        // can intercept clicks before the SwiftUI controls above it receive them.
        Color.black.opacity(0.01).contentShape(Rectangle())
            .onTapGesture(perform:dismiss).accessibilityHidden(true)
    }
}

enum HistoryPreviewGeometry {
    static func rect(screen:CGSize,image:CGSize,topInset:CGFloat)->CGRect {
        let top = topInset + 146
        let available = CGSize(width:screen.width*0.86,height:max(120,screen.height-top-212))
        let ratio = max(0.1,image.width/max(1,image.height))
        let width = min(available.width,available.height*ratio), height = min(available.height,available.width/ratio)
        return CGRect(x:(screen.width-width)/2,y:top+(available.height-height)/2,width:width,height:height)
    }
}

struct ComfortableButtonStyle: ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label.frame(minWidth:44,minHeight:44).contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65:1)
    }
}

extension View {
    /// Both archive and classic pages share the same native control material.
    func liquidGlass(radius: CGFloat = 24, interactive: Bool = true) -> some View {
        modifier(NativeGlassModifier(radius:radius,interactive:interactive))
    }
}

/// Results share the single full-window desktop material. macOS scroll-edge
/// treatments would add a second rectangular veil beneath the filter row.
struct ContinuousResultsBackground:ViewModifier {
    var fadesVerticalEdges = false
    func body(content:Content)->some View {
        Group {
            if #available(macOS 26.0, *) {
                content.scrollContentBackground(.hidden).scrollEdgeEffectHidden(true,for:.all)
            } else { content.scrollContentBackground(.hidden) }
        }.mask {
            if fadesVerticalEdges {
                // Glass shadows extend beyond each card. Fade their clipping
                // boundary into the shared backdrop instead of a hard shelf.
                VStack(spacing:0) {
                    LinearGradient(colors:[.clear,.black],startPoint:.top,endPoint:.bottom).frame(height:24)
                    Rectangle().fill(.black)
                    LinearGradient(colors:[.black,.clear],startPoint:.top,endPoint:.bottom).frame(height:24)
                }
            } else { Rectangle().fill(.black) }
        }
    }
}

private struct NativeGlassModifier: ViewModifier {
    let radius: CGFloat
    let interactive: Bool
    func body(content:Content)->some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive),in:RoundedRectangle(cornerRadius:radius,style:.continuous))
        } else {
            content.background(.regularMaterial,in:RoundedRectangle(cornerRadius:radius,style:.continuous))
        }
    }
}

struct SearchGlassGroup<Content:View>: View {
    @ViewBuilder var content:()->Content
    var body:some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing:18) { content() } }
        else { content() }
    }
}

struct SearchGlassSurface: ViewModifier {
    let id:String
    let namespace:Namespace.ID
    let radius:CGFloat
    func body(content:Content)->some View {
        if #available(macOS 26.0, *) { content.liquidGlass(radius:radius).glassEffectID(id,in:namespace) }
        else { content.liquidGlass(radius:radius) }
    }
}

struct DesktopBlur: NSViewRepresentable {
    var fadesUpward = false
    var material:NSVisualEffectView.Material = .fullScreenUI
    func makeNSView(context: Context) -> DesktopEffectView {
        let view = DesktopEffectView()
        view.blendingMode = .behindWindow
        view.material = material
        view.state = .active
        view.fadesUpward = fadesUpward
        return view
    }
    func updateNSView(_ view: DesktopEffectView, context: Context) {
        view.material = material
        view.fadesUpward = fadesUpward
    }
}

final class DesktopEffectView: NSVisualEffectView {
    var fadesUpward = false { didSet { if oldValue != fadesUpward { updateMask() } } }
    private func updateMask() {
        guard fadesUpward else { maskImage = nil; return }
        // Install before the first draw, not in a later layout pass; otherwise
        // launch briefly shows an unmasked rectangular block of blur.
        // Public AppKit material + alpha mask: the desktop remains live behind it.
        // Opaque at the Dock, fading completely before the upper edge.
        let size = NSSize(width: 16, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill(); NSRect(origin:.zero,size:size).fill(using:.copy)
        for row in 0..<512 {
            // AppKit y=0 is the bottom. Leave the top 18% completely clear,
            // then use a smoothstep curve rather than linear opacity stops.
            NSColor.black.withAlphaComponent(TimelineBlurProfile.opacity(at:1-Double(row)/511)).setFill()
            NSRect(x:0,y:row,width:16,height:1).fill(using:.copy)
        }
        image.unlockFocus()
        image.resizingMode = .stretch
        maskImage = image
    }
}

/// Select original OCR text directly over the recorded pixels.
struct SelectableMemoryImage: NSViewRepresentable {
    let url: URL
    var regions:[TextRegion] = []
    var maxPixels = 3072
    var cornerRadius:CGFloat = 22
    var onImageSize: ((CGSize)->Void)? = nil
    func makeNSView(context: Context) -> LiveTextImageView { LiveTextImageView() }
    func updateNSView(_ view: LiveTextImageView, context: Context) { view.cornerRadius = cornerRadius;view.onImageSize = onImageSize; view.load(url,regions:regions,maxPixels:maxPixels) }
    static func dismantleNSView(_ view: LiveTextImageView, coordinator: ()) { view.cancelAnalysis() }
}

@MainActor final class LiveTextImageView: NSView {
    private let content = NSView()
    private let picture = NSImageView()
    private let indexedText = IndexedTextOverlay()
    private var task: Task<Void, Never>?
    private var loadedURL: URL?
    private var displayedURL:URL?
    private var latestRegions:[TextRegion] = []
    var onImageSize: ((CGSize)->Void)?
    var cornerRadius:CGFloat = 22 { didSet { if oldValue != cornerRadius { needsLayout = true } } }
    private final class Recognition { let regions:[TextRegion];init(_ regions:[TextRegion]) { self.regions = regions } }
    private static let analyses = NSCache<NSURL,Recognition>()
    override var isOpaque: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        content.layer?.cornerCurve = .continuous
        addSubview(content)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignCenter
        picture.setAccessibilityLabel("Recorded screen. Drag across text to select, then press Command C to copy.")
        content.addSubview(picture)
        content.addSubview(indexedText)
        Self.analyses.countLimit = 12
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        // Round the actual fitted pixels, not the letterboxed SwiftUI view.
        // Keep the selection in this same surface so its coordinates and
        // highlights remain aligned when the transcript changes the layout.
        let size = picture.image?.size ?? .zero
        let factor = size.width > 0 && size.height > 0 ? min(bounds.width/size.width,bounds.height/size.height):0
        let fitted = CGSize(width:size.width*factor,height:size.height*factor)
        let rect = CGRect(x:bounds.midX-fitted.width/2,y:bounds.midY-fitted.height/2,width:fitted.width,height:fitted.height)
        CATransaction.begin();CATransaction.setDisableActions(true)
        content.frame = rect
        content.layer?.cornerRadius = min(cornerRadius,min(fitted.width,fitted.height)/2)
        picture.frame = content.bounds;indexedText.frame = content.bounds
        CATransaction.commit()
    }
    func load(_ url: URL,regions:[TextRegion],maxPixels:Int = 3072) {
        latestRegions = regions
        if loadedURL == url {
            if displayedURL == url {
                let effective = regions.isEmpty ? Self.analyses.object(forKey:url as NSURL)?.regions ?? []:regions
                indexedText.setRegions(effective);indexedText.isHidden = effective.isEmpty
            }
            return
        }
        loadedURL = url;task?.cancel();indexedText.isHidden = true
        task = Task { [weak self] in
            // Coalesce updates from the same display frame during fast scrubs.
            try? await Task.sleep(for:.milliseconds(16))
            guard !Task.isCancelled else { return }
            let decoded = await MemoryImagePipeline.previews.image(at:url,maxPixels:maxPixels)
            guard !Task.isCancelled,let self,self.loadedURL == url else { return }
            guard let pixels = decoded else { picture.image = nil;needsLayout = true;return }
            let image = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
            picture.image = image;displayedURL = url;needsLayout = true;onImageSize?(image.size)
            indexedText.imageSize = image.size
            indexedText.setRegions(latestRegions);indexedText.isHidden = latestRegions.isEmpty
            if !latestRegions.isEmpty { return }
            if let cached = Self.analyses.object(forKey:url as NSURL) { indexedText.setRegions(cached.regions);indexedText.isHidden = false;return }
            try? await Task.sleep(for:.milliseconds(650))
            guard !Task.isCancelled,latestRegions.isEmpty else { return }
            do {
                // Only a settled, unindexed image needs this on-demand pass.
                // Indexed screenshots never run OCR again during navigation.
                let work = Task.detached(priority:.utility) { () throws -> [TextRegion] in
                    try Task.checkCancellation()
                    guard let original = StoredImage.load(url) else { return [] }
                    return try NativeOCR.recognize(original).1
                }
                let regions = try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                guard !Task.isCancelled,loadedURL == url,latestRegions.isEmpty else { return }
                Self.analyses.setObject(Recognition(regions),forKey:url as NSURL)
                indexedText.setRegions(regions);indexedText.isHidden = regions.isEmpty
            } catch { /* Indexed OCR remains available in the inspector. */ }
        }
    }
    func cancelAnalysis() { task?.cancel() }
}

@MainActor enum AppIconCache {
    private static var icons: [String: NSImage] = [:]
    private static var missingUntil: [String:Date] = [:]
    static func image(name: String, bundleID: String?) -> NSImage? {
        let key = bundleID.flatMap { $0.isEmpty ? nil:$0 } ?? name
        if let cached = icons[key] { return cached }
        if let retry = missingUntil[key],retry > Date() { return nil }
        let url = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ?? NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.bundleURL
        guard let url else { missingUntil[key] = Date().addingTimeInterval(30); return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[key] = image
        return image
    }
}

/// NSTextField's field editor consumes mouseDown before SwiftUI tap gestures.
/// Observe only clicks inside this search field; preserve the original event so
/// cursor positioning, selection and dragging keep their native behavior.
struct SearchClickObserver: NSViewRepresentable {
    let clicked: () -> Void
    func makeNSView(context:Context)->SearchClickObservationView { SearchClickObservationView() }
    func updateNSView(_ view:SearchClickObservationView,context:Context) { view.clicked = clicked }
    static func dismantleNSView(_ view:SearchClickObservationView,coordinator:()) { view.stop() }
}
final class SearchClickObservationView: NSView {
    var clicked: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point:NSPoint)->NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching:.leftMouseDown) { [weak self] event in
            guard let self,let window = self.window,event.window === window,
                  window.attachedSheet == nil,!self.isHiddenOrHasHiddenAncestor,
                  self.bounds.contains(self.convert(event.locationInWindow,from:nil)) else { return event }
            self.clicked?()
            return event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

/// One selection document covers every OCR line. Only the two partial endpoint
/// lines need glyph layouts; whole lines use their recorded boxes directly.
struct ScreenTextPosition:Comparable,Equatable {
    let line:Int
    let offset:Int
    static func <(lhs:Self,rhs:Self)->Bool { lhs.line == rhs.line ? lhs.offset < rhs.offset:lhs.line < rhs.line }
}

struct ScreenTextSelection {
    let anchor:ScreenTextPosition
    let head:ScreenTextPosition
    var allColumns = false
    func ranges(in regions:[TextRegion])->[(Int,NSRange)] {
        let first = min(anchor,head),last = max(anchor,head)
        guard regions.indices.contains(first.line),regions.indices.contains(last.line) else { return [] }
        let left = min(regions[first.line].x,regions[last.line].x)
        let right = max(regions[first.line].x+regions[first.line].width,regions[last.line].x+regions[last.line].width)
        return (first.line...last.line).filter { index in
            guard !allColumns,index != first.line,index != last.line else { return true }
            let region = regions[index]
            let overlap = min(right,region.x+region.width)-max(left,region.x)
            return overlap > min(region.width,right-left)*0.2
        }.map { index in
            let text = regions[index].text as NSString
            let start = index == first.line ? min(text.length,max(0,first.offset)):0
            let end = index == last.line ? min(text.length,max(start,last.offset)):text.length
            let range = NSRange(location:start,length:end-start)
            return (index,range.length == 0 ? range:text.rangeOfComposedCharacterSequences(for:range))
        }
    }
    func text(in regions:[TextRegion])->String {
        ranges(in:regions).map { (regions[$0.0].text as NSString).substring(with:$0.1) }.joined(separator:"\n")
    }
}

@MainActor private final class ScreenTextLineLayout {
    let size:CGSize
    private let manager = NSLayoutManager()
    private let storage:NSTextStorage
    private let container:NSTextContainer
    init(_ text:String) {
        let font = NSFont.systemFont(ofSize:16)
        size = CGSize(width:max(1,(text as NSString).size(withAttributes:[.font:font]).width+2),height:ceil(font.ascender-font.descender+font.leading)+2)
        storage = NSTextStorage(string:text,attributes:[.font:font])
        container = NSTextContainer(containerSize:size);container.lineFragmentPadding = 0
        storage.addLayoutManager(manager);manager.addTextContainer(container);manager.ensureLayout(for:container)
    }
    func index(at fraction:CGFloat)->Int {
        if fraction <= 0 { return 0 };if fraction >= 1 { return storage.length }
        return min(storage.length,manager.characterIndex(for:CGPoint(x:fraction*size.width,y:size.height/2),in:container,fractionOfDistanceBetweenInsertionPoints:nil))
    }
    func boxes(for range:NSRange)->[CGRect] {
        let glyphs = manager.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
        var result:[CGRect] = []
        manager.enumerateEnclosingRects(forGlyphRange:glyphs,withinSelectedGlyphRange:glyphs,in:container) { rect,_ in result.append(rect) }
        return result
    }
}

/// The selection paints only translucent blue. No NSTextView/Live Text layer
/// can replace the screenshot with an opaque or inactive grey text background.
@MainActor final class IndexedTextOverlay:NSView,NSMenuItemValidation {
    override var isFlipped:Bool {true}
    override var isOpaque:Bool {false}
    override var acceptsFirstResponder:Bool {true}
    var imageSize:CGSize = .zero { didSet { if oldValue != imageSize { needsLayout = true } } }
    private var regions:[TextRegion] = []
    private var rects:[CGRect] = []
    private var layouts:[Int:ScreenTextLineLayout] = [:]
    private(set) var selection:ScreenTextSelection?
    var selectedText:String { selection?.text(in:regions) ?? "" }
    func setRegions(_ value:[TextRegion]) {
        guard regions != value else { return }
        regions = value;selection = nil;layouts.removeAll()
        needsLayout = true;needsDisplay = true
        setAccessibilityElement(true);setAccessibilityRole(.staticText)
        setAccessibilityLabel("Recognized text. Drag to select across lines, then press Command C to copy.")
    }
    private func textLayout(_ index:Int)->ScreenTextLineLayout {
        if let cached = layouts[index] { return cached }
        // A long drag should not accumulate a layout for every line it crosses.
        if layouts.count >= 4 { layouts.removeAll(keepingCapacity:true) }
        let result = ScreenTextLineLayout(regions[index].text);layouts[index] = result;return result
    }
    override func hitTest(_ point:NSPoint)->NSView? {
        guard !isHidden else { return nil }
        layoutSubtreeIfNeeded()
        return rects.contains(where:{$0.contains(convert(point,from:superview))}) ? self:nil
    }
    override func resetCursorRects() { for rect in rects { addCursorRect(rect,cursor:.iBeam) } }
    override func layout() {
        super.layout()
        guard imageSize.width > 0,imageSize.height > 0 else { rects = [];return }
        let scale = min(bounds.width/imageSize.width,bounds.height/imageSize.height)
        let size = CGSize(width:imageSize.width*scale,height:imageSize.height*scale)
        let origin = CGPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2)
        rects = regions.map { CGRect(x:origin.x+$0.x*size.width,y:origin.y+$0.y*size.height,width:$0.width*size.width,height:$0.height*size.height) }
        window?.invalidateCursorRects(for:self);needsDisplay = true
    }
    private func position(_ event:NSEvent)->ScreenTextPosition? {
        let point = convert(event.locationInWindow,from:nil)
        guard let index = rects.indices.min(by:{ distance(point,rects[$0]) < distance(point,rects[$1]) }) else { return nil }
        let rect = rects[index]
        return ScreenTextPosition(line:index,offset:textLayout(index).index(at:(point.x-rect.minX)/max(1,rect.width)))
    }
    private func distance(_ point:CGPoint,_ rect:CGRect)->CGFloat {
        let dx = max(rect.minX-point.x,max(0,point.x-rect.maxX)),dy = max(rect.minY-point.y,max(0,point.y-rect.maxY))
        return dy*dy+dx*dx*0.02
    }
    func select(from anchor:ScreenTextPosition,to head:ScreenTextPosition,allColumns:Bool = false) {
        selection = ScreenTextSelection(anchor:anchor,head:head,allColumns:allColumns);needsDisplay = true
        setAccessibilityValue(selectedText)
    }
    override func mouseDown(with event:NSEvent) {
        guard let point = position(event) else { return }
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.shift),let selection { select(from:selection.anchor,to:point) }
        else if event.clickCount >= 3 { select(from:.init(line:point.line,offset:0),to:.init(line:point.line,offset:(regions[point.line].text as NSString).length)) }
        else if event.clickCount == 2 {
            let text = regions[point.line].text
            var word = NSRange(location:point.offset,length:0)
            text.enumerateSubstrings(in:text.startIndex..<text.endIndex,options:.byWords) { _,range,_,stop in
                let candidate = NSRange(range,in:text)
                if NSLocationInRange(min(point.offset,max(0,(text as NSString).length-1)),candidate) { word = candidate;stop = true }
            }
            select(from:.init(line:point.line,offset:word.location),to:.init(line:point.line,offset:NSMaxRange(word)))
        } else { select(from:point,to:point) }
    }
    override func mouseDragged(with event:NSEvent) {
        guard let anchor = selection?.anchor,let head = position(event) else { return }
        select(from:anchor,to:head)
    }
    override func mouseUp(with event:NSEvent) {}
    override func keyDown(with event:NSEvent) { interpretKeyEvents([event]) }
    private func move(horizontal:Int = 0,vertical:Int = 0,extend:Bool = false) {
        guard let selection else { return }
        var line = selection.head.line,offset = selection.head.offset
        guard regions.indices.contains(line) else { return }
        let text = regions[line].text as NSString
        if vertical != 0 { line = min(regions.count-1,max(0,line+vertical));offset = min(offset,(regions[line].text as NSString).length) }
        else if horizontal > 0 {
            if offset < text.length { offset = NSMaxRange(text.rangeOfComposedCharacterSequence(at:offset)) }
            else if line+1 < regions.count { line += 1;offset = 0 }
        } else if horizontal < 0 {
            if offset > 0 { offset = text.rangeOfComposedCharacterSequence(at:offset-1).location }
            else if line > 0 { line -= 1;offset = (regions[line].text as NSString).length }
        }
        let point = ScreenTextPosition(line:line,offset:offset)
        select(from:extend ? selection.anchor:point,to:point)
    }
    override func moveLeft(_ sender:Any?) { move(horizontal:-1) }
    override func moveRight(_ sender:Any?) { move(horizontal:1) }
    override func moveUp(_ sender:Any?) { move(vertical:-1) }
    override func moveDown(_ sender:Any?) { move(vertical:1) }
    override func moveLeftAndModifySelection(_ sender:Any?) { move(horizontal:-1,extend:true) }
    override func moveRightAndModifySelection(_ sender:Any?) { move(horizontal:1,extend:true) }
    override func moveUpAndModifySelection(_ sender:Any?) { move(vertical:-1,extend:true) }
    override func moveDownAndModifySelection(_ sender:Any?) { move(vertical:1,extend:true) }
    @objc func copy(_ sender:Any?) {
        guard !selectedText.isEmpty else { return }
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(selectedText,forType:.string)
    }
    override func selectAll(_ sender:Any?) {
        guard let last = regions.last else { return }
        select(from:.init(line:0,offset:0),to:.init(line:regions.count-1,offset:(last.text as NSString).length),allColumns:true)
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool { item.action != #selector(copy(_:)) || !selectedText.isEmpty }
    override func menu(for event:NSEvent)->NSMenu? {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        for (title,action) in [("Copy",#selector(copy(_:))),("Select All",#selector(selectAll(_:)))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:"");item.target = self;menu.addItem(item)
        }
        return menu
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let selection else { return }
        NSColor.systemBlue.withAlphaComponent(0.25).setFill()
        for (index,range) in selection.ranges(in:regions) where range.length > 0 && rects.indices.contains(index) {
            let rect = rects[index]
            if range.location == 0,range.length == (regions[index].text as NSString).length {
                NSBezierPath(roundedRect:rect,xRadius:2,yRadius:2).fill()
            } else {
                let layout = textLayout(index)
                for box in layout.boxes(for:range) {
                    let highlight = CGRect(x:rect.minX+box.minX/layout.size.width*rect.width,y:rect.minY+box.minY/layout.size.height*rect.height,width:box.width/layout.size.width*rect.width,height:box.height/layout.size.height*rect.height)
                    NSBezierPath(roundedRect:highlight,xRadius:2,yRadius:2).fill()
                }
            }
        }
    }
}
