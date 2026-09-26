import XCTest
import SwiftUI
import AppKit
@testable import Rewind

final class ArchiveSearchTests:XCTestCase {
    @MainActor private func fields(in view:NSView)->[NSTextField] {
        if let field = view as? NSTextField,field.isEditable { return [field] }
        return view.subviews.flatMap { fields(in:$0) }
    }

    @MainActor func testSearchPreservesNativeEditorAndChineseCompositionAcrossPages() async throws {
        for night in [false,true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:root) }
            let model = try AppModel(root:root)
            model.onboardingOpen = false;model.launchFilmOpen = false
            model.settings.glassArchiveEnabled = true
            model.settings.appearance = night ? .deepNight:.warmDay
            let size = CGSize(width:1200,height:800)
            let host = NSHostingView(rootView:RootView(model:model).frame(width:size.width,height:size.height))
            let window = RewindOverlayWindow(contentRect:CGRect(x:-1600,y:0,width:size.width,height:size.height),styleMask:[.borderless],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false;window.contentView = host;window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for:.milliseconds(150))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(fields(in:host).count,1,"The archive starts with the same search field used by results")
            let field = try XCTUnwrap(fields(in:host).first)
            XCTAssertEqual(field.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]),night ? .darkAqua:.aqua)
            XCTAssertEqual(field.placeholderAttributedString?.string ?? field.placeholderString,"Search memories","Use the native placeholder, which understands marked text")
            let hint = try XCTUnwrap(field.placeholderAttributedString)
            let ink = try XCTUnwrap((hint.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor)?.usingColorSpace(.sRGB))
            XCTAssertEqual(ink.redComponent,night ? 0.78:0.40,accuracy:0.02,"The archive's own theme controls placeholder ink even on a light desktop")
            XCTAssertGreaterThanOrEqual(ink.alphaComponent,0.6)
            let original = field.convert(field.bounds,to:host)
            XCTAssertTrue(window.makeFirstResponder(field))
            try await Task.sleep(for:.milliseconds(80))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.setMarkedText("记忆",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            XCTAssertTrue(editor.hasMarkedText())
            model.showSearch()
            try await Task.sleep(for:.milliseconds(250))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(fields(in:host).count,1)
            XCTAssertTrue(fields(in:host).first === field,"Changing pages must not recreate the input or its glass container")
            XCTAssertTrue(field.currentEditor() === editor)
            XCTAssertTrue(editor.hasMarkedText(),"Opening results during composition must preserve the Chinese input session")
            XCTAssertEqual(editor.string,"记忆")
            let results = field.convert(field.bounds,to:host)
            XCTAssertEqual(results.minX,original.minX,accuracy:1)
            XCTAssertEqual(results.minY,original.minY,accuracy:1)
            XCTAssertEqual(results.width,original.width,accuracy:1)
            editor.insertText("记忆",replacementRange:NSRange(location:NSNotFound,length:0))
            editor.insertText(" Recall",replacementRange:NSRange(location:NSNotFound,length:0))
            try await Task.sleep(for:.milliseconds(250))
            XCTAssertEqual(model.query,"记忆 Recall")
            XCTAssertFalse(editor.hasMarkedText())
            XCTAssertTrue(fields(in:host).first === field)
            model.returnToDesktop()
            try await Task.sleep(for:.milliseconds(150))
            XCTAssertTrue(fields(in:host).first === field,"Returning to the archive must also reuse the search control")
            XCTAssertEqual(field.stringValue,"")
            model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
        }
    }
}
