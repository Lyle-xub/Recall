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
    @MainActor func testTimelinePanelCanActivateWhenClicked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model = try AppModel(root:root)
        let parent = NSWindow(contentRect:.zero,styleMask:.borderless,backing:.buffered,defer:false)
        let controller = TimelinePanelController(parent:parent,model:model)
        XCTAssertFalse(controller.panel.styleMask.contains(.nonactivatingPanel),"Clicking a timeline control must retain application activation")
        XCTAssertTrue(controller.panel.canBecomeKey)
        XCTAssertFalse(controller.panel.hidesOnDeactivate)
    }
}
