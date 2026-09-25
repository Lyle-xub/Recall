import XCTest
import AppKit
import AVFoundation
import ImageIO
@testable import Rewind

final class StorageOptimizationTests:XCTestCase {
    @MainActor private func image()->CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1600,pixelsHigh:1000,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill();NSRect(x:0,y:0,width:1600,height:1000).fill()
        for (index,size) in [12.0,16.0,24.0,36.0].enumerated() {
            ("Recall Paper 2026 invoice 81742" as NSString).draw(at:NSPoint(x:60,y:850-index*150),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:NSColor.black])
            ("会议记录 本地识别 预算 12345 元" as NSString).draw(at:NSPoint(x:60,y:800-index*150),withAttributes:[.font:NSFont.systemFont(ofSize:size),.foregroundColor:NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState();return bitmap.cgImage!
    }
    @MainActor func testLosslessSpoolAndArchivePreserveOriginalOCRAndDimensions() async throws {
        let source = image(),root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root),path = "frames/source-test.png"
        try ScreenArchive.saveSource(source,to:root.appendingPathComponent(path))
        let recovered = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL,nil).flatMap {CGImageSourceCreateImageAtIndex($0,0,nil)})
        XCTAssertEqual(ImagePixelComparison.psnr(source,recovered),.infinity)
        let processor = ScreenIndexProcessor(),indexed = try await processor.process(root.appendingPathComponent(path))
        let cached = try await processor.process(root.appendingPathComponent(path))
        XCTAssertEqual(cached.regions,indexed.regions);XCTAssertEqual(cached.archive.path,indexed.archive.path)
        let baseline = try await Task.detached { try NativeOCR.recognize(source) }.value
        XCTAssertEqual(indexed.text,baseline.0)
        XCTAssertTrue(indexed.text.contains("81742"));XCTAssertTrue(indexed.text.contains("会议记录"))
        let frame = MemoryFrame(timestamp:Date(),appName:"Test",bundleID:"test",title:"Native OCR",imagePath:path,text:"",regions:[])
        try store.save(frame)
        let saved = try XCTUnwrap(store.updateIndex(frameID:frame.id,text:indexed.text,regions:indexed.regions,archive:indexed.archive))
        XCTAssertEqual(saved.text,baseline.0);XCTAssertEqual(saved.regions,indexed.regions)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
        let archived = try XCTUnwrap(StoredImage.load(root.appendingPathComponent(saved.imagePath)))
        XCTAssertEqual(archived.width,source.width);XCTAssertEqual(archived.height,source.height)
        let legacy = try ScreenArchive.encode(source,type:.jpeg,quality:0.9)
        XCTAssertLessThan(indexed.archive.totalBytes,legacy.count)
        print("STORAGE_IMAGE_FIXTURE: legacy=\(legacy.count), archive=\(indexed.archive.totalBytes), format=\(indexed.archive.fileExtension), originalOCRExact=true")
    }
    @MainActor func testDeduplicatedFilesKeepEveryTimestampExportAndSurvivePartialCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root),archive = try ScreenArchive.make(image())
        let one = MemoryFrame(timestamp:Date().addingTimeInterval(-10),appName:"A",bundleID:"a",title:"one",imagePath:"",text:"original text",regions:[])
        var two = one;two.id = UUID().uuidString;two.timestamp = Date();two.appName = "B"
        try store.saveRecognizedFrame(one,archive:archive);try store.saveRecognizedFrame(two,archive:archive)
        let all = try store.frames();XCTAssertEqual(all.count,2);XCTAssertEqual(Set(all.map(\.imagePath)).count,1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("frames").path).count,1)
        try store.export(to:root.appendingPathComponent("export"),frames:all)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("export/frames").path).count,1)
        try store.moveToTrash(try XCTUnwrap(store.frame(one.id)));_ = try store.clearStorage(store.cleanupPlan(scope:.trash))
        XCTAssertNotNil(try store.frame(two.id));XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(archive.path).path))
    }
    func testVideoCommitCannotReplaceActiveDeletedOrChangedSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root),original = "recordings/original.mp4",copy = "recordings/archive-work-test.mp4"
        try Data(repeating:1,count:16000).write(to:root.appendingPathComponent(original));try Data([1]).write(to:root.appendingPathComponent(copy))
        let a = try CleanupFiles.size(root.appendingPathComponent(original)),b = try CleanupFiles.size(root.appendingPathComponent(copy))
        let result = VideoArchiveResult(accepted:true,originalBytes:a,archivedBytes:b,reason:"test")
        var session = RecordingSession(startedAt:Date(),videoPath:original,appName:"Test",hasAudio:false)
        try store.saveSession(session)
        XCTAssertEqual(try store.commitVideoArchive(sessionID:session.id,originalPath:original,candidatePath:copy,result:result),0)
        XCTAssertEqual(try store.session(session.id)?.videoPath,original)
        session.endedAt = Date();try store.saveSession(session)
        XCTAssertEqual(try store.commitVideoArchive(sessionID:session.id,originalPath:"recordings/wrong.mp4",candidatePath:copy,result:result),0)
        XCTAssertEqual(try store.commitVideoArchive(sessionID:"missing",originalPath:original,candidatePath:copy,result:result),0)
        XCTAssertGreaterThan(try store.commitVideoArchive(sessionID:session.id,originalPath:original,candidatePath:copy,result:result),0)
        XCTAssertEqual(try store.session(session.id)?.videoPath,copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(original).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(copy).path))
    }
    func testCommittedVideoReplacementRecoversWithoutRemovingReferencedMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var store:MemoryStore? = try MemoryStore(root:root)
        let old = "recordings/old.mp4",copy = "recordings/archive-work-recovered.mp4"
        try Data(repeating:1,count:12000).write(to:root.appendingPathComponent(old));try Data([1]).write(to:root.appendingPathComponent(copy))
        var session = RecordingSession(startedAt:Date(),endedAt:Date(),videoPath:copy,appName:"Test",hasAudio:false)
        session.supersededVideoPath = old;session.archivedVideoBytes = try CleanupFiles.size(root.appendingPathComponent(copy))
        try store?.saveSession(session);store = nil;store = try MemoryStore(root:root)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(old).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(copy).path))
        XCTAssertNil(try store?.session(session.id)?.supersededVideoPath)
    }
    func testRealVideoOptimizationInTemporaryOutputOnly() async throws {
        guard let path = ProcessInfo.processInfo.environment["RECALL_STORAGE_VIDEO"] else { throw XCTSkip("Optional real recording codec/quality benchmark") }
        let source = URL(fileURLWithPath:path),destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        defer {try? FileManager.default.removeItem(at:destination)}
        let before = try Data(contentsOf:source,options:.mappedIfSafe).count,started = Date()
        let result = try await VideoArchive.make(source:source,destination:destination)
        XCTAssertEqual(try Data(contentsOf:source,options:.mappedIfSafe).count,before)
        print("STORAGE_VIDEO_BENCHMARK: accepted=\(result.accepted), original=\(result.originalBytes), candidate=\(result.archivedBytes), reason=\(result.reason), seconds=\(Date().timeIntervalSince(started))")
        if ProcessInfo.processInfo.environment["RECALL_STORAGE_EXPECT_ACCEPTED"] == "1" { XCTAssertTrue(result.accepted,result.reason) }
        if FileManager.default.fileExists(atPath:destination.path) {
            if result.accepted { XCTAssertLessThan(result.archivedBytes,result.originalBytes*85/100) }
            let asset = AVURLAsset(url:destination),original = AVURLAsset(url:source)
            let tracks = try await asset.loadTracks(withMediaType:.video)
            let track = try XCTUnwrap(tracks.first)
            let size = try await track.load(.naturalSize),fps = try await track.load(.nominalFrameRate)
            XCTAssertLessThanOrEqual(max(size.width,size.height),720);XCTAssertLessThanOrEqual(fps,1.1)
            let duration = try await asset.load(.duration).seconds,originalDuration = try await original.load(.duration).seconds
            XCTAssertEqual(duration,originalDuration,accuracy:0.15)
            let audio = try await asset.loadTracks(withMediaType:.audio).count,originalAudio = try await original.loadTracks(withMediaType:.audio).count
            XCTAssertEqual(audio,originalAudio)
        }
        // A cancelled background optimization must stop rather than strand a
        // writer or publish a partially encoded replacement.
        let cancelledURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        defer {try? FileManager.default.removeItem(at:cancelledURL)}
        let task = Task {try await VideoArchive.make(source:source,destination:cancelledURL)}
        try await Task.sleep(for:.milliseconds(100));task.cancel()
        do {_ = try await task.value;XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    }
}
