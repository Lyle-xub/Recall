import XCTest
import AppKit
@testable import Rewind

final class LocalOCRTests:XCTestCase {
    func testTSVPreservesChineseWordsNumbersAndNormalizedCoordinates() {
        let tsv = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n" +
        "5\t1\t1\t1\t1\t1\t10\t20\t30\t20\t95\t会议\n" +
        "5\t1\t1\t1\t1\t2\t40\t20\t30\t20\t96\t记录\n" +
        "5\t1\t1\t1\t2\t1\t10\t50\t40\t20\t97\t81742\n"
        let result = LocalOCR.parse(tsv,width:100,height:100)
        XCTAssertEqual(result.map(\.text),["会议记录","81742"])
        XCTAssertEqual(result[0].x,0.1);XCTAssertEqual(result[0].y,0.2)
        XCTAssertEqual(result[0].width,0.6);XCTAssertEqual(result[0].height,0.2)
        XCTAssertTrue(LocalOCR.parse("malformed",width:100,height:100).isEmpty)
    }
    @MainActor func testBundledEngineRecognizesChineseEnglishAndNumbers() async throws {
        guard LocalOCR.root != nil else { throw XCTSkip("Build bundled OCR with scripts/prepare-ocr-runtime.py") }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1200,pixelsHigh:500,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill();NSRect(x:0,y:0,width:1200,height:500).fill()
        for (i,text) in ["Recall paper 81742","会议记录 本地识别 预算 12345 元"].enumerated() {
            (text as NSString).draw(at:NSPoint(x:40,y:350-i*150),withAttributes:[.font:NSFont.systemFont(ofSize:36),.foregroundColor:NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState();let image = bitmap.cgImage!
        let result = try await Task.detached { try NativeOCR.perform(image,compatible:true) }.value
        XCTAssertTrue(result.0.contains("Recall"));XCTAssertTrue(result.0.contains("81742"))
        XCTAssertTrue(result.0.contains("会议记录"));XCTAssertTrue(result.0.contains("12345"))
        XCTAssertTrue(result.1.allSatisfy{$0.x >= 0 && $0.y >= 0 && $0.x+$0.width <= 1.001 && $0.y+$0.height <= 1.001})
    }
}
