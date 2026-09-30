import AppKit
import Combine

/// A process-local budget, independent from SwiftUI invalidation. Saved work
/// waits between jobs; pixels and explicit detail requests are never discarded.
@MainActor final class ForegroundWorkBudget {
    enum Pressure {case normal,warning,critical}
    struct State:Equatable {
        var interacting=false
        var stopped=false
        var pressure:Pressure = .normal
        var limited:Bool {stopped || interacting || pressure != .normal}
        var defersBackground:Bool {interacting || pressure == .critical}
    }
    typealias Wait = @Sendable (ContinuousClock.Instant) async throws->Void
    private(set) var state=State()
    let changes=PassthroughSubject<State,Never>()
    var onDeferred:(()->Void)?
    private let gate=BackgroundWorkGate()
    private let wait:Wait
    private var visible=false,stopped=false
    private var inputPending=false
    private var leases=Set<UUID>()
    private var idleTask:Task<Void,Never>?,pressureTask:Task<Void,Never>?
    private var idleRevision=0,pressureRevision=0
    private var idleDeadline=ContinuousClock.now
    private var monitor:Any?
    private var pressureSource:DispatchSourceMemoryPressure?

    init(observeSystem:Bool = true,wait:@escaping Wait = {try await Task.sleep(until:$0,clock:.continuous)}) {
        self.wait=wait
        guard observeSystem else {return}
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.leftMouseDown,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,.keyDown,.mouseMoved]) { [weak self] event in
            // This is a local monitor, and ignores non-window/global shortcuts.
            if event.window != nil {self?.interaction()}
            return event
        }
        let source=DispatchSource.makeMemoryPressureSource(eventMask:[.normal,.warning,.critical],queue:.main)
        source.setEventHandler { [weak self] in
            guard let flags=self?.pressureSource?.data else {return}
            self?.setPressure(flags.contains(.critical) ? .critical:flags.contains(.warning) ? .warning:.normal)
        }
        pressureSource=source;source.resume()
    }
    deinit {idleTask?.cancel();pressureTask?.cancel();pressureSource?.cancel();if let monitor {NSEvent.removeMonitor(monitor)}}
    func setVisible(_ value:Bool) {
        guard !stopped else {return}
        visible=value
        if value {interaction()}
        else {idleRevision += 1;idleTask?.cancel();idleTask=nil;inputPending=false;leases.removeAll();publish()}
    }
    func interaction() {
        guard visible,!stopped else {return}
        inputPending=true;idleRevision += 1
        idleDeadline=ContinuousClock.now.advanced(by:.milliseconds(700))
        if idleTask == nil {
            let wait=wait
            idleTask=Task { [weak self] in
                while !Task.isCancelled {
                    guard let observed=self.map({($0.idleRevision,$0.idleDeadline)}) else {return}
                    do {try await wait(observed.1)} catch {return}
                    guard !Task.isCancelled else {return}
                    if self?.finishIdleWait(observed.0) != false {return}
                }
            }
        }
        publish()
    }
    private func finishIdleWait(_ revision:Int)->Bool {
        guard !stopped,idleRevision == revision else {return stopped}
        idleTask=nil;inputPending=false;publish();return true
    }
    /// Native springs hold the budget through real settlement, including
    /// transitions longer than the input debounce. Cancellation releases too.
    func beginActivity()->UUID? {
        guard visible,!stopped else {return nil}
        let id=UUID();leases.insert(id);publish();return id
    }
    func endActivity(_ id:UUID?) {
        guard let id,leases.remove(id) != nil else {return}
        publish()
    }
    func setPressure(_ value:Pressure) {
        guard !stopped else {return}
        pressureRevision += 1;pressureTask?.cancel();pressureTask=nil
        if value != .normal {state.pressure=value;publish();return}
        guard state.pressure != .normal else {return}
        let revision=pressureRevision,wait=wait,deadline=ContinuousClock.now.advanced(by:.milliseconds(1500))
        pressureTask=Task { [weak self] in
            do {try await wait(deadline)} catch {return}
            guard let self,!Task.isCancelled,!stopped,pressureRevision == revision else {return}
            pressureTask=nil;state.pressure = .normal;publish()
        }
    }
    private var published=State()
    private func publish() {
        state.interacting=visible && (inputPending || !leases.isEmpty)
        gate.setSuspended(state.defersBackground)
        guard state != published else {return}
        published=state;changes.send(state)
    }
    func waitForBackgroundWork()async throws {
        guard !stopped else {throw CancellationError()}
        if state.defersBackground {onDeferred?()}
        try await gate.wait()
        guard !stopped else {throw CancellationError()}
    }
    func recoveryInterval(after work:TimeInterval,pending:Int = 0,latencySensitive:Bool = false)->TimeInterval {
        // Warning pressure still makes progress. Critical pressure waits at
        // the gate; it does not repeatedly reload models or restart a job.
        // Screen text has a capture deadline even before the queue reaches 32.
        // It reuses one bounded serial worker; a longer idle delay would create
        // backlog without lowering its peak memory. Maintenance keeps its
        // slower pacing, and heat/low-power recovery remain the lower bound.
        let catchingUp = latencySensitive || pending >= 32
        return max(BackgroundProcessingPolicy.recoveryInterval(after:work,pending:pending,latencySensitive:latencySensitive),state.pressure == .warning ? min(catchingUp ? 1:30,max(catchingUp ? 0.25:1,work*(catchingUp ? 0.1:2))):0)
    }
    func stop() {
        guard !stopped else {return};stopped=true
        idleTask?.cancel();pressureTask?.cancel();idleTask=nil;pressureTask=nil
        pressureSource?.cancel();pressureSource=nil
        if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
        leases.removeAll();visible=false;inputPending=false;state=State(stopped:true);publish()
        gate.setSuspended(false)
    }
}
