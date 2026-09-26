import XCTest
import AVFoundation
import CoreImage
@testable import Rewind

final class VisualArchiveTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)}
    override func tearDownWithError()throws {try FileManager.default.removeItem(at:root)}
    private func image(_ color:CIColor)throws->CGImage {
        try XCTUnwrap(CIContext().createCGImage(CIImage(color:color),from:CGRect(x:0,y:0,width:1200,height:800)))
    }
    func testNativeVideoIsSharedByCardsReplayAndExportWithOriginalOCR()async throws {
        let store=try MemoryStore(root:root),start=Date(),path="recordings/native.mp4"
        var session=RecordingSession(startedAt:start,videoPath:path,appName:"Test",hasAudio:false,unifiedVisualArchive:true)
        try store.saveSession(session)
        let sink=try LightweightVideoSink(url:root.appendingPathComponent(path),width:1200,height:800,startedAt:start,hostStart:.zero,nativeArchive:true)
        let original=try image(.blue),changed=try image(.red)
        sink.queue.sync {sink.consume(CIImage(cgImage:original),at:.zero)}
        // A forced application-change capture inside the 1 fps replay cadence
        // must be independently addressable, rather than receiving the old card.
        let time:Double?=await withCheckedContinuation {resume in sink.archiveFrame(changed,sourceTime:CMTime(seconds:0.3,preferredTimescale:600)) {resume.resume(returning:$0)}}
        XCTAssertEqual(time,0.3)
        let writer=CaptureFrameStore(store:store)
        var frame=MemoryFrame(timestamp:start.addingTimeInterval(0.3),appName:"Changed app",bundleID:"test.changed",title:"Window 2",imagePath:"",text:"",regions:[],sessionID:session.id)
        frame.visualTime=time;frame.visualWidth=1200;frame.visualHeight=800;frame.indexingComplete=false
        let capture=try await writer.save(changed,frame:frame)
        let saved=try XCTUnwrap(capture.frame)
        let source=root.appendingPathComponent(saved.imagePath)
        let regions=[TextRegion(text:"中文小字 0123456789",x:0.0123456789,y:0.3,width:0.2,height:0.03)]
        _=try store.updateIndex(frameID:saved.id,text:regions[0].text,regions:regions)
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path),"Keep original OCR pixels until movie finalization")
        try await sink.finish(at:start.addingTimeInterval(2))
        session.endedAt=start.addingTimeInterval(2);session.visualArchiveReady=true;try store.saveSession(session)
        // A crash after movie commit but before linking cards is resumable.
        XCTAssertEqual(try store.unfinishedVisualSessions(),[session.id])
        let frames=try store.finalizeVisualSession(session.id),archived=try XCTUnwrap(frames.first)
        XCTAssertTrue(try store.unfinishedVisualSessions().isEmpty)
        XCTAssertEqual(archived.regions,regions);XCTAssertEqual(archived.text,regions[0].text)
        XCTAssertTrue(archived.imagePath.hasSuffix(".recallvideo"));XCTAssertFalse(FileManager.default.fileExists(atPath:source.path))
        let card=try XCTUnwrap(StoredImage.load(root.appendingPathComponent(archived.imagePath)))
        XCTAssertEqual(card.width,1200);XCTAssertEqual(card.height,800)
        let context=try XCTUnwrap(CGContext(data:nil,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(card,in:CGRect(x:0,y:0,width:1,height:1))
        let pixel=try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
        XCTAssertGreaterThan(pixel[0],220);XCTAssertLessThan(pixel[2],25,"Card must select the red app-change frame")
        let replay=try await RecordingPlayback.asset(session:session,root:root)
        let tracks=try await replay.loadTracks(withMediaType:.video),size=try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size,CGSize(width:1200,height:800))
        let export=root.appendingPathComponent("export");try store.export(to:export,frames:frames)
        let images=try FileManager.default.contentsOfDirectory(at:export.appendingPathComponent("frames"),includingPropertiesForKeys:nil)
        XCTAssertEqual(images.count,1);XCTAssertEqual(images.first?.pathExtension,"png")
        XCTAssertEqual(try store.frames(query:"0123456789",demo:false).map(\.id),[saved.id])
        _=try store.clearStorage(store.cleanupPlan(scope:.all,keepStarred:false,at:start.addingTimeInterval(3)))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
    }
    func testCompressedOCRKeepsArbitraryIDsAndDoubleCoordinatesExactly()throws {
        let store=try MemoryStore(root:root)
        var frame=MemoryFrame(timestamp:Date(),appName:"Test",bundleID:"test",title:"Test",imagePath:"frames/test.png",text:"一行只改一个字 81742",regions:(0..<200).map {TextRegion(text:"一行只改一个字 \($0)",x:Double($0)/731,y:0.123456789123,width:0.0312345678123,height:0.01)})
        frame.regions[4].id="custom/region/ID";frame.meetingRegions=[TextRegion(text:"会议声音",x:0.1,y:0.2,width:0.3,height:0.4)]
        try store.save(frame)
        let saved=try XCTUnwrap(try store.frame(frame.id))
        XCTAssertEqual(saved.regions,frame.regions);XCTAssertEqual(saved.meetingRegions,frame.meetingRegions);XCTAssertEqual(saved.text,frame.text)
        let data=try JSONEncoder().encode(SharedOCR(frame)),packed=try CompactOCR.payload(data)
        XCTAssertLessThan(packed.utf8.count,data.count/2)
        XCTAssertEqual(try CompactOCR.payload(packed).regions,SharedOCR(frame).regions)
        XCTAssertThrowsError(try CompactOCR.unpack(Data([255,255,255,255])))
        XCTAssertThrowsError(try CompactOCR.regionIDs(Data([1,2,3])))
    }
    func testInterruptedMovieRetainsOriginalsAndReturnsToImageIndexing()throws {
        var store:MemoryStore?=try MemoryStore(root:root)
        let session=RecordingSession(startedAt:Date().addingTimeInterval(-30),videoPath:"recordings/interrupted.mp4",appName:"Test",hasAudio:false,unifiedVisualArchive:true)
        try store!.saveSession(session)
        let path="frames/source-recovery.png",pixels=try image(.green)
        try ScreenArchive.saveSource(pixels,to:root.appendingPathComponent(path))
        var frame=MemoryFrame(timestamp:Date().addingTimeInterval(-20),appName:"Test",bundleID:"test",title:"Original",imagePath:path,text:"Original 81742",regions:[],sessionID:session.id)
        frame.visualTime=10;frame.visualWidth=1200;frame.visualHeight=800;frame.indexingComplete=true
        try store!.save(frame)
        let bytes=try Data(contentsOf:root.appendingPathComponent(path))
        store=nil;store=try MemoryStore(root:root)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(path)),bytes)
        XCTAssertNil(try store!.frame(frame.id)?.visualTime)
        XCTAssertEqual(try store!.session(session.id)?.visualArchiveReady,false)
        XCTAssertEqual(try store!.interruptedVisualImages(),[path])
        XCTAssertEqual(try store!.frame(frame.id)?.text,frame.text)
    }
    func testSharedMovieSurvivesDeletingItsOriginalSession()throws {
        let store=try MemoryStore(root:root),date=Date().addingTimeInterval(-60)
        var session=RecordingSession(startedAt:date,endedAt:date.addingTimeInterval(10),videoPath:"recordings/shared.mp4",appName:"Test",hasAudio:false,unifiedVisualArchive:true,visualArchiveReady:true)
        try Data(repeating:7,count:100).write(to:root.appendingPathComponent(session.videoPath))
        try store.saveSession(session)
        var first=MemoryFrame(timestamp:date,appName:"First",bundleID:"test",title:"First",imagePath:"frames/source.png",text:"original",regions:[],sessionID:session.id)
        first.visualTime=0;first.visualWidth=1200;first.visualHeight=800;first.indexingComplete=true
        try store.save(first);first=try XCTUnwrap(store.finalizeVisualSession(session.id).first)
        session.id=UUID().uuidString;session.videoPath="recordings/second.mp4";try store.saveSession(session)
        var second=first;second.id=UUID().uuidString;second.sessionID=session.id;try store.save(second)
        try store.moveToTrash(first);_=try store.emptyTrash()
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("recordings/shared.mp4").path))
        XCTAssertNotNil(try store.frame(second.id))
        _=try store.clearStorage(store.cleanupPlan(scope:.all,keepStarred:false))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("recordings/shared.mp4").path))
    }
}
