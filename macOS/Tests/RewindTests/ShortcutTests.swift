import XCTest
import AppKit
@testable import Rewind

final class ShortcutTests: XCTestCase {
    @MainActor func testHoldingShortcutDoesNotRepeatedlyToggleOverlay() {
        let shortcut = GlobalShortcut()
        var toggles = 0
        shortcut.action = { toggles += 1 }
        for _ in 0..<20 { shortcut.receive(id:1,pressed:true) }
        XCTAssertEqual(toggles,1)
        shortcut.receive(id:1,pressed:false)
        shortcut.receive(id:1,pressed:true)
        XCTAssertEqual(toggles,2)
        shortcut.receive(id:2,pressed:true)
        shortcut.receive(id:2,pressed:true)
        XCTAssertEqual(toggles,3)
        shortcut.receive(id:9,pressed:true)
        XCTAssertEqual(toggles,3,"Unrelated registered hotkeys cannot toggle Recall")
        shortcut.unregister()
        shortcut.receive(id:1,pressed:true)
        XCTAssertEqual(toggles,4,"Retry clears any held state")
    }
    @MainActor func testTimelinePanelAcceptsInputWithoutActivatingAnotherSpace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model = try AppModel(root:root)
        let parent = NSWindow(contentRect:.zero,styleMask:.borderless,backing:.buffered,defer:false)
        let controller = TimelinePanelController(parent:parent,model:model)
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel),"Clicking the timeline must not switch away from a full-screen app")
        XCTAssertTrue(controller.panel.canBecomeKey)
        XCTAssertFalse(controller.panel.canBecomeMain)
        XCTAssertFalse(controller.panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(controller.panel.hidesOnDeactivate)
    }
    @MainActor func testOverlayShortcutTracksPanelAndChildFocus() async throws {
        let panel = RewindOverlayWindow(contentRect:NSRect(x:-1200,y:0,width:800,height:600),styleMask:.borderless,backing:.buffered,defer:false)
        panel.isReleasedWhenClosed = false
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.ownsKeyboardFocus)
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertTrue(panel.ownsKeyboardFocus,"A nonactivating panel must still let the shortcut dismiss it")
        let child = TimelineStripWindow(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        child.isReleasedWhenClosed = false;panel.addChildWindow(child,ordered:.above)
        child.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.ownsKeyboardFocus,"Input in the timeline belongs to the same overlay")
        panel.removeChildWindow(child);child.orderOut(nil)
        panel.orderOut(nil)
        XCTAssertFalse(panel.ownsKeyboardFocus)
        try await Task.sleep(for:.milliseconds(250))
    }
}
