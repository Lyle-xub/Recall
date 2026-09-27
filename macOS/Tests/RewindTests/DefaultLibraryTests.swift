import XCTest
import CSQLite
@testable import Rewind

final class DefaultLibraryTests:XCTestCase {
    private func fixture()throws->DefaultLibrary {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("recall-location-"+UUID().uuidString)
        addTeardownBlock {try? FileManager.default.removeItem(at:root)}
        return DefaultLibrary(parent:root)
    }
    private func database(_ root:URL,json:String = "{\"imagePath\":\"frames/a.png\",\"text\":\"RewindReplica is user content\"}")throws {
        try FileManager.default.createDirectory(at:root.appendingPathComponent("frames"),withIntermediateDirectories:true)
        var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(root.appendingPathComponent("memory.sqlite").path,&db),SQLITE_OK)
        defer {sqlite3_close(db)}
        XCTAssertEqual(sqlite3_exec(db,"CREATE TABLE frames(id TEXT,json TEXT);",nil,nil,nil),SQLITE_OK)
        var statement:OpaquePointer?;XCTAssertEqual(sqlite3_prepare_v2(db,"INSERT INTO frames VALUES('one',?)",-1,&statement,nil),SQLITE_OK)
        defer {sqlite3_finalize(statement)}
        sqlite3_bind_text(statement,1,json,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self));XCTAssertEqual(sqlite3_step(statement),SQLITE_DONE)
        try Data([1,2,3]).write(to:root.appendingPathComponent("frames/a.png"))
    }
    func testMissingAndExplicitRootsHaveNoMigrationSideEffects()throws {
        let paths=try fixture()
        XCTAssertEqual(try paths.resolveDefault(checkProcesses:{}),paths.current)
        XCTAssertFalse(FileManager.default.fileExists(atPath:paths.parent.path))
        XCTAssertEqual(try DefaultLibrary.resolve(explicit:paths.legacy),paths.legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath:paths.parent.path))
    }
    func testSharedReaderAndWriterBlockMoveUntilReleased()throws {
        let paths=try fixture();try database(paths.legacy)
        var reader:MemoryStore?=try MemoryStore(root:paths.legacy,readOnly:true,locationPair:paths)
        XCTAssertThrowsError(try paths.resolveDefault(checkProcesses:{})) {XCTAssertEqual(($0 as? CoreCLIError)?.code,"busy")}
        withExtendedLifetime(reader) {};reader=nil
        var writer:CoreCLILease?=try CoreCLILease(root:paths.legacy,locationPair:paths)
        XCTAssertThrowsError(try paths.resolveDefault(checkProcesses:{})) {XCTAssertEqual(($0 as? CoreCLIError)?.code,"busy")}
        withExtendedLifetime(writer) {};writer=nil
        XCTAssertEqual(try paths.resolveDefault(checkProcesses:{}),paths.current)
    }
    func testAtomicMovePreservesDatabaseSettingsModelsAndSidecars()throws {
        let paths=try fixture();try database(paths.legacy)
        let fm=FileManager.default
        for folder in ["models","frames/packs",".recall-tasks",".cleanup-test"] {try fm.createDirectory(at:paths.legacy.appendingPathComponent(folder),withIntermediateDirectories:true)}
        let files=["models/weights.gguf","frames/packs/catalog.sqlite-wal","frames/packs/segment-0.sqlite",".recall-tasks/finished.json","settings.json"]
        for file in files {try Data("historical /RewindReplica/ content \(file)".utf8).write(to:paths.legacy.appendingPathComponent(file))}
        let original=try Data(contentsOf:paths.legacy.appendingPathComponent("memory.sqlite"))
        XCTAssertEqual(try paths.resolveDefault(checkProcesses:{}),paths.current)
        XCTAssertFalse(fm.fileExists(atPath:paths.legacy.path))
        XCTAssertEqual(try Data(contentsOf:paths.current.appendingPathComponent("memory.sqlite")),original)
        for file in files {XCTAssertEqual(try String(contentsOf:paths.current.appendingPathComponent(file)),"historical /RewindReplica/ content \(file)")}
    }
    func testConflictingLibrariesRemainSeparate()throws {
        let paths=try fixture();try database(paths.legacy);try database(paths.current)
        XCTAssertThrowsError(try paths.resolveDefault(checkProcesses:{})) {XCTAssertEqual(($0 as? CoreCLIError)?.code,"conflict")}
        XCTAssertTrue(FileManager.default.fileExists(atPath:paths.legacy.appendingPathComponent("memory.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:paths.current.appendingPathComponent("memory.sqlite").path))
    }
    func testAbsoluteMediaAndManifestPathsRefuseWithoutChangingSource()throws {
        let paths=try fixture();try database(paths.legacy,json:"{\"imagePath\":\"/old/frames/a.png\"}")
        XCTAssertThrowsError(try paths.resolveDefault(checkProcesses:{})) {XCTAssertEqual(($0 as? CoreCLIError)?.code,"invalid_path")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:paths.current.path))
        let second=try fixture();try database(second.legacy,json:"{\"imagePath\":\"frames/movie.recallvideo\"}")
        try Data("{\"video\":\"/old/recordings/a.mp4\"}".utf8).write(to:second.legacy.appendingPathComponent("frames/movie.recallvideo"))
        XCTAssertThrowsError(try second.resolveDefault(checkProcesses:{})) {XCTAssertEqual(($0 as? CoreCLIError)?.code,"invalid_path")}
        XCTAssertTrue(FileManager.default.fileExists(atPath:second.legacy.path))
    }
    func testMigrationCoordinatorExcludesAnotherMigratorAndExplicitReaders()throws {
        let paths=try fixture();try database(paths.legacy)
        let exclusive=try LibraryLocationLease(parent:paths.parent,exclusive:true)
        XCTAssertThrowsError(try paths.resolveDefault(checkProcesses:{})) {XCTAssertEqual(($0 as? CoreCLIError)?.code,"busy")}
        XCTAssertThrowsError(try MemoryStore(root:paths.legacy,readOnly:true,locationPair:paths)) {XCTAssertEqual(($0 as? CoreCLIError)?.code,"busy")}
        withExtendedLifetime(exclusive) {}
    }
    func testCaseVariantsShareManagedLockButCustomNamesDoNot()throws {
        let paths=try fixture();try database(paths.current)
        let shared=try LibraryLocationLease.access(paths.parent.appendingPathComponent("rEcAlL"),locations:paths)
        XCTAssertThrowsError(try LibraryLocationLease(parent:paths.parent,exclusive:true)) {XCTAssertEqual(($0 as? CoreCLIError)?.code,"busy")}
        withExtendedLifetime(shared) {}
        XCTAssertNil(try LibraryLocationLease.access(paths.current))
        let custom=try fixture()
        XCTAssertThrowsError(try MemoryStore(root:custom.current,readOnly:true))
        XCTAssertFalse(FileManager.default.fileExists(atPath:custom.parent.path))
    }
    func testFailedStoreOpenReleasesSharedAccess()throws {
        let paths=try fixture()
        try FileManager.default.createDirectory(at:paths.legacy,withIntermediateDirectories:true)
        XCTAssertThrowsError(try MemoryStore(root:paths.legacy,readOnly:true,locationPair:paths))
        let exclusive=try LibraryLocationLease(parent:paths.parent,exclusive:true)
        withExtendedLifetime(exclusive) {}
    }

    func testDestinationCreatedAfterPreflightIsNeverOverwritten()throws {
        let paths=try fixture();try database(paths.legacy)
        XCTAssertThrowsError(try paths.resolveDefault(checkProcesses:{try FileManager.default.createDirectory(at:paths.current,withIntermediateDirectories:true)})) {XCTAssertEqual(($0 as? CoreCLIError)?.code,"conflict")}
        XCTAssertTrue(FileManager.default.fileExists(atPath:paths.legacy.appendingPathComponent("memory.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:paths.current.path))
    }

}
