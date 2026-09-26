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

    @MainActor func testProgressiveThumbnailsSurviveCancellationAndPrioritizeCursor() async throws {
        let loader = ArchiveImageLoader(),items = records(count:5)
        let pixels = try XCTUnwrap(CGContext(data:nil,width:80,height:50,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        var decoded:[String] = []
        let task = Task { @MainActor in
            await loader.load(items,root:URL(fileURLWithPath:"/"),near:items[3].timestamp) { url in
                decoded.append(url.lastPathComponent)
                if decoded.count > 1 { try? await Task.sleep(for:.seconds(10)) }
                return pixels
            }
        }
        while decoded.count < 2 { await Task.yield() }
        XCTAssertEqual(decoded.first,"3.png")
        XCTAssertNotNil(loader.images[items[3].imagePath],"First image is visible while the batch is still loading")
        task.cancel();await task.value
        let completed = Set(loader.images.keys)
        XCTAssertGreaterThanOrEqual(completed.count,1)
        var retryCount = 0
        await loader.load(items,root:URL(fileURLWithPath:"/"),near:items[0].timestamp) { _ in retryCount += 1;return pixels }
        XCTAssertEqual(retryCount,items.count-completed.count,"Cancellation must not cause completed decodes to repeat")
        XCTAssertEqual(loader.images.count,items.count)
        let detail = try XCTUnwrap(CGContext(data:nil,width:320,height:200,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        for frame in items.prefix(3) { loader.showDetail(detail,for:frame.imagePath) }
        XCTAssertEqual(loader.images.values.filter { $0.size.width == 320 }.count,2)
        XCTAssertEqual(loader.images[items[0].imagePath]?.size.width,80,"Evicted detail must fall back to its thumbnail, never a blank card")
        await loader.load([items[0]],root:URL(fileURLWithPath:"/"),near:nil) { _ in pixels }
        XCTAssertEqual(Set(loader.images.keys),[items[0].imagePath],"Leaving a day releases its retained images")
    }

    @MainActor func testImageArrivalDoesNotRebuildGlassOrLabels() throws {
        let scene = ArchiveGlassScene(),items = records(count:48),size = CGSize(width:1440,height:900)
        scene.update(frames:items,images:[:],appearance:.warmDay,selected:nil,size:size,reduced:true,day:day)
        let builds = scene.surfaceBuildCount
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
        XCTAssertEqual(scene.textureUpdateCount,48)
        XCTAssertTrue(dates === scene.scene.rootNode.childNode(withName:"dates",recursively:false))
        XCTAssertTrue(glass === record.childNode(withName:"glass",recursively:false))
        XCTAssertFalse(try XCTUnwrap(record.childNode(withName:"artwork",recursively:false)).isHidden)
        scene.stopMotion()
    }

}
