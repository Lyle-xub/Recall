import SwiftUI
import AppKit

/// Shared tones for the ivory archive scene. The overlay window is transparent,
/// so every surface samples these in-window colors instead of the desktop.
enum ArchiveTone {
    static func base(_ appearance:OverlayAppearance)->Color {
        appearance == .warmDay ? Color(red:0.906,green:0.898,blue:0.886):Color(red:0.043,green:0.047,blue:0.063)
    }
    static func fog(_ appearance:OverlayAppearance)->Color {
        appearance == .warmDay ? Color(red:0.965,green:0.962,blue:0.955):Color(red:0.030,green:0.033,blue:0.045)
    }
    static func glassMilk(_ appearance:OverlayAppearance)->Color {
        appearance == .warmDay ? .white:Color(white:0.09)
    }
    static func colorScheme(_ appearance:OverlayAppearance)->ColorScheme { appearance == .warmDay ? .light:.dark }
}

/// The native material samples the live desktop. A restrained tint keeps
/// wallpaper colors visible without the old opaque cream blanket.
struct ArchiveBackdrop: View {
    let appearance: OverlayAppearance
    var body: some View {
        ZStack {
            DesktopBlur(material:.underWindowBackground)
            LinearGradient(colors:appearance == .warmDay
                ? [.white.opacity(0.09),.white.opacity(0.025)]
                : [.black.opacity(0.16),.black.opacity(0.06)],startPoint:.top,endPoint:.bottom)
        }.allowsHitTesting(false)
    }
}

struct ArchiveStripBackground: View {
    let appearance: OverlayAppearance
    var body: some View {
        DesktopBlur(fadesUpward:true,material:.underWindowBackground)
    }
}

/// Bare top-bar icon from the reference design: no glass bubble, just a thin
/// symbol that brightens and lifts on hover.
struct BareIconButton: View {
    var symbol: String
    var label: String
    var size: CGFloat = 16
    var action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action:action) {
            Image(systemName:symbol).font(.system(size:size,weight:.medium))
                .foregroundStyle(Color.overlayControl.opacity(hovered ? 1:0.78))
                .frame(width:44,height:44).contentShape(Rectangle())
                .scaleEffect(hovered && !reduceMotion ? 1.12:1)
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .animation(.spring(response:0.3,dampingFraction:0.7),value:hovered)
            .help(label).accessibilityLabel(label)
    }
}

/// Tone only screenshot pixels, keeping text, icons and glass highlights clear.
enum ArchiveImageTone {
    static func intensity(night:Bool)->CGFloat { night ? 0.78:1 }
    static func color(night:Bool)->Color {
        let value = Double(intensity(night:night))
        return Color(.sRGBLinear,red:value,green:value,blue:value)
    }
}

