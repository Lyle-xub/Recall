import XCTest
import AppKit
@testable import Rewind

final class RecordingLifecycleTests:XCTestCase {
    @MainActor func testWholeInterfacePausesAndManualPauseIsPreserved() async {
        var starts = 0,stops = 0
        let coordinator = RecordingCoordinator(resumeDelay:.zero,start:{ starts += 1 },stop:{ stops += 1 })
        coordinator.request(true);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,1)
        coordinator.setInterfaceVisible(true);await coordinator.waitUntilSettled()
        XCTAssertEqual(stops,1);XCTAssertTrue(coordinator.state.automaticallyPaused);XCTAssertFalse(coordinator.state.active)
        // Moving from timeline to search/settings does not close the interface.
        coordinator.setInterfaceVisible(true);await coordinator.waitUntilSettled();XCTAssertEqual(starts,1)
        coordinator.setInterfaceVisible(false);await coordinator.waitUntilSettled();XCTAssertEqual(starts,2)
        coordinator.setInterfaceVisible(true);await coordinator.waitUntilSettled()
        coordinator.request(false);coordinator.setInterfaceVisible(false);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,2);XCTAssertFalse(coordinator.state.requested)
        coordinator.setInterfaceVisible(true);coordinator.request(true);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,2,"Starting from the visible UI only arms recording")
        coordinator.setInterfaceVisible(false);await coordinator.waitUntilSettled();XCTAssertEqual(starts,3)
        await coordinator.shutdown();XCTAssertFalse(coordinator.state.active)
    }
    @MainActor func testOpeningDuringSlowStartStopsBeforeAnyRestartAndSerializesRotation() async {
        let operations=RecordingLifecycleGate(count:4)
        var busy = false,starts = 0,stops = 0
        let coordinator = RecordingCoordinator(resumeDelay:.zero,start:{
            XCTAssertFalse(busy);busy = true;starts += 1
            await operations.wait();busy = false
        },stop:{
            XCTAssertFalse(busy);busy = true;stops += 1
            await operations.wait();busy = false
        })
        coordinator.request(true)
        await fulfillment(of:[operations.started[0]],timeout:2)
        coordinator.setInterfaceVisible(true);await operations.release(0)
        await fulfillment(of:[operations.started[1]],timeout:2)
        XCTAssertEqual(starts,1);XCTAssertEqual(stops,1)
        await operations.release(1);await coordinator.waitUntilSettled()
        XCTAssertFalse(coordinator.state.active)
        coordinator.setInterfaceVisible(false)
        await fulfillment(of:[operations.started[2]],timeout:2)
        await operations.release(2);await coordinator.waitUntilSettled()
        coordinator.rotateSegment()
        await fulfillment(of:[operations.started[3]],timeout:2)
        coordinator.setInterfaceVisible(true);await operations.release(3)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,2);XCTAssertEqual(stops,2)
        for _ in 0..<50 {coordinator.setInterfaceVisible(false);coordinator.setInterfaceVisible(true)}
        await coordinator.waitUntilSettled();XCTAssertEqual(starts,2)
        await coordinator.shutdown();coordinator.setInterfaceVisible(false);coordinator.request(true)
        await coordinator.waitUntilSettled();XCTAssertEqual(starts,2)
    }
    @MainActor func testDebouncedResumeAndStartFailure() async {
        let delay=RecordingLifecycleGate(count:2)
        var starts = 0,failures = 0
        let coordinator = RecordingCoordinator(resumeDelay:.milliseconds(30),waitForResume:{_ in await delay.wait()},start:{
            starts += 1;throw NSError(domain:"Test",code:1)
        },stop:{})
        coordinator.failed = {_ in failures += 1}
        coordinator.setInterfaceVisible(true);coordinator.request(true)
        coordinator.setInterfaceVisible(false)
        await fulfillment(of:[delay.started[0]],timeout:2)
        coordinator.setInterfaceVisible(true);await delay.release(0)
        await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,0)
        coordinator.setInterfaceVisible(false)
        await fulfillment(of:[delay.started[1]],timeout:2)
        await delay.release(1);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,1);XCTAssertEqual(failures,1);XCTAssertFalse(coordinator.state.requested)
    }
    @MainActor func testLateResumeNeedsFreshDelayAndCannotSurviveManualPauseOrShutdown() async {
        let delay=RecordingLifecycleGate(count:3)
        var starts=0,stops=0
        let coordinator=RecordingCoordinator(waitForResume:{_ in await delay.wait()},start:{starts += 1},stop:{stops += 1})
        coordinator.request(true)
        await fulfillment(of:[delay.started[0]],timeout:2)
        // The desired state is true again, but the earlier resume token is old.
        coordinator.setInterfaceVisible(true);coordinator.setInterfaceVisible(false)
        await delay.release(0)
        await fulfillment(of:[delay.started[1]],timeout:2)
        XCTAssertEqual(starts,0,"An old resume callback cannot bypass the new debounce interval")
        guard starts == 0 else {await coordinator.shutdown();return}
        coordinator.request(false);await delay.release(1);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,0);XCTAssertFalse(coordinator.state.requested)
        coordinator.request(true)
        await fulfillment(of:[delay.started[2]],timeout:2)
        let terminated=expectation(description:"Shutdown invalidates the pending resume before it returns")
        var reported=false
        coordinator.changed={state in if state.terminated,!reported {reported=true;terminated.fulfill()}}
        let shutdown=Task {await coordinator.shutdown()}
        await fulfillment(of:[terminated],timeout:2)
        await delay.release(2);await shutdown.value
        XCTAssertTrue(coordinator.state.terminated);XCTAssertFalse(coordinator.state.active)
        XCTAssertEqual(starts,0);XCTAssertEqual(stops,0)
        coordinator.request(true);coordinator.setInterfaceVisible(false);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,0,"Shutdown remains final even after a delayed callback and another request")
    }
    @MainActor func testUsageWritesRemainOrderedWhenCaptureStops() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let database = try MemoryStore(root:root),recorder = AppUsageRecorder(store:database,backgroundWrites:true)
        let origin = Date()
        for index in 0..<30 {
            try recorder.transition(to:AppUsageIdentity(name:"App \(index)",bundleID:"test.\(index)"),at:origin.addingTimeInterval(Double(index)))
        }
        try recorder.stop(at:origin.addingTimeInterval(30))
        XCTAssertNil(recorder.current)
        await recorder.flush()
        let intervals = try database.usage(in:DateInterval(start:origin,end:origin.addingTimeInterval(30)))
        XCTAssertEqual(intervals.count,30)
        XCTAssertEqual(intervals.reduce(0) { $0+$1.end.timeIntervalSince($1.start) },30,accuracy:0.001)
    }
    @MainActor func testBackgroundGateResumesAndCancellationDoesNotRunPendingWork() async {
        let gate = BackgroundWorkGate();gate.setSuspended(true)
        var ran = 0
        let first = Task {try await gate.wait();ran += 1}
        let cancelled = Task {try await gate.wait();ran += 100}
        await Task.yield();cancelled.cancel();_ = try? await cancelled.value
        XCTAssertEqual(ran,0)
        gate.setSuspended(false);try? await first.value;XCTAssertEqual(ran,1)
    }
}

/// Intentionally returns cancelled/obsolete waits when released, so callers'
/// state and revision checks are exercised independently of wall-clock timing.
private actor RecordingLifecycleGate {
    let started:[XCTestExpectation]
    private var pending:[Int:CheckedContinuation<Void,Never>]=[:]
    private var next=0
    init(count:Int) {started=(0..<count).map {XCTestExpectation(description:"Recording operation \($0) is held")}}
    func wait()async {
        let index=next;next += 1
        guard started.indices.contains(index) else {XCTFail("Unexpected recording operation \(index)");return}
        await withCheckedContinuation {pending[index]=$0;started[index].fulfill()}
    }
    func release(_ index:Int) {pending.removeValue(forKey:index)?.resume()}
}
