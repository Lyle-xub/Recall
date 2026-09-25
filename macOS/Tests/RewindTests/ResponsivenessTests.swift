import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Rewind

final class ResponsivenessTests: XCTestCase {
    @MainActor func testRapidRequestsCoalesceAndDoNotApplyStaleResults() async {
        let worker = LatestRequestWorker<Int,Int> { input in
            XCTAssertFalse(Thread.isMainThread,"Disk work must not block AppKit")
            Thread.sleep(forTimeInterval:0.02); return input
        }
        var applied:[Int] = []
        worker.submit(0,apply:{ applied.append($0) })
        try? await Task.sleep(for:.milliseconds(3))
        for i in 1...100 { worker.submit(i,apply:{ applied.append($0) }) }
        await worker.waitUntilIdle()
        XCTAssertEqual(applied,[100])
        XCTAssertLessThanOrEqual(worker.operationCount,2,"A fast drag must not enqueue every intermediate read")
        worker.submit(101,apply:{ applied.append($0) }); worker.cancel()
        await worker.waitUntilIdle()
        XCTAssertEqual(applied,[100],"Closing the overlay must invalidate pending results")
    }

    @MainActor func testRapidScrubbingSettlesOnLatestFrameAndBackgroundCaptureDoesNotResetIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model = try AppModel(root:root), origin = Date().addingTimeInterval(-100)
        var frames:[MemoryFrame] = []
        for i in 0..<30 {
            let frame = MemoryFrame(timestamp:origin.addingTimeInterval(Double(i)*2),appName:"Safari",bundleID:"Safari",title:"Frame \(i)",imagePath:"test.jpg",text:"Complete OCR \(i)",regions:[],sessionID:"session",continuityID:"run")
            try model.store.save(frame); frames.append(frame)
        }
        model.reload(); model.scrub(to:origin); await model.waitForPendingLoads()
        let began = CFAbsoluteTimeGetCurrent()
        for i in 0..<1000 { model.scrub(to:frames[i % 30].timestamp) }
        let elapsed = (CFAbsoluteTimeGetCurrent()-began)*1000
        await model.waitForPendingLoads()
        XCTAssertEqual(model.selected?.id,frames[9].id)
        XCTAssertEqual(model.selected?.text,"Complete OCR 9")
        let new = MemoryFrame(timestamp:Date(),appName:"Finder",bundleID:"Finder",title:"New",imagePath:"new.jpg",text:"",regions:[])
        try model.store.save(new); model.capture.onFrame?(new); model.capture.onIndexed?(new)
        XCTAssertEqual(model.selected?.id,frames[9].id)
        XCTAssertEqual(model.timelineCursor,frames[9].timestamp)
        XCTAssertEqual(model.timeline.last?.id,new.id)
        model.scrub(to:frames[14].timestamp); model.back(); await model.waitForPendingLoads()
        XCTAssertNil(model.selected); XCTAssertNil(model.timelineCursor)
        print(String(format:"SCRUB_BENCHMARK: 1000 cached input updates %.2f ms (headless model; not UI FPS)",elapsed))
    }

    @MainActor func testTranscriptJumpKeepsReaderOpenAndUsesLatestRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model = try AppModel(root:root), origin = Date().addingTimeInterval(-100)
        var frames:[MemoryFrame] = []
        for i in 0..<5 {
            let frame = MemoryFrame(timestamp:origin.addingTimeInterval(Double(i)*2),appName:"Test",bundleID:"test",title:"Frame",imagePath:"test.jpg",text:"Test",regions:[])
            try model.store.save(frame);frames.append(frame)
        }
        model.reload();model.select(frames[0]);model.inspectorOpen = true
        model.jump(to:frames[3].timestamp)
        await model.waitForPendingLoads()
        XCTAssertTrue(model.inspectorOpen)
        XCTAssertEqual(model.selected?.id,frames[3].id)
        model.scrub(to:frames[1].timestamp)
        XCTAssertFalse(model.inspectorOpen,"Timeline scrubbing still closes the inspector")
    }

    func testLightweightNavigationProjectionAndIndependentReadConnection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let writer = try MemoryStore(root:root), origin = Date()
        let regions = (0..<80).map { TextRegion(text:String(repeating:"OCR text ",count:20)+String($0),x:0,y:0,width:0.1,height:0.01) }
        for i in 0..<200 {
            try writer.save(MemoryFrame(timestamp:origin.addingTimeInterval(Double(i)),appName:"Finder",bundleID:"com.apple.finder",title:"\(i)",imagePath:"test.jpg",text:String(repeating:"OCR ",count:500),regions:regions))
        }
        let reader = try MemoryStore(root:root,readOnly:true)
        let start = CFAbsoluteTimeGetCurrent(), full = try reader.frames(limit:200)
        let fullTime = CFAbsoluteTimeGetCurrent()-start, next = CFAbsoluteTimeGetCurrent()
        let light = try reader.timelineMoments(limit:200)
        let lightTime = CFAbsoluteTimeGetCurrent()-next
        XCTAssertEqual(light.map(\.id),full.map(\.id))
        XCTAssertEqual(light.first?.bundleID,"com.apple.finder")
        var update = full[0]; update.text = "Index completed"; try writer.save(update)
        XCTAssertEqual(try reader.frame(update.id)?.text,"Index completed","WAL readers must see newly indexed frames")
        XCTAssertThrowsError(try reader.save(update))
        print(String(format:"INDEX_BENCHMARK: 200 OCR-heavy frames full %.2f ms; metadata %.2f ms",fullTime*1000,lightTime*1000))
    }

    func testImageDecodingCachesPixelsAtEachResolution() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer { try? FileManager.default.removeItem(at:file) }
        let context = try XCTUnwrap(CGContext(data:nil,width:1200,height:800,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.1,green:0.4,blue:0.8,alpha:1)); context.fill(CGRect(x:0,y:0,width:1200,height:800))
        let image = try XCTUnwrap(context.makeImage()), destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let pipeline = MemoryImagePipeline()
        let first = await pipeline.image(at:file,maxPixels:900), second = await pipeline.image(at:file,maxPixels:900)
        XCTAssertTrue(first === second)
        XCTAssertEqual(first?.width,900)
        let full = await pipeline.image(at:file)
        XCTAssertEqual(full?.width,1200)
        let count = await pipeline.decodeCount
        XCTAssertEqual(count,2,"Revisiting a frame must reuse decoded pixels")
    }

    func testCapsuleSeparatorsAreVisualOnlyAndShortVisitsRemainVisible() {
        let first = TimelineGeometry.capsuleRect(start:0,end:100,baseline:50,width:600)
        let second = TimelineGeometry.capsuleRect(start:100,end:300,baseline:50,width:600)
        XCTAssertEqual(second.minX-first.maxX,3,accuracy:0.01)
        XCTAssertEqual(first.height,7)
        XCTAssertGreaterThanOrEqual(TimelineGeometry.capsuleRect(start:100,end:100.1,baseline:50,width:600).width,1)
    }
}
