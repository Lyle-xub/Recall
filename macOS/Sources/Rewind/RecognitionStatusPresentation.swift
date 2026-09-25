import Foundation
import Combine

/// Coalesce brief hand-offs without animating glyphs or resizing the capsule on
/// each commit. Real errors are immediate; final completion settles within 180 ms.
@MainActor final class RecognitionStatusPresentation:ObservableObject {
    @Published private(set) var snapshot:RecognitionStatusSnapshot?
    private var target:RecognitionStatusSnapshot?
    private var transition:Task<Void,Never>?
    private let delay:Duration
    init(delay:Duration = .milliseconds(180)) { self.delay = delay }
    func receive(_ next:RecognitionStatusSnapshot) {
        guard next != target else { return }
        target = next;transition?.cancel()
        // Never carry a previous image/video's badge across a selection change.
        if snapshot == nil || snapshot?.contextID != next.contextID || next.hasIssue {
            if snapshot != next { snapshot = next }
            return
        }
        transition = Task { [weak self,delay] in
            do { try await Task.sleep(for:delay) } catch { return }
            guard !Task.isCancelled,let self,self.target == next else { return }
            self.snapshot = next;self.transition = nil
        }
    }
    func cancel() { transition?.cancel();transition = nil;target = nil }
    deinit { transition?.cancel() }
}
