import XCTest
import AppKit
import ImageIO
import CSQLite
@testable import Rewind

final class ImageArchiveTests:XCTestCase {
    private var root:URL!
    private var store:MemoryStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try MemoryStore(root:root)
    }
    override func tearDownWithError() throws { store = nil;try FileManager.default.removeItem(at:root) }
    @MainActor private func fixture()->CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1200,pixelsHigh:760,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill();NSRect(x:0,y:0,width:1200,height:760).fill()
        for n in 0..<30 {
            NSColor(calibratedRed:0.3,green:0.7,blue:0.9,alpha:1).setFill()
            NSRect(x:30,y:20+n*23,width:40+n*3,height:6).fill()
            ("Paper 81742 · 会议预算 12345 元 · small text (n)" as NSString).draw(at:NSPoint(x:200,y:20+n*23),withAttributes:[.font:NSFont.systemFont(ofSize:n%3 == 0 ? 10:14),.foregroundColor:NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState();return bitmap.cgImage!
    }
    private func frame(path:String,pending:Bool = false,trash:Bool = false,meeting:String? = nil) throws -> MemoryFrame {
        var f = MemoryFrame(timestamp:Date(),appName:"Notes",bundleID:"test",title:"Paper notes",imagePath:path,text:"会议预算 81742",regions:[TextRegion(text:"81742",x:0.1,y:0.2,width:0.2,height:0.03)])
        f.indexingComplete = !pending;f.meetingImagePath = meeting;f.starred = true
        if trash { f.deletedAt = Date() }
        try store.save(f);return f
    }
    @MainActor private func legacy(_ path:String = "frames/legacy.jpg") throws -> ImageArchiveResult {
        try ScreenArchive.encode(fixture(),type:.jpeg,quality:0.9).write(to:root.appendingPathComponent(path))
        return try ImageArchive.make(source:root.appendingPathComponent(path))
    }
    @MainActor func testLegacyImageKeepsNativePixelsAndPassesEdgeQualityGuard() throws {
        let path = "frames/legacy.jpg",result = try legacy(path)
        let original = try XCTUnwrap(CGImageSourceCreateWithURL(root.appendingPathComponent(path) as CFURL,nil).flatMap {CGImageSourceCreateImageAtIndex($0,0,nil)})
        for tile in result.archive.tiles {
            let url = root.appendingPathComponent(tile.path)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try tile.data.write(to:url)
        }
        try result.archive.data.write(to:root.appendingPathComponent(result.archive.path))
        let archived = try XCTUnwrap(StoredImage.load(root.appendingPathComponent(result.archive.path)))
        XCTAssertEqual(archived.width,1200);XCTAssertEqual(archived.height,760)
        XCTAssertGreaterThan(ImagePixelComparison.psnr(original,archived),30)
        XCTAssertLessThanOrEqual(result.archive.totalBytes,try Data(contentsOf:root.appendingPathComponent(path)).count)
        let blank = CGContext(data:nil,width:1200,height:760,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        blank.setFillColor(CGColor(gray:1,alpha:1));blank.fill(CGRect(x:0,y:0,width:1200,height:760))
        XCTAssertFalse(ImageArchive.preservesPixels(original,blank.makeImage()!))
    }
    @MainActor func testSharedMainMeetingAndTrashReferencesKeepOCRAndSearch() throws {
        let path = "frames/shared.jpg",result = try legacy(path)
        let first = try frame(path:path,meeting:path),second = try frame(path:path,trash:true)
        let committed = try store.commitImageArchive(originalPath:path,result:result)
        XCTAssertTrue(committed.changed)
        for before in [first,second] {
            let after = try XCTUnwrap(store.frame(before.id))
            XCTAssertEqual(after.imagePath,result.archive.path);XCTAssertEqual(after.text,before.text)
            XCTAssertEqual(after.regions,before.regions);XCTAssertEqual(after.timestamp,before.timestamp)
            XCTAssertEqual(after.deletedAt,before.deletedAt);XCTAssertEqual(after.starred,before.starred)
        }
        XCTAssertEqual(try store.frame(first.id)?.meetingImagePath,result.archive.path)
        XCTAssertEqual(try store.frames(query:"81742").map(\.id),[first.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
        // Old UI snapshots cannot restore deleted paths or overwrite fresh OCR.
        try store.moveToTrash(first);try store.restore(first)
        XCTAssertEqual(try store.frame(first.id)?.imagePath,result.archive.path)
        XCTAssertEqual(try store.frame(first.id)?.regions,first.regions)
        var cached = first;cached.starred = false;try store.save(cached)
        XCTAssertEqual(try store.frame(first.id)?.imagePath,result.archive.path)
        XCTAssertTrue(try store.imageArchiveCandidates().isEmpty)
        try store.moveToTrash(first);_ = try store.emptyTrash()
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(result.archive.path).path))
    }
    @MainActor func testPendingOCRAndChangedOrDeletedSourcesCannotBeReplaced() throws {
        let path = "frames/pending.jpg",result = try legacy(path),f = try frame(path:path,pending:true)
        XCTAssertTrue(try store.imageArchiveCandidates().isEmpty)
        XCTAssertFalse(try store.commitImageArchive(originalPath:path,result:result).changed)
        _ = try store.updateIndex(frameID:f.id,text:"original OCR",regions:f.regions)
        XCTAssertEqual(try store.imageArchiveCandidates(),[path])
        try Data(repeating:7,count:100).write(to:root.appendingPathComponent(path))
        XCTAssertFalse(try store.commitImageArchive(originalPath:path,result:result).changed)
        XCTAssertEqual(try store.frame(f.id)?.imagePath,path)
        try store.moveToTrash(f);_ = try store.emptyTrash()
        XCTAssertFalse(try store.commitImageArchive(originalPath:path,result:result).changed)
        XCTAssertNil(try store.frame(f.id))
    }
    @MainActor func testIdenticalFilesDeduplicateWithoutLosingMomentsOrRecompressing() throws {
        let one = "frames/one.jpg",two = "frames/two.jpg",result = try legacy(one)
        try FileManager.default.copyItem(at:root.appendingPathComponent(one),to:root.appendingPathComponent(two))
        let a = try frame(path:one),b = try frame(path:two)
        _ = try store.commitImageArchive(originalPath:one,result:result)
        let second = try store.commitImageArchive(originalPath:two,result:result)
        XCTAssertEqual(second.savedBytes,result.sourceBytes)
        XCTAssertEqual(try store.frame(a.id)?.imagePath,try store.frame(b.id)?.imagePath)
        XCTAssertEqual(try store.count(),2);XCTAssertTrue(try store.imageArchiveCandidates().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("frames").path).filter { !["tiles","packs"].contains($0) }.count,1)
        try store.moveToTrash(a);_ = try store.emptyTrash()
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(result.archive.path).path))
    }
    @MainActor func testCorruptDestinationKeepsOriginalAndDatabase() throws {
        let path = "frames/collision.jpg",result = try legacy(path),f = try frame(path:path)
        try Data([1,2,3]).write(to:root.appendingPathComponent(result.archive.path))
        XCTAssertThrowsError(try store.commitImageArchive(originalPath:path,result:result))
        XCTAssertEqual(try store.frame(f.id)?.imagePath,path)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
    }
    @MainActor func testRestartFinishesCommittedCleanupAndRemovesOnlyUnpublishedCandidates() throws {
        let path = "frames/old.jpg",result = try legacy(path),original = try Data(contentsOf:root.appendingPathComponent(path))
        let f = try frame(path:path);_ = try store.commitImageArchive(originalPath:path,result:result)
        // Simulate interruption after DB publication, before original removal.
        try original.write(to:root.appendingPathComponent(path));store = nil
        store = try MemoryStore(root:root)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
        XCTAssertEqual(try store.frame(f.id)?.imagePath,result.archive.path)
        // Simulate a crash between a durable candidate write and DB publication.
        let orphan = ScreenArchive(data:Data([3,4,5]),fileExtension:"png")
        try orphan.data.write(to:root.appendingPathComponent(orphan.path))
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK)
        for item in [orphan,result.archive] {
            let sql = "INSERT OR REPLACE INTO image_archive_staging VALUES('\(item.path)','\(ImageArchive.digest(item.data))')"
            XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
        }
        sqlite3_close(db);store = nil;store = try MemoryStore(root:root)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(orphan.path).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(result.archive.path).path))
    }
    @MainActor func testButtonJobPausesAndResumesImagesWithoutASecondLossyPass() async throws {
        let path = "frames/button.jpg";_ = try legacy(path);_ = try frame(path:path)
        let optimizer = StorageOptimizer(store:store)
        optimizer.optimizeExisting();optimizer.cancel()
        while optimizer.running { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(try store.imageArchiveCandidates(),[path])
        optimizer.optimizeExisting()
        let deadline = Date().addingTimeInterval(20)
        while optimizer.running,Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertFalse(optimizer.running);XCTAssertEqual(optimizer.checkedImages,1);XCTAssertEqual(optimizer.checkedIndexes,1);XCTAssertEqual(optimizer.totalItems,3)
        XCTAssertTrue(try store.imageArchiveCandidates().isEmpty)
        optimizer.optimizeExisting()
        while optimizer.running { try await Task.sleep(for:.milliseconds(20)) }
        XCTAssertEqual(optimizer.checkedImages,0)
    }
    func testRealLegacyImageSamplesOnlyInTemporaryOutput() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RECALL_STORAGE_IMAGES"] else { throw XCTSkip("Optional real legacy screenshot benchmark") }
        let files = try FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:directory),includingPropertiesForKeys:nil).filter { ["jpg","jpeg","png"].contains($0.pathExtension.lowercased()) }
        var before = 0,after = 0,compressed = 0
        for file in files {
            let data = try Data(contentsOf:file)
            let result = try await Task.detached(priority:.utility) { try ImageArchive.make(source:file) }.value
            before += data.count;after += result.archive.totalBytes
            if result.recompressed { compressed += 1 }
            XCTAssertEqual(try Data(contentsOf:file),data)
        }
        print("LEGACY_IMAGE_BENCHMARK: images=\(files.count), compressed=\(compressed), before=\(before), after=\(after)")
    }
}
