import XCTest
import AppKit
import SceneKit
@testable import Rewind

/// Independent acceptance against the isolated, on-device 5 × 600-card library.
/// This reader never changes the library used for the actual native UI checks.
final class ArchivePaginationAcceptanceTests:XCTestCase {
    private func fixture() throws -> (URL,MemoryStore,Calendar,Date) {
        guard let path=ProcessInfo.processInfo.environment["RECALL_ARCHIVE_PAGINATION_FIXTURE"] else {
            throw XCTSkip("Set RECALL_ARCHIVE_PAGINATION_FIXTURE to the isolated 5 × 600-card fixture")
        }
        let root=URL(fileURLWithPath:path),store=try MemoryStore(root:root,readOnly:true)
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=try XCTUnwrap(TimeZone(identifier:"Asia/Shanghai"))
        let day=try XCTUnwrap(calendar.date(from:DateComponents(year:2026,month:9,day:25)))
        return (root,store,calendar,day)
    }

    func testForwardBackwardCompletenessAndOldestTimelineTarget() throws {
        let (_,store,calendar,day)=try fixture()
        var window=ArchiveWindow(),forward=Set<String>(),backward=Set<String>()
        var durations:[Double]=[],maximumMetadata=0
        let offsets=Array(stride(from:0,through:600,by:24))
        for (direction,rows) in [("forward",offsets),("backward",Array(offsets.reversed()))] {
            for row in rows {
                let started=ContinuousClock.now
                window=try store.archiveWindow(.init(day:day,row:Double(row),anchors:window.anchors(near:Double(row))),calendar:calendar)
                let elapsed=started.duration(to:.now).components
                durations.append(Double(elapsed.seconds)*1000+Double(elapsed.attoseconds)/1e15)
                maximumMetadata=max(maximumMetadata,window.frames.count)
                XCTAssertEqual(window.columns.count,5)
                for column in window.columns {
                    XCTAssertEqual(column.totalCount,600,"Duplicate paths must not add rack slots")
                    XCTAssertLessThanOrEqual(column.records.count,96)
                    XCTAssertGreaterThanOrEqual(column.startIndex,0)
                    XCTAssertLessThanOrEqual(column.startIndex+column.records.count,column.totalCount)
                    XCTAssertEqual(Set(column.records.map(\.imagePath)).count,column.records.count)
                    let expectedDay=column.lane+3
                    for (index,frame) in column.records.enumerated() {
                        XCTAssertEqual(frame.id,String(format:"archive-day-%d-rank-%04d",expectedDay,column.startIndex+index))
                    }
                }
                if direction == "forward" {forward.formUnion(window.frames.map(\.id))}
                else {backward.formUnion(window.frames.map(\.id))}
            }
        }
        XCTAssertEqual(forward.count,3000)
        XCTAssertEqual(backward,forward)
        XCTAssertLessThanOrEqual(maximumMetadata,480)
        for index in 1...5 {
            let oldest=try XCTUnwrap(store.frame(String(format:"archive-day-%d-rank-0599",index)))
            let near=try store.archiveWindow(.init(day:oldest.timestamp,near:oldest.timestamp),calendar:calendar)
            let column=try XCTUnwrap(near.columns.first {$0.lane == 0})
            XCTAssertEqual(near.focusRow,599)
            XCTAssertEqual(column.row(of:oldest.id),599)
            XCTAssertEqual(column.records.last?.id,oldest.id)
        }
        durations.sort()
        print(String(format:"ARCHIVE_PAGINATION_ACCEPTANCE unique-forward=%d unique-backward=%d metadata-max=%d page-queries=%d median=%.3fms p95=%.3fms max=%.3fms",forward.count,backward.count,maximumMetadata,durations.count,durations[durations.count/2],durations[Int(Double(durations.count-1)*0.95)],durations.last!))
    }

