import XCTest
import AppKit
import Combine
@testable import Rewind

private actor BudgetWaits {
    let started:[XCTestExpectation]
    private var pending:[Int:CheckedContinuation<Void,Never>]=[:]
    private var next=0
    init(_ count:Int) {started=(0..<count).map {XCTestExpectation(description:"Budget wait \($0)")}}
    func wait()async {
        let id=next;next += 1
        await withCheckedContinuation {pending[id]=$0;if id < started.count {started[id].fulfill()}}
    }
    func release(_ id:Int) {pending.removeValue(forKey:id)?.resume()}
    func releaseAll() {let values=pending.values;pending.removeAll();values.forEach {$0.resume()}}
}

final class ForegroundWorkBudgetTests:XCTestCase {
    @MainActor func testContinuousInputsCoalesceAndMotionOutlivesIdleThenCancellationReleases()async throws {
        let waits=BudgetWaits(2),budget=ForegroundWorkBudget(observeSystem:false,wait:{_ in await waits.wait()})
        var edges=0
        let subscription=budget.changes.sink {_ in edges += 1}
        budget.setVisible(true)
        await fulfillment(of:[waits.started[0]],timeout:2)
        for _ in 0..<1000 {budget.interaction()}
        XCTAssertEqual(edges,1,"Input pulses do not publish a state or spawn a sleeper per event")
        let lease=budget.beginActivity()
        await waits.release(0);await fulfillment(of:[waits.started[1]],timeout:2)
        let stillHeld=expectation(description:"Background work waits for the real native motion")
        budget.onDeferred={stillHeld.fulfill()}
        let cancelled=Task {try await budget.waitForBackgroundWork()}
        await fulfillment(of:[stillHeld],timeout:2)
        budget.onDeferred=nil
        cancelled.cancel()
        do {try await cancelled.value;XCTFail("Cancellation must release a gate waiter")} catch is CancellationError {} catch {XCTFail("\(error)")}
        await waits.release(1)
        // End-of-input alone is not end-of-animation.
        XCTAssertTrue(budget.state.interacting)
        budget.endActivity(lease)
        try await budget.waitForBackgroundWork()
        XCTAssertFalse(budget.state.interacting);XCTAssertEqual(edges,2)
        budget.stop();subscription.cancel();await waits.releaseAll()
    }

    @MainActor func testHiddenAndPressureRecoveryDoNotStarveVisibleIdleWorkOrReviveStoppedBudget()async throws {
        let waits=BudgetWaits(3),budget=ForegroundWorkBudget(observeSystem:false,wait:{_ in await waits.wait()})
        budget.setVisible(true);await fulfillment(of:[waits.started[0]],timeout:2)
        let lease=budget.beginActivity();budget.setVisible(false)
        try await budget.waitForBackgroundWork()
        budget.endActivity(lease);await waits.release(0)
        XCTAssertFalse(budget.state.interacting)
        budget.setPressure(.critical)
        let deferred=expectation(description:"Critical pressure postpones a new job")
        budget.onDeferred={deferred.fulfill()}
        let pending=Task {try await budget.waitForBackgroundWork()}
        await fulfillment(of:[deferred],timeout:2)
        budget.setPressure(.warning);try await pending.value
        XCTAssertTrue(budget.state.limited);XCTAssertGreaterThanOrEqual(budget.recoveryInterval(after:2),4)
        budget.setPressure(.normal);await fulfillment(of:[waits.started[1]],timeout:2)
        budget.setPressure(.critical);await waits.release(1)
        XCTAssertEqual(budget.state.pressure,.critical,"An obsolete normal callback cannot clear newer pressure")
        let recovered=expectation(description:"Debounced normal state applied")
        let subscription=budget.changes.sink {if $0.pressure == .normal {recovered.fulfill()}}
        budget.setPressure(.normal);await fulfillment(of:[waits.started[2]],timeout:2)
        await waits.release(2);await fulfillment(of:[recovered],timeout:2)
        try await budget.waitForBackgroundWork()
        subscription.cancel()
        budget.setPressure(.critical)
        let stopping=expectation(description:"A waiter is present during shutdown")
        budget.onDeferred={stopping.fulfill()}
        let closing=Task {try await budget.waitForBackgroundWork()}
        await fulfillment(of:[stopping],timeout:2);budget.onDeferred=nil;budget.stop()
        do {try await closing.value;XCTFail("Shutdown must cancel a pending waiter")} catch is CancellationError {} catch {XCTFail("\(error)")}
        do {try await budget.waitForBackgroundWork();XCTFail("Stopped budgets cannot authorize new jobs")} catch is CancellationError {} catch {XCTFail("\(error)")}
    }

