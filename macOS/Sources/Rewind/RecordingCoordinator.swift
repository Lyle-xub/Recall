import Foundation

/// User intent is independent from the stream. All starts, stops and segment
/// rotations pass through one serial reconciliation loop, including shutdown.
@MainActor final class RecordingCoordinator {
    struct State:Equatable {
        var requested = false
        var interfaceVisible = false
        var active = false
        var transitioning = false
        var terminated = false
        var shouldCapture:Bool { requested && !interfaceVisible && !terminated }
        var automaticallyPaused:Bool { requested && interfaceVisible && !terminated }
    }
    private(set) var state = State()
    var changed:((State)->Void)?
    var failed:((Error)->Void)?
    private let start:() async throws -> Void
    private let stop:() async -> Void
    private let resumeDelay:Duration
    private var task:Task<Void,Never>?
    private var rotate = false
    private var revision = 0
    init(resumeDelay:Duration = .milliseconds(300),start:@escaping() async throws -> Void,stop:@escaping() async -> Void) {
        self.resumeDelay = resumeDelay;self.start = start;self.stop = stop
    }
    func request(_ enabled:Bool) {
        guard !state.terminated else { return }
        state.requested = enabled;reconcile()
    }
    func setInterfaceVisible(_ visible:Bool) {
        guard state.interfaceVisible != visible else { return }
        state.interfaceVisible = visible;reconcile()
    }
    func rotateSegment() { guard state.active else { return };rotate = true;reconcile() }
    func interrupted() { state.active = false;state.requested = false;rotate = false;reconcile() }
    func shutdown() async {
        state.terminated = true;state.requested = false;reconcile();await waitUntilSettled()
    }
    func waitUntilSettled() async { await task?.value }
    private func reconcile() {
        revision += 1;changed?(state)
        guard task == nil else { return }
        task = Task { [self] in
            defer { state.transitioning = false;task = nil;changed?(state) }
            while true {
                if state.active && (!state.shouldCapture || rotate) {
                    rotate = false;state.transitioning = true;changed?(state)
                    await stop();state.active = false;state.transitioning = false;changed?(state)
                } else if !state.active && state.shouldCapture {
                    let token = revision
                    // Let the overlay finish disappearing and coalesce rapid
                    // toggles without making tiny recordings between them.
                    try? await Task.sleep(for:resumeDelay)
                    guard state.shouldCapture,token == revision else { continue }
                    state.transitioning = true;changed?(state)
                    do { try await start();state.active = true }
                    catch {
                        if state.shouldCapture { state.requested = false;failed?(error) }
                    }
                    state.transitioning = false;changed?(state)
                } else { break }
            }
        }
    }
}

/// Background work yields between items while Recall is being used. In-flight
/// commits finish safely; cancellation releases a waiter without losing work.
@MainActor final class BackgroundWorkGate {
    private(set) var suspended = false
    private var waiters:[UUID:CheckedContinuation<Void,Error>] = [:]
    func setSuspended(_ value:Bool) {
        suspended = value
        if !value { let pending = waiters;waiters.removeAll();pending.values.forEach { $0.resume() } }
    }
    func wait() async throws {
        try Task.checkCancellation()
        guard suspended else { return }
        let id = UUID()
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                if Task.isCancelled { continuation.resume(throwing:CancellationError()) }
                else { waiters[id] = continuation }
            }
        },onCancel:{ Task { @MainActor [weak self] in self?.waiters.removeValue(forKey:id)?.resume(throwing:CancellationError()) } })
        try Task.checkCancellation()
        // A rapid close/reopen may suspend again before this waiter resumes.
        if suspended { try await wait() }
    }
}
