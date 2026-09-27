import XCTest
import Combine
import AVFoundation
import CoreImage
@testable import Rewind

private actor DestinationDecodeGate {
    let oldStarted=XCTestExpectation(description:"Four old reads occupy the decoder slots")
    let targetStarted=XCTestExpectation(description:"The target uses the first released slot")
    let newerStarted=XCTestExpectation(description:"The replacement target starts")
    private var pending:[String:[CheckedContinuation<CGImage?,Never>]]=[:]
    private var calls:[String:Int]=[:]
    private(set) var maximum=0
    init() {oldStarted.expectedFulfillmentCount=4}
    func decode(_ url:URL)async->CGImage? {
        let key=url.lastPathComponent
        return await withCheckedContinuation {continuation in
            pending[key,default:[]].append(continuation);calls[key,default:0] += 1;maximum=max(maximum,pending.values.reduce(0) {$0+$1.count})
            if key.hasPrefix("old") {oldStarted.fulfill()}
            else if key == "target.png",calls[key] == 1 {targetStarted.fulfill()}
            else if key == "newer.png",calls[key] == 1 {newerStarted.fulfill()}
        }
    }
    func release(_ key:String) {
        let image=CGContext(data:nil,width:320,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        for continuation in pending.removeValue(forKey:key) ?? [] {continuation.resume(returning:image)}
    }
    func releaseAll() {for key in Array(pending.keys) {release(key)}}
    func count(_ key:String)->Int {calls[key,default:0]}
}

private actor DestinationRebalanceGate {
    let first=XCTestExpectation(description:"First over-budget plan")
    let second=XCTestExpectation(description:"A newly protected path requires one replacement plan")
    private var count=0
    private var released=Set<Int>()
    private var pending:[Int:CheckedContinuation<Void,Never>]=[:]
    func wait()async {
        count += 1;let id=count
        guard id <= 2,!released.contains(id) else {return}
        await withCheckedContinuation {pending[id]=$0;(id == 1 ? first:second).fulfill()}
    }
    func release(_ id:Int) {released.insert(id);pending.removeValue(forKey:id)?.resume()}
}

private final class DestinationReadGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"The first near-time read is held")
    private let lock=NSLock(),permit=DispatchSemaphore(value:0)
    private var armed=true
    func read(_ query:ArchiveWindowQuery,store:MemoryStore)throws->ArchiveWindow {
        lock.lock();let block=armed && query.near != nil;if block {armed=false};lock.unlock()
        if block {
            entered.fulfill()
            guard permit.wait(timeout:.now()+10) == .success else {throw RewindError.message("Unreleased test read")}
        }
        return try store.archiveWindow(query)
    }
    func release() {permit.signal()}
}
@MainActor private final class DestinationRefreshGate {
    let entered=XCTestExpectation(description:"Maintenance debounce is held")
    private var first=true
    private var pending:CheckedContinuation<Void,Never>?
    func wait()async {
        guard first else {return};first=false
        await withCheckedContinuation {pending=$0;entered.fulfill()}
    }
    func release() {pending?.resume();pending=nil}
}