    @MainActor func testCaptureRechecksAfterDatabaseAwaitAndRestoresCancelledDurableWork()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root)
        var frame=MemoryFrame(timestamp:Date(),appName:"Synthetic",bundleID:"test",title:"Budget",imagePath:"frames/budget.png",text:"",regions:[])
        frame.indexingComplete=false;frame.visualTime=0
        try store.save(frame)
        let savedFrame=frame,reader=ReadOnce(),reads=BudgetWaits(1),jobs=BudgetWaits(1),idle=BudgetWaits(2)
        let budget=ForegroundWorkBudget(observeSystem:false,wait:{_ in await idle.wait()})
        let engine=CaptureEngine(store:store,workBudget:budget,indexFrame:{_,_ in
            await jobs.wait();return ScreenIndexResult(text:"indexed",regions:[],archive:ScreenArchive(data:Data(),fileExtension:"png"))
        },readFrame:{_ in
            if await !reader.take() {await reads.wait()}
            return savedFrame
        })
        engine.resumePendingIndexing();await fulfillment(of:[reads.started[0]],timeout:2)
        budget.setVisible(true);await fulfillment(of:[idle.started[0]],timeout:2)
        let deferred=expectation(description:"Input arriving during the database read still postpones OCR")
        budget.onDeferred={deferred.fulfill()}
        await reads.release(0);await fulfillment(of:[deferred],timeout:2)
        await engine.suspendIndexing()
        XCTAssertEqual(try store.frame(frame.id)?.indexingComplete,false)
        budget.setVisible(false);await idle.release(0)
        budget.onDeferred=nil
        await engine.resumeIndexingAfterCleanup();await fulfillment(of:[jobs.started[0]],timeout:2)
        // Interaction does not cancel an already admitted recognition/commit.
        budget.setVisible(true);await fulfillment(of:[idle.started[1]],timeout:2)
        let indexed=expectation(description:"In-flight result commits safely")
        engine.onIndexed={_ in indexed.fulfill()}
        await jobs.release(0);await fulfillment(of:[indexed],timeout:2)
        XCTAssertEqual(try store.frame(frame.id)?.text,"indexed")
        XCTAssertEqual(try store.pendingIndexFrames().count,0)
        await engine.suspendIndexing();budget.stop();await idle.releaseAll()
    }

    @MainActor func testNativeSceneAndCancelledDetailReleaseActivityAndApplyInitialPressure()async throws {
        let waits=BudgetWaits(2),budget=ForegroundWorkBudget(observeSystem:false,wait:{_ in await waits.wait()})
        budget.setVisible(true);await fulfillment(of:[waits.started[0]],timeout:2)
        budget.setPressure(.warning)
        let scene=ArchiveGlassScene();scene.bind(to:budget)
        XCTAssertFalse(try XCTUnwrap(scene.cameraNode.camera).wantsDepthOfField,"A newly mounted scene applies existing memory pressure before any advance")
        let native=MemoryImageTransitionView(frame:NSRect(x:0,y:0,width:800,height:600))
        let window=NSWindow(contentRect:native.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=native;native.workBudget=budget
        let image=NSImage(size:NSSize(width:320,height:200))
        native.update(id:"test",url:URL(fileURLWithPath:"/missing.png"),regions:[],destination:CGRect(x:50,y:50,width:640,height:400),source:MemoryImageTransitionSource(id:"test",image:image,rectInWindow:CGRect(x:0,y:0,width:320,height:200)),radius:14,reduced:false)
        await waits.release(0)
        XCTAssertTrue(budget.state.interacting)
        native.onMotionChanged=nil;native.stop()
        try await budget.waitForBackgroundWork()
        XCTAssertFalse(scene.cameraNode.camera?.wantsDepthOfField == true)
        let restored=expectation(description:"Pressure recovery restores scene quality")
        let subscription=budget.changes.sink {if $0.pressure == .normal {restored.fulfill()}}
        budget.setPressure(.normal);await fulfillment(of:[waits.started[1]],timeout:2)
        await waits.release(1);await fulfillment(of:[restored],timeout:2);subscription.cancel()
        XCTAssertTrue(scene.cameraNode.camera?.wantsDepthOfField == true)
        XCTAssertFalse(scene.isAnimating,"A quality-only restore must not acquire another motion lease")
        scene.scroll(by:0,horizontal:1,precise:true)
        XCTAssertTrue(scene.isAnimating)
        XCTAssertTrue(scene.cameraNode.camera?.wantsDepthOfField == true,"Ordinary interaction keeps depth of field stable")
        budget.stop();scene.setActive(true)
        XCTAssertFalse(scene.isActive);XCTAssertFalse(scene.isAnimating,"A stopped budget cannot restart the display clock")
        window.close()
    }

    @MainActor func testVisibleImagesAndExplicitDetailContinueWhilePrefetchAndHoverResumeWithoutNewInput()async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let pixels=try XCTUnwrap(CGContext(data:nil,width:320,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let frames=(0..<8).map {MemoryFrame(timestamp:Date(),appName:"Synthetic",bundleID:"test",title:"",imagePath:"\($0).png",text:"",regions:[])}
        for frame in frames {try ScreenArchive.saveSource(pixels,to:root.appendingPathComponent(frame.imagePath))}
        let waits=BudgetWaits(2),budget=ForegroundWorkBudget(observeSystem:false,wait:{_ in await waits.wait()})
        budget.setVisible(true);await fulfillment(of:[waits.started[0]],timeout:2)
        let loader=ArchiveImageLoader(decode:{_ in CGContext(data:nil,width:80,height:50,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()},hoverDelay:{})
        loader.bind(to:budget)
        loader.request(frames,viewport:.init(visible:Set(frames.prefix(4).map(\.id)),nearby:Set(frames.suffix(4).map(\.id))),root:root)
        await loader.waitUntilIdle()
        XCTAssertEqual(loader.decodeConcurrency,4);XCTAssertEqual(loader.decodeCount,4)
        XCTAssertEqual(loader.images.count,4,"Visible pixels still publish during continuous interaction")
        loader.hover(frames[0].id);await loader.waitForHover()
        XCTAssertEqual(loader.images[frames[0].imagePath]?.size.width,80)
        await loader.showDetail(pixels,for:frames[1].imagePath)
        XCTAssertEqual(loader.images[frames[1].imagePath]?.size.width,320,"Explicit detail never waits for the idle gate")
        let recovered=expectation(description:"Interaction idle")
        let subscription=budget.changes.sink {if !$0.interacting {recovered.fulfill()}}
        await waits.release(0);await fulfillment(of:[recovered],timeout:2)
        await loader.waitForHover();await loader.waitUntilIdle()
        XCTAssertEqual(loader.images[frames[0].imagePath]?.size.width,320,"The stationary hovered card resumes without another pointer event")
        XCTAssertEqual(loader.decodeCount,8);XCTAssertEqual(loader.decodeConcurrency,4)
        XCTAssertLessThanOrEqual(loader.cachedBytes,ArchiveImageLoader.memoryBudget)
        subscription.cancel()
        budget.setPressure(.warning);XCTAssertEqual(loader.decodeConcurrency,2)
        let normal=expectation(description:"Pressure recovery restores visible throughput")
        let pressureSubscription=budget.changes.sink {if $0.pressure == .normal {normal.fulfill()}}
        budget.setPressure(.normal);await fulfillment(of:[waits.started[1]],timeout:2)
        await waits.release(1);await fulfillment(of:[normal],timeout:2)
        XCTAssertEqual(loader.decodeConcurrency,4)
        pressureSubscription.cancel();budget.stop()
        XCTAssertTrue(loader.budgetLimited,"Stopping never restarts speculative work")
        let decodes=loader.decodeCount
        let unseen=MemoryFrame(timestamp:Date(),appName:"Synthetic",bundleID:"test",title:"",imagePath:"unseen.png",text:"",regions:[])
        loader.request(frames+[unseen],viewport:.init(visible:[unseen.id]),root:root)
        loader.updateViewport(.init(visible:[unseen.id]))
        await loader.waitUntilIdle();XCTAssertEqual(loader.decodeCount,decodes)
        loader.stop()
    }
}

private actor ReadOnce {
    private var read=false
    func take()->Bool {defer {read=true};return read}
}
