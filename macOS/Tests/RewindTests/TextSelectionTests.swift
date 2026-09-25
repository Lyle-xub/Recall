import XCTest
import AppKit
@testable import Rewind

final class TextSelectionTests:XCTestCase {
    private func rows(_ texts:[String])->[TextRegion] {
        texts.enumerated().map { TextRegion(text:$0.element,x:0.1,y:Double($0.offset)*0.2,width:0.6,height:0.1) }
    }
    @MainActor func testScrubbingDoesNotBuildTextViewsAndKeepsSelectionOnRefresh() {
        let overlay = IndexedTextOverlay(frame:NSRect(x:0,y:0,width:1000,height:800))
        let parent = NSView(frame:overlay.frame);parent.addSubview(overlay)
        overlay.imageSize = CGSize(width:1000,height:800)
        let origin = CFAbsoluteTimeGetCurrent()
        var regions:[TextRegion] = []
        for frame in 0..<100 {
            regions = (0..<300).map {TextRegion(text:"Screen \(frame) line \($0)",x:0.1,y:Double($0)/400,width:0.3,height:0.002)}
            overlay.setRegions(regions);overlay.layoutSubtreeIfNeeded()
            XCTAssertEqual(overlay.subviews.count,0)
        }
        let elapsed = (CFAbsoluteTimeGetCurrent()-origin)*1000
        XCTAssertTrue(overlay.hitTest(NSPoint(x:120,y:799.5)) === overlay)
        overlay.selectAll(nil);let text = overlay.selectedText
        overlay.setRegions(regions);overlay.needsLayout = true;overlay.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.selectedText,text);XCTAssertEqual(overlay.subviews.count,0)
        print(String(format:"TEXT_OVERLAY_BENCHMARK: 100 frames × 300 regions %.2f ms; 0 native text controls",elapsed))
    }
    func testForwardAndReverseSelectionAcrossChineseEnglishAndEmoji() {
        let regions = rows(["First paper","跨行选择😀内容","Last line"])
        let start = ScreenTextPosition(line:0,offset:6),end = ScreenTextPosition(line:2,offset:4)
        let expected = "paper\n跨行选择😀内容\nLast"
        XCTAssertEqual(ScreenTextSelection(anchor:start,head:end).text(in:regions),expected)
        XCTAssertEqual(ScreenTextSelection(anchor:end,head:start).text(in:regions),expected)
        XCTAssertEqual(ScreenTextSelection(anchor:.init(line:1,offset:4),head:.init(line:1,offset:5)).text(in:regions),"😀","Do not split UTF-16 surrogate pairs")
        XCTAssertEqual(ScreenTextSelection(anchor:start,head:start).text(in:regions),"")
    }
    func testCrossLineSelectionDoesNotIncludeAnotherColumn() {
        let regions = [
            TextRegion(text:"First paragraph",x:0.1,y:0.1,width:0.3,height:0.04),
            TextRegion(text:"Unrelated sidebar",x:0.8,y:0.2,width:0.15,height:0.04),
            TextRegion(text:"Second paragraph",x:0.1,y:0.3,width:0.3,height:0.04)
        ]
        let first = ScreenTextPosition(line:0,offset:0),last = ScreenTextPosition(line:2,offset:16)
        XCTAssertEqual(ScreenTextSelection(anchor:first,head:last).text(in:regions),"First paragraph\nSecond paragraph")
        XCTAssertEqual(ScreenTextSelection(anchor:last,head:first).text(in:regions),"First paragraph\nSecond paragraph")
        XCTAssertTrue(ScreenTextSelection(anchor:first,head:last,allColumns:true).text(in:regions).contains("Unrelated sidebar"))
    }
    @MainActor func testSelectionDrawsOnlyTranslucentBlueAcrossLinesAndSupportsKeyboard() throws {
        let overlay = IndexedTextOverlay(frame:NSRect(x:0,y:0,width:300,height:200))
        overlay.imageSize = overlay.bounds.size;overlay.setRegions(rows(["Recall 图片 81742","Second paper","第三行内容"]))
        overlay.layoutSubtreeIfNeeded()
        overlay.select(from:.init(line:0,offset:7),to:.init(line:2,offset:2))
        XCTAssertEqual(overlay.selectedText,"图片 81742\nSecond paper\n第三")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:300,pixelsHigh:200,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = context
        NSColor.clear.setFill();overlay.bounds.fill(using:.copy);overlay.draw(overlay.bounds)
        NSGraphicsContext.restoreGraphicsState()
        var colored = 0,paintedRows = Set<Int>()
        for y in 0..<200 { for x in 0..<300 {
            guard let pixel = bitmap.colorAt(x:x,y:y),pixel.alphaComponent > 0 else { continue }
            colored += 1;paintedRows.insert(y/40)
            XCTAssertLessThan(pixel.alphaComponent,0.4,"Never paint opaque grey over screenshot text")
        }}
        XCTAssertGreaterThan(colored,0);XCTAssertGreaterThanOrEqual(paintedRows.count,3)
        overlay.moveRightAndModifySelection(nil);XCTAssertTrue(overlay.selectedText.hasSuffix("第三行"))
        overlay.selectAll(nil);XCTAssertEqual(overlay.selectedText,"Recall 图片 81742\nSecond paper\n第三行内容")
    }
}
