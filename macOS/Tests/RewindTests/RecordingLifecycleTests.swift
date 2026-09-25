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
        var busy = false,starts = 0,stops = 0
        let coordinator = RecordingCoordinator(resumeDelay:.zero,start:{
            XCTAssertFalse(busy);busy = true;starts += 1
            try await Task.sleep(for:.milliseconds(25));busy = false
        },stop:{
            XCTAssertFalse(busy);busy = true;stops += 1
            try? await Task.sleep(for:.milliseconds(25));busy = false
        })
        coordinator.request(true);try? await Task.sleep(for:.milliseconds(5))
        coordinator.setInterfaceVisible(true);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,1);XCTAssertEqual(stops,1);XCTAssertFalse(coordinator.state.active)
        coordinator.setInterfaceVisible(false);await coordinator.waitUntilSettled()
        coordinator.rotateSegment();try? await Task.sleep(for:.milliseconds(5))
        coordinator.setInterfaceVisible(true);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,2);XCTAssertEqual(stops,2)
        for _ in 0..<50 {coordinator.setInterfaceVisible(false);coordinator.setInterfaceVisible(true)}
        await coordinator.waitUntilSettled();XCTAssertEqual(starts,2)
        await coordinator.shutdown();coordinator.setInterfaceVisible(false);coordinator.request(true)
        await coordinator.waitUntilSettled();XCTAssertEqual(starts,2)
    }
    @MainActor func testDebouncedResumeAndStartFailure() async {
        var starts = 0,failures = 0
        let coordinator = RecordingCoordinator(resumeDelay:.milliseconds(30),start:{
            starts += 1;throw NSError(domain:"Test",code:1)
        },stop:{})
        coordinator.failed = {_ in failures += 1}
        coordinator.setInterfaceVisible(true);coordinator.request(true)
        coordinator.setInterfaceVisible(false);try? await Task.sleep(for:.milliseconds(5))
        coordinator.setInterfaceVisible(true);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,0)
        coordinator.setInterfaceVisible(false);await coordinator.waitUntilSettled()
        XCTAssertEqual(starts,1);XCTAssertEqual(failures,1);XCTAssertFalse(coordinator.state.requested)
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