/// Keep the native scene mounted across search/detail navigation so returning
/// restores the same camera and card instead of replaying an entrance.
struct ArchiveStackView: View {
    @ObservedObject var model: AppModel
    @Binding var focusedID: String?
    var active:Bool = true
    @StateObject private var imageLoader = ArchiveImageLoader()
    private var images:[String:NSImage] { imageLoader.images }
    @State private var recognizedRegions:[String:[TextRegion]] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var frames:[MemoryFrame] { model.archiveFrames }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ArchiveGlassRenderer(frames:frames,images:images,appearance:model.settings.appearance,
                    selected:focusedID,day:model.archiveDay,timelinePosition:model.archiveTimelinePosition,regions:focusedID.flatMap { recognizedRegions[$0] } ?? [],size:geo.size,reduced:reduceMotion,active:active,onSelect:toggle,onRecordAction:recordAction,onHoverRecord:{ imageLoader.hover(focusedID == nil ? $0:nil) },onViewportChange:{ imageLoader.updateViewport($0) },window:model.archiveWindow,onWindowDemand:{model.requestArchiveWindow(at:$0)})
                    .accessibilityRepresentation {
                        VStack {
                            ForEach(frames) { frame in
                                Button("\(focusedID == frame.id ? "Collapse":"Expand") \(frame.title.isEmpty ? frame.appName:frame.title), \(frame.timestamp.recallFormatted(date:.abbreviated,time:.standard))") { toggle(frame.id) }
                            }
                            if let focusedID {
                                Button("Collapse card") { toggle(focusedID) }
                                Button("Star memory") { recordAction(focusedID,"star") }
                                Button("Copy recognized text") { recordAction(focusedID,"copy") }
                                Button("Rewind to this moment") { recordAction(focusedID,"rewind") }
                            }
                        }
                    }
                LinearGradient(stops:[.init(color:ArchiveTone.base(model.settings.appearance).opacity(0.13),location:0),
                    .init(color:ArchiveTone.base(model.settings.appearance).opacity(0.04),location:0.08),
                    .init(color:.clear,location:0.23)],startPoint:.top,endPoint:.bottom)
                    .allowsHitTesting(false)
                    .opacity(focusedID == nil ? 1:0)
                VStack {
                    Spacer()
                    HStack(spacing:14) {
                        Button { focusedID = nil;model.moveArchiveDay(by:-1) } label: { Image(systemName:"chevron.left").frame(width:44,height:40).contentShape(Rectangle()) }.help("Previous day")
                        Text(model.archiveDay.recallFormatted(.dateTime.year().month().day())).monospacedDigit()
                        Text("One day per column").foregroundStyle(.secondary)
                        Button { focusedID = nil;model.moveArchiveDay(by:1) } label: { Image(systemName:"chevron.right").frame(width:44,height:40).contentShape(Rectangle()) }.help("Next day")
                    }.font(.system(size:11,weight:.medium)).buttonStyle(.plain)
                        .padding(.horizontal,12).liquidGlass(radius:18).padding(.bottom,22)
                }
                .opacity(model.timelineVisible ? 0:1)
                .allowsHitTesting(!model.timelineVisible)
                .accessibilityHidden(model.timelineVisible)
            }
            .task(id:active ? focusedID:nil) {
                guard active else { return }
                guard let id = focusedID,let frame = frames.first(where: { $0.id == id }) else { return }
                imageLoader.hover(nil)
                let url = model.store.root.appendingPathComponent(frame.imagePath)
                // The existing thumbnail follows the extraction immediately.
                // Upload full-size pixels after its busiest rotation phase.
                if !reduceMotion {
                    do { try await Task.sleep(for:.milliseconds(350)) } catch { return }
                }
                guard let pixels = await MemoryImagePipeline.previews.image(at:url,maxPixels:2600),!Task.isCancelled else { return }
                imageLoader.showDetail(pixels,for:frame.imagePath)
                if frame.regions.isEmpty,recognizedRegions[id] == nil {
                    let regions = await Task.detached(priority:.userInitiated) { (try? NativeOCR.recognize(pixels).1) ?? [] }.value
                    if !Task.isCancelled { recognizedRegions[id] = regions }
                }
            }
            .task(id:active ? model.archiveExtractionID:nil) {
                guard active else { return }
                guard let id = model.archiveExtractionID,let frame = frames.first(where:{ $0.id == id }) else { return }
                // The same physical sheet is extracted only once its real pixels
                // are ready; the focused task then upgrades it for text selection.
                guard let pixels = await MemoryImagePipeline.previews.image(at:model.store.root.appendingPathComponent(frame.imagePath),maxPixels:1600),
                      !Task.isCancelled,model.archiveExtractionID == id else { return }
                imageLoader.showDetail(pixels,for:frame.imagePath)
                model.pinArchiveRecord(id);focusedID = id
            }
            .onChange(of:focusedID) { _,id in model.pinArchiveRecord(id) }
            .onChange(of:frames.map(\.id)) { _,ids in
                requestImages()
                if let focusedID,!ids.contains(focusedID) { self.focusedID = nil }
                let retained = Set(ids)
                recognizedRegions = recognizedRegions.filter { retained.contains($0.key) }
            }
            .onAppear { requestImages() }
            .onChange(of:frames.map(\.imagePath)) { _,_ in requestImages() }
            .onChange(of:active) { _,isActive in
                if isActive { requestImages() } else { imageLoader.stop() }
            }
            .onDisappear { imageLoader.stop() }
        }
    }
    private func requestImages() {
        guard active else { return }
        imageLoader.request(frames,viewport:imageLoader.viewport,root:model.store.root)
    }
    private func toggle(_ id:String?) {
        model.cancelArchiveExtraction()
        let next=focusedID == id ? nil:id
        model.pinArchiveRecord(next);focusedID=next
    }
    private func recordAction(_ id:String,_ action:String) {
        guard let frame = frames.first(where: { $0.id == id }) else { return }
        switch action {
        case "star":model.star(frame)
        case "copy":model.copy(frame.text.isEmpty ? (recognizedRegions[id] ?? frame.regions).map(\.text).joined(separator:"\n"):frame.text)
        case "rewind":model.select(frame)
        case "close":model.cancelArchiveExtraction();focusedID = nil
        default:break
        }
    }
}
