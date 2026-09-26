import XCTest
@testable import Rewind

final class StorageCleanupTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    let now = Date(timeIntervalSince1970:1_780_000_000)
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil;try FileManager.default.removeItem(at:root) }
    @discardableResult private func memory(age:Double = 0,starred:Bool = false,session:String? = nil,path:String? = nil) throws -> MemoryFrame {
        let path = path ?? "frames/\(UUID().uuidString).jpg"
        var frame = MemoryFrame(timestamp:now.addingTimeInterval(-age),appName:"Notes",bundleID:"test",title:"Cleanup fixture",imagePath:path,text:"searchable fixture",regions:[])
        frame.starred = starred;frame.sessionID = session
        try Data(repeating:0x41,count:1024).write(to:root.appendingPathComponent(path));try store.save(frame);return frame
    }
    private func session(_ id:String,active:Bool = false) throws {
        let row = RecordingSession(id:id,startedAt:now.addingTimeInterval(-3600),endedAt:active ? nil:now,videoPath:"recordings/\(id).mp4",appName:"Notes",hasAudio:true,systemAudioPath:"recordings/\(id).m4a")
        try store.saveSession(row)
        for path in [row.videoPath,row.systemAudioPath!] { try Data(repeating:1,count:2048).write(to:root.appendingPathComponent(path)) }
        try store.saveTranscript(.init(sessionID:id,timestamp:now,speaker:"Audio",text:"fixture speech"))
    }
    func testPreviewDoesNotMutateAndRespectsAgeStarsAndActiveSessions() throws {
        let old = try memory(age:86400*40)
        _ = try memory(age:86400*40,starred:true)
        _ = try memory(age:86400*2)
        try session("active",active:true);_ = try memory(age:86400*40,session:"active")
        let plan = try store.cleanupPlan(scope:.older30,at:now)
        XCTAssertEqual(plan.frameIDs,[old.id]);XCTAssertEqual(plan.skippedStarred,1);XCTAssertEqual(plan.skippedActive,1)
        XCTAssertGreaterThan(plan.bytes,0);XCTAssertEqual(try store.count(),4)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(old.imagePath).path))
    }
    func testCleanupKeepsSharedRecordingUntilLastRetainedMemoryIsRemoved() throws {
        try session("shared")
        let old = try memory(age:86400*40,session:"shared"),recent = try memory(age:1,session:"shared")
        let plan = try store.cleanupPlan(scope:.older30,at:now)
        XCTAssertTrue(plan.sessionIDs.isEmpty)
        let result = try store.clearStorage(plan)
        XCTAssertEqual(result.memories,1);XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(old.imagePath).path))
        XCTAssertNotNil(try store.session("shared"));XCTAssertEqual(try store.transcript("shared").count,1)
        let last = try store.clearStorage(store.cleanupPlan(scope:.all,at:now))
        XCTAssertEqual(last.recordings,1);XCTAssertNil(try store.frame(recent.id));XCTAssertNil(try store.session("shared"))
        XCTAssertTrue(try store.transcript("shared").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("recordings/shared.mp4").path))
        XCTAssertTrue(try store.frames(query:"searchable").isEmpty)
        XCTAssertFalse(try store.replaceExistingSessionTranscript(sessionID:"shared",lines:[.init(sessionID:"shared",timestamp:now,speaker:"Audio",text:"late result")]))
    }
    func testConfirmedSnapshotDoesNotDeleteNewRecordsOrNewlyStarredMemories() throws {
        var existing = try memory(age:1)
        let preview = try store.cleanupPlan(scope:.all,at:now)
        existing.starred = true;try store.save(existing)
        let fresh = try memory(age:0)
        let result = try store.clearStorage(preview)
        XCTAssertEqual(result.memories,0);XCTAssertNotNil(try store.frame(existing.id));XCTAssertNotNil(try store.frame(fresh.id))
    }
    func testTrashScopeAndSharedImagePreservePreferencesModelsAndUsage() throws {
        let a = try memory(),b = try memory(path:a.imagePath)
        try store.moveToTrash(a)
        try Data("preferences".utf8).write(to:root.appendingPathComponent("settings.json"))
        try FileManager.default.createDirectory(at:root.appendingPathComponent("models"),withIntermediateDirectories:true)
        try Data([1]).write(to:root.appendingPathComponent("models/test.gguf"))
        try store.saveUsage(.init(app:.init(name:"Notes",bundleID:"test"),start:now.addingTimeInterval(-60),end:now))
        let preview = try store.cleanupPlan(scope:.trash,at:now)
        XCTAssertEqual(preview.frameIDs,[a.id]);XCTAssertTrue(preview.paths.isEmpty)
        _ = try store.clearStorage(preview)
        XCTAssertNotNil(try store.frame(b.id));XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(b.imagePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("settings.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("models/test.gguf").path))
        XCTAssertEqual(try store.usage(in:DateInterval(start:now.addingTimeInterval(-60),end:now)).count,1)
    }
    func testAllIncludesEmptyCompletedRecordingsButConfirmationExcludesNewOnes() throws {
        try session("empty")
        let preview = try store.cleanupPlan(scope:.all,at:now)
        XCTAssertTrue(preview.frameIDs.isEmpty);XCTAssertEqual(preview.sessionIDs,["empty"])
        try session("new-empty")
        let result = try store.clearStorage(preview)
        XCTAssertEqual(result.memories,0);XCTAssertEqual(result.recordings,1)
        XCTAssertNil(try store.session("empty"));XCTAssertNotNil(try store.session("new-empty"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("recordings/empty.mp4").path))
    }
    func testEmptyRecordingCleanupJournalRecoversBeforeAndAfterCommit() throws {
        try session("orphan")
        let media = root.appendingPathComponent("recordings/orphan.mp4")
        let folder = root.appendingPathComponent(".cleanup-"+UUID().uuidString)
        let journal = CleanupJournal(frameIDs:[],paths:["recordings/orphan.mp4"],sessionIDs:["orphan"])
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        try JSONEncoder().encode(journal).write(to:folder.appendingPathComponent("journal.json"))
        try FileManager.default.moveItem(at:media,to:folder.appendingPathComponent("0"))
        store = nil;store = try MemoryStore(root:root)
        XCTAssertTrue(FileManager.default.fileExists(atPath:media.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
        _ = try store.clearStorage(store.cleanupPlan(scope:.all,at:now))
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        try JSONEncoder().encode(journal).write(to:folder.appendingPathComponent("journal.json"))
        try Data([1]).write(to:folder.appendingPathComponent("0"))
        store = nil;store = try MemoryStore(root:root)
        XCTAssertNil(try store.session("orphan"));XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
    }
    func testUnsafePathsAndSymlinksAreRejectedBeforeDeletion() throws {
        let good = try memory()
        var bad = good;bad.id = UUID().uuidString;bad.imagePath = "../outside.jpg";try store.save(bad)
        XCTAssertThrowsError(try store.cleanupPlan(scope:.all,at:now))
        XCTAssertNotNil(try store.frame(good.id))
        XCTAssertThrowsError(try CleanupFiles.ownedURL("settings.json",root:root))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to:outside);defer {try? FileManager.default.removeItem(at:outside)}
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("frames/linked.jpg"),withDestinationURL:outside)
        XCTAssertThrowsError(try CleanupFiles.ownedURL("frames/linked.jpg",root:root))
        XCTAssertTrue(FileManager.default.fileExists(atPath:outside.path))
    }
    func testDelayedOCRNeverRecreatesClearedOrTrashedMemories() throws {
        let starred = try memory(starred:true),removed = try memory(),trashed = try memory()
        try store.moveToTrash(trashed)
        XCTAssertNil(try store.updateIndex(frameID:trashed.id,text:"late OCR",regions:[]))
        _ = try store.clearStorage(store.cleanupPlan(scope:.all,at:now))
        XCTAssertNil(try store.updateIndex(frameID:removed.id,text:"late OCR",regions:[]))
        let updated = try store.updateIndex(frameID:starred.id,text:"new OCR",regions:[])
        XCTAssertEqual(updated?.starred,true);XCTAssertEqual(updated?.text,"new OCR")
        XCTAssertEqual(try store.count(),1)
        XCTAssertTrue(try store.frames(query:"late").isEmpty)
    }
    func testInterruptedCleanupRestoresBeforeCommitAndFinishesAfterCommit() throws {
        let frame = try memory()
        let folder = root.appendingPathComponent(".cleanup-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        let journal = CleanupJournal(frameIDs:[frame.id],paths:[frame.imagePath])
        try JSONEncoder().encode(journal).write(to:folder.appendingPathComponent("journal.json"))
        try FileManager.default.moveItem(at:root.appendingPathComponent(frame.imagePath),to:folder.appendingPathComponent("0"))
        store = nil;store = try MemoryStore(root:root)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(frame.imagePath).path))
        XCTAssertNotNil(try store.frame(frame.id));XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
        _ = try store.clearStorage(store.cleanupPlan(scope:.all,at:now))
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        try JSONEncoder().encode(journal).write(to:folder.appendingPathComponent("journal.json"))
        try Data([1]).write(to:folder.appendingPathComponent("0"))
        store = nil;store = try MemoryStore(root:root)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path));XCTAssertEqual(try store.count(),0)
    }
}
