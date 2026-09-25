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
        }.buttonStyle(.plain)
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

/// One slot in the staircase: a recorded memory, or a decorative sheet that
/// only carries a pastel band so the wings can stretch into the fog.
private struct ArchiveSlot: Identifiable {
    let id: String
    let frame: MemoryFrame?
    let palette: Int
}

/// App-icon tint per sheet, echoing the reference where every glass panel
/// carries the palette of the cover beneath it.
@MainActor enum ArchiveAppTint {
    private static var colors: [String:Color] = [:]
    static func color(appName:String,bundleID:String?)->Color? {
        let key = bundleID.flatMap { $0.isEmpty ? nil:$0 } ?? appName
        if let cached = colors[key] { return cached }
        guard let icon = AppIconCache.image(name:appName,bundleID:bundleID),
              let image = icon.cgImage(forProposedRect:nil,context:nil,hints:nil),
              let tint = IconColorSampler.sample(image),!tint.isNeutral else { return nil }
        let color = Color(red:tint.red,green:tint.green,blue:tint.blue)
        colors[key] = color
        return color
    }
}

/// The diagonal staircase of frosted glass sheets from the reference: a raised
/// focus sheet at the upper middle, a steep left wing dissolving into mist and
/// a shallow right wing stretching offscreen. Sheets further from the focus
/// slide in front of the nearer ones, like foreground bokeh; opening a sheet
/// lifts, sharpens and unfolds it while the staircase follows in one spring.
struct ArchiveStackView: View {
    @ObservedObject var model: AppModel
    @State private var focal: Int?
    @State private var appeared = false
    @State private var hovered: Int?
    @State private var pointer = CGPoint(x:0.5,y:0.5)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let slotCount = 20
    private var slots: [ArchiveSlot] {
        let frames = Array(model.archiveFrames.prefix(Self.slotCount))
        var result = frames.map { ArchiveSlot(id:$0.id,frame:$0,palette:0) }
        for index in result.count..<Self.slotCount { result.append(ArchiveSlot(id:"fog-\(index)",frame:nil,palette:index)) }
        return result
    }
    private var defaultFocal: Int { slots.count >= 16 ? 8:slots.count/2 }
    var body: some View {
        GeometryReader { geo in
            let w = min(430,max(260,geo.size.width*0.26))
            let size = CGSize(width:w,height:w*0.72)
            ZStack {
                ZStack {
                    ForEach(Array(slots.enumerated()),id:\.element.id) { index,slot in
                        card(index:index,slot:slot,size:size,scene:geo.size)
                    }
                }
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .rotation3DEffect(.degrees(reduceMotion ? 0:36+Double(0.5-pointer.y)*3),axis:(x:1,y:0,z:0),perspective:0.65)
                .rotation3DEffect(.degrees(reduceMotion ? 0:Double(pointer.x-0.5)*4),axis:(x:0,y:1,z:0),perspective:0.65)
                .rotationEffect(reduceMotion ? .zero:.degrees(7))
                fogOverlay(scene:geo.size).allowsHitTesting(false).zIndex(200)
            }
            .animation(reduceMotion ? nil:.easeOut(duration:0.35),value:pointer)
            .onContinuousHover(coordinateSpace:.local) { phase in
                switch phase {
                case .active(let location):
                    pointer = CGPoint(x:location.x/max(1,geo.size.width),y:location.y/max(1,geo.size.height))
                case .ended:
                    pointer = CGPoint(x:0.5,y:0.5)
                }
            }
            .onAppear {
                if focal == nil { focal = defaultFocal }
                appeared = true
            }
        }
    }
    /// Whiteout layers above the sheets, tuned so mid-distance cards stay
    /// crisp: only the bottom, the far left wing and the right edge dissolve.
    private func fogOverlay(scene:CGSize)->some View {
        let fog = ArchiveTone.fog(model.settings.appearance)
        return ZStack {
            LinearGradient(stops:[.init(color:fog.opacity(0),location:0.60),.init(color:fog.opacity(0.32),location:0.82),.init(color:fog.opacity(0.80),location:1)],
                           startPoint:.top,endPoint:.bottom)
            LinearGradient(colors:[fog.opacity(0.60),fog.opacity(0)],
                           startPoint:.leading,endPoint:UnitPoint(x:0.24,y:0.5))
            RadialGradient(colors:[fog.opacity(0.5),fog.opacity(0)],center:.center,startRadius:0,endRadius:scene.width*0.24)
                .frame(width:scene.width*0.48,height:scene.width*0.48)
                .position(x:scene.width*1.02,y:scene.height*0.75)
        }
    }
    private func card(index:Int,slot:ArchiveSlot,size:CGSize,scene:CGSize)->some View {
        let pivot = focal ?? defaultFocal
        let t = CGFloat(index-pivot)
        let at = abs(t)
        let isFocal = focal == index
        let isHovered = hovered == index
        let raise = size.height*1.15
        let pivotX = scene.width/2-size.width*0.30
        let restY = scene.height*0.58
        let originY = restY-(focal != nil ? raise:0)
        var x = pivotX, y = originY
        var blur = min(4,at*0.7), opacity = max(0.55,1-at*0.04), tilt = 0.0, scale = 1-at*0.03
        if t < 0 {
            x = pivotX+t*size.width*0.36
            y = originY+at*size.height*0.36
            blur = min(4.5,at*0.7); opacity = max(0.5,1-at*0.055)
        } else if t > 0 {
            x = pivotX+t*size.width*0.32
            y = originY+at*size.height*0.24
        }
        if isFocal { scale = 1.42; blur = 0; opacity = 1; tilt = -25 }
        if isHovered,!isFocal,slot.frame != nil { scale *= 1.06; y -= 12; blur = max(0,blur-0.5) }
        let day = model.settings.appearance == .warmDay
        var label = ""
        if let frame = slot.frame { label = "\(frame.title.isEmpty ? frame.appName:frame.title), \(frame.appName), \(frame.timeLabel)" }
        let halo = RadialGradient(colors:[(day ? Color.white:Color(red:0.35,green:0.42,blue:0.60)).opacity(0.95),(day ? Color.white:Color.clear).opacity(0)],
                                  center:.center,startRadius:0,endRadius:size.width*1.05)
        let sheet = ArchiveCardView(model:model,frame:slot.frame,expanded:isFocal,trackLines:t > 0,palette:slot.palette,wing:t < 0 ? -1:1)
            .frame(width:size.width,height:size.height)
            .background { if isFocal { halo.frame(width:size.width*2.2,height:size.height*2.6).blur(radius:30) } }
            .shadow(color:.black.opacity(isFocal ? 0.24:0.16),radius:isFocal ? 38:14,y:isFocal ? 20:7)
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(reduceMotion ? 0:tilt),axis:(x:1,y:0,z:0),perspective:0.65)
            .blur(radius:reduceMotion ? 0:blur)
            .opacity(appeared ? opacity:0)
            .offset(y:appeared ? 0:340)
            .position(x:x,y:y)
            .zIndex(isFocal ? 100:at)
        return sheet
            .contentShape(RoundedRectangle(cornerRadius:8,style:.continuous))
            .onTapGesture {
                guard slot.frame != nil else { return }
                withAnimation(reduceMotion ? nil:.spring(response:0.62,dampingFraction:0.84)) {
                    focal = isFocal ? nil:index
                }
            }
            .onHover { if slot.frame != nil { hovered = $0 ? index:nil } }
            .animation(reduceMotion ? nil:.spring(response:0.62,dampingFraction:0.84).delay(at*0.028),value:focal)
            .animation(reduceMotion ? nil:.spring(response:0.72,dampingFraction:0.88).delay(0.1+Double(index)*0.04),value:appeared)
            .animation(reduceMotion ? nil:.spring(response:0.32,dampingFraction:0.8),value:hovered)
            .accessibilityElement(children:isFocal ? .contain:.ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isFocal ? .isSelected:[])
    }
}

