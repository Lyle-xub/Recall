import XCTest
import AppKit
import VisionKit
@testable import Rewind

final class TimelineTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970:1_700_000_000)
    private func frame(_ offset:Double,_ app:String = "Safari") -> MemoryFrame {
        MemoryFrame(timestamp:origin.addingTimeInterval(offset),appName:app,bundleID:app,title:app,imagePath:"frames/test.jpg",text:"",regions:[])
    }
    func testNearestFrameHandlesEdgesAndMissingIntervals() {
        let frames = [frame(0),frame(3),frame(6),frame(60)]
        XCTAssertEqual(TimelineGeometry.nearest(to:origin.addingTimeInterval(-10),in:frames)?.id,frames.first?.id)
        XCTAssertEqual(TimelineGeometry.nearest(to:origin.addingTimeInterval(4),in:frames)?.id,frames[1].id)
        XCTAssertEqual(TimelineGeometry.nearest(to:origin.addingTimeInterval(59),in:frames)?.id,frames.last?.id)
        XCTAssertEqual(TimelineGeometry.nearest(to:origin.addingTimeInterval(100),in:frames)?.id,frames.last?.id)
        XCTAssertNil(TimelineGeometry.nearest(to:origin,in:[]))
    }
    func testAppSegmentsKeepDurationAndRecordingGaps() {
        let segments = TimelineGeometry.segments([frame(0),frame(3),frame(6,"Finder"),frame(60,"Finder")],interval:3)
        XCTAssertEqual(segments.count,3)
        XCTAssertEqual(segments[0].end.timeIntervalSince(segments[0].start),6)
        XCTAssertLessThan(segments[1].end,segments[2].start)
        XCTAssertEqual(segments[2].end.timeIntervalSince(segments[2].start),3)
    }
    func testContinuousCaptureDoesNotInventAnIdleGap() {
        var first = frame(0), second = frame(60,"Finder"), resumed = frame(120,"Finder")
        first.sessionID = "recording"; second.sessionID = "recording"; resumed.sessionID = "recording"
        first.continuityID = "run1"; second.continuityID = "run1"; resumed.continuityID = "run2"
        let segments = TimelineGeometry.segments([first,second,resumed],interval:3)
        XCTAssertEqual(segments[0].end,segments[1].start)
        XCTAssertLessThan(segments[1].end,segments[2].start,"An excluded app or suspended screen must keep a real gap")
    }
    func testDenseBadgesKeepEveryMomentAndAppWithoutOverlapping() {
        // Reproduces isolated same-app records followed by a short app switch.
        let moments = [0.0,19,21,26,32,34,46,49].enumerated().map { index,offset -> MemoryFrame in
            var item = frame(offset,index == 5 ? "Obsidian":"ChatGPT")
            item.continuityID = "run\(index)"; item.sessionID = "recording"
            return item
        }
        let segments = TimelineGeometry.segments(moments,interval:3)
        let badges = TimelineGeometry.badges(for:segments,cursor:origin.addingTimeInterval(25),scale:6,width:1000)
        XCTAssertTrue(badges.contains { $0.segments.count > 1 })
        XCTAssertEqual(badges.flatMap(\.segments).map(\.id),segments.map(\.id),"Clustering must retain every selectable moment")
        XCTAssertTrue(badges.flatMap(\.segments).contains { $0.appName == "Obsidian" })
        for pair in zip(badges,badges.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.x-pair.0.x,TimelineGeometry.badgeHitWidth)
        }
        // Layout must not pretend the real excluded/paused intervals were captured.
        XCTAssertEqual(segments[0].start,segments[0].end)
        XCTAssertLessThan(segments[0].end,segments[1].start)
    }
    func testBadgeClippingAndZoomPreserveAccessibleHitAreas() {
        let segments = (0..<40).map { index in
            AppTimeSegment(id:"\(index)",appName:"App \(index)",bundleID:"app.\(index)",start:origin.addingTimeInterval(Double(index)),end:origin.addingTimeInterval(Double(index)+0.2))
        }
        for scale in [0.15,6,40.0] {
            let badges = TimelineGeometry.badges(for:segments,cursor:origin.addingTimeInterval(20),scale:scale,width:600)
            XCTAssertFalse(badges.isEmpty)
            for badge in badges {
                XCTAssertGreaterThanOrEqual(badge.x,22)
                XCTAssertLessThanOrEqual(badge.x,506,"Leave room for the return-to-desktop button")
            }
            for pair in zip(badges,badges.dropFirst()) { XCTAssertGreaterThanOrEqual(pair.1.x-pair.0.x,44) }
            let visible = segments.filter {
                TimelineGeometry.x(for:$0.end,cursor:origin.addingTimeInterval(20),scale:scale,width:600) >= 0 &&
                TimelineGeometry.x(for:$0.start,cursor:origin.addingTimeInterval(20),scale:scale,width:600) <= 506
            }
            XCTAssertEqual(badges.flatMap(\.segments).map(\.id),visible.map(\.id))
        }
    }
    func testHistoryPreviewLeavesSpaceForControlsAndTimeline() {
        for size in [CGSize(width:1512,height:982),CGSize(width:1024,height:768)] {
            let rect = HistoryPreviewGeometry.rect(screen:size,image:CGSize(width:3024,height:1964),topInset:28)
            XCTAssertGreaterThan(rect.minX,0); XCTAssertGreaterThanOrEqual(rect.minY,174)
            XCTAssertLessThanOrEqual(rect.maxY,size.height-212)
            XCTAssertEqual(rect.width/rect.height,3024.0/1964.0,accuracy:0.001)
        }
    }
    @MainActor func testTimelinePanelUsesNativeInputWithoutChangingDockOptions() throws {
        let original = NSApplication.shared.presentationOptions
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model = try AppModel(root:root)
        let parent = NSWindow(contentRect:CGRect(x:-1200,y:40,width:1200,height:800),styleMask:.borderless,backing:.buffered,defer:false)
        let controller = TimelinePanelController(parent:parent,model:model)
        XCTAssertFalse(controller.panel.isOpaque,"Native desktop blur needs no opaque launch placeholder")
        XCTAssertFalse(controller.panel.ignoresMouseEvents)
        XCTAssertTrue(controller.panel.acceptsMouseMovedEvents)
        XCTAssertFalse(controller.panel.hidesOnDeactivate)
        XCTAssertGreaterThan(controller.panel.level.rawValue,Int(CGWindowLevelForKey(.dockWindow)))
        controller.present(); controller.dismiss(); controller.dismiss()
        XCTAssertEqual(NSApplication.shared.presentationOptions,original)
        XCTAssertFalse(controller.panel.isVisible)
    }
    @MainActor func testClassicTimelineReturnsAfterSwitchingModesAndSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model = try AppModel(root:root)
        model.onboardingOpen = false
        let parent = NSWindow(contentRect:CGRect(x:0,y:0,width:1200,height:800),styleMask:.borderless,backing:.buffered,defer:false)
        parent.isReleasedWhenClosed = false
        let controller = TimelinePanelController(parent:parent,model:model)
        defer { controller.dismiss();parent.orderOut(nil);model.prepareToQuit() }
        parent.orderFront(nil);controller.present()
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertTrue(controller.panel.isVisible,"Classic timeline appears immediately without bottom-edge hover")
        XCTAssertTrue(model.timelineVisible)
        model.settings.glassArchiveEnabled = true
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertFalse(controller.panel.isVisible,"Glass archive keeps the strip out of the resting scene")
        XCTAssertFalse(model.timelineVisible)
        model.timelineCursor = Date()
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertTrue(model.timelineVisible,"A revealed glass timeline hides the archive's bottom controls")
        controller.dismiss()
        XCTAssertTrue(model.timelineVisible,"Keep the bottom controls hidden during the exit animation")
        controller.present()
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertTrue(model.timelineVisible,"A cancelled dismissal must not restore the bottom controls")
        model.timelineCursor = nil
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertFalse(controller.panel.isVisible)
        XCTAssertFalse(model.timelineVisible,"Restore the bottom controls only after the strip has left")
        model.settings.glassArchiveEnabled = false
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertTrue(controller.panel.isVisible,"Switching back restores the timeline immediately")
        model.showSearch()
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertFalse(controller.panel.isVisible)
        model.returnToDesktop()
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertFalse(model.searchPresented)
        XCTAssertTrue(controller.panel.isVisible,"Returning from search must restore the classic timeline")
        controller.dismiss();controller.present()
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertTrue(controller.panel.isVisible,"Reopening classic mode keeps the timeline available")
        await model.shutDownRecording();await model.storageOptimizer.stop()
    }
    @MainActor func testExplicitDateJumpRevealsRestingArchiveTimeline()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        _ = try MemoryStore(root:root)
        let model=try AppModel(root:root,maintenanceOnly:true)
        model.onboardingOpen=false;model.settings.glassArchiveEnabled=true
        let parent=NSWindow(contentRect:CGRect(x:0,y:0,width:1200,height:800),styleMask:.borderless,backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false
        let controller=TimelinePanelController(parent:parent,model:model)
        defer {controller.dismiss();parent.orderOut(nil);model.prepareToQuit()}
        parent.orderFront(nil);controller.present()
        XCTAssertFalse(controller.panel.isVisible)
        let revealed=XCTestExpectation(description:"Explicit date jump reveals native panel")
        let subscription=model.$timelineVisible.dropFirst().filter {$0}.prefix(1).sink {_ in revealed.fulfill()}
        model.timelineJumpOpen=true
        await fulfillment(of:[revealed],timeout:2)
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertTrue(model.timelineVisible)
        XCTAssertNil(model.timelineCursor,"Opening the picker must not invent a timeline selection")
        withExtendedLifetime(subscription) {}
        controller.dismiss()
        XCTAssertFalse(model.timelineJumpOpen,"Closing the overlay also closes its date picker")
    }
    @MainActor func testBlurMaskExistsBeforeTheFirstWindowLayout() {
        let view = DesktopEffectView(frame:NSRect(x:0,y:0,width:1200,height:220))
        XCTAssertNil(view.window)
        view.fadesUpward = true
        XCTAssertNotNil(view.maskImage,"The first displayed frame must already have its gradient mask")
        view.fadesUpward = false
        XCTAssertNil(view.maskImage)
    }
    @MainActor func testDockPresentationRestoresOptionsAcrossRepeatedOpenClose() {
        for original: NSApplication.PresentationOptions in [[],[.autoHideDock,.autoHideMenuBar],[.hideDock,.hideMenuBar]] {
            var options = original
            let scope = OverlayDockPresentation(read:{options},write:{options = $0})
            for _ in 0..<3 {
                scope.begin(); scope.begin()
                XCTAssertTrue(options.contains(.hideDock))
                XCTAssertFalse(options.contains(.autoHideDock))
                scope.end(); scope.end()
                XCTAssertEqual(options,original)
            }
        }
    }
    func testOverlayCanJoinOtherApplicationsFullScreenSpaces() {
        let behavior = RecallWindowBehavior.collection
        XCTAssertTrue(behavior.contains([.canJoinAllSpaces,.canJoinAllApplications,.fullScreenAuxiliary]))
        XCTAssertFalse(behavior.contains(.fullScreenPrimary))
        XCTAssertFalse(behavior.contains(.moveToActiveSpace),"Do not combine mutually exclusive Space policies")
    }
    @MainActor func testOutsideClickDismissesAndClearsTimelineState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model = try AppModel(root:root)
        model.selected = frame(0); model.query = "test"; model.searchPresented = true
        model.dismissTimeline()
        XCTAssertNil(model.selected); XCTAssertNil(model.timelineCursor); XCTAssertEqual(model.query,"")
        XCTAssertFalse(model.searchPresented)
    }
    func testPlayheadStaysCenteredAndOlderMomentsMoveRightOnDrag() {
        XCTAssertEqual(TimelineGeometry.x(for:origin,cursor:origin,scale:6,width:1200),600)
        XCTAssertEqual(TimelineGeometry.x(for:origin,cursor:origin.addingTimeInterval(-10),scale:6,width:1200),660)
    }
    @MainActor func testDesktopAndScrubStatesUseOnlyRealFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let model = try AppModel(root:root)
        let real = frame(0); var demo = frame(3); demo.demo = true
        try model.store.save(real);try model.store.save(demo);model.reload()
        XCTAssertEqual(model.timeline.map(\.id),[real.id]);XCTAssertNil(model.selected)
        model.scrub(to:origin);await model.waitForPendingLoads();XCTAssertEqual(model.selected?.id,real.id);XCTAssertFalse(model.searchPresented)
        model.showSearch();XCTAssertTrue(model.searchPresented);XCTAssertNil(model.selected)
        model.returnToDesktop();XCTAssertFalse(model.searchPresented);XCTAssertNil(model.timelineCursor)
    }
    @MainActor func testNativeLiveTextSupportsWordRangeSelection() async throws {
        guard ImageAnalyzer.isSupported else {throw XCTSkip("Live Text unsupported on this machine")}
        let image = NSImage(size:NSSize(width:800,height:160));image.lockFocusFlipped(true)
        NSColor.white.setFill();NSRect(x:0,y:0,width:800,height:160).fill()
        ("Select individual words here" as NSString).draw(at:NSPoint(x:40,y:50),withAttributes:[.font:NSFont.systemFont(ofSize:40),.foregroundColor:NSColor.black]);image.unlockFocus()
        let analysis = try await ImageAnalyzer().analyze(image,orientation:.up,configuration:.init([.text]))
        let overlay = ImageAnalysisOverlayView();overlay.preferredInteractionTypes = .textSelection;overlay.analysis = analysis
        let text = overlay.text
        let range = try XCTUnwrap(text.range(of:"individual"))
        overlay.selectedRanges = [range]
        XCTAssertEqual(overlay.selectedText,"individual")
    }
}
