import XCTest
@testable import Rewind

final class AppUsageTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970:1_700_000_000)
    private func date(_ seconds:Double) -> Date { origin.addingTimeInterval(seconds) }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    @MainActor func testRapidAppSwitchesAreContiguousWithoutAnyScreenshots() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), recorder = AppUsageRecorder(store:store)
        let apps = ["Safari","Obsidian","ChatGPT","Finder"]
        for (i,app) in apps.enumerated() { try recorder.transition(to:.init(name:app,bundleID:app),at:date(Double(i)*0.15)) }
        try recorder.checkpoint(at:date(10))
        let usage = try store.usage(in:DateInterval(start:date(0),end:date(10)))
        XCTAssertEqual(usage.map(\.app.name),apps)
        XCTAssertEqual(try store.count(),0,"Usage must not depend on completed screenshots or OCR")
        for (a,b) in zip(usage,usage.dropFirst()) { XCTAssertEqual(a.end,b.start) }
        XCTAssertEqual(usage.last?.end,date(10))
        XCTAssertEqual(try store.firstTimelineDate(),date(0))
    }
    @MainActor func testCheckpointRestartAndPauseNeverInventUsage() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), recorder = AppUsageRecorder(store:store)
        let app = AppUsageIdentity(name:"Safari",bundleID:"com.apple.Safari")
        try recorder.transition(to:app,at:date(0))
        try recorder.transition(to:app,at:date(5))
        try recorder.checkpoint(at:date(4)) // Late notification / clock adjustment.
        try recorder.stop(at:date(10))
        try recorder.checkpoint(at:date(50))
        let restarted = AppUsageRecorder(store:store)
        XCTAssertNil(restarted.current)
        try restarted.transition(to:app,at:date(100))
        try restarted.stop(at:date(120))
        let usage = try MemoryStore(root:root).usage(in:DateInterval(start:date(0),end:date(200)))
        XCTAssertEqual(usage.count,2)
        XCTAssertEqual(usage[0].end,date(10))
        XCTAssertEqual(usage[1].start,date(100))
        let segments = TimelineGeometry.continuous(legacy:[],usage:usage,range:DateInterval(start:date(0),end:date(120)),cutover:date(0))
        XCTAssertEqual(segments.count,3)
        XCTAssertNil(segments[1].kind)
        XCTAssertEqual(segments[1].duration,90)
        for (a,b) in zip(segments,segments.dropFirst()) { XCTAssertEqual(a.end,b.start,"Neutral intervals keep the rail continuous without claiming recorded usage") }
    }
    func testExcludedAppsNeverPersistTheirIdentity() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        let identity = AppUsageIdentity.resolved(name:"1Password",bundleID:"com.1password.1password",ownApp:false,settings:AppSettings())
        try store.saveUsage(.init(app:identity,start:date(0),end:date(20)))
        let saved = try XCTUnwrap(store.usage(in:DateInterval(start:date(5),end:date(10))).first)
        XCTAssertEqual(saved.app.kind,.excluded)
        XCTAssertEqual(saved.app.bundleID,"")
        XCTAssertEqual(saved.app.name,"Private activity")
    }
    func testLegacyProjectionCutoverAndLongIntervalQuery() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        let frame = MemoryFrame(timestamp:date(0),appName:"Safari",bundleID:"Safari",title:"",imagePath:"",text:"Private OCR is not part of usage",regions:[])
        try store.save(frame)
        let range = DateInterval(start:date(0),end:date(100))
        let legacy = TimelineGeometry.legacySegments(try store.capturedApps(in:range),interval:3)
        let usage = AppUsageInterval(app:.init(name:"Finder",bundleID:"Finder"),start:date(2),end:date(100))
        try store.saveUsage(usage)
        XCTAssertEqual(try store.usage(in:DateInterval(start:date(30),end:date(40))).map(\.id),[usage.id])
        XCTAssertEqual(try store.firstUsageDate(),date(2))
        let segments = TimelineGeometry.continuous(legacy:legacy,usage:[usage],range:range,cutover:date(2))
        XCTAssertEqual(segments.count,2)
        XCTAssertEqual(segments[0].end,date(2))
        XCTAssertEqual(segments[1].start,date(2))
        XCTAssertEqual(segments.last?.end,date(100))
    }
    @MainActor func testScrubbingUncapturedUsageDoesNotShowAnotherAppsScreenshot() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at:root) }
        let model = try AppModel(root:root)
        try model.store.save(MemoryFrame(timestamp:date(0),appName:"Safari",bundleID:"Safari",title:"",imagePath:"",text:"",regions:[]))
        try model.store.saveUsage(.init(app:.init(name:"Obsidian",bundleID:"Obsidian"),start:date(10),end:date(20)))
        model.reload(); model.scrub(to:date(15)); await model.waitForPendingLoads()
        XCTAssertEqual(model.timelineCursor,date(15))
        XCTAssertNil(model.selected)
        model.setTimelineSpan(86400)
        await model.waitForPendingLoads()
        XCTAssertEqual(model.timelineCursor,date(15),"Zoom must preserve the exact playhead time")
        XCTAssertTrue(model.timelineActivity.contains { $0.appName == "Obsidian" })
        XCTAssertEqual(model.timelineViewportWidth/model.timelineScale,86400,accuracy:0.001)
    }
    func testZoomBoundsAndTicks() {
        XCTAssertEqual(TimelineZoom.clamp(0),60)
        XCTAssertEqual(TimelineZoom.clamp(.infinity),300)
        XCTAssertEqual(TimelineZoom.clamp(1e10),86400)
        for span in TimelineZoom.presets { XCTAssertLessThanOrEqual(span/TimelineZoom.tickStep(for:span),8) }
    }
    func testBlurHasTransparentMarginAndSmoothMonotonicFalloff() {
        XCTAssertEqual(TimelineBlurProfile.opacity(at:0),0)
        XCTAssertEqual(TimelineBlurProfile.opacity(at:0.18),0)
        XCTAssertEqual(TimelineBlurProfile.opacity(at:1),1,accuracy:0.000001)
        let samples = (0...100).map { TimelineBlurProfile.opacity(at:Double($0)/100) }
        for (a,b) in zip(samples,samples.dropFirst()) { XCTAssertLessThanOrEqual(a,b); XCTAssertLessThan(b-a,0.025) }
        XCTAssertLessThan(TimelineBlurProfile.opacity(at:0.19),0.0001)
    }
}