final class ArchiveDestinationTests:XCTestCase {
    private func frame(_ id:String,day:Date = Date(),row:Int = 0)->MemoryFrame {
        MemoryFrame(id:id,timestamp:day.addingTimeInterval(Double(43200-row*60)),appName:"Synthetic",bundleID:"test",title:id,imagePath:id+".png",text:"",regions:[])
    }
    @MainActor func testResolvedDestinationSurvivesIntermediatePagesAndArrivalReusesItsRead()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root)
        let model=try AppModel(root:store.root,maintenanceOnly:true)
        defer {model.prepareToQuit()}
        let day=Calendar.current.startOfDay(for:Date()).addingTimeInterval(-86400*4),next=day.addingTimeInterval(86400)
        let days=[day,next].enumerated().map {lane,date in (0..<600).map {frame("destination-\(lane)-\($0)",day:date,row:$0)}}
        for item in days.flatMap({$0}) {try model.store.save(item)}
        model.settings.glassArchiveEnabled=true;model.archiveDay=day;model.reload();await model.waitForPendingLoads()
        model.requestArchiveWindow(at:20)
        model.beginTimelineDrag();model.scrub(to:days[0][550].timestamp);await model.waitForPendingLoads()
        let target=try XCTUnwrap(model.archiveNavigationTarget)
        XCTAssertEqual(target.recordID,days[0][550].id)
        XCTAssertFalse(model.archiveFrames.contains {$0.id == target.recordID},"Source metadata remains mounted while the camera starts moving")
        XCTAssertTrue(try XCTUnwrap(model.archiveDestinationWindow).frames.contains {$0.id == target.recordID})
        XCTAssertEqual(model.archiveImagePreparation?.target.id,target.recordID)
        XCTAssertLessThanOrEqual(try XCTUnwrap(model.archiveImagePreparation).images.count,24)
        for row in [180.0,320,440] {
            model.requestArchiveNavigationWindow(at:row,target:target);await model.waitForPendingLoads()
            XCTAssertEqual(model.archiveImagePreparation?.target.id,target.recordID)
            XCTAssertLessThanOrEqual(model.archiveWindow.frames.count,480)
            XCTAssertLessThanOrEqual(model.archiveDestinationWindow?.frames.count ?? 0,480)
        }
        let beforeArrival=model.archiveWindowRequestCount
        model.requestArchiveNavigationWindow(at:550,target:target);await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveWindowRequestCount,beforeArrival,"Arrival consumes the resolved page without another SQL read")
        XCTAssertTrue(model.archiveFrames.contains {$0.id == target.recordID})
        model.endTimelineDrag();XCTAssertNil(model.archiveExtractionID)
        model.archiveNavigationDidSettle(target);XCTAssertEqual(model.archiveExtractionID,target.recordID)

        model.scrub(to:days[1][580].timestamp)
        XCTAssertNil(model.archiveDestinationWindow);XCTAssertNil(model.archiveImagePreparation,"A new target invalidates preparation before its SQL result")
        model.archiveNavigationDidSettle(target);XCTAssertNil(model.archiveExtractionID)
        await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveImagePreparation?.target.id,days[1][580].id)
        model.scrub(to:days[0][80].timestamp);model.scrub(to:days[1][120].timestamp);await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveImagePreparation?.target.id,days[1][120].id)
        model.refreshArchiveWindowAfterMaintenance()
        XCTAssertNil(model.archiveDestinationWindow);XCTAssertNil(model.archiveImagePreparation)
        model.cancelArchiveExtraction();XCTAssertNil(model.archiveImagePreparation)
    }

    @MainActor func testFirstFreeDecoderPrioritizesTargetAndIntermediatePagesKeepItsPixels()async {
        let gate=DestinationDecodeGate(),old=(0..<4).map {frame("old\($0)")},target=frame("target"),page=frame("page")
        let root=URL(fileURLWithPath:"/synthetic-destination")
        let loader=ArchiveImageLoader(decode:{await gate.decode($0)},decodePreview:{await gate.decode($0)})
        defer {loader.stop();Task {await gate.releaseAll()}}
        loader.request(old,viewport:.init(visible:Set(old.map(\.id))),root:root)
        await fulfillment(of:[gate.oldStarted],timeout:3)
        let plan=ArchiveImagePreparation(generation:1,target:.init(id:target.id,path:target.imagePath),nearby:[])
        loader.request(old,viewport:.init(visible:Set(old.map(\.id))),root:root,preparation:plan)
        await gate.release("old0.png")
        await fulfillment(of:[gate.targetStarted],timeout:3)
        let ready=expectation(description:"Target pixels publish before the remaining old reads finish")
        let subscription=loader.$images.filter {$0[target.imagePath] != nil}.prefix(1).sink {_ in ready.fulfill()}
        await gate.release("target.png");await fulfillment(of:[ready],timeout:3)
        let maximum=await gate.maximum
        XCTAssertEqual(maximum,4,"The priority preview shares the four existing slots")
        loader.request([page],viewport:.init(),root:root,preparation:plan)
        XCTAssertNotNil(loader.images[target.imagePath],"Intermediate metadata must not evict destination pixels")
        await gate.releaseAll();await loader.waitUntilIdle()
        loader.request([page],viewport:.init(),root:root)
        XCTAssertNil(loader.images[target.imagePath],"Returning to ordinary browsing releases destination protection")
        XCTAssertLessThanOrEqual(loader.cachedBytes,ArchiveImageLoader.memoryBudget)
        subscription.cancel()
    }

    @MainActor func testRetargetRejectsLatePreviewWithoutWaitingForThreeOldReads()async {
        let gate=DestinationDecodeGate(),old=(0..<4).map {frame("old\($0)")},target=frame("target"),newer=frame("newer")
        let loader=ArchiveImageLoader(decode:{await gate.decode($0)},decodePreview:{await gate.decode($0)}),root=URL(fileURLWithPath:"/synthetic-destination")
        defer {loader.stop();Task {await gate.releaseAll()}}
        loader.request(old,viewport:.init(visible:Set(old.map(\.id))),root:root)
        await fulfillment(of:[gate.oldStarted],timeout:3)
        loader.request([],viewport:.init(),root:root,preparation:.init(generation:1,target:.init(id:target.id,path:target.imagePath),nearby:[]))
        await gate.release("old0.png");await fulfillment(of:[gate.targetStarted],timeout:3)
        loader.request([],viewport:.init(),root:root,preparation:.init(generation:2,target:.init(id:newer.id,path:newer.imagePath),nearby:[]))
        await gate.release("target.png");await fulfillment(of:[gate.newerStarted],timeout:3)
        XCTAssertNil(loader.images[target.imagePath])
        let ready=expectation(description:"Only the new target publishes")
        let subscription=loader.$images.filter {$0[newer.imagePath] != nil}.prefix(1).sink {_ in ready.fulfill()}
        await gate.release("newer.png");await fulfillment(of:[ready],timeout:3)
        let maximum=await gate.maximum
        XCTAssertNil(loader.images[target.imagePath]);XCTAssertEqual(maximum,4)
        await gate.releaseAll();await loader.waitUntilIdle();subscription.cancel()
    }

    @MainActor func testRepeatedSamePathUsesOnePreviewAndFreeSlotsAcceptRetargetImmediately()async {
        let gate=DestinationDecodeGate(),loader=ArchiveImageLoader(decode:{await gate.decode($0)},decodePreview:{await gate.decode($0)})
        let root=URL(fileURLWithPath:"/synthetic-retarget"),target=frame("target"),newer=frame("newer")
        defer {loader.stop();Task {await gate.releaseAll()}}
        func plan(_ item:MemoryFrame,_ generation:Int)->ArchiveImagePreparation {.init(generation:generation,target:.init(id:item.id,path:item.imagePath),nearby:[])}
        loader.request([],viewport:.init(),root:root,preparation:plan(target,0))
        await fulfillment(of:[gate.targetStarted],timeout:3)
        for generation in 1...100 {loader.request([],viewport:.init(),root:root,preparation:plan(target,generation))}
        let repeated=await gate.count("target.png")
        XCTAssertEqual(repeated,1,"Generation changes cannot duplicate an immutable preview read")
        loader.request([],viewport:.init(),root:root,preparation:plan(newer,101))
        await fulfillment(of:[gate.newerStarted],timeout:3)
        let maximum=await gate.maximum
        XCTAssertEqual(maximum,2,"A genuinely free slot starts the new path while the obsolete read is held")
        await gate.releaseAll();await loader.waitUntilIdle()
        XCTAssertNotNil(loader.images[newer.imagePath]);XCTAssertNil(loader.images[target.imagePath])
        loader.request([],viewport:.init(),root:root,preparation:plan(newer,102));await loader.waitUntilIdle()
        let cached=await gate.count("newer.png")
        XCTAssertEqual(cached,1)
    }

    @MainActor func testStopAndRootReplacementKeepUncancellableReadsInsideFourSlots()async {
        let gate=DestinationDecodeGate(),old=(0..<4).map {frame("old\($0)")},target=frame("target")
        let loader=ArchiveImageLoader(decode:{await gate.decode($0)},decodePreview:{await gate.decode($0)})
        defer {loader.stop();Task {await gate.releaseAll()}}
        loader.request(old,viewport:.init(visible:Set(old.map(\.id))),root:URL(fileURLWithPath:"/first-root"))
        await fulfillment(of:[gate.oldStarted],timeout:3)
        loader.stop()
        loader.request([],viewport:.init(),root:URL(fileURLWithPath:"/replacement-root"),preparation:.init(generation:2,target:.init(id:target.id,path:target.imagePath),nearby:[]))
        let before=await gate.count("target.png")
        XCTAssertEqual(before,0,"Cancellation cannot release a decoder that has not actually returned")
        await gate.release("old0.png");await fulfillment(of:[gate.targetStarted],timeout:3)
        await gate.releaseAll();await loader.waitUntilIdle()
        let maximum=await gate.maximum
        XCTAssertEqual(maximum,4);XCTAssertEqual(Set(loader.images.keys),[target.imagePath])
    }

    @MainActor func testMaintenanceRebuildsLatestIntentAndCancelledNavigationCannotRevive()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),day=Calendar.current.startOfDay(for:Date()).addingTimeInterval(-86400*4)
        let items=(0..<600).map {frame("refresh-\($0)",day:day,row:$0)}
        for item in items {try store.save(item)}
        let gate=DestinationReadGate(),delay=DestinationRefreshGate()
        let model=try AppModel(root:root,maintenanceOnly:true,archiveRefreshDelay:{await delay.wait()},archiveWindowLoad:{try gate.read($0,store:store)})
        defer {gate.release();delay.release();model.prepareToQuit()}
        model.settings.glassArchiveEnabled=true;model.archiveDay=day;model.reload()
        model.beginTimelineDrag();model.scrub(to:items[550].timestamp)
        await fulfillment(of:[gate.entered],timeout:3)
        model.refreshArchiveWindowAfterMaintenance();await fulfillment(of:[delay.entered],timeout:3)
        model.scrub(to:items[450].timestamp)
        gate.release();delay.release();await model.waitForPendingLoads()
        let target=try XCTUnwrap(model.archiveNavigationTarget)
        XCTAssertEqual(target.recordID,items[450].id);XCTAssertEqual(model.archiveImagePreparation?.target.id,items[450].id)
        XCTAssertFalse(model.archiveWindowLoading)
        model.endTimelineDrag();XCTAssertNil(model.archiveExtractionID)
        model.requestArchiveNavigationWindow(at:target.row,target:target);model.archiveNavigationDidSettle(target)
        XCTAssertEqual(model.archiveExtractionID,items[450].id)
        model.refreshArchiveWindowAfterMaintenance();model.cancelArchiveExtraction()
        await model.waitForPendingLoads()
        XCTAssertNil(model.archiveNavigationTarget);XCTAssertNil(model.archiveImagePreparation);XCTAssertNil(model.archiveExtractionID)
        model.reload()
        XCTAssertNil(model.archiveNavigationTarget);XCTAssertNil(model.archiveImagePreparation)
    }

    @MainActor func testIndexedPathReplacementAndArchiveMergeRefreshDestinationIdentity()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),day=Calendar.current.startOfDay(for:Date()).addingTimeInterval(-86400*4)
        let items=(0..<600).map {frame("path-\($0)",day:day,row:$0)}
        for item in items {try store.save(item)}
        let model=try AppModel(root:root,maintenanceOnly:true,archiveRefreshDelay:{})
        defer {model.prepareToQuit()}
        model.settings.glassArchiveEnabled=true;model.archiveDay=day;model.reload()
        model.scrub(to:items[550].timestamp);await model.waitForPendingLoads()
        let before=try XCTUnwrap(model.archiveNavigationTarget)
        var updated=items[550];updated.imagePath="frames/new-canonical.png";try store.save(updated)
        try Data([1]).write(to:root.appendingPathComponent(items[550].imagePath))
        model.capture.onIndexed?(updated)
        try FileManager.default.removeItem(at:root.appendingPathComponent(items[550].imagePath))
        XCTAssertNil(model.archiveImagePreparation)
        await model.waitForPendingLoads()
        let after=try XCTUnwrap(model.archiveNavigationTarget)
        XCTAssertNotEqual(after.generation,before.generation)
        XCTAssertEqual(model.archiveImagePreparation?.target.path,updated.imagePath)
        model.requestArchiveNavigationWindow(at:after.row,target:after)
        XCTAssertEqual(model.archiveFrames.first {$0.id == updated.id}?.imagePath,updated.imagePath)
        var duplicate=items[551];duplicate.imagePath=updated.imagePath;try store.save(duplicate)
        model.storageOptimizer.onImageArchived?(items[551].imagePath,updated.imagePath)
        await model.waitForPendingLoads()
        XCTAssertEqual(model.archiveDestinationWindow?.columns.first {$0.lane == 0}?.totalCount,599)
        XCTAssertEqual(model.archiveImagePreparation?.target.path,updated.imagePath)
        let generation=model.archiveNavigationTarget?.generation
        model.reload()
        XCTAssertNotEqual(model.archiveNavigationTarget?.generation,generation)
        XCTAssertEqual(model.archiveImagePreparation?.target.path,updated.imagePath)
        model.scrub(to:items[599].timestamp);await model.waitForPendingLoads()
        let tail=try XCTUnwrap(model.archiveNavigationTarget)
        model.requestArchiveNavigationWindow(at:tail.row,target:tail);model.archiveNavigationDidSettle(tail)
        var merged=items[598];merged.imagePath=items[597].imagePath;try store.save(merged)
        model.storageOptimizer.onImageArchived?(items[598].imagePath,items[597].imagePath)
        await model.waitForPendingLoads()
        let final=try XCTUnwrap(model.archiveNavigationTarget),column=try XCTUnwrap(model.archiveWindow.columns.first {$0.lane == 0})
        XCTAssertEqual(column.totalCount,598)
        XCTAssertEqual(column.row(of:items[599].id).map(Double.init),final.row,"A refreshed tail page uses the new rank, not its old records")
        XCTAssertEqual(column.records.map(\.id),model.archiveDestinationWindow?.columns.first {$0.lane == 0}?.records.map(\.id))
    }

    @MainActor func testViewportChangesCannotStarveRebalanceOrEvictNewlyVisiblePixels()async {
        let gate=DestinationRebalanceGate(),items=(0..<3).map {frame("balance\($0)")}
        let loader=ArchiveImageLoader(decode:{_ in CGContext(data:nil,width:320,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()},cacheBudget:128*1024,rebalanceWait:{await gate.wait()})
        defer {loader.stop()}
        let root=URL(fileURLWithPath:"/synthetic-balance")
        loader.request(items,viewport:.init(visible:[items[0].id]),root:root);await loader.waitUntilIdle()
        loader.updateViewport(.init(visible:[items[1].id]));await loader.waitUntilIdle()
        XCTAssertEqual(loader.rebalanceCount,0,"Provably in-budget inserts do not launch an async cache plan")
        loader.updateViewport(.init(visible:[items[2].id]));await fulfillment(of:[gate.first],timeout:3)
        for step in 0..<1000 {loader.updateViewport(.init(visible:[items[step%2].id]))}
        loader.updateViewport(.init(visible:[items[0].id]))
        await gate.release(1);await fulfillment(of:[gate.second],timeout:3)
        for step in 0..<1000 {loader.updateViewport(.init(visible:[items[step%2].id]))}
        loader.updateViewport(.init(visible:[items[0].id]))
        await gate.release(2);await loader.waitUntilIdle()
        XCTAssertEqual(loader.rebalanceCount,2,"Only an actual newly protected eviction requires a retry")
        XCTAssertNotNil(loader.images[items[0].imagePath]);XCTAssertLessThanOrEqual(loader.cachedBytes,128*1024)
    }

    @MainActor func testRealMovieDestinationPreviewIsCachedAtExtractionResolution()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root),start=Date().addingTimeInterval(-60),path="recordings/destination.mp4"
        var session=RecordingSession(startedAt:start,videoPath:path,appName:"Synthetic",hasAudio:false,unifiedVisualArchive:true)
        try store.saveSession(session)
        let sink=try LightweightVideoSink(url:root.appendingPathComponent(path),width:1200,height:800,startedAt:start,hostStart:.zero,nativeArchive:true)
        let pixels=try XCTUnwrap(CIContext().createCGImage(CIImage(color:.red),from:CGRect(x:0,y:0,width:1200,height:800)))
        let time:Double?=await withCheckedContinuation {done in sink.archiveFrame(pixels,sourceTime:CMTime(seconds:5,preferredTimescale:600)) {done.resume(returning:$0)}}
        XCTAssertEqual(time,0,"The archive writer rebases its first sample to zero")
        try await sink.finish(at:start.addingTimeInterval(12))
        session.endedAt=start.addingTimeInterval(12);session.visualArchiveReady=true;try store.saveSession(session)
        var item=frame("movie-target",day:start);item.timestamp=start.addingTimeInterval(5);item.sessionID=session.id;item.visualTime=time;item.visualWidth=1200;item.visualHeight=800;item.indexingComplete=true
        try store.save(item);item=try XCTUnwrap(store.finalizeVisualSession(session.id).first)
        XCTAssertTrue(item.imagePath.hasSuffix(".recallvideo"))
        let loader=ArchiveImageLoader(),before=await MemoryImagePipeline.previews.decodeCount,clock=ContinuousClock(),began=ContinuousClock.now
        loader.request([],viewport:.init(),root:root,preparation:.init(generation:1,target:.init(id:item.id,path:item.imagePath),nearby:[]))
        await loader.waitUntilIdle()
        let readyAt=clock.now,prepared=try XCTUnwrap(loader.images[item.imagePath])
        XCTAssertEqual(prepared.size.width,1200)
        let count=await MemoryImagePipeline.previews.decodeCount
        XCTAssertEqual(count,before+1)
        let extraction=await MemoryImagePipeline.previews.image(at:root.appendingPathComponent(item.imagePath),maxPixels:1600)
        let afterExtraction=await MemoryImagePipeline.previews.decodeCount
        XCTAssertNotNil(extraction);XCTAssertEqual(afterExtraction,count,"Extraction reuses the exact preloaded preview")
        let color=try XCTUnwrap(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        color.draw(try XCTUnwrap(extraction),in:CGRect(x:0,y:0,width:1,height:1))
        XCTAssertGreaterThan(try XCTUnwrap(color.data).assumingMemoryBound(to:UInt8.self)[0],220)
        print("ARCHIVE_DESTINATION_MOVIE first-pixels=\(began.duration(to:readyAt)) cached-extraction=\(readyAt.duration(to:clock.now)) preview-decodes=1")
        XCTAssertLessThanOrEqual(loader.cachedBytes,ArchiveImageLoader.memoryBudget);loader.stop()
    }
}
