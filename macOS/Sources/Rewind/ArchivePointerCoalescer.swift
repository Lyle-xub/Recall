import Foundation
import CoreGraphics

/// The deadline is captured before the task joins the main actor's queue. A
/// busy actor may deliver late, but must not add another frame of relative sleep.
@MainActor struct ArchivePointerScheduler {
    typealias Callback = @MainActor () -> Void
    typealias Cancellation = () -> Void
    let now:() -> ContinuousClock.Instant
    let schedule:(ContinuousClock.Instant,@escaping Callback) -> Cancellation

    static var continuous:Self {
        let clock=ContinuousClock()
        return Self(now:{clock.now},schedule:{deadline,callback in
            let task=Task { @MainActor in
                do {try await clock.sleep(until:deadline,tolerance:.zero)} catch {return}
                guard !Task.isCancelled else {return}
                callback()
            }
            return {task.cancel()}
        })
    }
}

/// One immediate sample and at most one replaceable trailing sample per frame.
/// Cancellation also invalidates callbacks whose sleep has already completed.
@MainActor final class ArchivePointerCoalescer {
    static let interval:Duration = .seconds(1.0/60.0)
    private let scheduler:ArchivePointerScheduler
    private let deliver:(CGPoint) -> Void
    private var lastDelivery:ContinuousClock.Instant?
    private var pending:CGPoint?
    private var cancelDelivery:ArchivePointerScheduler.Cancellation?
    private var generation:UInt64 = 0
    var hasPending:Bool {pending != nil}

    init(scheduler:ArchivePointerScheduler,deliver:@escaping(CGPoint) -> Void) {
        self.scheduler=scheduler;self.deliver=deliver
    }
    func submit(_ point:CGPoint) {
        let now=scheduler.now()
        guard let lastDelivery,now < lastDelivery.advanced(by:Self.interval) else {emit(point);return}
        pending=point
        guard cancelDelivery == nil else {return}
        let expectedGeneration=generation
        cancelDelivery=scheduler.schedule(lastDelivery.advanced(by:Self.interval)) { [weak self] in
            guard let self,self.generation == expectedGeneration,let point=self.pending else {return}
            self.emit(point)
        }
    }
    func flush(at point:CGPoint) {
        if hasPending {emit(point)}
    }
    func cancel() {
        generation &+= 1
        cancelDelivery?();cancelDelivery=nil;pending=nil
    }
    private func emit(_ point:CGPoint) {
        cancel()
        lastDelivery=scheduler.now()
        deliver(point)
    }
}
