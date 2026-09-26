import XCTest
import CoreGraphics
import CSQLite
@testable import Rewind

final class TilePackTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws {root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws {try FileManager.default.removeItem(at:root)}
    private func tile(_ number:Int,bytes:Int = 2000)->ScreenTile {
        var data=Data(repeating:UInt8(number%251),count:bytes);data.append(Data(String(number).utf8))
        return ScreenTile(path:"frames/tiles/t1-"+ImageArchive.digest(data)+".png",data:data)
    }
    private func sql(_ file:URL,_ command:String)throws {
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(file.path,&db),SQLITE_OK);defer {sqlite3_close(db)}
        let result=sqlite3_exec(db,command,nil,nil,nil)
        guard result == SQLITE_OK else {throw NSError(domain:String(cString:sqlite3_errmsg(db)),code:Int(result))}
    }
    func testSegmentRolloverDedupReadAndReclamation()throws {
        let tiles=(0..<20).map {tile($0)},packs=try TilePackStore(root:root,writable:true,limit:8500)
        try packs.install(tiles)
        let ids=try packs.segmentIDs();XCTAssertEqual(ids.count,5)
        try packs.install(tiles)
        XCTAssertEqual(try packs.segmentIDs(),ids,"Identical content must not be copied again")
        let reader=try TilePackStore(root:root,writable:false)
        for tile in tiles.reversed() {XCTAssertEqual(try reader.read(tile.path),tile.data)}
        try packs.remove(tiles.prefix(8).map(\.path))
        XCTAssertEqual(try packs.segmentIDs().count,3)
        for tile in tiles.dropFirst(8) {XCTAssertEqual(try reader.read(tile.path),tile.data)}
        try packs.remove(tiles.dropFirst(8).map(\.path))
        XCTAssertTrue(try packs.segmentIDs().isEmpty)
        try packs.install([tiles[0]])
        XCTAssertGreaterThan(try XCTUnwrap(packs.segmentIDs().first),try XCTUnwrap(ids.last))
        XCTAssertEqual(try reader.read(tiles[0].path),tiles[0].data)
    }
    func testUnpublishedAndDeletedSegmentBytesRecoverWithoutDamagingLiveBlocks()throws {
        let a=tile(1),b=tile(2),packs=try TilePackStore(root:root,writable:true)
        try packs.install([a,b])
        let catalog=root.appendingPathComponent("frames/packs/catalog.sqlite")
        // Simulate a crash between deleting a mapping and reclaiming payload.
        let key=try XCTUnwrap(TilePackStore.key(b.path)).map {String(format:"%02x",$0)}.joined()
        try sql(catalog,"DELETE FROM tiles WHERE key=x'\(key)'")
        let recovered=try TilePackStore(root:root,writable:true)
        for id in try recovered.segmentIDs() {try recovered.reclaimSegment(id)}
        XCTAssertEqual(try recovered.read(a.path),a.data);XCTAssertNil(try recovered.read(b.path))
        try recovered.install([b]);XCTAssertEqual(try recovered.read(b.path),b.data)
        // A committed segment with a rolled-back catalog is never discoverable.
        try sql(catalog,"DELETE FROM tiles;DELETE FROM segments;")
        let final=try TilePackStore(root:root,writable:true)
        for id in try final.segmentIDs() {try final.reclaimSegment(id)}
        XCTAssertTrue(try final.segmentIDs().isEmpty)
    }
    func testCorruptionAndUnsafeKeysAreRejected()throws {
        let a=tile(1),packs=try TilePackStore(root:root,writable:true)
        XCTAssertThrowsError(try packs.install([ScreenTile(path:a.path,data:Data([0]))]))
        XCTAssertNil(TilePackStore.key("frames/tiles/../../outside.png"))
        try packs.install([a])
        let id=try XCTUnwrap(packs.segmentIDs().first)
        try sql(root.appendingPathComponent("frames/packs/segment-\(id).sqlite"),"UPDATE tiles SET data=x'00'")
        XCTAssertThrowsError(try packs.read(a.path))
    }
    func testFailureAfterSegmentCommitRetainsOriginalsAndRestartsMigration()throws {
        var store:MemoryStore?=try MemoryStore(root:root)
        let originals=[tile(10),tile(20)]
        try FileManager.default.createDirectory(at:root.appendingPathComponent("frames/tiles"),withIntermediateDirectories:true)
        for tile in originals {try tile.data.write(to:root.appendingPathComponent(tile.path))}
        _=try store!.imageBytes(originals[0].path)
        let catalog=root.appendingPathComponent("frames/packs/catalog.sqlite")
        try sql(catalog,"CREATE TRIGGER fail_publish BEFORE INSERT ON tiles BEGIN SELECT RAISE(ABORT,'simulated interrupted publication'); END")
        XCTAssertThrowsError(try store!.packLegacyTiles())
        for tile in originals {
            XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(tile.path)),tile.data)
            XCTAssertNil(try TilePackStore(root:root,writable:false).read(tile.path))
        }
        store=nil
        try sql(catalog,"DROP TRIGGER fail_publish")
        store=try MemoryStore(root:root)
        while try store!.packLegacyTiles().more { }
        for tile in originals {XCTAssertEqual(try store!.imageBytes(tile.path),tile.data)}
    }
    func testIndependentConnectionsSerializeConcurrentWriters() async throws {
        let directory=root!,first=(0..<40).map {tile($0)},second=(20..<60).map {tile($0)}
        _=try TilePackStore(root:directory,writable:true)
        try await withThrowingTaskGroup(of:Void.self) { group in
            for batch in [first,second] {
                group.addTask {try TilePackStore(root:directory,writable:true,limit:17000).install(batch)}
            }
            try await group.waitForAll()
        }
        let reader=try TilePackStore(root:directory,writable:false)
        for tile in first+second {XCTAssertEqual(try reader.read(tile.path),tile.data)}
    }
    func testLegacyMigrationPreservesPixelsMetadataAndCleanupAcrossRestart()throws {
        var store:MemoryStore?=try MemoryStore(root:root)
        let context=try XCTUnwrap(CGContext(data:nil,width:770,height:410,bitsPerComponent:8,bytesPerRow:3080,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red:0.2,green:0.5,blue:0.8,alpha:1));context.fill(CGRect(x:0,y:0,width:770,height:410))
        let image=try XCTUnwrap(context.makeImage()),archive=try ScreenArchive.pack(image)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("frames/tiles"),withIntermediateDirectories:true)
        for file in archive.tiles+[ScreenTile(path:archive.path,data:archive.data)] {try file.data.write(to:root.appendingPathComponent(file.path))}
        let frame=MemoryFrame(timestamp:Date(),appName:"Original",bundleID:"test",title:"Saved",imagePath:archive.path,text:"81742",regions:[TextRegion(text:"81742",x:0.1,y:0.1,width:0.2,height:0.1)])
        try store!.save(frame)
        for tile in archive.tiles {try sql(root.appendingPathComponent("memory.sqlite"),"INSERT INTO image_tiles VALUES('\(archive.path)','\(tile.path)')")}
        XCTAssertNotNil(StoredImage.load(root.appendingPathComponent(frame.imagePath)))
        _=try store!.packLegacyTiles(limit:1)
        store=nil;store=try MemoryStore(root:root)
        while try store!.packLegacyTiles(limit:1).more { }
        XCTAssertEqual(try store!.frame(frame.id)?.regions,frame.regions)
        XCTAssertEqual(try store!.frame(frame.id)?.text,frame.text)
        let loaded=try XCTUnwrap(StoredImage.load(root.appendingPathComponent(frame.imagePath)))
        XCTAssertTrue(ImageArchive.preservesPixels(image,loaded))
        for tile in archive.tiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(tile.path).path))
            XCTAssertEqual(try store!.imageBytes(tile.path),tile.data)
        }
        // New writes after switching the SQL table to the compact view still
        // share the exact blocks; deleting one frame must keep the other.
        var second=frame;second.id=UUID().uuidString
        try store!.saveRecognizedFrame(second,archive:archive)
        try store!.moveToTrash(frame);_=try store!.emptyTrash()
        XCTAssertNotNil(StoredImage.load(root.appendingPathComponent(second.imagePath)))
        _=try store!.clearStorage(store!.cleanupPlan(scope:.all,keepStarred:false))
        for tile in archive.tiles {XCTAssertNil(try store!.imageBytes(tile.path))}
        XCTAssertTrue(try TilePackStore(root:root,writable:false).segmentIDs().isEmpty)
    }
}
