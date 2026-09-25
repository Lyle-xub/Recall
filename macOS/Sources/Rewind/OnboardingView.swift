import SwiftUI
import AppKit

/// Setup completion is independent of recording, microphone preferences and models.
/// An existing library never gets a blocking tour after an upgrade.
enum OnboardingPolicy {
    static func shouldPresent(completed:Bool, memories:Int)->Bool { !completed && memories == 0 }
    static func shouldPlayFilm(settings:AppSettings,memories:Int)->Bool {
        shouldPresent(completed:settings.onboardingComplete,memories:memories) && !settings.launchFilmSeen
    }
    static func filmStartedSettings(_ settings:AppSettings)->AppSettings {
        var result = settings;result.launchFilmSeen = true;return result
    }
    static func completedSettings(_ settings:AppSettings)->AppSettings {
        var result = settings; result.onboardingComplete = true; return result
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var models = BuiltinModels.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var appeared = false
    @State private var screenAllowed = CapturePermissions.screen
    @State private var microphone = CapturePermissions.microphone
    @State private var permissionBusy = false
    @State private var permissionMessage: String?
    @State private var moment = 0.65
    @Namespace private var hero
    private let ink = Color(red:0.15,green:0.17,blue:0.21)
    private let cyan = Color(red:0.37,green:0.77,blue:0.80)
    private let rose = Color(red:0.95,green:0.60,blue:0.57)
    private let violet = Color(red:0.66,green:0.60,blue:0.78)
    private let captions = ["Your day.\nWithin reach.","Find your way back.","Only what you choose.","A little more insight.","Ready for your next idea."]
    private let descriptions = [
        "A private, searchable memory of the things you see and hear.",
        "Slide back to a moment, search a word, and pick up where you left off.",
        "Choose what Recall can capture. You can change this at any time.",
        "Download a model for private answers and transcription on this Mac.",
        "Recall stays in your menu bar, ready whenever you need it."
    ]
    private var motion: Animation? { reduceMotion ? nil:.spring(response:0.72,dampingFraction:0.84) }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                DesktopBlur().ignoresSafeArea().allowsHitTesting(false)
                Color.white.opacity(0.12).ignoresSafeArea()
                VStack(spacing:0) {
                    HStack {
                        HStack(spacing:8) {
                            if let mark = NSImage(named:"RecallTemplate") {
                                Image(nsImage:mark).renderingMode(.template).resizable().scaledToFit()
                                    .foregroundStyle(ink.opacity(0.72)).frame(width:16,height:16)
                            }
                            Text("Recall").font(.system(size:14,weight:.semibold)).tracking(-0.2).foregroundStyle(ink)
                        }
                        Spacer()
                        Button("Skip introduction") { finish() }.buttonStyle(.plain)
                            .font(.system(size:12)).foregroundStyle(.secondary).padding(12).contentShape(Rectangle())
                    }.padding(.horizontal,32).padding(.top,16)
                    ZStack {
                        if step == 0 || step == 4 { welcomeHero }
                        else if step == 1 { timelineHero }
                        else { symbolHero }
                    }.frame(height:step == 2 || step == 3 ? 126:step == 0 ? 254:236)
                        .animation(motion,value:step)
                    VStack(spacing:12) {
                        Text(captions[step]).font(.system(size:step == 0 ? 46:step == 4 ? 38:34,weight:.semibold))
                            .tracking(-1.6).foregroundStyle(ink).multilineTextAlignment(.center)
                        Text(descriptions[step]).font(.system(size:15)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth:480).fixedSize(horizontal:false,vertical:true)
                    }.id("copy-\(step)").transition(copyTransition).padding(.horizontal,28)
                    Group {
                        if step == 2 { permissions }
                        else if step == 3 { modelDownloads }
                        else if step == 4 { shortcut }
                        else if step == 1 { Text("Drag the timeline to try it").font(.system(size:12)).foregroundStyle(.tertiary).padding(.top,22) }
                        else { Label("Saved on your Mac. Controlled by you.",systemImage:"lock.shield").font(.system(size:12)).foregroundStyle(.secondary).padding(.top,26) }
                    }.id("details-\(step)").transition(copyTransition)
                    Spacer(minLength:12)
                    HStack {
                        Button { move(-1) } label: {Image(systemName:"arrow.left").frame(width:44,height:44)}
                            .buttonStyle(.plain).foregroundStyle(ink).opacity(step == 0 ? 0:1).disabled(step == 0).accessibilityLabel("Previous step").frame(width:172,alignment:.leading)
                        Spacer()
                        HStack(spacing:7) {
                            ForEach(0..<5) { index in
                                Capsule().fill(index == step ? violet:ink.opacity(0.12)).frame(width:index == step ? 22:6,height:6)
                            }
                        }.accessibilityElement(children:.ignore).accessibilityLabel("Step \(step+1) of 5")
                        Spacer()
                        Button { if step == 4 { finish(start:screenAllowed && !model.recordingRequested) } else { move(1) } } label: {
                            HStack(spacing:9) {
                                Text(step == 0 ? "Let’s begin":step == 4 ? (screenAllowed && !model.recordingRequested ? "Start recording":"Open Recall"):"Continue")
                                Image(systemName:step == 4 ? "checkmark":"arrow.right")
                            }.font(.system(size:13,weight:.semibold)).padding(.horizontal,22).frame(height:44)
                                .foregroundStyle(.white).background(ink,in:Capsule())
                        }.buttonStyle(OnboardingButtonStyle()).keyboardShortcut(.defaultAction).frame(width:172,alignment:.trailing)
                    }.padding(.horizontal,32).padding(.bottom,26)
                }
                .frame(width:min(840,geo.size.width-72),height:min(706,geo.size.height-64))
                .background {
                    ZStack {
                        Color.white
                        Circle().fill(RadialGradient(colors:[cyan.opacity(0.24),cyan.opacity(0)],center:.center,startRadius:0,endRadius:220))
                            .frame(width:440,height:440).offset(x:step == 0 ? -175:170,y:-190)
                        Circle().fill(RadialGradient(colors:[rose.opacity(0.25),rose.opacity(0)],center:.center,startRadius:0,endRadius:240))
                            .frame(width:480,height:480).offset(x:step == 0 ? 205:-190,y:80)
                        Circle().fill(RadialGradient(colors:[violet.opacity(0.10),violet.opacity(0)],center:.center,startRadius:0,endRadius:280))
                            .frame(width:560,height:560).offset(y:270)
                    }.clipShape(RoundedRectangle(cornerRadius:36,style:.continuous))
                     .overlay { RoundedRectangle(cornerRadius:36,style:.continuous).strokeBorder(.white.opacity(0.9),lineWidth:1) }
                     .shadow(color:ink.opacity(0.17),radius:38,y:22)
                     .animation(reduceMotion ? nil:.easeInOut(duration:1.1),value:step)
                     .allowsHitTesting(false)
                }
                .scaleEffect(appeared || reduceMotion ? 1:0.96).opacity(appeared ? 1:0)
                .offset(y:appeared || reduceMotion ? 0:16)
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }.preferredColorScheme(.light)
        .onAppear { refreshPermissions(); withAnimation(motion) { appeared = true } }
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in refreshPermissions() }
        .onExitCommand { finish() }
    }
    private var copyTransition:AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion:.offset(y:14).combined(with:.opacity).animation(.spring(response:0.58,dampingFraction:0.9).delay(0.12)),removal:.opacity.animation(.easeOut(duration:0.12)))
    }
    private func move(_ direction:Int) { withAnimation(motion) { step = min(4,max(0,step+direction)) }; refreshPermissions() }
    private func refreshPermissions() { screenAllowed = CapturePermissions.screen;microphone = CapturePermissions.microphone }
    private func finish(start:Bool = false) { model.finishOnboarding(startRecording:start) }
    private var welcomeHero: some View {
        ZStack {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius:37,style:.continuous)
                    .fill(LinearGradient(colors:[.white.opacity(0.6),index == 0 ? cyan.opacity(0.26):rose.opacity(0.22),.white.opacity(0.65)],startPoint:.topLeading,endPoint:.bottomTrailing))
                    .frame(width:160,height:160)
                    .overlay { RoundedRectangle(cornerRadius:37,style:.continuous).stroke(.white.opacity(0.92),lineWidth:1) }
                    .rotationEffect(.degrees(appeared ? Double(index-1)*15:0))
                    .offset(x:appeared ? CGFloat(index-1)*72:0,y:12)
                    .shadow(color:(index == 0 ? cyan:rose).opacity(0.13),radius:20,y:12)
                    .animation(reduceMotion ? nil:.spring(response:1.1,dampingFraction:0.73).delay(Double(index)*0.08),value:appeared)
            }
            if let url = Bundle.main.url(forResource:"Recall-1024",withExtension:"png"),let image = NSImage(contentsOf:url) {
                Image(nsImage:image).resizable().interpolation(.high).frame(width:216,height:216)
                    .matchedGeometryEffect(id:"mark",in:hero).shadow(color:violet.opacity(0.19),radius:22,y:16)
                    .rotation3DEffect(.degrees(appeared || reduceMotion ? 0:-18),axis:(x:0,y:1,z:0))
            }
        }.accessibilityHidden(true)
    }
    private var symbolHero: some View {
        ZStack {
            Circle().fill(LinearGradient(colors:[cyan.opacity(0.42),rose.opacity(0.45)],startPoint:.topLeading,endPoint:.bottomTrailing))
                .frame(width:92,height:92).offset(x:-9,y:5)
            Image(systemName:step == 2 ? "hand.raised.fingers.spread":"sparkles")
                .font(.system(size:37,weight:.light)).foregroundStyle(ink.opacity(0.78))
                .frame(width:82,height:82).liquidGlass(radius:27,interactive:false)
                .overlay { RoundedRectangle(cornerRadius:27).stroke(.white.opacity(0.8),lineWidth:1) }
        }.matchedGeometryEffect(id:"mark",in:hero).padding(.top,8).accessibilityHidden(true)
    }
    private var timelineHero: some View {
        VStack(spacing:20) {
            HStack(spacing:12) {
                Image(systemName:"magnifyingglass").font(.system(size:18))
                Text("Find a moment").font(.system(size:17)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName:"sparkles").font(.system(size:17))
            }.foregroundStyle(ink.opacity(0.7)).padding(.horizontal,20).frame(width:362,height:52)
                .liquidGlass(radius:26,interactive:false).shadow(color:.black.opacity(0.08),radius:14,y:8)
                .matchedGeometryEffect(id:"mark",in:hero)
            VStack(spacing:12) {
                Text("\(Int((1-moment)*12)+1) minutes ago").font(.system(size:12,weight:.medium)).monospacedDigit()
                    .padding(.horizontal,13).padding(.vertical,7).background(.white,in:Capsule())
                GeometryReader { proxy in
                    ZStack(alignment:.leading) {
                        HStack(spacing:4) {
                            Capsule().fill(cyan.opacity(0.75)).frame(width:proxy.size.width*0.27)
                            Capsule().fill(violet.opacity(0.65)).frame(width:proxy.size.width*0.37)
                            Capsule().fill(rose.opacity(0.72))
                        }.frame(height:7)
                        Capsule().fill(.white).frame(width:4,height:42).shadow(color:.black.opacity(0.18),radius:3,y:1).offset(x:moment*(proxy.size.width-4))
                    }.frame(height:42).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance:0).onChanged { moment = min(1,max(0,$0.location.x/proxy.size.width)) })
                        .accessibilityElement(children:.ignore).accessibilityLabel("Practice timeline")
                        .accessibilityValue("\(Int((1-moment)*12)+1) minutes ago")
                        .accessibilityAdjustableAction { direction in moment = min(1,max(0,moment+(direction == .increment ? 0.1 : -0.1))) }
                }.frame(width:450,height:42)
            }
        }.padding(.top,24)
    }
    private var permissions: some View {
        VStack(spacing:10) {
            permissionRow(symbol:"rectangle.inset.filled",title:"Screen recording",detail:"Screen history and searchable text",allowed:screenAllowed) {
                model.hideOverlay()
                if !CGRequestScreenCaptureAccess() { CapturePermissions.openSettings(microphone:false) }
                refreshPermissions()
            }
            permissionRow(symbol:"mic",title:"Microphone",detail:"Optional · Include your voice",allowed:microphone == .authorized) {
                guard !permissionBusy else { return }; permissionBusy = true; model.hideOverlay()
                Task { @MainActor in
                    defer { permissionBusy = false;refreshPermissions() }
                    do { try await CapturePermissions.ensureMicrophone(enabled:true) }
                    catch { permissionMessage = error.localizedDescription;CapturePermissions.openSettings(microphone:true) }
                }
            }
            Text(permissionMessage ?? "Permissions don’t start recording. Enable audio in Settings when you need it.")
                .font(.system(size:11)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth:570).padding(.top,24).padding(.horizontal,28)
    }
    private func permissionRow(symbol:String,title:String,detail:String,allowed:Bool,action:@escaping ()->Void)->some View {
        HStack(spacing:15) {
            Image(systemName:symbol).font(.system(size:20,weight:.light)).frame(width:38)
            VStack(alignment:.leading,spacing:4) { Text(title).font(.system(size:14,weight:.medium));Text(detail).font(.system(size:12)).foregroundStyle(.secondary) }
            Spacer()
            if allowed { Label("Allowed",systemImage:"checkmark.circle.fill").font(.system(size:12,weight:.medium)).foregroundStyle(Color(red:0.25,green:0.48,blue:0.37)) }
            else { Button("Allow",action:action).buttonStyle(.bordered).clipShape(Capsule()).disabled(permissionBusy) }
        }.foregroundStyle(ink).padding(17).background(.white.opacity(0.74),in:RoundedRectangle(cornerRadius:22)).overlay { RoundedRectangle(cornerRadius:22).stroke(.white,lineWidth:1) }
    }
    private var modelDownloads: some View {
        VStack(spacing:10) {
            ForEach(models.catalog) { item in
                HStack(spacing:14) {
                    Image(systemName:item.id == "chat" ? "sparkles":"waveform").font(.system(size:21,weight:.light)).frame(width:36)
                    VStack(alignment:.leading,spacing:4) {
                        Text(item.id == "chat" ? "Ask Recall":"Speech transcription").font(.system(size:14,weight:.medium))
                        Text(item.title+" · "+item.sizeLabel).font(.system(size:11)).foregroundStyle(.secondary)
                        if models.busy.contains(item.id) { ProgressView(value:models.progress[item.id] ?? 0).tint(ink).frame(maxWidth:260) }
                        if let status = models.status[item.id] { Text(status).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                    }
                    Spacer(minLength:8)
                    if models.installed.contains(item.id) { Image(systemName:"checkmark.circle.fill").foregroundStyle(Color(red:0.25,green:0.48,blue:0.37)).accessibilityLabel("Installed") }
                    else if models.busy.contains(item.id) { Button("Cancel") { models.cancel(item.id) }.buttonStyle(.bordered) }
                    else { Button("Download") { models.download(item) }.buttonStyle(.bordered) }
                }.padding(16).background(.white.opacity(0.74),in:RoundedRectangle(cornerRadius:22)).overlay { RoundedRectangle(cornerRadius:22).stroke(.white,lineWidth:1) }
            }
            Button("Use an online or existing local model…") {
                guard model.finishOnboarding() else { return };model.settingsTab = "models";model.settingsOpen = true
            }.buttonStyle(.plain).font(.system(size:12)).foregroundStyle(.secondary).padding(.vertical,8)
            Text("You can download later. Screen search works without these models.").font(.system(size:11)).foregroundStyle(.tertiary)
        }.frame(maxWidth:570).padding(.top,20).padding(.horizontal,28)
    }
    private var shortcut: some View {
        VStack(spacing:12) {
            Text(model.settings.shortcuts.open.label).font(.system(size:21,weight:.medium,design:.rounded))
                .padding(.horizontal,26).padding(.vertical,12).liquidGlass(radius:17,interactive:false)
            Text("Open from anywhere. Recording pauses while Recall is open.").font(.system(size:12)).foregroundStyle(.secondary)
        }.padding(.top,22)
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration)->some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.95:1)
            .animation(reduceMotion ? nil:.spring(response:0.3,dampingFraction:0.65),value:configuration.isPressed)
    }
}
