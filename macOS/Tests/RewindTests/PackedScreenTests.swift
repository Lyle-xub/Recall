import XCTest
import CoreGraphics
import ImageIO
import CSQLite
@testable import Rewind

final class PackedScreenTests:XCTestCase {
    private var root:URL!
    private var store:MemoryStore!
    override func setUpWithError() throws {root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store = try MemoryStore(root:root)}
    override func tearDownWithError() throws {store = nil;try FileManager.default.removeItem(at:root)}
    private func picture(change:Bool = false)->CGImage {
        let c = CGContext(data:nil,width:800,height:800,bitsPerComponent:8,bytesPerRow:3200,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));c.fill(CGRect(x:0,y:400,width:800,height:400))
        c.setFillColor(CGColor(red:0,green:0,blue:1,alpha:1));c.fill(CGRect(x:0,y:0,width:800,height:400))
        if change {c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:50,y:680,width:30,height:30))}
        return c.makeImage()!
    }
    private func save(_ image:CGImage) throws -> (MemoryFrame,ScreenArchive) {
        let archive = try ScreenArchive.pack(image)
        var frame = MemoryFrame(timestamp:Date(),appName:"Notes",bundleID:"test",title:"Papers",imagePath:archive.path,text:"预算 81742",regions:[TextRegion(text:"81742",x:0.1,y:0.2,width:0.3,height:0.04)])
        frame.indexingComplete = true
        try store.saveRecognizedFrame(frame,archive:archive)
        return (frame,archive)
    }
    private func channels(_ image:CGImage,x:Int,y:Int)->[UInt8] {
        let c = CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let p = c.data!.assumingMemoryBound(to:UInt8.self),i = (y*image.width+x)*4
        return [p[i],p[i+1],p[i+2],p[i+3]]
    }
    func testUnregisteredWindowNumbersCannotCrashCaptureFiltering() {
        XCTAssertEqual(CaptureWindowIDs.valid([-1,0,12,12,Int.max]),Set([CGWindowID(12)]))
    }
    func testFullSizeOrientationEdgeTilesAndThumbnail() throws {
        let (frame,_) = try save(picture()),loaded = try XCTUnwrap(StoredImage.load(root.appendingPathComponent(frame.imagePath)))
        XCTAssertEqual(loaded.width,800);XCTAssertEqual(loaded.height,800)
        for (x,y) in [(20,20),(780,20),(20,780),(780,780)] {for (a,b) in zip(channels(picture(),x:x,y:y),channels(loaded,x:x,y:y)) {XCTAssertLessThanOrEqual(abs(Int(a)-Int(b)),4)}}
        let thumbnail = try XCTUnwrap(StoredImage.load(root.appendingPathComponent(frame.imagePath),maxPixels:200))
        XCTAssertEqual(thumbnail.width,200);for (a,b) in zip(channels(thumbnail,x:10,y:10),channels(picture(),x:10,y:10)) {XCTAssertLessThanOrEqual(abs(Int(a)-Int(b)),4)}
    }
    func testSharedTilesSurviveTrashAndClearOnlyAfterLastUse() throws {
        let (first,a) = try save(picture()),(second,b) = try save(picture(change:true))
        let shared = Set(a.tiles.map(\.path)).intersection(b.tiles.map(\.path))
        XCTAssertFalse(shared.isEmpty);XCTAssertNotEqual(first.imagePath,second.imagePath)
        try store.moveToTrash(first);_ = try store.emptyTrash()
        for tile in shared {XCTAssertNotNil(try store.imageBytes(tile))}
        XCTAssertNotNil(StoredImage.load(root.appendingPathComponent(second.imagePath)))
        let plan = try store.cleanupPlan(scope:.all,keepStarred:false)
        XCTAssertTrue(shared.isSubset(of:Set(plan.paths)))
        _ = try store.clearStorage(plan)
        for tile in Set(a.tiles.map(\.path)+b.tiles.map(\.path)) {XCTAssertNil(try store.imageBytes(tile))}
    }
    func testExportMaterializesPortablePNGAndPreservesText() throws {
        let (frame,_) = try save(picture()),destination = root.appendingPathComponent("export")
        try store.export(to:destination,frames:[frame])
        let copies = try JSONDecoder().decode([MemoryFrame].self,from:Data(contentsOf:destination.appendingPathComponent("frames.json")))
        XCTAssertEqual(copies[0].text,frame.text);XCTAssertEqual(copies[0].regions,frame.regions)
        XCTAssertEqual(URL(fileURLWithPath:copies[0].imagePath).pathExtension,"png")
        XCTAssertNotNil(CGImageSourceCreateWithURL(destination.appendingPathComponent(copies[0].imagePath) as CFURL,nil))
    }
    func testRejectsTraversalMissingTilesAndKeepsPendingOriginal() throws {
        let archive = try ScreenArchive.pack(picture())
        var bad = try JSONSerialization.jsonObject(with:archive.data) as! [String:Any]
        var tiles = bad["tiles"] as! [[String:Any]];tiles[0]["path"] = "../outside.png";bad["tiles"] = tiles
        XCTAssertThrowsError(try PackedScreen.manifest(JSONSerialization.data(withJSONObject:bad)))
        let path = "frames/source.png";try ScreenArchive.saveSource(picture(),to:root.appendingPathComponent(path))
        let frame = MemoryFrame(timestamp:Date(),appName:"Notes",bundleID:"test",title:"Papers",imagePath:path,text:"",regions:[])
        try store.save(frame)
        let incomplete = ScreenArchive(data:archive.data,fileExtension:archive.fileExtension,tiles:[])
        let updated = try store.updateIndex(frameID:frame.id,text:"81742",regions:[],archive:incomplete)
        XCTAssertEqual(updated?.imagePath,path);XCTAssertEqual(updated?.text,"81742")
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path))
    }
    func testMigrationKeepsOCRAndResolvesOldCachedPathsAcrossVersions() throws {
        let source = "frames/old.png",archive = try ScreenArchive.pack(picture())
        var original = try ScreenArchive.encode(picture(),type:.png);original.append(Data(repeating:0,count:100000))
        try original.write(to:root.appendingPathComponent(source))
        var first = MemoryFrame(timestamp:Date(),appName:"Notes",bundleID:"test",title:"Papers",imagePath:source,text:"81742",regions:[TextRegion(text:"81742",x:0.1,y:0.1,width:0.2,height:0.03)])
        first.meetingImagePath = source;first.indexingComplete = true;try store.save(first)
        let intermediate = ScreenArchive(data:original,fileExtension:"png")
        _ = try store.commitImageArchive(originalPath:source,result:ImageArchiveResult(sourceDigest:ImageArchive.digest(original),sourceBytes:Int64(original.count),archive:intermediate,recompressed:false))
        let second = try store.commitImageArchive(originalPath:intermediate.path,result:ImageArchiveResult(sourceDigest:ImageArchive.digest(original),sourceBytes:Int64(original.count),archive:archive,recompressed:true))
        XCTAssertTrue(second.changed);XCTAssertGreaterThan(second.savedBytes,0)
        try store.save(first)
        let current = try XCTUnwrap(store.frame(first.id))
        XCTAssertEqual(current.imagePath,archive.path);XCTAssertEqual(current.meetingImagePath,archive.path)
        XCTAssertEqual(current.text,first.text);XCTAssertEqual(current.regions,first.regions)
        XCTAssertNotNil(StoredImage.load(root.appendingPathComponent(current.imagePath)))
    }
    func testFullImageFallbackDoesNotEnterAnotherLossyPass() throws {
        let bytes = try ScreenArchive.encode(picture(),type:.png),archive = ScreenArchive(data:bytes,fileExtension:"png")
        let path = "frames/fallback.png";try bytes.write(to:root.appendingPathComponent(path))
        let frame = MemoryFrame(timestamp:Date(),appName:"Notes",bundleID:"test",title:"Papers",imagePath:path,text:"81742",regions:[])
        try store.save(frame)
        XCTAssertTrue(try store.commitImageArchive(originalPath:path,result:ImageArchiveResult(sourceDigest:ImageArchive.digest(bytes),sourceBytes:Int64(bytes.count),archive:archive,recompressed:false)).changed)
        XCTAssertTrue(try store.imageArchiveCandidates().isEmpty)
    }
    func testInterruptedPackedWriteRecoversWithoutDeletingSharedTiles() throws {
        let (frame,a) = try save(picture()),b = try ScreenArchive.pack(picture(change:true))
        let pending = b.tiles+[ScreenTile(path:b.path,data:b.data)]
        var database:OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&database),SQLITE_OK)
        for file in pending {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            if !FileManager.default.fileExists(atPath:url.path) {try file.data.write(to:url)}
            XCTAssertEqual(sqlite3_exec(database,"INSERT OR REPLACE INTO image_archive_staging VALUES('\(file.path)','\(ImageArchive.digest(file.data))')",nil,nil,nil),SQLITE_OK)
        }
        for tile in b.tiles {XCTAssertEqual(sqlite3_exec(database,"INSERT OR IGNORE INTO image_tiles VALUES('\(b.path)','\(tile.path)')",nil,nil,nil),SQLITE_OK)}
        sqlite3_close(database);store = nil;store = try MemoryStore(root:root)
        XCTAssertNotNil(StoredImage.load(root.appendingPathComponent(frame.imagePath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(b.path).path))
        for tile in a.tiles {XCTAssertNotNil(try store.imageBytes(tile.path))}
        for tile in b.tiles where !Set(a.tiles.map(\.path)).contains(tile.path) {XCTAssertNil(try store.imageBytes(tile.path))}
    }
    func testConsecutiveRealScreenshotsStorage() throws {
        guard let directory = ProcessInfo.processInfo.environment["RECALL_PACKED_SAMPLES"] else {throw XCTSkip("Opt-in private local storage benchmark")}
        let files = try FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:directory),includingPropertiesForKeys:nil).sorted {$0.path < $1.path}
        var previousBytes = 0,sourceBytes = 0,paths = Set<String>(),sharedBytes = 0
        let start = Date()
        for file in files {
            try autoreleasepool {
                let image = try XCTUnwrap(StoredImage.load(file)),old = try ScreenArchive.make(image)
                previousBytes += old.data.count;sourceBytes += try Data(contentsOf:file).count
                let (frame,archive) = try save(image)
                for tile in archive.tiles where paths.insert(tile.path).inserted {sharedBytes += tile.data.count}
                if paths.insert(archive.path).inserted {sharedBytes += archive.data.count}
                let loaded = try XCTUnwrap(StoredImage.load(root.appendingPathComponent(frame.imagePath)))
                XCTAssertEqual(loaded.width,image.width);XCTAssertEqual(loaded.height,image.height)
            }
        }
        print("PACKED_SCREEN_BENCHMARK images=\(files.count) source=\(sourceBytes) previous=\(previousBytes) shared=\(sharedBytes) seconds=\(Date().timeIntervalSince(start))")
        XCTAssertEqual(try store.count(),files.count)
    }
    func testLocalNeuralOCRFixtureAndRepeatAreIdentical() throws {
        guard let path = ProcessInfo.processInfo.environment["RECALL_NEURAL_FIXTURE"] else {throw XCTSkip("Opt-in local OCR model test")}
        let image = try XCTUnwrap(StoredImage.load(URL(fileURLWithPath:path)))
        let first = try NeuralOCR.shared.recognize(image),second = try NeuralOCR.shared.recognize(image)
        XCTAssertTrue(first.0.contains("81742"));XCTAssertTrue(first.0.contains("12345"));XCTAssertTrue(first.0.contains("papers"))
        XCTAssertEqual(first.1,second.1)
    }
}
