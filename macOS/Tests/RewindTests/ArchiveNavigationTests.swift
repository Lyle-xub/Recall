import XCTest
import AppKit
@testable import Rewind

final class ArchiveNavigationTests:XCTestCase {
    private let day = Calendar.current.startOfDay(for:Date()).addingTimeInterval(-86400*3)
    private func records(count:Int = 90)->[MemoryFrame] {
        (0..<count).map { index in
            MemoryFrame(timestamp:day.addingTimeInterval(3600+Double(index)*60),appName:"Navigation fixture",bundleID:"test",title:"",imagePath:"frames/\(index).png",text:"",regions:[])
        }
    }
    func testTimeWindowIncludesRecordsOlderThanLatestDailyCap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root),items = records()
        for frame in items { try store.save(frame) }
        XCTAssertFalse(try store.archiveFrames(around:day).contains { $0.id == items[4].id })
        let around = try store.archiveFrames(around:day,near:items[4].timestamp)
        XCTAssertEqual(around.count,48)
        XCTAssertTrue(around.contains { $0.id == items[4].id })
    }
    @MainActor func testArchiveScrubbingNeverLoadsClassicPreviewAndLatestRequestWins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model = try AppModel(root:root),items = records()
        for frame in items { try model.store.save(frame) }
        model.settings.glassArchiveEnabled = true;model.reload()
        for frame in items.reversed() { model.scrub(to:frame.timestamp) }
        await model.waitForPendingLoads()
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.searchPresented)
        XCTAssertEqual(model.archiveTimelinePosition,items[0].timestamp)
        XCTAssertTrue(model.archiveFrames.contains { $0.id == items[0].id })
        model.reload();await model.waitForPendingLoads()
        XCTAssertNil(model.selected,"Activity reload must not replace the archive with a classic preview")
        XCTAssertTrue(model.archiveFrames.contains { $0.id == items[0].id })
        model.returnToDesktop();model.settings.glassArchiveEnabled = false
        model.scrub(to:items[4].timestamp);await model.waitForPendingLoads()
        XCTAssertNil(model.archiveTimelinePosition)
        XCTAssertEqual(model.selected?.id,items[4].id)
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }
    @MainActor func testSceneInterpolatesTimelineBetweenCardsWithoutExtracting() throws {
        let scene = ArchiveGlassScene(),items = Array(records(count:12).reversed())
        let middle = items[4].timestamp.addingTimeInterval(-30)
        scene.update(frames:items,images:[:],appearance:.warmDay,selected:nil,size:CGSize(width:1440,height:900),reduced:true,day:day,timelinePosition:middle)
        XCTAssertEqual(scene.scrollOffset,4.5,accuracy:0.001)
        XCTAssertNil(scene.selectionSurface(),"Scrubbing moves the rack, never extracts a detail card")
        XCTAssertEqual(scene.renderedCardCount,12)
        scene.update(frames:items,images:[:],appearance:.warmDay,selected:nil,size:CGSize(width:1440,height:900),reduced:true,day:day,timelinePosition:items[8].timestamp)
        XCTAssertEqual(scene.scrollOffset,8,accuracy:0.001)
        scene.stopMotion()
    }
    @MainActor func testReleaseAndScrollIdleExtractLatestRecordAndNewDragCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model = try AppModel(root:root),items = records()
        for frame in items { try model.store.save(frame) }
        model.settings.glassArchiveEnabled = true;model.reload()
        model.beginTimelineDrag()
        for frame in items.reversed() { model.scrub(to:frame.timestamp) }
        await model.waitForPendingLoads();await model.waitForArchiveSettlement()
        XCTAssertNil(model.archiveExtractionID,"Holding the drag keeps the rack browsable")
        model.endTimelineDrag();await model.waitForArchiveSettlement()
        XCTAssertEqual(model.archiveExtractionID,items[0].id)
        XCTAssertNil(model.selected,"Extraction must remain in the archive renderer")
        model.beginTimelineDrag()
        XCTAssertNil(model.archiveExtractionID)
        model.scrub(to:items[40].timestamp);model.endTimelineDrag()
        model.scrub(to:items[75].timestamp)
        await model.waitForArchiveSettlement()
        XCTAssertEqual(model.archiveExtractionID,items[75].id,"Only the final scroll position may open")
        model.scrub(to:items[10].timestamp);model.returnToDesktop()
        await model.waitForArchiveSettlement()
        XCTAssertNil(model.archiveExtractionID)
        model.scrub(to:day.addingTimeInterval(86400+300));await model.waitForArchiveSettlement()
        XCTAssertNil(model.archiveExtractionID,"A day without records must not open an adjacent day's card")
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }

    @MainActor func testVisibleCohortPublishesTogetherAndNearbyCardsAreWarm() async throws {
        let probe = ArchiveDecodeProbe(),items = records(count:12)
        let loader = ArchiveImageLoader(decode:{ await probe.decode($0) })
        let viewport = ArchiveViewportRecords(visible:Set(items.prefix(8).map(\.id)),nearby:Set(items.suffix(4).map(\.id)))
        loader.request(items,viewport:viewport,root:URL(fileURLWithPath:"/"))
        try await Task.sleep(for:.milliseconds(20))
        XCTAssertTrue(loader.images.isEmpty,"Do not reveal the first decoded card before the visible cohort is ready")
        await loader.waitUntilIdle()
        XCTAssertEqual(loader.publicationCount,1,"Eight visible screenshots should arrive in one UI update")
        XCTAssertEqual(Set(loader.images.keys),Set(items.prefix(8).map(\.imagePath)))
        let concurrency = await probe.maximumActive
        XCTAssertEqual(concurrency,4,"Decode concurrently with a hard limit, not a serial actor or an unbounded task per card")
        let decodes = loader.decodeCount
        loader.request(items,viewport:.init(visible:Set(items.suffix(4).map(\.id))),root:URL(fileURLWithPath:"/"))
        XCTAssertEqual(loader.publicationCount,2)
        XCTAssertEqual(loader.decodeCount,decodes,"Scrolling into the prefetched region should need no disk reads")
        XCTAssertEqual(loader.images.count,12)
        let detail = try XCTUnwrap(CGContext(data:nil,width:320,height:200,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        for frame in items.prefix(3) { await loader.showDetail(detail,for:frame.imagePath) }
        XCTAssertEqual(loader.images.values.filter { $0.size.width == 320 }.count,2)
        XCTAssertEqual(loader.images[items[0].imagePath]?.size.width,80)
        let publications = loader.publicationCount
        await loader.showDetail(detail,for:items[2].imagePath)
        XCTAssertEqual(loader.publicationCount,publications,"Revisiting the current detail must not invalidate the whole SwiftUI scene")
        loader.request([items[0]],viewport:.init(visible:[items[0].id]),root:URL(fileURLWithPath:"/"))
        XCTAssertEqual(Set(loader.images.keys),[items[0].imagePath])
    }
    @MainActor func testMovingViewportReprioritizesWithoutPublishingStalePartialBatch() async throws {
        let probe = ArchiveDecodeProbe(),items = records(count:12)
        let loader = ArchiveImageLoader(decode:{ await probe.decode($0) })
        loader.request(items,viewport:.init(visible:Set(items.prefix(8).map(\.id))),root:URL(fileURLWithPath:"/"))
        while await probe.started < 4 { await Task.yield() }
        loader.request(items,viewport:.init(visible:Set(items.suffix(4).map(\.id))),root:URL(fileURLWithPath:"/"))
        await loader.waitUntilIdle()
        XCTAssertEqual(Set(loader.images.keys),Set(items.suffix(4).map(\.imagePath)))
        XCTAssertEqual(loader.publicationCount,1)
        XCTAssertEqual(loader.decodeCount,8,"Complete only the four in-flight reads before prioritizing the new viewport")
        loader.stop()
        loader.request(items,viewport:.init(visible:Set(items.suffix(4).map(\.id))),root:URL(fileURLWithPath:"/"))
        await loader.waitUntilIdle()
        XCTAssertEqual(loader.decodeCount,8,"Remounting keeps the completed batch cached")
    }

    @MainActor func testImageArrivalDoesNotRebuildGlassOrLabels() throws {
        let scene = ArchiveGlassScene(),items = records(count:48),size = CGSize(width:1440,height:900)
        scene.update(frames:items,images:[:],appearance:.warmDay,selected:nil,size:size,reduced:true,day:day)
        let builds = scene.surfaceBuildCount,shapes = scene.shapeUpdateCount
        let dates = try XCTUnwrap(scene.scene.rootNode.childNode(withName:"dates",recursively:false))
        let record = try XCTUnwrap(scene.scene.rootNode.childNode(withName:items[0].id,recursively:true))
        let glass = try XCTUnwrap(record.childNode(withName:"glass",recursively:false))
        var pictures:[String:NSImage] = [:]
        for frame in items {
            pictures[frame.imagePath] = NSImage(size:NSSize(width:160,height:100))
            scene.update(frames:items,images:pictures,appearance:.warmDay,selected:nil,size:size,reduced:true,day:day)
        }
        XCTAssertEqual(scene.surfaceBuildCount,builds,"48 arriving textures must build zero extra glass surfaces")
        XCTAssertEqual(scene.layoutUpdateCount,1)
        XCTAssertEqual(scene.shapeUpdateCount,shapes,"Same-aspect image arrivals must not retessellate glass geometry")
        XCTAssertEqual(scene.textureUpdateCount,48)
        XCTAssertTrue(dates === scene.scene.rootNode.childNode(withName:"dates",recursively:false))
        XCTAssertTrue(glass === record.childNode(withName:"glass",recursively:false))
        XCTAssertFalse(try XCTUnwrap(record.childNode(withName:"artwork",recursively:false)).isHidden)
        scene.stopMotion()
    }

    @MainActor func testHoverOnlyPublishesDetailAfterPointerSettlesAndStopCancelsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("frames"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let items = records(count:3)
        func pixels(_ width:Int)->CGImage {
            CGContext(data:nil,width:width,height:width*5/8,bitsPerComponent:8,bytesPerRow:0,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
        let thumbnail = pixels(80)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage:pixels(800)).representation(using:.png,properties:[:]))
        for frame in items { try data.write(to:root.appendingPathComponent(frame.imagePath)) }
        let loader = ArchiveImageLoader(decode:{ _ in thumbnail })
        loader.request(items,viewport:.init(visible:Set(items.map(\.id))),root:root)
        await loader.waitUntilIdle()
        let publications = loader.publicationCount
        for _ in 0..<20 { for frame in items { loader.hover(frame.id) } }
        try await Task.sleep(for:.milliseconds(80))
        XCTAssertEqual(loader.publicationCount,publications,"Moving across cards must not invalidate the SwiftUI scene")
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertEqual(loader.publicationCount,publications+1)
        XCTAssertEqual(loader.images[items[2].imagePath]?.size.width,800)
        XCTAssertEqual(loader.images[items[0].imagePath]?.size.width,80)
        loader.hover(items[0].id);loader.stop()
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertEqual(loader.publicationCount,publications+1,"Leaving the archive cancels queued hover upgrades")
    }

}

private actor ArchiveDecodeProbe {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var started = 0
    func decode(_ url:URL) async -> CGImage? {
        active += 1;started += 1;maximumActive = max(maximumActive,active)
        try? await Task.sleep(for:.milliseconds(60))
        active -= 1
        return CGContext(data:nil,width:80,height:50,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    }
}
