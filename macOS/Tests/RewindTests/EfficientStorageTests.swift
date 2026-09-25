import XCTest
import AppKit
import CoreImage
import AVFoundation
import CSQLite
import CryptoKit
@testable import Rewind

final class EfficientStorageTests:XCTestCase {
    private func root()throws->URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    private func image(change:Bool = false)throws->CGImage {
        var data = Data(repeating:255,count:80*40*4)
        if change { data[4] = 254 } // One bit in one source pixel; no perceptual threshold.
        return try XCTUnwrap(CGImage(width:80,height:40,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:80*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:CGDataProvider(data:data as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    func testStaticScreenStoresOneIntervalButOnePixelChangeCreatesAnother()async throws {
        let root = try root();defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root),writer = CaptureFrameStore(store:store),start = Date(timeIntervalSince1970:1000),pixels = try image()
        func frame(_ second:Double)->MemoryFrame { MemoryFrame(timestamp:start.addingTimeInterval(second),appName:"Notes",bundleID:"notes",title:"Numbers",imagePath:"",text:"",regions:[],sessionID:"recording",continuityID:"run",indexingComplete:false) }
        let first = try await writer.save(pixels,frame:frame(0)),id = try XCTUnwrap(first.frame?.id)
        for i in 1...60 { let result = try await writer.save(pixels,frame:frame(Double(i)*3));XCTAssertEqual(result.extendedID,id);XCTAssertNil(result.frame) }
        XCTAssertEqual(try store.count(),1);XCTAssertEqual(try store.pendingIndexFrames().count,1)
        XCTAssertEqual(try store.frame(id)?.endTimestamp,start.addingTimeInterval(180))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("frames").path).count,1)
        let changed = try await writer.save(image(change:true),frame:frame(183))
        XCTAssertNotEqual(changed.frame?.id,id);XCTAssertEqual(try store.count(),2)
        let held = try XCTUnwrap(store.frame(id)),next = try XCTUnwrap(changed.frame)
        let segment = AppTimeSegment(id:"clip",appName:"Notes",bundleID:"notes",start:start.addingTimeInterval(120),end:start.addingTimeInterval(200))
        XCTAssertEqual(TimelineFrameLookup.nearest(to:start.addingTimeInterval(179),in:[CapturedAppMoment(held),CapturedAppMoment(next)],segment:segment)?.id,id,"Holding a screen must not jump forward to a closer but later screenshot")
        XCTAssertEqual(try store.frames(since:start.addingTimeInterval(120),until:start.addingTimeInterval(170)).map(\.id),[id],"Date searches must include intervals that started before the filter")
        try await writer.finish(at:start.addingTimeInterval(190))
        XCTAssertEqual(try store.frame(next.id)?.endTimestamp,start.addingTimeInterval(190))
    }
    func testAppChangesKeepSeparateUsageMomentsAndReuseExactImageAndOCR()async throws {
        let root = try root();defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root),writer = CaptureFrameStore(store:store),pixels = try image()
        var f = MemoryFrame(timestamp:Date(),appName:"A",bundleID:"a",title:"Same content",imagePath:"",text:"",regions:[],sessionID:"s",continuityID:"run",indexingComplete:false)
        let firstResult = try await writer.save(pixels,frame:f)
        let first = try XCTUnwrap(firstResult.frame)
        let regions = [TextRegion(text:"Invoice 81742",x:0.1,y:0.2,width:0.5,height:0.1)]
        _ = try store.updateIndex(frameID:first.id,text:"Invoice 81742",regions:regions)
        f.id = UUID().uuidString;f.timestamp.addTimeInterval(3);f.bundleID = "b";f.appName = "B"
        let secondResult = try await writer.save(pixels,frame:f)
        let second = try XCTUnwrap(secondResult.frame)
        XCTAssertEqual(second.imagePath,first.imagePath);XCTAssertEqual(second.indexingComplete,true);XCTAssertEqual(second.regions,regions)
        XCTAssertEqual(try store.count(),2);XCTAssertTrue(try store.pendingIndexFrames().isEmpty)
        f.id = UUID().uuidString;f.timestamp.addTimeInterval(3);f.continuityID = "after-pause"
        let interrupted = try await writer.save(pixels,frame:f)
        XCTAssertNotNil(interrupted.frame,"Never merge across a capture interruption")
    }
    func testSharedOCRPreservesEveryRegionIDAndSearchAcrossTitleAndText()throws {
        let root = try root();defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root)
        let region = TextRegion(text:"Research papers 81742",x:0.1,y:0.2,width:0.7,height:0.04)
        var a = MemoryFrame(timestamp:Date(),appName:"Obsidian",bundleID:"obsidian",title:"Research vault",imagePath:"a.png",text:region.text,regions:[region],indexingComplete:true)
        try store.save(a)
        var b = a;b.id = UUID().uuidString;b.regions[0].id = UUID().uuidString;b.imagePath = "b.png";try store.save(b)
        XCTAssertEqual(try store.frame(a.id)?.ocrKey,try store.frame(b.id)?.ocrKey)
        XCTAssertEqual(try store.frame(a.id)?.regions,a.regions);XCTAssertEqual(try store.frame(b.id)?.regions,b.regions)
        XCTAssertEqual(try store.frames(query:"vault paper").count,2,"AND terms may span title and OCR indexes")
        XCTAssertEqual(try store.frames(query:"81742").count,2)
        a.text = "Updated number 81743";a.regions[0].text = a.text;try store.save(a)
        XCTAssertEqual(try store.frames(query:"81742").map(\.id),[b.id]);XCTAssertEqual(try store.frames(query:"81743").map(\.id),[a.id])
        try store.moveToTrash(b);_ = try store.emptyTrash();try store.compactIndex()
        XCTAssertTrue(try store.frames(query:"81742").isEmpty)
        XCTAssertEqual(try store.frame(a.id)?.text,a.text)
    }
    func testLegacyMigrationRetainsTextCoordinatesAndExternalFTS()throws {
        let root = try root();defer {try? FileManager.default.removeItem(at:root)}
        let original = MemoryFrame(timestamp:Date(),appName:"Notes",bundleID:"notes",title:"Legacy",imagePath:"a.png",text:"Old paper 81742",regions:[TextRegion(text:"81742",x:0.1,y:0.2,width:0.3,height:0.04)])
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE frames (id TEXT PRIMARY KEY,time REAL,app TEXT,text TEXT,starred INTEGER,deleted REAL,demo INTEGER,json TEXT); CREATE VIRTUAL TABLE frame_fts USING fts5(id UNINDEXED,text,tokenize='unicode61');",nil,nil,nil),SQLITE_OK)
        let json = String(decoding:try JSONEncoder().encode(original),as:UTF8.self).replacingOccurrences(of:"'",with:"''")
        XCTAssertEqual(sqlite3_exec(db,"INSERT INTO frames VALUES ('\(original.id)',\(original.timestamp.timeIntervalSince1970),'Notes','Legacy Old paper 81742',0,NULL,0,'\(json)')",nil,nil,nil),SQLITE_OK);sqlite3_close(db)
        let store = try MemoryStore(root:root),saved = try XCTUnwrap(store.frame(original.id))
        XCTAssertEqual(saved.text,original.text);XCTAssertEqual(saved.regions,original.regions);XCTAssertEqual(saved.timestamp,original.timestamp)
        XCTAssertEqual(try store.frames(query:"paper").map(\.id),[original.id])
        try store.compactIndex()
        XCTAssertEqual(try MemoryStore(root:root).frame(original.id)?.regions,original.regions)
    }
    func testDirectLightweightVideoHasNoAudioAndHoldsStaticFrame()async throws {
        let root = try root();defer {try? FileManager.default.removeItem(at:root)}
        let source = root.appendingPathComponent("replay.mp4"),start = Date()
        let sink = try LightweightVideoSink(url:source,width:3024,height:1964,startedAt:start,hostStart:.zero)
        let image = CIImage(color:.red).cropped(to:CGRect(x:0,y:0,width:3024,height:1964))
        sink.queue.sync { sink.consume(image,at:.zero) }
        try await Task.sleep(for:.milliseconds(100))
        try await sink.finish(at:start.addingTimeInterval(10))
        let asset = AVURLAsset(url:source),tracks = try await asset.loadTracks(withMediaType:.video)
        let video = try XCTUnwrap(tracks.first),size = try await video.load(.naturalSize),duration = try await asset.load(.duration)
        let audio = try await asset.loadTracks(withMediaType:.audio)
        XCTAssertEqual(size,CGSize(width:720,height:466));XCTAssertTrue(audio.isEmpty);XCTAssertEqual(duration.seconds,10,accuracy:0.02)
        let fps = try await video.load(.nominalFrameRate);XCTAssertLessThanOrEqual(fps,1.1)
        let still = try await AVAssetImageGenerator(asset:asset).image(at:CMTime(seconds:9,preferredTimescale:600)).image
        XCTAssertEqual(still.width,720)
        print("DIRECT_VIDEO_FIXTURE: native=3024x1964 replay=720x466 duration=\(duration.seconds) fps=\(fps) bytes=\(try Data(contentsOf:source).count) embeddedAudio=0")
    }
    func testRealLibraryMigrationInTemporaryCopyOnly()throws {
        guard let source = ProcessInfo.processInfo.environment["RECALL_MIGRATION_SOURCE"] else { throw XCTSkip("Optional read-only real library migration check") }
        let root = try root();defer {try? FileManager.default.removeItem(at:root)}
        var original:OpaquePointer?,copy:OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(source,&original,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&copy),SQLITE_OK)
        let backup = try XCTUnwrap(sqlite3_backup_init(copy,"main",original,"main"))
        XCTAssertEqual(sqlite3_backup_step(backup,-1),SQLITE_DONE);XCTAssertEqual(sqlite3_backup_finish(backup),SQLITE_OK);sqlite3_close(original)
        var statement:OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(copy,"SELECT json FROM frames",-1,&statement,nil),SQLITE_OK)
        var frames:[MemoryFrame] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = String(cString:sqlite3_column_text(statement,0))
            frames.append(try JSONDecoder().decode(MemoryFrame.self,from:Data(text.utf8)))
        }
        sqlite3_finalize(statement);sqlite3_close(copy)
        let before = try Data(contentsOf:root.appendingPathComponent("memory.sqlite")).count
        let store = try MemoryStore(root:root),encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        for original in frames {
            var frame = try XCTUnwrap(store.frame(original.id))
            frame.ocrKey = nil;frame.ocrRegionIDs = nil;frame.ocrMeetingRegionIDs = nil
            XCTAssertEqual(SHA256.hash(data:try encoder.encode(frame)),SHA256.hash(data:try encoder.encode(original)),"Migration changed original frame content")
        }
        try store.compactIndex()
        let after = try Data(contentsOf:root.appendingPathComponent("memory.sqlite")).count
        print("REAL_INDEX_MIGRATION: frames=\(frames.count) before=\(before) after=\(after) allOriginalFieldsIdentical=true")
    }

}
