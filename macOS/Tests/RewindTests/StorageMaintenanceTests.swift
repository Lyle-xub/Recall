import XCTest
@testable import Rewind

private final class StorageScanProbe:@unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls:Int {lock.lock();defer{lock.unlock()};return count}
    func scan() -> StorageUsage {
        lock.lock();count += 1;let value = count;lock.unlock()
        Thread.sleep(forTimeInterval:0.2)
        return StorageUsage(categories:[.init(kind:.video,bytes:Int64(value)*4096)],unreadableFiles:0)
    }
}
final class StorageMaintenanceTests:XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    @MainActor func testStorageRefreshCoalescesAndReusesCompletedResult() async throws {
        let root = try temporaryRoot();defer {try? FileManager.default.removeItem(at:root)}
        let probe = StorageScanProbe(),model = StorageUsageModel(root:root,modelRoot:root,scan:probe.scan)
        model.refresh()
        for _ in 0..<20 {model.refresh()}
        // Invalidations while a scan is running request one subsequent scan.
        for _ in 0..<20 {model.refresh(force:true)}
        let start = Date()
        try await Task.sleep(for:.milliseconds(10))
        XCTAssertTrue(model.loading)
        XCTAssertLessThan(Date().timeIntervalSince(start),0.18,"Scanning must not occupy the main actor")
        await model.waitForRefresh()
        XCTAssertEqual(probe.calls,2);XCTAssertEqual(model.usage?.totalBytes,8192)
        for _ in 0..<20 {model.refresh()}
        XCTAssertFalse(model.loading);XCTAssertEqual(probe.calls,2)
    }
    @MainActor func testSavedMeasurementAppearsBeforeFreshScanFinishes() async throws {
        let root = try temporaryRoot();defer {try? FileManager.default.removeItem(at:root)}
        let cached = StorageUsage(categories:[.init(kind:.screenshots,bytes:12345)],unreadableFiles:0,measuredAt:.distantPast)
        try JSONEncoder().encode(cached).write(to:root.appendingPathComponent("storage-usage.json"))
        let probe = StorageScanProbe(),model = StorageUsageModel(root:root,modelRoot:root,scan:probe.scan)
        model.refresh()
        for _ in 0..<100 where model.usage == nil {try await Task.sleep(for:.milliseconds(1))}
        XCTAssertEqual(model.usage?.totalBytes,12345);XCTAssertTrue(model.loading)
        await model.waitForRefresh()
        XCTAssertEqual(model.usage?.totalBytes,4096)
    }
    @MainActor func testStoragePageReleasesAutomaticOptimizationAndCleanupQuiescesIt() async throws {
        let root = try temporaryRoot();defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root),optimizer = StorageOptimizer(store:store)
        optimizer.setInterfaceVisible(true);optimizer.resume()
        XCTAssertTrue(optimizer.waitingForInterface);XCTAssertNil(optimizer.progress)
        optimizer.setStoragePageVisible(true)
        XCTAssertFalse(optimizer.waitingForInterface)
        await optimizer.beginCleanup()
        XCTAssertFalse(optimizer.running);XCTAssertTrue(optimizer.maintenanceSuspended)
        optimizer.optimizeExisting();XCTAssertFalse(optimizer.running)
        optimizer.endCleanup()
        for _ in 0..<200 where optimizer.running {try await Task.sleep(for:.milliseconds(5))}
        XCTAssertFalse(optimizer.running);XCTAssertFalse(optimizer.maintenanceSuspended)
        XCTAssertFalse(optimizer.status.contains("Paused"))
    }
    @MainActor func testApplicationCleanupRefreshesLibraryAndStorage() async throws {
        let root = try temporaryRoot();defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root)
        for index in 0..<3 {
            var frame = MemoryFrame(timestamp:Date(),appName:"Fixture",bundleID:"fixture",title:"Memory",imagePath:"frames/\(index).png",text:"Fixture",regions:[])
            frame.starred = index == 2;frame.indexingComplete = true
            try Data([1,2,3]).write(to:root.appendingPathComponent(frame.imagePath));try store.save(frame)
        }
        let model = try AppModel(root:root)
        model.interfaceVisibilityChanged(true)
        let result = try await model.clearStorage(store.cleanupPlan(scope:.all))
        XCTAssertEqual(result.memories,2);XCTAssertEqual(model.total,1)
        XCTAssertFalse(model.storageClearing);XCTAssertEqual(try store.frames().first?.starred,true)
        await model.storageOptimizer.beginCleanup()
        await model.storageUsage.waitForRefresh()
        XCTAssertNotNil(model.storageUsage.usage)
    }
    @MainActor func testCleanupWriterNeverHoldsTheInterfaceStoreMutex() async throws {
        let root = try temporaryRoot();defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root)
        let frame = MemoryFrame(timestamp:Date(),appName:"Fixture",bundleID:"fixture",title:"Retained until commit",imagePath:"frames/a.jpg",text:"text",regions:[])
        try Data([1,2,3]).write(to:root.appendingPathComponent(frame.imagePath));try store.save(frame)
        let plan = try store.cleanupPlan(scope:.all),entered = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        let work = Task.detached(priority:.utility) {
            let writer = try MemoryStore(root:root,maintenanceOnly:true)
            return try writer.clearStorage(plan) { phase in
                if phase.hasPrefix("Checking") {entered.signal();_ = release.wait(timeout:.now()+5)}
            }
        }
        let ready = await Task.detached {entered.wait(timeout:.now()+5) == .success}.value
        defer {release.signal()}
        XCTAssertTrue(ready)
        let start = Date()
        XCTAssertEqual(try store.count(),1);XCTAssertNotNil(try store.frame(frame.id))
        XCTAssertLessThan(Date().timeIntervalSince(start),0.2,"WAL readers must remain usable throughout cleanup")
        release.signal()
        let result = try await work.value
        XCTAssertEqual(result.memories,1);XCTAssertEqual(try store.count(),0)
    }
}
