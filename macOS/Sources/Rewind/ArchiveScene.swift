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
                .frame(width:34,height:34).contentShape(Rectangle())
                .scaleEffect(hovered && !reduceMotion ? 1.12:1)
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .animation(.spring(response:0.3,dampingFraction:0.7),value:hovered)
            .help(label).accessibilityLabel(label)
    }
}

/// 暖昼 / 深夜 pill from the reference design. A matched-geometry knob slides
/// between the two segments so the toggle reads as one continuous motion.
struct ThemeTogglePill: View {
    let appearance: OverlayAppearance
    var action: () -> Void
    @Namespace private var knob
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil:.spring(response:0.42,dampingFraction:0.78)) { action() }
        } label: {
            HStack(spacing:2) {
                segment("暖昼",symbol:"sun.max.fill",active:appearance == .warmDay)
                segment("深夜",symbol:"moon.stars.fill",active:appearance == .deepNight)
            }.padding(3)
            .background(scheme == .dark ? Color.white.opacity(0.10):Color.white.opacity(0.55),in:Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(scheme == .dark ? 0.22:0.7),lineWidth:1))
        }.buttonStyle(.plain).fixedSize()
            .help("切换暖昼 / 深夜外观").accessibilityLabel("切换外观,当前\(appearance.label)")
    }
    private func segment(_ title:String,symbol:String,active:Bool)->some View {
        HStack(spacing:5) {
            Circle().fill(active ? Color(red:0.98,green:0.80,blue:0.45):Color.secondary).frame(width:5,height:5)
            Text(title).font(.system(size:11,weight:.medium))
        }
        .padding(.horizontal,11).frame(height:28)
        .foregroundStyle(active ? (scheme == .dark ? Color.black:Color.white):Color.primary.opacity(0.5))
        .background {
            if active {
                Capsule().fill(Color.primary.opacity(0.88)).matchedGeometryEffect(id:"themeKnob",in:knob)
            }
        }
        .accessibilityAddTraits(active ? .isSelected:[])
    }
}

/// Keep the native scene mounted across search/detail navigation so returning
/// restores the same camera and card instead of replaying an entrance.
struct ArchiveStackView: View {
    @ObservedObject var model: AppModel
    @Binding var focusedID: String?
    var active:Bool = true
    @State private var viewportRecords = ArchiveViewportRecords()
    @State private var hoveredID:String?
    @StateObject private var imageLoader = ArchiveImageLoader()
    private var images:[String:NSImage] { imageLoader.images }
    @State private var recognizedRegions:[String:[TextRegion]] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var frames:[MemoryFrame] { model.archiveFrames }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ArchiveGlassRenderer(frames:frames,images:images,appearance:model.settings.appearance,
                    selected:focusedID,day:model.archiveDay,timelinePosition:model.archiveTimelinePosition,regions:focusedID.flatMap { recognizedRegions[$0] } ?? [],size:geo.size,reduced:reduceMotion,active:active,onSelect:toggle,onRecordAction:recordAction,onHoverRecord:{ if hoveredID != $0 { hoveredID = $0 } },onViewportChange:{ viewportRecords = $0 })
                    .accessibilityRepresentation {
                        VStack {
                            ForEach(frames) { frame in
                                Button("\(focusedID == frame.id ? "收起":"展开") \(frame.title.isEmpty ? frame.appName:frame.title)，\(frame.timestamp.formatted(date:.abbreviated,time:.standard))") { toggle(frame.id) }
                            }
                            if let focusedID {
                                Button("收起卡片") { toggle(focusedID) }
                                Button("收藏记忆") { recordAction(focusedID,"star") }
                                Button("复制识别文字") { recordAction(focusedID,"copy") }
                                Button("回到此刻") { recordAction(focusedID,"rewind") }
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
                        Button { focusedID = nil;model.moveArchiveDay(by:-1) } label: { Image(systemName:"chevron.left").frame(width:30,height:28) }.help("前一天")
                        Text(model.archiveDay.formatted(.dateTime.year().month().day())).monospacedDigit()
                        Text("一列一天").foregroundStyle(.secondary)
                        Button { focusedID = nil;model.moveArchiveDay(by:1) } label: { Image(systemName:"chevron.right").frame(width:30,height:28) }.help("后一天")
                    }.font(.system(size:11,weight:.medium)).buttonStyle(.plain)
                        .padding(.horizontal,12).background(.regularMaterial,in:Capsule()).padding(.bottom,22)
                }
            }
            .task(id:active ? hoveredID:nil) {
                guard active else { return }
                guard focusedID == nil,let id = hoveredID,let frame = frames.first(where: { $0.id == id }) else { return }
                // Coalesce pointer sweeps instead of decoding every crossed card.
                do { try await Task.sleep(for:.milliseconds(180)) } catch { return }
                guard let pixels = await MemoryImagePipeline.previews.image(at:model.store.root.appendingPathComponent(frame.imagePath),maxPixels:1000),!Task.isCancelled else { return }
                imageLoader.showDetail(pixels,for:frame.imagePath)
            }
            .task(id:active ? focusedID:nil) {
                guard active else { return }
                guard let id = focusedID,let frame = frames.first(where: { $0.id == id }) else { return }
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
                focusedID = id
            }
            .onChange(of:frames.map(\.id)) { _,ids in
                if let focusedID,!ids.contains(focusedID) { self.focusedID = nil }
                let retained = Set(ids)
                recognizedRegions = recognizedRegions.filter { retained.contains($0.key) }
            }
            .onAppear { requestImages() }
            .onChange(of:frames.map(\.imagePath)) { _,_ in requestImages() }
            .onChange(of:viewportRecords) { _,_ in requestImages() }
            .onChange(of:active) { _,isActive in
                if isActive { requestImages() } else { hoveredID = nil;imageLoader.stop() }
            }
            .onDisappear { imageLoader.stop() }
        }
    }
    private func requestImages() {
        guard active else { return }
        imageLoader.request(frames,viewport:viewportRecords,root:model.store.root)
    }
    private func toggle(_ id:String?) {
        model.cancelArchiveExtraction()
        focusedID = focusedID == id ? nil:id
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