    @MainActor func testNaturalSceneDemandRendersEveryCardWithBoundedNodes() throws {
        let (_,store,calendar,day)=try fixture()
        let scene=ArchiveGlassScene(),size=CGSize(width:1512,height:982)
        var window=try store.archiveWindow(.init(day:day),calendar:calendar)
        var seen=Set<String>(),maximumNodes=0,requests=0
        func update() {
            scene.update(frames:window.frames,images:[:],appearance:.warmDay,selected:nil,size:size,reduced:true,day:day,window:window)
            maximumNodes=max(maximumNodes,scene.residentNodeCount)
            let cards=scene.scene.rootNode.childNode(withName:"racks",recursively:false)?.childNodes.compactMap(\.name).filter {$0.hasPrefix("archive-day-")} ?? []
            seen.formUnion(cards)
        }
        update()
        scene.onWindowDemand={ row in
            guard !window.covers(row) else {return}
            do {
                requests += 1
                window=try store.archiveWindow(.init(day:day,row:row,anchors:window.anchors(near:row)),calendar:calendar)
                update()
            } catch {XCTFail("Natural scroll demand failed: \(error)")}
        }
        defer {scene.onWindowDemand=nil;scene.stopMotion()}
        for _ in 0..<26 {
            scene.scroll(by:CGFloat(24)/0.42,precise:false)
            update()
            XCTAssertLessThanOrEqual(scene.residentNodeCount,262)
        }
        XCTAssertEqual(scene.scrollOffset,599,accuracy:0.001,"The very oldest card must be reachable")
        XCTAssertEqual(seen.count,3000,"Every distinct card must become a real scene node while scrolling")
        let last=try XCTUnwrap(scene.scene.rootNode.childNode(withName:"archive-day-3-rank-0599",recursively:true))
        XCTAssertNotNil(last.childNode(withName:"artwork",recursively:false)?.geometry)
        for _ in 0..<26 {scene.scroll(by:-CGFloat(24)/0.42,precise:false);update()}
        XCTAssertEqual(scene.scrollOffset,0,accuracy:0.001)
        scene.scroll(by:100000,precise:false)
        XCTAssertEqual(scene.scrollOffset,599,accuracy:0.001)
        XCTAssertTrue(scene.recordIDs.contains("archive-day-3-rank-0599"),"A fast jump across unloaded pages must issue demand")
        print("ARCHIVE_SCENE_ACCEPTANCE rendered-unique=\(seen.count) resident-node-max=\(maximumNodes) metadata-requests=\(requests) bottom-row=\(scene.scrollOffset)")
    }

    @MainActor func testModelDateBurstReloadAndNewestRequestWins() async throws {
        let (source,_,calendar,day)=try fixture()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("archive-acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try FileManager.default.copyItem(at:source.appendingPathComponent("memory.sqlite"),to:root.appendingPathComponent("memory.sqlite"))
        try FileManager.default.copyItem(at:source.appendingPathComponent("settings.json"),to:root.appendingPathComponent("settings.json"))
        let model=try AppModel(root:root)
        await model.storageOptimizer.stop()
        model.settings.glassArchiveEnabled=true;model.reload()
        model.moveArchiveDay(by:-1);model.moveArchiveDay(by:-1)
        await model.waitForPendingLoads()
        XCTAssertEqual(calendar.startOfDay(for:model.archiveDay),day,"Rapid day clicks must accumulate")
        model.requestArchiveWindow(at:580);await model.waitForPendingLoads()
        XCTAssertTrue(model.archiveWindow.covers(580))
        let before=try XCTUnwrap(model.archiveWindow.columns.first {$0.lane == 0})
        XCTAssertEqual(before.row(of:"archive-day-3-rank-0580"),580)
        model.reload();await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveScrollRow,580,accuracy:0.001)
        XCTAssertEqual(model.archiveWindow.focusRow,580,"Refresh epochs must retain camera position")
        var added=try XCTUnwrap(model.store.frame("archive-day-3-rank-0000"))
        added.id="archive-new-during-deep-browse";added.timestamp=added.timestamp.addingTimeInterval(60)
        added.imagePath="frames/new-during-deep-browse.png"
        try model.store.save(added)
        model.reload();await model.waitForPendingLoads()
        let after=try XCTUnwrap(model.archiveWindow.columns.first {$0.lane == 0})
        XCTAssertEqual(after.totalCount,601)
        XCTAssertEqual(after.row(of:"archive-day-3-rank-0580"),580,"An insertion before the viewport must not move its existing identity")
        model.requestArchiveWindow(at:400);model.requestArchiveWindow(at:20)
        await model.waitForPendingLoads()
        XCTAssertTrue(model.archiveWindow.covers(20))
        XCTAssertFalse(model.archiveWindowLoading)
        XCTAssertEqual(model.archiveScrollRow,20,accuracy:0.001)
        let oldest=try XCTUnwrap(model.store.frame("archive-day-3-rank-0599"))
        model.beginTimelineDrag();model.scrub(to:oldest.timestamp)
        await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveTimelinePosition,oldest.timestamp)
        XCTAssertEqual(model.archiveNavigationTarget?.recordID,oldest.id)
        model.endTimelineDrag()
        let navigation=try XCTUnwrap(model.archiveNavigationTarget)
        model.requestArchiveNavigationWindow(at:navigation.row,target:navigation);await model.waitForPendingLoads()
        model.archiveNavigationDidSettle(navigation)
        await model.waitForArchiveSettlement()
        XCTAssertEqual(model.archiveExtractionID,oldest.id)
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
        print("ARCHIVE_MODEL_ACCEPTANCE accumulated-day-navigation=passed reload-anchor=passed concurrent-insert-anchor=passed latest-request=passed oldest-timeline-extraction=passed")
    }
}
