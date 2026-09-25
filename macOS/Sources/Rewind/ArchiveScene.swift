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

/// Warm mist backdrop: an opaque ivory gradient with soft drifting fog blobs,
/// so the archive never shows the real desktop through the transparent window.
struct ArchiveBackdrop: View {
    let appearance: OverlayAppearance
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let day = appearance == .warmDay
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors:day
                    ? [Color(red:0.960,green:0.956,blue:0.946),ArchiveTone.base(appearance)]
                    : [Color(red:0.078,green:0.086,blue:0.110),ArchiveTone.base(appearance)],
                    startPoint:.top,endPoint:.bottom)
                blob(day ? Color.white.opacity(0.95):Color(red:0.25,green:0.31,blue:0.46).opacity(0.5),radius:geo.size.width*0.66)
                    .position(x:geo.size.width*0.32,y:geo.size.height*0.18)
                    .offset(x:drift ? 26:-26,y:drift ? -14:14).animation(driftAnimation(16),value:drift)
                blob(day ? Color(red:0.80,green:0.84,blue:0.90).opacity(0.55):Color(red:0.20,green:0.25,blue:0.39).opacity(0.55),radius:geo.size.width*0.52)
                    .position(x:geo.size.width*0.88,y:geo.size.height*0.50)
                    .offset(x:drift ? -30:30,y:drift ? 18:-18).animation(driftAnimation(19),value:drift)
                blob(day ? Color(red:0.96,green:0.86,blue:0.78).opacity(0.40):Color(red:0.31,green:0.22,blue:0.37).opacity(0.40),radius:geo.size.width*0.44)
                    .position(x:geo.size.width*0.10,y:geo.size.height*0.90)
                    .offset(x:drift ? 20:-20,y:drift ? 12:-12).animation(driftAnimation(23),value:drift)
            }
            .animation(.easeInOut(duration:0.7),value:appearance)
            .onAppear { drift = true }
        }
    }
    private func blob(_ color:Color,radius:CGFloat)->some View {
        Circle().fill(RadialGradient(colors:[color,color.opacity(0)],center:.center,startRadius:0,endRadius:radius/2))
            .frame(width:radius,height:radius)
    }
    private func driftAnimation(_ duration:Double)->Animation? {
        reduceMotion ? nil:.easeInOut(duration:duration).repeatForever(autoreverses:true)
    }
}

/// Ivory gradient for the detached timeline strip window: clear at the top,
/// settling into the archive base tone at the bottom edge of the screen.
struct ArchiveStripBackground: View {
    let appearance: OverlayAppearance
    var body: some View {
        LinearGradient(colors:[ArchiveTone.base(appearance).opacity(0),ArchiveTone.base(appearance).opacity(0.72),ArchiveTone.base(appearance)],
                       startPoint:.top,endPoint:.bottom)
            .animation(.easeInOut(duration:0.7),value:appearance)
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
    @State private var images: [String:NSImage] = [:]
    @State private var recognizedRegions:[String:[TextRegion]] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var frames:[MemoryFrame] { model.archiveFrames }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ArchiveGlassRenderer(frames:frames,images:images,appearance:model.settings.appearance,
                    selected:focusedID,day:model.archiveDay,regions:focusedID.flatMap { recognizedRegions[$0] } ?? [],size:geo.size,reduced:reduceMotion,onSelect:toggle,onRecordAction:recordAction)
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
                LinearGradient(stops:[.init(color:ArchiveTone.base(model.settings.appearance),location:0),
                    .init(color:ArchiveTone.base(model.settings.appearance).opacity(0.9),location:0.08),
                    .init(color:.clear,location:0.23)],startPoint:.top,endPoint:.bottom)
                    .allowsHitTesting(false)
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
            .task(id:focusedID) {
                guard let id = focusedID,let frame = frames.first(where: { $0.id == id }) else { return }
                let url = model.store.root.appendingPathComponent(frame.imagePath)
                guard let pixels = await MemoryImagePipeline.previews.image(at:url,maxPixels:2600),!Task.isCancelled else { return }
                images[frame.imagePath] = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
                if frame.regions.isEmpty,recognizedRegions[id] == nil {
                    let regions = await Task.detached(priority:.userInitiated) { (try? NativeOCR.recognize(pixels).1) ?? [] }.value
                    if !Task.isCancelled { recognizedRegions[id] = regions }
                }
            }
            .onChange(of:frames.map(\.id)) { _,ids in
                if let focusedID,!ids.contains(focusedID) { self.focusedID = nil }
            }
            .task(id:frames.map(\.imagePath)) {
                let paths = Set(frames.map(\.imagePath))
                var loaded = images.filter { paths.contains($0.key) }
                for frame in frames where loaded[frame.imagePath] == nil {
                    guard !Task.isCancelled else { return }
                    if let pixels = await MemoryImagePipeline.shared.image(at:model.store.root.appendingPathComponent(frame.imagePath),maxPixels:720),!Task.isCancelled {
                        loaded[frame.imagePath] = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
                    }
                }
                if !Task.isCancelled {
                    for (path,image) in loaded where image.size.width > (images[path]?.size.width ?? 0) { images[path] = image }
                    images = images.filter { paths.contains($0.key) }
                }
            }
        }
    }
    private func toggle(_ id:String?) {
        focusedID = focusedID == id ? nil:id
    }
    private func recordAction(_ id:String,_ action:String) {
        guard let frame = frames.first(where: { $0.id == id }) else { return }
        switch action {
        case "star":model.star(frame)
        case "copy":model.copy(frame.text.isEmpty ? (recognizedRegions[id] ?? frame.regions).map(\.text).joined(separator:"\n"):frame.text)
        case "rewind":model.select(frame)
        case "close":focusedID = nil
        default:break
        }
    }
}
