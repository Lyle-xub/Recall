import XCTest
import SwiftUI
@testable import Rewind

final class TimelineDatePickerTests:XCTestCase {
    @MainActor func testDateAndTimeControlsFitCompactPopoverInBothLocalesAndAppearances()async throws {
        for locale in ["en_US","zh_CN"] {for dark in [false,true] {
            let date=Date(timeIntervalSince1970:1_790_100_042)
            let content=TimelineDateJumpPicker(date:.constant(date),jump:{})
                .background(Color(nsColor:.windowBackgroundColor))
                .environment(\.locale,Locale(identifier:locale)).preferredColorScheme(dark ? .dark:.light)
            let host=NSHostingView(rootView:content)
            let size=host.fittingSize
            XCTAssertEqual(size.width,360,accuracy:1)
            XCTAssertLessThan(size.height,520)
            host.frame=NSRect(origin:.zero,size:size)
            let window=NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=host
            defer {window.orderOut(nil)}
            let updated=expectation(forNotification:NSWindow.didUpdateNotification,object:window)
            window.orderFront(nil)
            await fulfillment(of:[updated],timeout:2)
            host.layoutSubtreeIfNeeded()
            func pickers(_ view:NSView)->[NSDatePicker] {
                (view as? NSDatePicker).map {[$0]} ?? view.subviews.flatMap(pickers)
            }
            let controls=pickers(host)
            XCTAssertEqual(controls.count,2,"Use distinct date and time controls, with no squeezed calendar label")
            for control in controls {
                let rect=host.convert(control.bounds,from:control)
                XCTAssertGreaterThanOrEqual(rect.minX,-1)
                XCTAssertLessThanOrEqual(rect.maxX,host.bounds.maxX+1)
                XCTAssertGreaterThanOrEqual(rect.minY,-1)
                XCTAssertLessThanOrEqual(rect.maxY,host.bounds.maxY+1)
            }
            if let folder=ProcessInfo.processInfo.environment["RECALL_DATE_PICKER_SNAPSHOT_PATH"] {
                let directory=URL(fileURLWithPath:folder)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
                host.cacheDisplay(in:host.bounds,to:bitmap)
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("picker-\(locale)-\(dark ? "dark":"light").png"))
            }
        }}
    }
}
