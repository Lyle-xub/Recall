import XCTest
import AppKit
import SceneKit
@testable import Rewind

final class ArchivePaginationTests:XCTestCase {
    private let day=Calendar.current.startOfDay(for:Date()).addingTimeInterval(-86400*4)
    private func items(_ count:Int = 620,lane:Int = 0)->[MemoryFrame] {
        (0..<count).map { index in
            var frame=MemoryFrame(timestamp:day.addingTimeInterval(Double(lane)*86400+72000-Double(index)*60),appName:"Paging fixture",bundleID:"test",title:"Row \(index)",imagePath:"frames/\(lane)-\(index).png",text:"",regions:[])
            frame.id=String(format:"day-%d-row-%04d",lane,index);return frame
        }
    }
    private func root()->URL {FileManager.default.temporaryDirectory.appendingPathComponent("archive-paging-"+UUID().uuidString)}

    func testAllUniqueRecordsAreReachableInBothDirectionsWithBoundedWindows()throws {
        let root=root();defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root)
        let frames=(-2...2).flatMap {items(lane:$0)}
        for frame in frames {try store.save(frame)}
        for source in frames.prefix(20) {
            var duplicate=source;duplicate.id="duplicate-"+source.id;duplicate.timestamp -= 1
            try store.save(duplicate)
        }
        var hidden=items(1)[0];hidden.id="demo";hidden.imagePath="demo";hidden.demo=true;try store.save(hidden)
        hidden.id="trash";hidden.demo=false;hidden.deletedAt=Date();try store.save(hidden)
        var window=try store.archiveWindow(ArchiveWindowQuery(day:day))
        for direction in [Array(stride(from:0,through:620,by:24)),Array(stride(from:620,through:0,by:-24))+[0]] {
            var seen=Set<String>()
            for row in direction {
                window=try store.archiveWindow(ArchiveWindowQuery(day:day,row:Double(row),anchors:window.anchors(near:Double(row))))
                XCTAssertLessThanOrEqual(window.frames.count,480)
                XCTAssertTrue(window.columns.allSatisfy {$0.totalCount == 620 && $0.records.count <= 96})
                seen.formUnion(window.frames.map(\.id))
            }
            XCTAssertEqual(seen,Set(frames.map(\.id)))
        }
        let target=items()[605]
        let located=try store.archiveWindow(ArchiveWindowQuery(day:day,near:target.timestamp))
        XCTAssertEqual(located.focusRow,605)
        XCTAssertEqual(located.columns[2].row(of:target.id),605)
        XCTAssertTrue(located.frames.contains {$0.id == target.id})
    }

    func testInsertedAndRemovedRowsPreserveStableAnchorWithoutRowidAssumptions()throws {
        let root=root();defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),frames=items()
        for frame in frames {try store.save(frame)}
        let first=try store.archiveWindow(ArchiveWindowQuery(day:day,row:400))
        let anchors=first.anchors(near:400)
        var added=frames[0];added.id="new";added.imagePath="new.png";added.timestamp += 30;try store.save(added)
        let next=try store.archiveWindow(ArchiveWindowQuery(day:day,row:400,anchors:anchors))
        XCTAssertEqual(next.columns[2].totalCount,621)
        XCTAssertEqual(next.columns[2].origin,-1)
        XCTAssertEqual(next.columns[2].row(of:frames[400].id),400)
        try store.moveToTrash(frames[10])
        let afterDelete=try store.archiveWindow(ArchiveWindowQuery(day:day,row:400,anchors:next.anchors(near:400)))
        XCTAssertEqual(afterDelete.columns[2].row(of:frames[400].id),400)
        let top=try store.archiveWindow(ArchiveWindowQuery(day:day))
        XCTAssertEqual(top.columns[2].origin,0)
        XCTAssertEqual(top.columns[2].records.first?.id,added.id)
    }

    @MainActor func testLatestScrollAndRepeatedDateNavigationWinAndReloadKeepsPosition()async throws {
        let root=root();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(root:root)
        for frame in items() {try model.store.save(frame)}
        model.settings.glassArchiveEnabled=true;model.archiveDay=day;model.reload()
        for row in [150.0,400,580,250] {model.requestArchiveWindow(at:row)}
        await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveScrollRow,250)
        XCTAssertTrue(model.archiveWindow.covers(250))
        let requests=model.archiveWindowRequestCount
        for _ in 0..<50 {model.requestArchiveWindow(at:250)}
        XCTAssertEqual(model.archiveWindowRequestCount,requests,"Mouse/frame updates inside a covered window cause no SQL")
        model.requestArchiveWindow(at:450)
        let inFlightRequests=model.archiveWindowRequestCount
        for row in stride(from:450.5,through:464,by:0.5) {model.requestArchiveWindow(at:row)}
        XCTAssertEqual(model.archiveWindowRequestCount,inFlightRequests,"Continuous input inside the pending page's coverage must let that read finish")
        await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveScrollRow,464,"A completed read must not rewind the newer wheel position")
        XCTAssertTrue(model.archiveWindow.covers(464))
        model.reload()
        XCTAssertEqual(model.archiveWindow.focusRow,464)
        let anchor=model.archiveDay
        model.moveArchiveDay(by:-1);model.moveArchiveDay(by:-1)
        await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveDay,Calendar.current.date(byAdding:.day,value:-2,to:anchor))
        model.scrub(to:items()[590].timestamp)
        await model.waitForPendingLoads()
        let navigation=try XCTUnwrap(model.archiveNavigationTarget)
        model.requestArchiveNavigationWindow(at:navigation.row,target:navigation);await model.waitForPendingLoads()
        model.archiveNavigationDidSettle(navigation)
        await model.waitForArchiveSettlement()
        XCTAssertEqual(model.archiveWindow.focusRow,590)
        XCTAssertEqual(model.archiveExtractionID,items()[590].id)
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }

    @MainActor func testExpandedCardKeepsNodeIdentityAcrossFarWindowAndDeletionInvalidatesPin()throws {
        let root=root();defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),frames=items(),scene=ArchiveGlassScene()
        defer {scene.stopMotion()}
        for frame in frames {try store.save(frame)}
        let first=try store.archiveWindow(ArchiveWindowQuery(day:day,row:300,epoch:1))
        let selected=frames[300]
        func update(_ window:ArchiveWindow,_ id:String?) {
            scene.update(frames:window.frames,images:[:],appearance:.warmDay,selected:id,size:CGSize(width:1440,height:900),reduced:true,day:day,window:window)
        }
        update(first,nil);update(first,selected.id)
        let node=try XCTUnwrap(scene.scene.rootNode.childNode(withName:selected.id,recursively:true))
        let pin=ArchivePinnedRecord(frame:selected,day:day,lane:0,row:300)
        let next=try store.archiveWindow(ArchiveWindowQuery(day:day,row:580,anchors:first.anchors(near:580),epoch:1,pins:[pin]))
        update(next,selected.id)
        XCTAssertTrue(node === scene.scene.rootNode.childNode(withName:selected.id,recursively:true))
        XCTAssertEqual(scene.selectionSurface()?.0.id,selected.id)
        XCTAssertLessThanOrEqual(scene.residentNodeCount,262)
        update(next,nil)
        scene.scroll(by:100000,precise:false)
        XCTAssertGreaterThan(scene.scrollOffset,600)
        XCTAssertLessThanOrEqual(scene.residentNodeCount,262)
        try store.moveToTrash(selected)
        let removed=try store.archiveWindow(ArchiveWindowQuery(day:day,row:580,pins:[pin]))
        XCTAssertTrue(removed.pins.isEmpty)
    }

    @MainActor func testProtectedThumbnailsAndDetailsShareHardMemoryBudget()async throws {
        let pixels=try XCTUnwrap(CGContext(data:nil,width:1024,height:768,bitsPerComponent:8,bytesPerRow:4096,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let detail=try XCTUnwrap(CGContext(data:nil,width:3000,height:2000,bitsPerComponent:8,bytesPerRow:12000,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let loader=ArchiveImageLoader(decode:{_ in pixels}),frames=items(48)
        loader.request(frames,viewport:.init(visible:Set(frames.prefix(24).map(\.id)),nearby:Set(frames.suffix(24).map(\.id))),root:URL(fileURLWithPath:"/fixture"))
        await loader.waitUntilIdle()
        XCTAssertLessThanOrEqual(loader.cachedBytes,ArchiveImageLoader.memoryBudget)
        XCTAssertEqual(loader.images.count,24)
        for frame in frames.prefix(4) {
            await loader.showDetail(detail,for:frame.imagePath)
            XCTAssertLessThanOrEqual(loader.cachedBytes,ArchiveImageLoader.memoryBudget,"Detailed images cannot bypass the protected cache budget")
        }
        XCTAssertLessThanOrEqual(loader.cachedImageCount,50)
        loader.request([frames[0]],viewport:.init(visible:[frames[0].id]),root:URL(fileURLWithPath:"/fixture"))
        XCTAssertEqual(loader.cachedImageCount,1)
        loader.stop()
    }

    @MainActor func testModelPinsSelectionAndRefreshesMergedPathsWithoutMovingViewport()async throws {
        let root=root();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(root:root),frames=items()
        for frame in frames {try model.store.save(frame)}
        model.settings.glassArchiveEnabled=true;model.archiveDay=day;model.reload()
        model.requestArchiveWindow(at:300);await model.waitForPendingLoads()
        model.pinArchiveRecord(frames[300].id)
        model.requestArchiveWindow(at:580);await model.waitForPendingLoads()
        XCTAssertTrue(model.archiveFrames.contains {$0.id == frames[300].id})
        XCTAssertTrue(model.archiveWindow.pins.contains {$0.frame.id == frames[300].id})
        var merged=frames[20];merged.imagePath=frames[10].imagePath;try model.store.save(merged)
        model.refreshArchiveWindowAfterMaintenance();await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveScrollRow,580)
        XCTAssertEqual(model.archiveWindow.columns[2].totalCount,619)
        XCTAssertEqual(model.archiveWindow.pins.first?.frame.id,frames[300].id)
        try model.store.moveToTrash(frames[300])
        model.refreshArchiveWindowAfterMaintenance();await model.waitForPendingLoads()
        XCTAssertFalse(model.archiveFrames.contains {$0.id == frames[300].id})
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }

    @MainActor func testCaptureDuringTopRefreshDoesNotLoseTheNewerNotification()async throws {
        let root=root();defer {try? FileManager.default.removeItem(at:root)}
        let model=try AppModel(root:root),frames=items()
        for frame in frames {try model.store.save(frame)}
        model.settings.glassArchiveEnabled=true;model.archiveDay=day;model.reload()
        model.requestArchiveWindow(at:400);await model.waitForPendingLoads()
        var added=frames[0];added.id="new-first";added.imagePath="new-first.png";added.timestamp += 10
        try model.store.save(added);model.capture.onFrame?(added)
        XCTAssertEqual(model.archiveScrollRow,400,"Background capture never shifts the deep viewport")
        model.requestArchiveWindow(at:0)
        added.id="new-second";added.imagePath="new-second.png";added.timestamp += 10
        try model.store.save(added);model.capture.onFrame?(added)
        await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveWindow.columns[2].records.first?.id,"new-second")
        XCTAssertEqual(model.archiveWindow.columns[2].totalCount,622)
        XCTAssertEqual(model.archiveScrollRow,0)
        model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }

    @MainActor func testTenThousandCardQueriesAndReconciliationStayBounded()async throws {
        let root=root();defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),scene=ArchiveGlassScene()
        defer {scene.stopMotion()}
        for (index,var frame) in items(10000).enumerated() {
            frame.timestamp=day.addingTimeInterval(80000-Double(index)*6)
            try store.save(frame)
        }
        var queryMS:[Double]=[],sceneMS:[Double]=[],window=ArchiveWindow()
        func elapsed(_ start:ContinuousClock.Instant)->Double {
            let value=start.duration(to:.now).components
            return Double(value.seconds)*1000+Double(value.attoseconds)/1e15
        }
        for row in [0,1000,5000,9000,9999,7000,3000,0] {
            var started=ContinuousClock.now
            window=try store.archiveWindow(ArchiveWindowQuery(day:day,row:Double(row),epoch:row))
            queryMS.append(elapsed(started));started = .now
            scene.update(frames:window.frames,images:[:],appearance:.warmDay,selected:nil,size:CGSize(width:1440,height:900),reduced:true,day:day,window:window)
            scene.advance(dt:1/60)
            sceneMS.append(elapsed(started))
            XCTAssertEqual(window.columns[2].totalCount,10000)
            XCTAssertLessThanOrEqual(window.frames.count,480)
            XCTAssertLessThanOrEqual(scene.residentNodeCount,262)
        }
        await scene.waitForFooters()
        var stepMS:[Double]=[]
        for _ in 0..<8 {
            let started=ContinuousClock.now
            scene.scroll(by:8/0.42,precise:false)
            stepMS.append(elapsed(started))
            await scene.waitForFooters()
        }
        let sorted=queryMS.sorted(),render=sceneMS.sorted(),steps=stepMS.sorted()
        print(String(format:"ARCHIVE_8_ROW_FIXTURE median=%.2fms p95=%.2fms max=%.2fms (main-thread scene work; excludes async footers; not screen FPS)",steps[steps.count/2],steps[Int(Double(steps.count-1)*0.95)],steps.last!))
        scene.setActive(false)
        print(String(format:"ARCHIVE_10000_FIXTURE query-cold=%.2fms query-median=%.2fms query-max=%.2fms reconcile-median=%.2fms reconcile-max=%.2fms (model work; not screen FPS)",queryMS[0],sorted[sorted.count/2],sorted.last!,render[render.count/2],render.last!))
    }
}
