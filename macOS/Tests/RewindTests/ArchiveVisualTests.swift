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
            scene.addSubview(image,positioned:.below,relativeTo:scene.subviews.first)
            return [image]
        }
        return view.subviews.flatMap { materializeMetal(in:$0) }
    }

    @MainActor private func archiveView(in view:NSView)->ArchiveSceneView? {
        if let archive = view as? ArchiveSceneView { return archive }
        return view.subviews.compactMap { archiveView(in:$0) }.first
    }

    @MainActor private func selectionOverlay(in view:NSView)->IndexedTextOverlay? {
        if let overlay = view as? IndexedTextOverlay { return overlay }
        return view.subviews.compactMap { selectionOverlay(in:$0) }.first
    }

    @MainActor private func searchField(in view:NSView)->NSTextField? {
        if let field = view as? NSTextField,field.isEditable { return field }
        return view.subviews.compactMap { searchField(in:$0) }.first
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
        let anchor = try reader.frames(demo:false,limit:1).first?.timestamp ?? Date()
        let records = try reader.archiveFrames(around:anchor)
        XCTAssertFalse(records.isEmpty,"Visual verification requires actual recorded screenshots")
        let root = destination.appendingPathComponent("records-"+UUID().uuidString)
        let model = try AppModel(root:root)
        model.interfaceVisibilityChanged(true)
        defer { model.interfaceVisibilityChanged(false) }
        model.onboardingOpen = false; model.launchFilmOpen = false
        model.settings.onboardingComplete = true; model.settings.launchFilmSeen = true;model.settings.glassArchiveEnabled = true
        for record in records {
            guard let pixels = await MemoryImagePipeline.shared.image(at:source.appendingPathComponent(record.imagePath),maxPixels:900) else { continue }
            let bitmap = NSBitmapImageRep(cgImage:pixels)
            let path = "frames/\(record.id).png"
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent(path))
            var copy = record;copy.imagePath = path;copy.indexingComplete = true
            try model.store.save(copy)
        }
        try root.path.write(to:destination.appendingPathComponent("preview-data-path.txt"),atomically:true,encoding:.utf8)
        model.archiveDay = Calendar.current.startOfDay(for:anchor)
        model.reload()
        let scene = ArchiveGlassScene()
        scene.update(frames:model.archiveFrames,images:[:],appearance:.warmDay,selected:nil,size:CGSize(width:1600,height:720),reduced:true)
        XCTAssertEqual(scene.recordIDs,Set(model.archiveFrames.map(\.id)),"Exactly one sheet per real record")
        XCTAssertEqual(scene.renderedCardCount,model.archiveFrames.count,"Blank sleeves must not have record identities")
        XCTAssertGreaterThan(scene.blankCardCount,0,"Missing slots are filled with empty glass, never invented records")
        XCTAssertEqual(scene.dayColumns.count,5)
        for column in scene.dayColumns {
            XCTAssertTrue(column.records.allSatisfy { Calendar.current.isDate($0.timestamp,inSameDayAs:column.day) })
            XCTAssertEqual(Set(column.records.map(\.imagePath)).count,column.records.count)
        }
        scene.scroll(by:100000,precise:false)
        XCTAssertGreaterThan(scene.scrollOffset,0)
        scene.scroll(by:-100000,precise:false)
        XCTAssertEqual(scene.scrollOffset,0,"Scrolling clamps to the first record")
        // Verify physical motion using exactly the same real records as the UI.
        let moving = ArchiveGlassScene()
        let pictures = Dictionary(uniqueKeysWithValues:model.archiveFrames.compactMap { frame -> (String,NSImage)? in
            guard let image = NSImage(contentsOf:root.appendingPathComponent(frame.imagePath)) else { return nil }
            return (frame.imagePath,image)
        })
        func configure(_ selected:String?) {
            moving.update(frames:model.archiveFrames,images:pictures,appearance:.warmDay,selected:selected,size:CGSize(width:2000,height:876),reduced:false)
        }
        configure(nil)
        let renderer = SCNRenderer(device:nil,options:nil)
        renderer.scene = moving.scene;renderer.pointOfView = moving.cameraNode
        moving.scene.background.contents = NSColor(red:0.90,green:0.89,blue:0.86,alpha:1)
        func snapshot(_ name:String) throws {
            let image = renderer.snapshot(atTime:0,with:CGSize(width:2000,height:876),antialiasingMode:.multisampling2X)
            let data = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data:data))
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent(name+".png"))
        }
        try snapshot("ridge-idle")
        moving.pointer(at:CGPoint(x:0.90,y:0.35))
        for _ in 0..<100 { moving.advance(dt:1/60) }
        try snapshot("ridge-wave-right")
        moving.pointer(at:CGPoint(x:0.10,y:0.65))
        for _ in 0..<100 { moving.advance(dt:1/60) }
        try snapshot("ridge-wave-left")
        moving.hover(nil)
        for _ in 0..<120 { moving.advance(dt:1/60) }
        let id = try XCTUnwrap(model.archiveFrames.max(by: { $0.timestamp < $1.timestamp })?.id)
        let card = try XCTUnwrap(moving.scene.rootNode.childNode(withName:id,recursively:true))
        moving.hover(id)
        for _ in 0..<120 { moving.advance(dt:1/60) }
        XCTAssertEqual(moving.hoveredID,id)
        XCTAssertEqual(moving.cameraNode.camera!.focusDistance,Double(-moving.cameraNode.convertPosition(card.worldPosition,from:nil).z),accuracy:0.01)
        XCTAssertEqual(moving.cameraNode.camera!.fStop,18,accuracy:0.01)
        try snapshot("ridge-hover-focused")
        moving.hover(nil)
        for _ in 0..<120 { moving.advance(dt:1/60) }
        XCTAssertEqual(moving.cameraNode.camera!.focusDistance,33.5,accuracy:0.01)
        let original = card.simdTransform
        configure(id)
        for step in 1...120 {
            moving.advance(dt:1/60)
            XCTAssertEqual(card.opacity,1)
            XCTAssertTrue(moving.scene.rootNode.childNode(withName:id,recursively:true) === card)
            if [8,16,30,120].contains(step) { try snapshot("extract-\(step)") }
        }
        let selection = try XCTUnwrap(moving.selectionSurface())
        XCTAssertEqual(selection.0.id,id)
        XCTAssertGreaterThan(selection.2.width*selection.1.scale.x,6.3,"Expanded screenshot should be substantially wider")
        let indexed = IndexedTextOverlay()
        indexed.frame = CGRect(x:0,y:0,width:1000,height:650)
        indexed.imageSize = indexed.frame.size;indexed.setRegions(selection.0.regions)
        if !selection.0.regions.isEmpty {
            indexed.selectAll(nil)
            XCTAssertFalse(indexed.selectedText.isEmpty,"Real OCR remains selectable on the expanded artwork")
        }
        configure(nil)
        XCTAssertNil(moving.selectionSurface(),"Text selection must not float above a returning card")
        for step in 1...180 {
            moving.advance(dt:1/60)
            XCTAssertEqual(card.opacity,1)
            if [8,16,30,180].contains(step) { try snapshot("return-\(step)") }
        }
        XCTAssertEqual(card.position.x,CGFloat(original.columns.3.x),accuracy:0.001)
        XCTAssertEqual(card.position.y,CGFloat(original.columns.3.y),accuracy:0.001)
        XCTAssertEqual(card.position.z,CGFloat(original.columns.3.z),accuracy:0.001)
        // Reverse while extracting: the node and current transform survive.
        configure(id)
        for _ in 0..<16 { moving.advance(dt:1/60) }
        let interrupted = card.simdTransform
        configure(nil)
        XCTAssertEqual(card.simdTransform,interrupted)
        for _ in 0..<180 { moving.advance(dt:1/60) }
        XCTAssertEqual(card.position.y,CGFloat(original.columns.3.y),accuracy:0.001)
        moving.stopMotion()
        try JSONEncoder().encode(model.settings).write(to:root.appendingPathComponent("settings.json"))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1600,height:900),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        for (name,size,night,open) in [
            ("archive-wide",CGSize(width:2000,height:876),false,false),
            ("archive-desktop",CGSize(width:1440,height:900),false,false),
            ("archive-night",CGSize(width:1600,height:720),true,false),
            ("archive-open",CGSize(width:1440,height:900),false,true),
            ("archive-open-night",CGSize(width:1440,height:900),true,true),
            ("archive-compact",CGSize(width:800,height:600),false,false),
            ("archive-disabled",CGSize(width:1440,height:900),false,false)
        ] {
            model.settings.appearance = night ? .deepNight:.warmDay
            model.settings.glassArchiveEnabled = name != "archive-disabled"
            let view:AnyView
            if open {
                view = AnyView(ZStack {
                    ArchiveBackdrop(appearance:model.settings.appearance)
                    ArchiveStackView(model:model,focusedID:.constant(model.archiveFrames.max(by: { $0.timestamp < $1.timestamp })?.id))
                }.preferredColorScheme(night ? .dark:.light))
            } else { view = AnyView(RootView(model:model)) }
            let host = NSHostingView(rootView:view.frame(width:size.width,height:size.height))
            window.setContentSize(size);window.contentView = host;window.orderFront(nil)
            try await Task.sleep(for:.seconds(4))
            // GPU contention can delay animation ticks; inspect the settled
            // state instead of assuming four wall-clock seconds is enough.
            if open {
                for _ in 0..<100 {
                    if let overlay = selectionOverlay(in:host),!overlay.isHidden,overlay.frame.width > size.width*0.5 { break }
                    try await Task.sleep(for:.milliseconds(100))
                }
            }
            if !open,name != "archive-disabled",let native = archiveView(in:host),let archive = native.archive {
                for _ in 0..<60 {
                    let visible = archive.viewportRecords(in:native).visible
                    if !visible.isEmpty,visible.allSatisfy({ id in
                        archive.scene.rootNode.childNode(withName:id,recursively:true)?.childNode(withName:"artwork",recursively:false)?.isHidden == false
                    }) { break }
                    try await Task.sleep(for:.milliseconds(100))
                }
                let visible = archive.viewportRecords(in:native).visible
                XCTAssertFalse(visible.isEmpty)
                XCTAssertTrue(visible.allSatisfy { id in
                    archive.scene.rootNode.childNode(withName:id,recursively:true)?.childNode(withName:"artwork",recursively:false)?.isHidden == false
                },"Every real screenshot in the current viewport must have pixels")
                XCTAssertFalse(native.isPlaying,"The view must not run SceneKit playback continuously while idle")
                print("ARCHIVE_VIEWPORT: \(name) has \(visible.count) visible real cards, all textured")
            }
            host.layoutSubtreeIfNeeded()
            // AppKit cacheDisplay omits Metal-backed layers. Snapshot those
            // with SceneKit itself, then include the pixels as a test-only
            // image subview during the complete native-window capture.
            let replacements = materializeMetal(in:host)
            if name == "archive-disabled" { XCTAssertTrue(replacements.isEmpty,"Disabled archive must not mount a 3D renderer");XCTAssertFalse(model.searchPresented,"Classic mode must open the timeline desktop, not search results") }
            defer { replacements.forEach { $0.removeFromSuperview() } }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
            host.cacheDisplay(in:host.bounds,to:bitmap)
            let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            try data.write(to:destination.appendingPathComponent("\(name).png"))
            XCTAssertGreaterThan(data.count,10000)
            if name == "archive-desktop" {
                replacements.forEach { $0.removeFromSuperview() }
                let native = try XCTUnwrap(archiveView(in:host)),archive = try XCTUnwrap(native.archive)
                let rack = try XCTUnwrap(archive.scene.rootNode.childNode(withName:"racks",recursively:false))
                var summits:[CGFloat] = []
                for (name,point) in [("pointer-left",CGPoint(x:size.width*0.28,y:size.height*0.58)),("pointer-right",CGPoint(x:size.width*0.74,y:size.height*0.58))] {
                    let windowPoint = native.convert(point,to:nil)
                    let event = try XCTUnwrap(NSEvent.mouseEvent(with:.mouseMoved,location:windowPoint,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0))
                    native.mouseMoved(with:event)
                    let hitID = archive.hoveredID
                    try await Task.sleep(for:.seconds(3))
                    if let hitID {
                        let summit = try XCTUnwrap(rack.childNodes.max { $0.position.y < $1.position.y })
                        XCTAssertEqual(summit.name,hitID,"The visible summit must be the record under the pointer")
                        XCTAssertNil(rack.childNode(withName:"hover-outline",recursively:true))
                        var clicked:String?
                        let originalSelect = native.onSelect;native.onSelect = { clicked = $0 }
                        native.mouseDown(with:event);native.mouseUp(with:event)
                        native.onSelect = originalSelect
                        XCTAssertEqual(clicked,hitID,"Click the hovered record after geometry has moved")
                    }
                    let visible = archive.viewportRecords(in:native).visible
                    for _ in 0..<40 {
                        if visible.allSatisfy({ id in archive.scene.rootNode.childNode(withName:id,recursively:true)?.childNode(withName:"artwork",recursively:false)?.isHidden == false }) { break }
                        try await Task.sleep(for:.milliseconds(100))
                    }
                    XCTAssertTrue(visible.allSatisfy { id in archive.scene.rootNode.childNode(withName:id,recursively:true)?.childNode(withName:"artwork",recursively:false)?.isHidden == false },"Cards revealed at the end of the wave also need their cached pixels")
                    summits.append(try XCTUnwrap(rack.childNodes.max { $0.position.y < $1.position.y }).position.x)
                    let capture = materializeMetal(in:host)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                    host.cacheDisplay(in:host.bounds,to:bitmap)
                    try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent(name+".png"))
                    capture.forEach { $0.removeFromSuperview() }
                }
                XCTAssertGreaterThan(summits[1],summits[0],"Moving the native mouse right must move the summit right")
                let target = try XCTUnwrap(model.archiveFrames.sorted { $0.timestamp < $1.timestamp }.dropFirst(8).first)
                model.beginTimelineDrag();model.scrub(to:target.timestamp)
                await model.waitForPendingLoads()
                try await Task.sleep(for:.milliseconds(400))
                XCTAssertNil(model.archiveExtractionID)
                XCTAssertTrue(selectionOverlay(in:host)?.isHidden ?? true)
                model.endTimelineDrag();await model.waitForArchiveSettlement()
                XCTAssertEqual(model.archiveExtractionID,target.id)
                for _ in 0..<120 {
                    if let overlay = selectionOverlay(in:host),!overlay.isHidden,overlay.frame.width > size.width*0.5 { break }
                    try await Task.sleep(for:.milliseconds(100))
                }
                let overlay = try XCTUnwrap(selectionOverlay(in:host))
                XCTAssertFalse(overlay.isHidden,"Releasing the real-record timeline must extract its sheet")
                XCTAssertGreaterThan(overlay.frame.width,size.width*0.5)
                let extracted = materializeMetal(in:host)
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                host.cacheDisplay(in:host.bounds,to:image)
                try XCTUnwrap(image.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent("timeline-release-extracted.png"))
                extracted.forEach { $0.removeFromSuperview() }
                model.beginTimelineDrag()
                try await Task.sleep(for:.milliseconds(100))
                XCTAssertTrue(overlay.isHidden,"A new drag must immediately release the text selection overlay")
                model.back()
            }
            if name == "archive-disabled" {
                let field = try XCTUnwrap(searchField(in:host))
                let resting = field.convert(field.bounds,to:host)
                NotificationCenter.default.post(name:Notification.Name("RewindFocusSearch"),object:nil)
                try await Task.sleep(for:.seconds(1))
                host.layoutSubtreeIfNeeded()
                let engaged = try XCTUnwrap(searchField(in:host))
                let focused = engaged.convert(engaged.bounds,to:host)
                XCTAssertEqual(resting.midY,focused.midY,accuracy:8,"Focusing the classic search field must not move it to the top")
                XCTAssertFalse(model.searchPresented)
                let focusedBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                host.cacheDisplay(in:host.bounds,to:focusedBitmap)
                try XCTUnwrap(focusedBitmap.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent("classic-search-focused.png"))
                model.showSearch()
                try await Task.sleep(for:.seconds(1))
                let resultsBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                host.cacheDisplay(in:host.bounds,to:resultsBitmap)
                try XCTUnwrap(resultsBitmap.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent("all-memories.png"))
            }
            if open {
                let overlay = try XCTUnwrap(selectionOverlay(in:host))
                XCTAssertFalse(overlay.isHidden,"Selection must be mounted on the actual expanded image")
                XCTAssertGreaterThan(overlay.frame.width,size.width*0.5)
                // Newly captured records may not yet have stored OCR. Wait
                // for the real on-demand recognition used by this image view.
                for _ in 0..<16 {
                    overlay.selectAll(nil)
                    if !overlay.selectedText.isEmpty { break }
                    try await Task.sleep(for:.milliseconds(500))
                }
                XCTAssertFalse(overlay.selectedText.isEmpty,"Actual recorded pixels must expose selectable OCR text")
                if let selection = overlay.selection {
                    overlay.select(from:.init(line:0,offset:0),to:.init(line:min(10,selection.head.line),offset:8))
                    XCTAssertFalse(overlay.selectedText.isEmpty)
                }
                overlay.layoutSubtreeIfNeeded()
                var hits = false
                for x in stride(from:overlay.frame.minX+4,to:overlay.frame.maxX,by:12) {
                    for y in stride(from:overlay.frame.minY+4,to:overlay.frame.maxY,by:12) where !hits {
                        hits = overlay.hitTest(NSPoint(x:x,y:y)) === overlay
                    }
                    if hits { break }
                }
                XCTAssertTrue(hits,"The OCR layer must receive clicks inside the projected artwork")
                let selectionBitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                host.cacheDisplay(in:host.bounds,to:selectionBitmap)
                try XCTUnwrap(selectionBitmap.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent("archive-selection.png"))
            }
        }
        for glass in [false,true] {
            for night in [false,true] {
                model.settings.glassArchiveEnabled = glass
                model.settings.appearance = night ? .deepNight:.warmDay
                let size = CGSize(width:1440,height:900)
                let host = NSHostingView(rootView:RootView(model:model).preferredColorScheme(night ? .dark:.light).frame(width:size.width,height:size.height))
                window.setContentSize(size);window.contentView = host;window.orderFront(nil)
                try await Task.sleep(for:.milliseconds(100))
                model.showSearch();await model.waitForPendingLoads()
                try await Task.sleep(for:.seconds(2))
                func effects(_ view:NSView)->[DesktopEffectView] {
                    if let effect = view as? DesktopEffectView { return [effect] }
                    return view.subviews.flatMap { effects($0) }
                }
                XCTAssertEqual(effects(host).count,1,"Results should share the original full-window desktop background")
                func scrollGrid(_ view:NSView) {
                    if let scroll = view as? NSScrollView,let document = scroll.documentView,document.bounds.height > scroll.contentView.bounds.height+220 {
                        scroll.contentView.scroll(to:NSPoint(x:0,y:220));scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    view.subviews.forEach { scrollGrid($0) }
                }
                scrollGrid(host)
                try await Task.sleep(for:.milliseconds(300))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:destination.appendingPathComponent("results-\(glass ? "archive":"classic")-\(night ? "night":"day").png"))
                model.returnToDesktop()
            }
        }
        model.prepareToQuit(); await model.shutDownRecording(); await model.storageOptimizer.stop()
    }
}
