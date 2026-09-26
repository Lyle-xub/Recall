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
}