/// One frosted sheet: the recorded screen fills the card and a milky gradient
/// frosts over it from the bottom, so the cover's colors bleed through the
/// glass exactly like the reference. A bright hairline stroke and a per-wing
/// tint keep every sheet distinct inside the stack.
private struct ArchiveCardView: View {
    @ObservedObject var model: AppModel
    let frame: MemoryFrame?
    let expanded: Bool
    let trackLines: Bool
    let palette: Int
    let wing: CGFloat
    @State private var thumbnail: NSImage?
    @Environment(\.colorScheme) private var scheme
    private static let fogPalettes: [[Color]] = [
        [Color(red:0.98,green:0.84,blue:0.55),Color(red:0.95,green:0.68,blue:0.42)],
        [Color(red:0.72,green:0.80,blue:0.94),Color(red:0.55,green:0.66,blue:0.88)],
        [Color(red:0.95,green:0.74,blue:0.78),Color(red:0.88,green:0.55,blue:0.62)],
        [Color(red:0.70,green:0.86,blue:0.80),Color(red:0.50,green:0.74,blue:0.68)],
        [Color(red:0.84,green:0.77,blue:0.94),Color(red:0.68,green:0.60,blue:0.86)],
        [Color(red:0.95,green:0.66,blue:0.56),Color(red:0.85,green:0.48,blue:0.42)],
    ]
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment:.bottom) {
                cover.frame(width:geo.size.width,height:geo.size.height)
                Rectangle().fill(glassGradient).allowsHitTesting(false)
                wingTint.allowsHitTesting(false)
                if trackLines,!expanded {
                    VStack(alignment:.leading,spacing:11) {
                        trackLine(width:geo.size.width*0.58)
                        trackLine(width:geo.size.width*0.76)
                        trackLine(width:geo.size.width*0.44)
                    }.padding(.horizontal,24)
                    .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
                    .padding(.top,geo.size.height*0.36)
                    .allowsHitTesting(false)
                }
                if frame != nil {
                    infoBar.frame(height:geo.size.height*0.34).opacity(expanded ? 1:0)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius:expanded ? 10:7,style:.continuous))
        .overlay(RoundedRectangle(cornerRadius:expanded ? 10:7,style:.continuous)
            .strokeBorder(.white.opacity(scheme == .dark ? 0.3:0.92),lineWidth:1.5).allowsHitTesting(false))
        .task(id:frame?.imagePath) {
            guard let frame,
                  let pixels = await MemoryImagePipeline.shared.image(at:model.store.root.appendingPathComponent(frame.imagePath),maxPixels:900),!Task.isCancelled else { return }
            thumbnail = NSImage(cgImage:pixels,size:NSSize(width:pixels.width,height:pixels.height))
        }
    }
    private var glassGradient: LinearGradient {
        let milk = ArchiveTone.glassMilk(model.settings.appearance)
        if expanded {
            return LinearGradient(stops:[.init(color:milk.opacity(0),location:0),.init(color:milk.opacity(0.04),location:0.55),
                                         .init(color:milk.opacity(0.18),location:0.8),.init(color:milk.opacity(0.4),location:1)],
                                  startPoint:.top,endPoint:.bottom)
        }
        return LinearGradient(stops:[.init(color:milk.opacity(0.04),location:0),.init(color:milk.opacity(0.24),location:0.32),
                                     .init(color:milk.opacity(0.52),location:0.62),.init(color:milk.opacity(0.78),location:1)],
                              startPoint:.top,endPoint:.bottom)
    }
    private var wingTint: some View {
        let day = scheme == .light
        var tint = wing < 0
            ? Color(red:0.98,green:0.90,blue:0.80).opacity(day ? 0.10:0.05)
            : Color(red:0.80,green:0.87,blue:0.96).opacity(day ? 0.13:0.07)
        if let frame,let appTint = ArchiveAppTint.color(appName:frame.appName,bundleID:frame.bundleID) {
            tint = appTint.opacity(expanded ? (day ? 0.10:0.06):(day ? 0.24:0.13))
        }
        return Rectangle().fill(tint)
    }
    private var cover: some View {
        ZStack {
            if let thumbnail {
                Image(nsImage:thumbnail).resizable().aspectRatio(contentMode:.fill)
                    .saturation(expanded ? 1.05:1.25).contrast(1.05)
            } else if frame != nil {
                LinearGradient(colors:scheme == .dark ? [Color(white:0.17),Color(white:0.10)]:[Color(white:0.91),Color(white:0.83)],startPoint:.top,endPoint:.bottom)
                AppBadge(name:frame!.appName,bundleID:frame!.bundleID,size:48).opacity(0.35)
            } else {
                let colors = Self.fogPalettes[palette%Self.fogPalettes.count]
                LinearGradient(colors:colors.map { $0.opacity(scheme == .dark ? 0.4:0.95) },startPoint:.topLeading,endPoint:.bottomTrailing)
            }
        }
    }
    private func trackLine(width:CGFloat)->some View {
        RoundedRectangle(cornerRadius:2)
            .fill(scheme == .dark ? Color.white.opacity(0.3):Color(red:0.70,green:0.77,blue:0.88).opacity(0.9))
            .frame(width:width,height:4)
    }
    private var infoBar: some View {
        ZStack(alignment:.top) {
            Rectangle().fill(.white.opacity(scheme == .dark ? 0.25:0.9)).frame(height:1)
            info.padding(.horizontal,14).padding(.vertical,10)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottom)
        }
        .background(scheme == .dark ? Color(white:0.12).opacity(0.88):Color.white.opacity(0.62))
    }
    private var info: some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(spacing:10) {
                AppBadge(name:frame!.appName,bundleID:frame!.bundleID,size:28)
                VStack(alignment:.leading,spacing:3) {
                    Text(frame!.title.isEmpty ? frame!.appName:frame!.title).font(.system(size:13,weight:.semibold)).lineLimit(1)
                    Text("\(frame!.appName) · \(frame!.timeLabel)").font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength:0)
                if frame!.starred { Image(systemName:"star.fill").font(.system(size:12)).foregroundStyle(.yellow) }
            }
            HStack(spacing:2) {
                infoButton(symbol:frame!.starred ? "star.fill":"star",label:frame!.starred ? "Remove star":"Star") { model.star(frame!) }
                infoButton(symbol:"doc.on.doc",label:"Copy recognized text") { model.copy(frame!.text) }
                Spacer(minLength:4)
                Button { model.select(frame!) } label: {
                    Label("Rewind",systemImage:"clock.arrow.circlepath")
                        .font(.system(size:11,weight:.semibold))
                        .padding(.horizontal,13).padding(.vertical,7)
                        .background(Color.primary.opacity(0.88),in:Capsule())
                        .foregroundStyle(scheme == .dark ? Color.black:Color.white)
                }.buttonStyle(.plain).help("Rewind to this moment")
            }
        }
    }
    private func infoButton(symbol:String,label:String,action:@escaping ()->Void)->some View {
        Button(action:action) {
            Image(systemName:symbol).font(.system(size:13,weight:.medium)).foregroundStyle(Color.overlayControl)
                .frame(width:32,height:32).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
