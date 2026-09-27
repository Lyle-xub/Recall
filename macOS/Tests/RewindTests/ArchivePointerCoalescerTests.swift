import XCTest
import AppKit
@testable import Rewind

/// A cancelled sleep can already have queued its continuation on MainActor.
/// Tests may deliberately run that continuation to verify the generation fence.
@MainActor final class ManualArchivePointerScheduler {
    final class Job {
        let deadline:ContinuousClock.Instant
        let callback:ArchivePointerScheduler.Callback
        var cancelled=false
        init(deadline:ContinuousClock.Instant,callback:@escaping ArchivePointerScheduler.Callback) {
            self.deadline=deadline;self.callback=callback
        }
    }
    var now=ContinuousClock().now
    private(set) var jobs:[Job]=[]
    var scheduler:ArchivePointerScheduler {
        ArchivePointerScheduler(now:{self.now},schedule:{deadline,callback in
            let job=Job(deadline:deadline,callback:callback)
            self.jobs.append(job)
            return {job.cancelled=true}
        })
    }
    func advance(by duration:Duration) {now=now.advanced(by:duration)}
    func fire(_ index:Int,includingCancelled:Bool=false) {
        let job=jobs[index]
        precondition(now >= job.deadline,"A timer cannot wake before its deadline")
        if !job.cancelled || includingCancelled {job.callback()}
    }
}

final class ArchivePointerCoalescerTests:XCTestCase {
    @MainActor func testBurstDeliversLatestPointAtOneAbsoluteFrameDeadline() {
        let time=ManualArchivePointerScheduler(),start:CGPoint=CGPoint(x:0,y:0)
        var received:[CGPoint]=[]
        let input=ArchivePointerCoalescer(scheduler:time.scheduler) {received.append($0)}
        let firstDeadline=time.now.advanced(by:ArchivePointerCoalescer.interval)
        input.submit(start)
        time.advance(by:.milliseconds(2))
        for index in 1...100 {input.submit(CGPoint(x:index,y:-index))}
        XCTAssertEqual(received,[start])
        XCTAssertEqual(time.jobs.count,1,"A burst shares one timer even across distant cards")
        XCTAssertEqual(time.jobs[0].deadline,firstDeadline,"Queueing delay must not move the frame deadline")
        time.now=firstDeadline
        time.fire(0)
        XCTAssertEqual(received,[start,CGPoint(x:100,y:-100)])
        XCTAssertFalse(input.hasPending)
    }

    @MainActor func testLateWakeDoesNotCatchUpWithExtraSamplesOrDelayNewestSampleAgain() {
        let time=ManualArchivePointerScheduler()
        var received:[CGPoint]=[]
        let input=ArchivePointerCoalescer(scheduler:time.scheduler) {received.append($0)}
        input.submit(CGPoint(x:1,y:0));input.submit(CGPoint(x:2,y:0))
        let deadline=time.jobs[0].deadline
        time.advance(by:.seconds(1))
        XCTAssertEqual(time.jobs[0].deadline,deadline)
        time.fire(0)
        XCTAssertEqual(received.map(\.x),[1,2],"A late wake emits the latest sample once")
        input.submit(CGPoint(x:3,y:0))
        XCTAssertEqual(received.count,2,"Cadence restarts at actual delivery, without catch-up bursts")
        XCTAssertEqual(time.jobs[1].deadline,time.now.advanced(by:ArchivePointerCoalescer.interval))
        time.advance(by:ArchivePointerCoalescer.interval);time.fire(1)
        XCTAssertEqual(received.map(\.x),[1,2,3])
    }

    @MainActor func testAwakenedOldCallbackCannotConsumeOrCancelNewGeneration() {
        let time=ManualArchivePointerScheduler()
        var received:[CGPoint]=[]
        let input=ArchivePointerCoalescer(scheduler:time.scheduler) {received.append($0)}
        input.submit(CGPoint(x:1,y:0));input.submit(CGPoint(x:2,y:0))
        // The old sleep has reached its deadline, but its continuation has not
        // reacquired MainActor. A fresh event and trailing event arrive first.
        time.advance(by:ArchivePointerCoalescer.interval)
        input.submit(CGPoint(x:3,y:0));input.submit(CGPoint(x:4,y:0))
        XCTAssertEqual(received.map(\.x),[1,3])
        XCTAssertTrue(time.jobs[0].cancelled)
        time.fire(0,includingCancelled:true)
        XCTAssertEqual(received.map(\.x),[1,3],"An old continuation must not steal a later generation's sample")
        XCTAssertFalse(time.jobs[1].cancelled,"The newer timer must remain scheduled")
        time.advance(by:ArchivePointerCoalescer.interval);time.fire(1)
        XCTAssertEqual(received.map(\.x),[1,3,4])
    }

    @MainActor func testCancelThenResumeRejectsAlreadyAwakenedContinuation() {
        let time=ManualArchivePointerScheduler()
        var received:[CGPoint]=[]
        let input=ArchivePointerCoalescer(scheduler:time.scheduler) {received.append($0)}
        input.submit(CGPoint(x:1,y:0));input.submit(CGPoint(x:2,y:0))
        input.cancel();input.submit(CGPoint(x:3,y:0))
        time.advance(by:ArchivePointerCoalescer.interval)
        time.fire(0,includingCancelled:true)
        XCTAssertEqual(received.map(\.x),[1])
        time.fire(1)
        XCTAssertEqual(received.map(\.x),[1,3])
    }

    @MainActor func testClickFlushesActualClickPositionAndInvalidatesOldCallback() {
        let time=ManualArchivePointerScheduler()
        var received:[CGPoint]=[]
        let input=ArchivePointerCoalescer(scheduler:time.scheduler) {received.append($0)}
        input.submit(CGPoint(x:1,y:0));input.submit(CGPoint(x:2,y:0))
        input.flush(at:CGPoint(x:3,y:0))
        input.flush(at:CGPoint(x:4,y:0))
        XCTAssertEqual(received.map(\.x),[1,3],"Only a pending sample is flushed, using the click's coordinates")
        time.advance(by:ArchivePointerCoalescer.interval)
        time.fire(0,includingCancelled:true)
        XCTAssertEqual(received.map(\.x),[1,3])
    }
}
