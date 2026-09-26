import XCTest
import AppKit
import SwiftUI
import SceneKit
@testable import Rewind

/// Explicitly opt-in, synthetic visual fixtures shared with the Windows runner.
/// This never opens the user's library or starts recording.
final class VisualParityReferenceTests: XCTestCase {
    @MainActor func testExportControlledReference() async throws {
        guard let output = ProcessInfo.processInfo.environment["RECALL_PARITY_REFERENCE"] else {
            throw XCTSkip("Set RECALL_PARITY_REFERENCE to export isolated cross-platform fixtures")
        }
        let destination = URL(fileURLWithPath:output)
        let root = destination.appendingPathComponent("library")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let model = try AppModel(root:root)
        model.interfaceVisibilityChanged(true)
        model.onboardingOpen = false; model.launchFilmOpen = false
        model.settings.onboardingComplete = true; model.settings.launchFilmSeen = true
        model.settings.retentionDays = 0
        let anchor = ISO8601DateFormatter().date(from:"2026-09-26T10:00:00+08:00")!
        let apps = ["Research", "Notes", "Design"]
        var manifest:[[String:Any]] = []
        for day in -2...2 {
            for index in 0..<12 {
                let id = "parity-\(day+2)-\(index)"
                let title = ["Aurora research", "Weekly notes", "Interface studies"][index%3]
                let timestamp = Calendar.current.date(byAdding:.day,value:day,to:anchor)!.addingTimeInterval(Double(-index*420))
                let relative = "frames/\(id).png"
                let image = fixture(title:title,index:index)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data:image.tiffRepresentation!))
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent(relative))
                let frame = MemoryFrame(id:id,timestamp:timestamp,appName:apps[index%3],bundleID:"parity.\(apps[index%3].lowercased())",title:title,imagePath:relative,text:"Aurora research notes interface study \(index+1)",regions:[],starred:index%4 == 0,indexingComplete:true)
                try model.store.save(frame)
                manifest.append(["id":id,"timestamp":ISO8601DateFormatter().string(from:timestamp),"appName":frame.appName,"title":title,"imagePath":relative,"text":frame.text,"starred":frame.starred])
            }
        }
        try JSONSerialization.data(withJSONObject:["anchor":ISO8601DateFormatter().string(from:anchor),"frames":manifest],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("fixture.json"))
        model.archiveDay = Calendar.current.startOfDay(for:anchor)
        model.reload()
        let environment = ProcessInfo.processInfo.environment
        let size = CGSize(width:Double(environment["RECALL_PARITY_WIDTH"] ?? "1280") ?? 1280,
                          height:Double(environment["RECALL_PARITY_HEIGHT"] ?? "800") ?? 800)
        let window = NSWindow(contentRect:CGRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(srgbRed:0.90,green:0.91,blue:0.91,alpha:1)
        model.window = window
        defer { window.orderOut(nil) }
        func capture<V:View>(_ view:V,_ name:String) async throws {
            let host = NSHostingView(rootView:view.frame(width:size.width,height:size.height))
            window.contentView = host; window.setContentSize(size); window.orderFront(nil)
            try await Task.sleep(for:.seconds(2))
            host.layoutSubtreeIfNeeded()
            func metal(_ view:NSView)->[NSView] {
                if let scene = view as? SCNView {
                    let image = NSImageView(frame:scene.bounds)
                    image.image = scene.snapshot(); image.imageScaling = .scaleAxesIndependently
                    scene.addSubview(image)
                    return [image]
                }
                return view.subviews.flatMap { metal($0) }
            }
            let layers = metal(host)
            defer { layers.forEach { $0.removeFromSuperview() } }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
            host.cacheDisplay(in:host.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent(name+".png"))
        }
        for rhine in [false,true] {
            for dark in [false,true] {
                let prefix = "\(rhine ? "rhine":"classic")-\(dark ? "dark":"light")"
                model.returnToDesktop(); model.settings.glassArchiveEnabled = rhine
                model.settings.appearance = dark ? .deepNight:.warmDay
                model.archiveDay = Calendar.current.startOfDay(for:anchor); model.reload()
                try await capture(RootView(model:model).preferredColorScheme(dark ? .dark:.light),prefix+"-home")
                model.query = ""; model.showSearch(); model.reload()
                try await capture(RootView(model:model).preferredColorScheme(dark ? .dark:.light),prefix+"-results")
                model.query = "Aurora"; model.appFilter = "Research"; model.reload()
                try await capture(RootView(model:model).preferredColorScheme(dark ? .dark:.light),prefix+"-search")
                model.query = ""; model.appFilter = nil; model.returnToDesktop()
                if rhine {
                    let selected = try XCTUnwrap(model.archiveFrames.first)
                    try await capture(ZStack { ArchiveBackdrop(appearance:model.settings.appearance); ArchiveStackView(model:model,focusedID:.constant(selected.id)) }.preferredColorScheme(dark ? .dark:.light),prefix+"-expanded")
                }
            }
        }
        for tab in ["recording","storage"] {
            model.settingsTab = tab
            try await capture(ZStack { Color(white:0.91); SettingsView(model:model) },"settings-"+tab)
        }
        try JSONEncoder().encode(model.settings).write(to:root.appendingPathComponent("settings.json"))
        let metadata:[String:Any] = ["logicalWidth":size.width,"logicalHeight":size.height,"backingScale":window.backingScaleFactor,"macOS":ProcessInfo.processInfo.operatingSystemVersionString,"syntheticRecords":60,"source":"native SwiftUI/AppKit views; SceneKit snapshots inserted for cacheDisplay; desktop-material verification requires onscreen review","capturedAt":ISO8601DateFormatter().string(from:Date())]
        try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:destination.appendingPathComponent("environment.json"))
        model.interfaceVisibilityChanged(false); model.prepareToQuit()
        await model.shutDownRecording(); await model.storageOptimizer.stop()
    }

    @MainActor private func fixture(title:String,index:Int)->NSImage {
        let image = NSImage(size:NSSize(width:1280,height:800))
        image.lockFocus()
        defer { image.unlockFocus() }
        NSColor(srgbRed:0.94,green:0.95,blue:0.96,alpha:1).setFill(); NSRect(x:0,y:0,width:1280,height:800).fill()
        NSColor(srgbRed:0.14,green:0.18,blue:0.23,alpha:1).setFill(); NSRect(x:0,y:744,width:1280,height:56).fill()
        NSColor(srgbRed:0.87,green:0.90,blue:0.92,alpha:1).setFill(); NSRect(x:0,y:0,width:238,height:744).fill()
        func text(_ string:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat,_ color:NSColor = .darkGray) {
            (string as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:color])
        }
        text("Recall / Controlled visual sample",26,762,19,.white)
        text("Workspace",28,692,24)
        for (row,label) in ["Overview","Research","Weekly notes","Design library","Archive"].enumerated() { text(label,28,626-CGFloat(row)*52,19) }
        NSColor.white.setFill(); NSBezierPath(roundedRect:NSRect(x:275,y:62,width:960,height:638),xRadius:18,yRadius:18).fill()
        text(title,320,622,38)
        text("A shared reference for clear, quiet interfaces",320,575,23,.gray)
        text("Study \(index+1) · September 2026",320,530,17,.gray)
        let colors:[NSColor] = [NSColor(srgbRed:0.70,green:0.82,blue:0.87,alpha:1),NSColor(srgbRed:0.84,green:0.78,blue:0.89,alpha:1),NSColor(srgbRed:0.90,green:0.83,blue:0.69,alpha:1)]
        for card in 0..<3 {
            colors[(card+index)%3].setFill()
            NSBezierPath(roundedRect:NSRect(x:320+CGFloat(card)*282,y:290,width:256,height:192),xRadius:14,yRadius:14).fill()
            text(["Observe","Explore","Remember"][card],342+CGFloat(card)*282,312,22)
        }
        for row in 0..<4 { NSColor(white:0.86,alpha:1).setFill(); NSBezierPath(roundedRect:NSRect(x:320,y:228-CGFloat(row)*31,width:CGFloat([780,690,805,540][row]),height:9),xRadius:4,yRadius:4).fill() }
        return image
    }
}
