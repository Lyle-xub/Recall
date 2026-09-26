// Onscreen reference for the public APIs used by NativeSurface.swift.
// This standalone harness never opens a Recall library or requests recording.
import AppKit
import SwiftUI

@main struct MaterialReference {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = ReferenceDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
final class ReferenceHost<V:View>: NSHostingView<V> { override var isOpaque:Bool { false }; override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); layer?.backgroundColor = NSColor.clear.cgColor } }
@MainActor final class ReferenceWindow: NSWindow { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }
@MainActor final class ReferenceDelegate: NSObject, NSApplicationDelegate {
    var backdrop: NSWindow!, window: NSWindow!, timer: Timer?
    var last = ""
    let directory = ProcessInfo.processInfo.environment["RECALL_MATERIAL_REFERENCE"] ?? "/tmp/recall-material-reference"
    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 800)
        backdrop = NSWindow(contentRect:frame,styleMask:[.borderless],backing:.buffered,defer:false)
        backdrop.isReleasedWhenClosed = false
        backdrop.title = "Recall Material Background"
        backdrop.contentView = NSHostingView(rootView:ReferencePattern().frame(width:1280,height:800))
        backdrop.center(); backdrop.orderFront(nil)
        window = ReferenceWindow(contentRect:backdrop.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.title = "Recall Material Reference"
        window.isReleasedWhenClosed = false; window.isOpaque = false
        window.backgroundColor = .clear
        render(dark:false,blur:false)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.readCommand() }
        }
    }
    func render(dark:Bool,blur:Bool) {
        let host = ReferenceHost(rootView:ReferenceControls(dark:dark,blur:blur).preferredColorScheme(dark ? .dark:.light).frame(width:1280,height:800))
        if #available(macOS 26.0, *) { host.safeAreaRegions = [] }
        window.appearance = NSAppearance(named:dark ? .darkAqua:.aqua)
        window.contentView = host
    }
    func readCommand() {
        guard let data = try? Data(contentsOf:URL(fileURLWithPath:directory+"/control.json")),
              let text = String(data:data,encoding:.utf8),text != last,
              let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else {return}
        last = text
        render(dark:object["dark"] as? Bool ?? false,blur:object["blur"] as? Bool ?? false)
    }
}
struct ReferencePattern: View {
    var body: some View {
        Canvas { context,size in
            context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(Color(red:0.89,green:0.91,blue:0.93)))
            let colors:[Color] = [Color(red:0.27,green:0.52,blue:0.83),Color(red:0.81,green:0.40,blue:0.49),Color(red:0.92,green:0.73,blue:0.35),Color(red:0.32,green:0.67,blue:0.58)]
            for i in 0..<16 {
                context.fill(Path(CGRect(x:i*80,y:0,width:40,height:800)),with:.color(colors[i%4]))
            }
            for y in stride(from:100,to:800,by:160) {
                context.fill(Path(CGRect(x:0,y:y,width:1280,height:3)),with:.color(.black.opacity(0.6)))
            }
        }
    }
}
struct ReferenceBlur: NSViewRepresentable {
    func makeNSView(context:Context)->NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .underWindowBackground
        view.blendingMode = .withinWindow; view.state = .active; return view
    }
    func updateNSView(_ view:NSVisualEffectView,context:Context) {}
}
struct ReferenceControls: View {
    let dark:Bool,blur:Bool
    @ViewBuilder func glass<V:View>(_ content:V,radius:CGFloat)->some View {
        if #available(macOS 26.0, *) { content.glassEffect(.regular.interactive(),in:RoundedRectangle(cornerRadius:radius,style:.continuous)) }
        else {content.background(.regularMaterial,in:RoundedRectangle(cornerRadius:radius))}
    }
    var body: some View {
        ZStack(alignment:.topLeading) {
            ReferencePattern()
            if blur { ReferenceBlur(); LinearGradient(colors:dark ? [.black.opacity(0.16),.black.opacity(0.06)] : [.white.opacity(0.09),.white.opacity(0.025)],startPoint:.top,endPoint:.bottom) }
            glass(Text("Search memories").font(.system(size:20)).foregroundStyle(dark ? Color.white:Color.black).frame(width:620,height:64),radius:32).offset(x:130,y:24)
            ForEach(0..<5) { index in
                glass(Image(systemName:["square.grid.2x2","star","sparkles","chart.bar","slider.horizontal.3"][index]).font(.system(size:21)).frame(width:64,height:64),radius:32).offset(x:766+CGFloat(index)*80,y:24)
            }
            glass(Text("Starred").font(.system(size:15,weight:.semibold)).frame(width:140,height:52),radius:26).offset(x:40,y:132)
            glass(Color.clear.frame(width:360,height:380),radius:29).offset(x:40,y:224)
            glass(Color.clear.frame(width:360,height:380),radius:29).offset(x:460,y:224)
            glass(Color.clear.frame(width:360,height:380),radius:29).offset(x:880,y:224)
            glass(Text("September 26, 2026      One day per column").font(.system(size:16)).frame(width:480,height:54),radius:27).offset(x:400,y:708)
        }
    }
}
