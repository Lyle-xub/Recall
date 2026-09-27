import XCTest
import AppKit
@testable import Rewind

final class MemoryTransitionPerformanceTests:XCTestCase {
    /// This opens only its own synthetic window. Cadence measures main-thread
    /// display-link callbacks, not physical screen presentation or screen FPS.
    @MainActor func testNativeDenseImageTransitionBenchmark()async throws {
        guard ProcessInfo.processInfo.environment["RECALL_MEMORY_TRANSITION_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in native 3K image / 300-region transition benchmark")
        }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("memory-transition-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let image=NSImage(size:NSSize(width:3200,height:2000),flipped:false) {rect in
            NSColor(calibratedRed:0.10,green:0.18,blue:0.32,alpha:1).setFill();rect.fill()
            for line in 0..<50 {
                ("Synthetic screen \(line) · 300 OCR regions · 规划 Aurora 81742" as NSString).draw(at:NSPoint(x:80,y:CGFloat(line)*38+30),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:27,weight:.medium),.foregroundColor:NSColor.white])
            }
            return true
        }
        let url=root.appendingPathComponent("dense.png")
        try ScreenArchive.saveSource(try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil)),to:url)
        let regions=(0..<300).map {index in TextRegion(text:"Region \(index) · 规划 Aurora 81742",x:Double(index % 6)/6+0.005,y:Double(index / 6)/50+0.002,width:0.15,height:0.016)}
        let native=MemoryImageTransitionView(frame:NSRect(x:0,y:0,width:1440,height:900))
        let window=NSWindow(contentRect:native.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=native;window.orderFront(nil)
        defer {native.stop();window.close()}
        let small=CGRect(x:700,y:440,width:400,height:250),large=CGRect(x:80,y:70,width:1280,height:800)
        let loaded=expectation(description:"Full-resolution decoded pixels and indexed OCR")
        native.image.onImageSize={_ in loaded.fulfill()}
        native.update(id:"dense",url:url,regions:regions,destination:small,source:nil,radius:22,reduced:true)
        await fulfillment(of:[loaded],timeout:5)
        native.image.layoutSubtreeIfNeeded();window.displayIfNeeded()
        func overlay(_ view:NSView)->IndexedTextOverlay? {if let result=view as? IndexedTextOverlay {return result};return view.subviews.compactMap(overlay).first}
        let text=try XCTUnwrap(overlay(native.image))
        var imageLayouts=0,textLayouts=0,cadence:[Double]=[],work:[Double]=[],legs:[Double]=[]
        native.image.onLayout={imageLayouts += 1};text.onLayout={textLayouts += 1}
        native.onFrameMeasured={interval,duration in cadence.append(interval);work.append(duration)}
        let start=ProcessInfo.processInfo.systemUptime
        for leg in 0..<24 {
            let began=ProcessInfo.processInfo.systemUptime
            await withCheckedContinuation {continuation in
                native.onSettled={_ in native.onSettled=nil;continuation.resume()}
                native.update(id:"dense",url:url,regions:regions,destination:leg.isMultiple(of:2) ? large:small,source:nil,radius:leg.isMultiple(of:2) ? 14:22,reduced:false)
            }
            legs.append((ProcessInfo.processInfo.systemUptime-began)*1000)
        }
        func report(_ name:String,_ values:[Double]) {
            let sorted=values.sorted();guard !sorted.isEmpty else {return}
            print(String(format:"MEMORY_NATIVE_TRANSITION %@ count=%d median=%.3fms p95=%.3fms max=%.3fms over25=%d",name,sorted.count,sorted[sorted.count/2],sorted[Int(Double(sorted.count-1)*0.95)],sorted.last!,sorted.filter {$0 > 25}.count))
        }
        report("callback-interval",cadence);report("advance",work);report("leg",legs)
        print("MEMORY_NATIVE_TRANSITION window=1440x900 backing=\(window.backingScaleFactor) image=3200x2000 regions=\(regions.count) image-layouts=\(imageLayouts) OCR-layouts=\(textLayouts) elapsed=\(ProcessInfo.processInfo.systemUptime-start)")
        XCTAssertGreaterThan(cadence.count,100)
        XCTAssertEqual(native.image.frame,small);XCTAssertNil(native.flight)
    }
}
