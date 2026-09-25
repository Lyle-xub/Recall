import XCTest
import ScreenCaptureKit
import CoreVideo
@testable import Rewind

final class CaptureTests: XCTestCase {
    func testOneScreenOutputFeedsVideoWithoutThrottlingItsSamples() throws {
        var pixels:CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,16,8,kCVPixelFormatType_32BGRA,nil,&pixels),kCVReturnSuccess)
        let image = try XCTUnwrap(pixels)
        var format:CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:image,formatDescriptionOut:&format),noErr)
        var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:3),presentationTimeStamp:.zero,decodeTimeStamp:.invalid),sample:CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:image,formatDescription:try XCTUnwrap(format),sampleTiming:&timing,sampleBufferOut:&sample),noErr)
        let sink = FrameSink(interval:3),start = Date()
        var video = 0,screens = 0
        sink.onVideoSample = { _ in video += 1 }
        sink.onImage = { _,_ in screens += 1 }
        for second in [0,1,2,3] { sink.consumeScreenSample(try XCTUnwrap(sample),time:start.addingTimeInterval(Double(second))) }
        XCTAssertEqual(video,4);XCTAssertEqual(screens,2)
    }
    func testIdleScreenKeepsLatestPixelsAndAppSwitchBypassesInterval() throws {
        func buffer(_ width:Int) throws -> CVPixelBuffer {
            var result:CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault,width,8,kCVPixelFormatType_32BGRA,nil,&result),kCVReturnSuccess)
            return try XCTUnwrap(result)
        }
        let sink = FrameSink(interval:3), start = Date(timeIntervalSince1970:1000)
        var widths:[Int] = []
        sink.onImage = { image,_ in widths.append(image.width) }
        sink.consume(try buffer(8),status:.complete,time:start)
        sink.consume(try buffer(16),status:.complete,time:start.addingTimeInterval(1))
        sink.consume(nil,status:.idle,time:start.addingTimeInterval(3))
        XCTAssertEqual(widths,[8,16],"Idle heartbeat must use the most recent complete frame, not the last indexed image")
        sink.requestFrame()
        sink.consume(nil,status:.idle,time:start.addingTimeInterval(3.1))
        XCTAssertEqual(widths.count,2,"App switches must wait for fresh pixels")
        sink.consume(try buffer(24),status:.complete,time:start.addingTimeInterval(3.2))
        XCTAssertEqual(widths,[8,16,24],"A short application visit must not wait three seconds")
        sink.consume(nil,status:.blank,time:start.addingTimeInterval(4))
        sink.consume(nil,status:.idle,time:start.addingTimeInterval(9))
        XCTAssertEqual(widths.count,3,"Never reuse pixels across an unavailable/protected screen")
    }
    func testSavedScreenshotsCanResumeOCRAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var frame = MemoryFrame(timestamp:Date(),appName:"Finder",bundleID:"com.apple.finder",title:"Test",imagePath:"test.jpg",text:"",regions:[])
        frame.indexingComplete = false; frame.continuityID = "test-run"
        do { let store = try MemoryStore(root:root); try store.save(frame) }
        let reopened = try MemoryStore(root:root)
        XCTAssertEqual(try reopened.pendingIndexFrames().map(\.id),[frame.id])
        XCTAssertEqual(try reopened.frame(frame.id)?.continuityID,"test-run")
        try reopened.moveToTrash(frame)
        XCTAssertTrue(try reopened.pendingIndexFrames().isEmpty,"Restart must not resurrect deleted screenshots")
    }
    func testDefaultDisplayIsPrimaryRegardlessOfEnumerationOrder() {
        XCTAssertEqual(CaptureDisplaySelection.choose(available:[7,1,9],preferred:nil,main:1),1)
        XCTAssertEqual(CaptureDisplaySelection.choose(available:[7,1,9],preferred:9,main:1),9)
        XCTAssertNil(CaptureDisplaySelection.choose(available:[7,1,9],preferred:8,main:1))
        XCTAssertNil(CaptureDisplaySelection.choose(available:[],preferred:nil,main:1))
    }
    func testRetinaCaptureKeepsNativeResolution() {
        XCTAssertEqual(CaptureDimensions.native(width:1512,height:982,scale:2,fallbackWidth:1512,fallbackHeight:982),CaptureDimensions(width:3024,height:1964))
    }
    func testDisplayMetadataFailureNeverCreatesAnEmptyStream() {
        for scale in [0,Double.nan,Double.infinity] {
            XCTAssertEqual(CaptureDimensions.native(width:1512,height:982,scale:scale,fallbackWidth:1512,fallbackHeight:982),CaptureDimensions(width:1512,height:982))
        }
        XCTAssertEqual(CaptureDimensions.native(width:1513,height:983,scale:1,fallbackWidth:0,fallbackHeight:0),CaptureDimensions(width:1512,height:982))
    }
}
