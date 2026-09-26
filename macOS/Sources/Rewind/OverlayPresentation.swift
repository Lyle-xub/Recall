import AppKit

/// Async animation completions may arrive after a rapid reopen. Only the latest
/// transition is allowed to order a window out or restore the Dock.
struct OverlayTransitionState {
    private(set) var visible = false
    private(set) var generation = 0
    @discardableResult mutating func setVisible(_ value:Bool) -> Int? {
        guard visible != value else { return nil }
        visible = value; generation += 1; return generation
    }
    func isCurrent(_ token:Int,visible:Bool)->Bool { generation == token && self.visible == visible }
}

enum RecallWindowBehavior {
    // Join the current application's full-screen Space without creating or
    // activating a separate desktop Space. Shared by both overlay panels.
    static let collection: NSWindow.CollectionBehavior = [.canJoinAllSpaces,.canJoinAllApplications,.fullScreenAuxiliary,.stationary]
}

/// Scope native Dock suppression to the overlay; restore the exact previous
/// app presentation settings on dismissal. Never change persistent Dock defaults.
@MainActor final class OverlayDockPresentation {
    private let read: @MainActor () -> NSApplication.PresentationOptions
    private let write: @MainActor (NSApplication.PresentationOptions) -> Void
    private var previous: NSApplication.PresentationOptions?
    init(read: @escaping @MainActor () -> NSApplication.PresentationOptions = { NSApp.presentationOptions },
         write: @escaping @MainActor (NSApplication.PresentationOptions) -> Void = { NSApp.presentationOptions = $0 }) {
        self.read = read; self.write = write
    }
    func begin() {
        if previous == nil { previous = read() }
        // AppKit may update presentation options as a panel gains focus or the
        // app becomes active. Reapply without overwriting the restore snapshot.
        var options = read()
        options.remove(.autoHideDock); options.insert(.hideDock)
        write(options)
    }
    func end() {
        guard let original = previous else { return }
        previous = nil; write(original)
    }
}
