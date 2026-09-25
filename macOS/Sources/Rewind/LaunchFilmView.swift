import SwiftUI
import AppKit
import AVFoundation

@MainActor private final class LaunchFilmSound:ObservableObject {
    @Published var muted = false
    private var player:AVAudioPlayer?
    func start() {
        guard let url = Bundle.main.url(forResource:"Recall-Opening",withExtension:"wav"),let audio = try? AVAudioPlayer(contentsOf:url) else { return }
        player = audio;audio.volume = muted ? 0:0.5;audio.prepareToPlay();audio.play()
    }
    func toggleMute() { muted.toggle();player?.setVolume(muted ? 0:0.5,fadeDuration:0.12) }
    func stop() { player?.stop();player = nil }
}

/// A finite opening sequence; SwiftUI cancels its task when the view disappears.
struct LaunchFilmView:View {
    let onStart:()->Void
    let onEvent:(String)->Void
    let onFinish:()->Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var light = false
    @State private var halo = false
    @State private var name = false
    @State private var reveal = false
    @State private var finished = false
    @State private var suspended = false
    @State private var playbackID = UUID()
    @StateObject private var sound = LaunchFilmSound()
    private static let texture = Bundle.main.url(forResource:"IridescentGlass",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
    private static let icon = Bundle.main.url(forResource:"Recall-1024",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
    private static let haloImage = Bundle.main.url(forResource:"RecallHalo",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
    private let ink = Color(red:0.14,green:0.15,blue:0.18)
    var body:some View {
        GeometryReader { geo in
            let compact = geo.size.height < 720
            let haloWidth = min(geo.size.width*0.42,compact ? 340:460)
            ZStack {
                Color(red:0.035,green:0.042,blue:0.052)
                if !reduceMotion {
                    ambientGlass(size:geo.size).frame(width:geo.size.width,height:geo.size.height).clipped().opacity(reveal ? 0:1)
                    Circle().fill(.white)
                        .frame(width:max(geo.size.width,geo.size.height)*2.6,height:max(geo.size.width,geo.size.height)*2.6)
                        .scaleEffect(reveal ? 1:0.001).opacity(reveal ? 1:0)
                        .frame(width:geo.size.width,height:geo.size.height)
                } else { Color.white }
                VStack(spacing:compact ? 22:34) {
                    ZStack {
                        if !reduceMotion,let haloImage = Self.haloImage {
                            Image(nsImage:haloImage).resizable().interpolation(.high)
                                .frame(width:haloWidth*1.8,height:haloWidth*1.8)
                                .rotationEffect(.degrees(halo ? 0:-22))
                                .scaleEffect(halo ? 1:0.78)
                                .opacity(halo && !reveal ? 1:0)
                                .accessibilityHidden(true)
                        }
                        if let icon = Self.icon {
                            Image(nsImage:icon).resizable().interpolation(.high).scaledToFit()
                                .frame(width:compact ? 166:210,height:compact ? 166:210)
                                .scaleEffect(reveal || reduceMotion ? 1:0.78)
                                .opacity(reveal || reduceMotion ? 1:0)
                                .shadow(color:ink.opacity(0.12),radius:28,y:16)
                                .accessibilityHidden(true)
                        }
                    }.frame(width:haloWidth,height:compact ? 254:330)
                    VStack(spacing:16) {
                        Text("Recall").font(.system(size:compact ? 54:68,weight:.medium)).tracking(-2.6)
                            .foregroundStyle(reveal || reduceMotion ? ink:.white)
                        Text("Your day. Within reach.").font(.system(size:compact ? 16:19,weight:.regular)).tracking(0.1)
                            .foregroundStyle(reveal || reduceMotion ? ink.opacity(0.58):.white.opacity(0.68))
                    }.opacity(name || reduceMotion ? 1:0)
                        .offset(y:name || reduceMotion ? 0:18)
                        .blur(radius:name || reduceMotion ? 0:9)
                }.offset(y:compact ? -12:-28)
                VStack {
                    HStack {
                        if !reduceMotion {
                            Button(action:sound.toggleMute) {
                                Image(systemName:sound.muted ? "speaker.slash":"speaker.wave.2")
                                    .font(.system(size:15)).frame(width:44,height:44)
                            }.buttonStyle(.plain)
                                .foregroundStyle(reveal ? ink.opacity(0.7):.white.opacity(0.8))
                                .background((reveal ? Color.black:Color.white).opacity(0.06),in:Circle())
                                .accessibilityLabel(sound.muted ? "Unmute opening sound":"Mute opening sound")
                        }
                        Spacer()
                        Button("Skip animation") { finish(reason:"skipped") }
                            .font(.system(size:12,weight:.medium))
                            .foregroundStyle(reveal || reduceMotion ? ink.opacity(0.7):.white.opacity(0.8))
                            .padding(.horizontal,18).frame(height:44)
                            .background((reveal || reduceMotion ? Color.black:Color.white).opacity(0.06),in:Capsule())
                            .contentShape(Capsule()).buttonStyle(.plain)
                            .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                    Text("A private memory, on your Mac.").font(.system(size:11)).tracking(0.4)
                        .foregroundStyle(reveal || reduceMotion ? ink.opacity(0.4):.white.opacity(0.38))
                        .opacity(name || reduceMotion ? 1:0)
                }.padding(.horizontal,32).padding(.top,38).padding(.bottom,32)
                    .frame(width:geo.size.width,height:geo.size.height)
            }.frame(width:geo.size.width,height:geo.size.height).clipped()
                .contentShape(Rectangle())
        }.ignoresSafeArea().preferredColorScheme(.light)
            .accessibilityElement(children:.contain).accessibilityLabel("Welcome to Recall")
            .task(id:playbackID) { await play() }
            .onChange(of:reduceMotion) { _,enabled in if enabled { finish(reason:"reduced motion") } }
            .onDisappear { sound.stop() }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didHideNotification)) { _ in
                // Hiding is an interruption, not successful playback or a skip.
                suspended = true;sound.stop();onEvent("suspended")
            }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didUnhideNotification)) { _ in
                guard suspended,!finished else { return }
                suspended = false;playbackID = UUID()
            }
            .onExitCommand { finish(reason:"skipped") }
    }
    private func ambientGlass(size:CGSize)->some View {
        ZStack {
            if let texture = Self.texture {
                Image(nsImage:texture).resizable().scaledToFill()
                    .frame(width:size.width*1.1,height:size.height*1.1)
                    .blur(radius:65).opacity(light ? 0.24:0)
                ForEach(0..<6,id:\.self) { index in
                    let distance = CGFloat(index)-2.5
                    Image(nsImage:texture).resizable().scaledToFill()
                        .frame(width:size.width*0.18,height:size.height*1.3).clipped()
                        .mask(LinearGradient(colors:[.clear,.white.opacity(0.5),.white,.white.opacity(0.6),.clear],startPoint:.leading,endPoint:.trailing))
                        .mask(LinearGradient(colors:[.clear,.white,.white,.clear],startPoint:.top,endPoint:.bottom))
                        .rotation3DEffect(.degrees(light ? Double(distance) * -5:Double(distance) * -20),axis:(x:0,y:1,z:0))
                        .offset(x:distance*size.width*(light ? 0.19:0.39),y:light ? 0:distance*36)
                        .opacity(light ? 0.22:0)
                        .blur(radius:1.5)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    @MainActor private func play() async {
        onStart()
        guard !finished,!suspended else { return }
        var reset = Transaction();reset.disablesAnimations = true
        withTransaction(reset) { light = false;halo = false;name = false;reveal = false }
        onEvent("started")
        do {
            if reduceMotion {
                try await Task.sleep(for:.milliseconds(650))
                guard canContinue else { return };finish(reason:"reduced motion");return
            }
            // Wait until mounted before starting sound and visual progress.
            try await Task.sleep(for:.milliseconds(120));guard canContinue else { return }
            sound.start()
            guard await animate(.easeOut(duration:1.6),changes:{ light = true }) else { return }
            onEvent("glass settled")
            guard await animate(.timingCurve(0.2,0.65,0.2,1,duration:1.7),changes:{ halo = true }) else { return }
            onEvent("halo settled")
            guard await animate(.easeOut(duration:0.75),changes:{ name = true }) else { return }
            onEvent("name settled")
            try await Task.sleep(for:.milliseconds(650));guard canContinue else { return }
            guard await animate(.timingCurve(0.4,0,0.2,1,duration:1.4),changes:{ reveal = true }) else { return }
            onEvent("reveal settled")
            try await Task.sleep(for:.seconds(1))
            guard canContinue else { return };finish(reason:"completed")
        } catch { /* Closing the view cancels the sequence. */ }
    }
    private var canContinue:Bool { !finished && !suspended && !Task.isCancelled }
    @MainActor private func animate(_ animation:Animation,changes:()->Void) async -> Bool {
        guard canContinue else { return false }
        // Advance only when the renderer removes the completed animation. A wall
        // clock timeout could remove the entire film before its last frames render.
        await withCheckedContinuation { continuation in
            withAnimation(animation,completionCriteria:.removed,changes) { continuation.resume() }
        }
        return canContinue
    }
    private func finish(reason:String) {
        guard !finished else { return };finished = true;sound.stop();onEvent(reason);onFinish()
    }
}
