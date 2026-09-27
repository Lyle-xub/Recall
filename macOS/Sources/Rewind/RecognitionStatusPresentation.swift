import Foundation
import Combine

/// Coalesce brief hand-offs without animating glyphs or resizing the capsule on
/// each commit. Real errors are immediate; final completion settles within 180 ms.
@MainActor final class RecognitionStatusPresentation:ObservableObject {
    typealias TransitionWait = @Sendable (Duration) async throws -> Void
    @Published private(set) var snapshot:RecognitionStatusSnapshot?
    private var target:RecognitionStatusSnapshot?
    private var transition:Task<Void,Never>?
    private let delay:Duration
    private let waitForTransition:TransitionWait
    /// Capture the exact scheduled operation before a later selection cancels it.
    var pendingTransition:Task<Void,Never>? {transition}
    init(delay:Duration = .milliseconds(180),waitForTransition:@escaping TransitionWait = {try await Task.sleep(for:$0)}) {
        self.delay=delay;self.waitForTransition=waitForTransition
    }
    func receive(_ next:RecognitionStatusSnapshot) {
        guard next != target else { return }
        target = next;transition?.cancel()
        // Never carry a previous image/video's badge across a selection change.
        if snapshot == nil || snapshot?.contextID != next.contextID || next.hasIssue {
            if snapshot != next { snapshot = next }
            return
        }
        transition = Task { [weak self,delay,waitForTransition] in
            do { try await waitForTransition(delay) } catch { return }
            guard !Task.isCancelled,let self,self.target == next else { return }
            self.snapshot = next;self.transition = nil
        }
    }
    func cancel() { transition?.cancel();transition = nil;target = nil }
    deinit { transition?.cancel() }
}
