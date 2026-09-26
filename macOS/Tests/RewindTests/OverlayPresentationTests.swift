import XCTest
import AppKit
@testable import Rewind

final class OverlayPresentationTests:XCTestCase {
    @MainActor func testActivationRefreshKeepsTheOriginalRestoreOptions() {
        let original:NSApplication.PresentationOptions = [.autoHideDock,.autoHideMenuBar]
        var options = original
        let scope = OverlayDockPresentation(read:{ options },write:{ options = $0 })
        scope.begin()
        options = [] // AppKit refreshes presentation while activating the panel.
        scope.begin()
        XCTAssertTrue(options.contains(.hideDock))
        XCTAssertFalse(options.contains(.autoHideDock))
        scope.end()
        XCTAssertEqual(options,original,"Reapplying must not replace the pre-overlay snapshot")
    }

    /// Opt-in WindowServer regression check. Put a separate app in full screen
    /// first and supply its bundle ID; no screenshots or window titles are read.
    @MainActor func testNativeDockSuppressionPreservesTheCurrentSpace() async throws {
        guard let identifier = ProcessInfo.processInfo.environment["RECALL_OVERLAY_QA_APP"] else {
            throw XCTSkip("Set RECALL_OVERLAY_QA_APP with that app visible on the current Space")
        }
        let source = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first)
        func sourceWindows()->Set<Int> {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
            return Set(windows.compactMap { window in
                guard (window[kCGWindowOwnerPID as String] as? Int) == Int(source.processIdentifier),
                      (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
                return window[kCGWindowNumber as String] as? Int
            })
        }
        let app = NSApplication.shared, originalPolicy = NSApp.activationPolicy()
        defer { app.setActivationPolicy(originalPolicy) }
        let originals = sourceWindows()
        XCTAssertFalse(originals.isEmpty,"The external app must actually be on the visible Space")
        for policy:NSApplication.ActivationPolicy in [.accessory,.regular] {
            let originalOptions = app.presentationOptions
            app.setActivationPolicy(policy)
            let panel = RewindOverlayWindow(contentRect:try XCTUnwrap(NSScreen.main).frame,styleMask:.borderless,backing:.buffered,defer:false)
            panel.isReleasedWhenClosed = false;panel.level = .statusBar
            panel.isOpaque = false;panel.backgroundColor = .clear
            panel.collectionBehavior = RecallWindowBehavior.collection
            defer { panel.orderOut(nil) }
            for _ in 0..<2 {
                app.unhideWithoutActivation()
                panel.makeKeyAndOrderFront(nil)
                // Wait past the native Space transition, not merely the first
                // frame when the old desktop may still be visible.
                try await Task.sleep(for:.seconds(1.2))
                XCTAssertTrue(app.isActive)
                XCTAssertTrue(app.currentSystemPresentationOptions.contains(.hideDock),"Check the effective system state, not just the requested app options")
                XCTAssertTrue(panel.ownsKeyboardFocus)
                XCTAssertTrue(originals.isSubset(of:sourceWindows()),"Activating Recall must not switch away from the underlying full-screen app")
                panel.dismiss(hideApplication:true)
                try await Task.sleep(for:.milliseconds(600))
                XCTAssertEqual(app.presentationOptions,originalOptions)
                XCTAssertTrue(originals.isSubset(of:sourceWindows()))
                XCTAssertFalse(app.currentSystemPresentationOptions.contains(.hideDock),"The Dock must become available again after closing Recall")
            }
        }
    }
}
