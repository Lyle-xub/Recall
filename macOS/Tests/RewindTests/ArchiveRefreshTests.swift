import XCTest
@testable import Rewind

/// The debounce is held by explicit completion events, including after
/// cancellation. This reproduces replacing a task that already has a waiter.
@MainActor private final class ArchiveRefreshDelayGate {
    let started=(0..<2).map {XCTestExpectation(description:"Refresh delay \($0) started")}
    private var next=0
    private var continuations:[Int:CheckedContinuation<Void,Never>]=[:]
    func wait()async {
        let index=next;next += 1
        await withCheckedContinuation { continuation in
            continuations[index]=continuation
            if started.indices.contains(index) {started[index].fulfill()}
        }
    }
    func release(_ index:Int) {continuations.removeValue(forKey:index)?.resume()}
    func releaseAll() {for index in Array(continuations.keys) {release(index)}}
}

private final class ArchiveRefreshReadGate:@unchecked Sendable {
    let entered=XCTestExpectation(description:"Maintenance read started")
    private let lock=NSLock(),permit=DispatchSemaphore(value:0)
    private var armed=false
    func arm() {lock.lock();armed=true;lock.unlock()}
    func blockIfArmed()throws {
        lock.lock();let shouldBlock=armed;armed=false;lock.unlock()
        guard shouldBlock else {return}
        entered.fulfill()
        guard permit.wait(timeout:.now()+10) == .success else {throw RewindError.message("Test did not release archive read")}
    }
    func release() {permit.signal()}
}

final class ArchiveRefreshTests:XCTestCase {
    private func fixture()throws->(URL,MemoryStore,[MemoryFrame]) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("archive-refresh-"+UUID().uuidString)
        let store=try MemoryStore(root:root),day=Calendar.current.startOfDay(for:Date())
        let frames=(0..<160).map { index in
            MemoryFrame(id:"row-\(index)",timestamp:day.addingTimeInterval(72000-Double(index)*60),appName:"Fixture",bundleID:"test",title:"Row \(index)",imagePath:"frames/\(index).png",text:"",regions:[])
        }
        for frame in frames {try store.save(frame)}
        return (root,store,frames)
    }

    @MainActor func testWaitingForReplacedMaintenanceRefreshIncludesLatestApply()async throws {
        let (root,_,frames)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let gate=ArchiveRefreshDelayGate()
        let model=try AppModel(root:root,maintenanceOnly:true,archiveRefreshDelay:{await gate.wait()})
        defer {gate.releaseAll();model.prepareToQuit()}
        model.pinArchiveRecord(frames[5].id)
        model.requestArchiveWindow(at:130);await model.waitForPendingLoads()
        XCTAssertTrue(model.archiveFrames.contains {$0.id == frames[5].id})
        try model.store.moveToTrash(frames[5])
        model.refreshArchiveWindowAfterMaintenance()
        await fulfillment(of:[gate.started[0]],timeout:2)

        let waiting=XCTestExpectation(description:"Waiter entered pending loads")
        let premature=XCTestExpectation(description:"Cannot finish while the replacement refresh is held")
        premature.isInverted=true
        var replacementHeld=true
        let waiter=Task { @MainActor in
            waiting.fulfill()
            await model.waitForPendingLoads()
            if replacementHeld {premature.fulfill()}
            XCTAssertFalse(model.archiveFrames.contains {$0.id == frames[5].id},"Completion includes applying deletion to the pinned record")
        }
        await fulfillment(of:[waiting],timeout:2)
        // This is the same callback that can arrive from startup optimization
        // while the original caller is suspended on its debounce task.
        model.storageOptimizer.onFinished?()
        await fulfillment(of:[gate.started[1]],timeout:2)
        gate.release(0)
        // This timeout only detects a forbidden completion: no timer controls
        // the query or releases the held replacement task.
        await fulfillment(of:[premature],timeout:0.1)
        replacementHeld=false;gate.release(1)
        await waiter.value
        XCTAssertFalse(model.archiveWindowLoading)
        XCTAssertEqual(model.archiveWindow.columns[2].totalCount,159)
        XCTAssertEqual(model.archiveScrollRow,130)
    }

    @MainActor func testCoveredWheelDemandCannotCancelMaintenanceInvalidation()async throws {
        let (root,_,frames)=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let reader=try MemoryStore(root:root,readOnly:true),gate=ArchiveRefreshReadGate()
        let model=try AppModel(root:root,maintenanceOnly:true,archiveRefreshDelay:{},archiveWindowLoad:{ query in
            try gate.blockIfArmed();return try reader.archiveWindow(query)
        })
        defer {gate.release();model.prepareToQuit()}
        model.pinArchiveRecord(frames[5].id)
        model.requestArchiveWindow(at:130);await model.waitForPendingLoads()
        try model.store.moveToTrash(frames[5])
        gate.arm();model.refreshArchiveWindowAfterMaintenance()
        await fulfillment(of:[gate.entered],timeout:2)
        let requests=model.archiveWindowRequestCount
        for row in [131.0,132,134] {model.requestArchiveWindow(at:row)}
        XCTAssertEqual(model.archiveWindowRequestCount,requests)
        XCTAssertTrue(model.archiveWindowLoading,"Old metadata covers this row but cannot satisfy a maintenance invalidation")
        gate.release();await model.waitForPendingLoads()
        XCTAssertFalse(model.archiveFrames.contains {$0.id == frames[5].id})
        XCTAssertEqual(model.archiveWindow.columns[2].totalCount,159)
        XCTAssertEqual(model.archiveScrollRow,134,"Refresh applies at the latest wheel coordinate")
    }
}
