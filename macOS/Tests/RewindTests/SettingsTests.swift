import XCTest
import AppKit
import Carbon
@testable import Rewind

final class SettingsTests: XCTestCase {
    func testOldSettingsPreservePreferencesAndAddDefaults() throws {
        let data = Data(#"{"captureInterval":10,"retentionDays":90,"systemAudio":true,"excludedApps":["private.app"],"launchAtLogin":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self,from:data)
        XCTAssertEqual(settings.captureInterval,10); XCTAssertEqual(settings.retentionDays,90)
        XCTAssertTrue(settings.systemAudio); XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.excludedApps,["private.app"]); XCTAssertFalse(settings.showDockIcon)
        XCTAssertEqual(settings.shortcuts,ShortcutConfiguration())
    }
    func testDockAndEveryShortcutRoundTripIncludingDisabledAlternate() throws {
        var settings = AppSettings(); settings.showDockIcon = true
        for action in RecallShortcutAction.allCases where action != .alternate {
            settings.shortcuts[action] = ShortcutBinding(keyCode:UInt32(20 + RecallShortcutAction.allCases.firstIndex(of:action)!),modifiers:UInt32(cmdKey|controlKey),keyLabel:action.rawValue)
        }
        settings.shortcuts.alternate = nil
        try settings.shortcuts.validate()
        let restored = try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings))
        XCTAssertTrue(restored.showDockIcon); XCTAssertEqual(restored.shortcuts,settings.shortcuts)
        XCTAssertNil(restored.shortcuts.alternate)
    }
    func testShortcutValidationRejectsDuplicatesPlainTypingAndReservedCommands() throws {
        var keys = ShortcutConfiguration(); try keys.validate()
        keys.search = keys.open
        XCTAssertThrowsError(try keys.validate())
        keys = ShortcutConfiguration(); keys.open = ShortcutBinding(keyCode:3,modifiers:0,keyLabel:"F")
        XCTAssertThrowsError(try keys.validate())
        keys.open = ShortcutBinding(keyCode:12,modifiers:UInt32(cmdKey),keyLabel:"Q")
        XCTAssertThrowsError(try keys.validate())
        keys = ShortcutConfiguration(); keys.previous = ShortcutBinding(keyCode:123,modifiers:UInt32(optionKey|cmdKey),keyLabel:"←")
        XCTAssertNoThrow(try keys.validate())
    }
    @MainActor func testFailedRegistrationKeepsPreviousShortcutAlive() throws {
        _ = NSApplication.shared
        let flags = UInt32(cmdKey|optionKey|controlKey|shiftKey)
        var current = ShortcutConfiguration()
        current.open = ShortcutBinding(keyCode:38,modifiers:flags,keyLabel:"J"); current.alternate = nil
        let shortcut = GlobalShortcut(); defer { shortcut.unregister() }
        _ = try shortcut.configure(current)
        var blocker:EventHotKeyRef?
        let status = RegisterEventHotKey(40,flags,EventHotKeyID(signature:0x54455354,id:20),GetEventDispatcherTarget(),0,&blocker)
        XCTAssertEqual(status,noErr)
        defer { if let blocker { UnregisterEventHotKey(blocker) } }
        var candidate = current; candidate.open = ShortcutBinding(keyCode:40,modifiers:flags,keyLabel:"K")
        XCTAssertThrowsError(try shortcut.configure(candidate))
        XCTAssertEqual(shortcut.configuration,current)
        var calls = 0; shortcut.action = { calls += 1 }
        shortcut.receive(id:1,pressed:true)
        XCTAssertEqual(calls,1)
        let existing = try shortcut.configure(current)
        XCTAssertTrue(existing.available)
    }
    func testStorageBucketsAccountForAllFilesWithoutFollowingSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at:root); try? fm.removeItem(at:external) }
        let samples:[(String,StorageCategory.Kind)] = [("frames/a.jpg",.screenshots),("recordings/a.mp4",.video),("recordings/a.m4a",.audio),("models/a.gguf",.models),("memory.sqlite-wal",.index),("settings.json",.other)]
        var expected:[StorageCategory.Kind:Int64] = [:]
        for (name,kind) in samples {
            let file = root.appendingPathComponent(name)
            try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(repeating:1,count:9000).write(to:file)
            let values = try file.resourceValues(forKeys:[.totalFileAllocatedSizeKey,.fileAllocatedSizeKey,.fileSizeKey])
            expected[kind] = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        try fm.createSymbolicLink(at:root.appendingPathComponent("duplicate"),withDestinationURL:root.appendingPathComponent("models"))
        let measured = try StorageUsageReader.scan(root:root,modelRoot:root.appendingPathComponent("models"))
        for category in measured.categories { XCTAssertEqual(category.bytes,expected[category.kind]) }
        XCTAssertEqual(measured.totalBytes,expected.values.reduce(0,+)); XCTAssertEqual(measured.unreadableFiles,0)
        try fm.createDirectory(at:external,withIntermediateDirectories:true)
        try Data(repeating:2,count:12345).write(to:external.appendingPathComponent("external.gguf"))
        let withExternal = try StorageUsageReader.scan(root:root,modelRoot:external)
        XCTAssertGreaterThan(withExternal.totalBytes,measured.totalBytes)
        let empty = try StorageUsageReader.scan(root:root.appendingPathComponent("missing"),modelRoot:root.appendingPathComponent("missing"))
        XCTAssertEqual(empty.totalBytes,0)
    }
}
