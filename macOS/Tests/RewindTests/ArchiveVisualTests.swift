import XCTest
import SwiftUI
import AppKit
import SceneKit
@testable import Rewind

/// Opt-in native snapshots sourced from real recorded screenshots, opened read-only.
final class ArchiveVisualTests: XCTestCase {
    @MainActor private func materializeMetal(in view:NSView)->[NSView] {
        if let scene = view as? SCNView {
            let image = NSImageView(frame:scene.bounds)
            image.image = scene.snapshot();image.imageScaling = .scaleAxesIndependently
            scene.addSubview(image)
            return [image]
        }
        return view.subviews.flatMap { materializeMetal(in:$0) }
    }

    @MainActor func testRenderArchiveStates() async throws {
        guard let output = ProcessInfo.processInfo.environment["RECALL_ARCHIVE_RENDER_DIR"] else {
            throw XCTSkip("Set RECALL_ARCHIVE_RENDER_DIR to render the native archive")
        }
        let destination = URL(fileURLWithPath:output)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        guard let sourcePath = ProcessInfo.processInfo.environment["RECALL_ARCHIVE_SOURCE_ROOT"] else {
            throw XCTSkip("Set RECALL_ARCHIVE_SOURCE_ROOT to a real record library; no demo data is used")
        }
        let source = URL(fileURLWithPath:sourcePath)
        let reader = try MemoryStore(root:source,readOnly:true)
        var seen = Set<String>()
        let records = Array(try reader.frames(demo:false,limit:192).filter { seen.insert($0.imagePath).inserted }.prefix(96))
        XCTAssertFalse(records.isEmpty,"Visual verification requires actual recorded screenshots")
        let root = destination.appendingPathComponent("records-"+UUID().uuidString)
        let model = try AppModel(root:root)
        model.onboardingOpen = false; model.launchFilmOpen = false
        model.settings.onboardingComplete = true; model.settings.launchFilmSeen = true
        for record in records {
            guard let pixels = await MemoryImagePipeline.shared.image(at:source.appendingPathComponent(record.imagePath),maxPixels:900) else { continue }
            let bitmap = NSBitmapImageRep(cgImage:pixels)
            let path = "frames/\(record.id).png"
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent(path))
            var copy = record;copy.imagePath = path;copy.indexingComplete = true
            try model.store.save(copy)
        }
        try root.path.write(to:destination.appendingPathComponent("preview-data-path.txt"),atomically:true,encoding:.utf8)
        model.reload()
        let scene = ArchiveGlassScene()
        scene.update(frames:model.archiveFrames,images:[:],appearance:.warmDay,selected:nil,size:CGSize(width:1600,height:720),reduced:true)
        XCTAssertEqual(scene.recordIDs,Set(model.archiveFrames.map(\.id)),"Exactly one sheet per real record")
        XCTAssertEqual(scene.renderedCardCount,model.archiveFrames.count,"No decorative duplicate cards")
        XCTAssertEqual(Set(model.archiveFrames.map(\.imagePath)).count,model.archiveFrames.count)
        scene.scroll(by:100000,precise:false)
        XCTAssertGreaterThan(scene.scrollOffset,0)
        scene.scroll(by:-100000,precise:false)
        XCTAssertEqual(scene.scrollOffset,0,"Scrolling clamps to the first record")
        try JSONEncoder().encode(model.settings).write(to:root.appendingPathComponent("settings.json"))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1600,height:900),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        for (name,size,night,open) in [
            ("archive-wide",CGSize(width:2000,height:876),false,false),
            ("archive-desktop",CGSize(width:1440,height:900),false,false),
            ("archive-night",CGSize(width:1600,height:720),true,false),
            ("archive-open",CGSize(width:1440,height:900),false,true),
            ("archive-compact",CGSize(width:800,height:600),false,false)
        ] {
            model.settings.appearance = night ? .deepNight:.warmDay
            let view:AnyView
            if open {
                view = AnyView(ZStack {
                    ArchiveBackdrop(appearance:model.settings.appearance)
                    ArchiveStackView(model:model,focusedID:.constant(model.archiveFrames.first?.id))
                }.preferredColorScheme(.light))
            } else { view = AnyView(RootView(model:model)) }
            let host = NSHostingView(rootView:view.frame(width:size.width,height:size.height))
            window.setContentSize(size);window.contentView = host;window.orderFront(nil)
            try await Task.sleep(for:.seconds(4))
            host.layoutSubtreeIfNeeded()
            // AppKit cacheDisplay omits Metal-backed layers. Snapshot those
            // with SceneKit itself, then include the pixels as a test-only
            // image subview during the complete native-window capture.
            let replacements = materializeMetal(in:host)
            defer { replacements.forEach { $0.removeFromSuperview() } }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
            host.cacheDisplay(in:host.bounds,to:bitmap)
            let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            try data.write(to:destination.appendingPathComponent("\(name).png"))
            XCTAssertGreaterThan(data.count,10000)
        }
        model.prepareToQuit(); await model.shutDownRecording(); await model.storageOptimizer.stop()
    }
}
