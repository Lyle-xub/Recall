import XCTest
import Darwin
import SwiftUI
@testable import Rewind

final class BackgroundPerformanceTests:XCTestCase {
    func testBacklogBudgetAdaptsToHeatAndLowPower() {
        // A continuous three-second job used to immediately start its successor.
        let work = 3.0
        let nominal = BackgroundProcessingPolicy.recoveryInterval(after:work,thermal:.nominal,lowPower:false)
        let battery = BackgroundProcessingPolicy.recoveryInterval(after:work,thermal:.nominal,lowPower:true)
        let warm = BackgroundProcessingPolicy.recoveryInterval(after:work,thermal:.fair,lowPower:false)
        let hot = BackgroundProcessingPolicy.recoveryInterval(after:work,thermal:.serious,lowPower:false)
        let critical = BackgroundProcessingPolicy.recoveryInterval(after:work,thermal:.critical,lowPower:false)
        XCTAssertLessThanOrEqual(work/(work+nominal),0.67)
        XCTAssertGreaterThan(battery,nominal)
        XCTAssertGreaterThan(warm,nominal)
        XCTAssertGreaterThan(hot,warm)
        XCTAssertGreaterThan(critical,hot)
        XCTAssertGreaterThan(BackgroundProcessingPolicy.recoveryInterval(after:0,thermal:.nominal,lowPower:false),0)
        XCTAssertLessThanOrEqual(BackgroundProcessingPolicy.recoveryInterval(after:600,thermal:.critical,lowPower:true),60)
    }

    func testCatchUpKeepsThermalAndLowPowerBudgetsAndBoundsDurableDiscovery()throws {
        let normal = BackgroundProcessingPolicy.recoveryInterval(after:3,pending:500,thermal:.nominal,lowPower:false)
        XCTAssertEqual(normal,0.15,accuracy:0.001)
        XCTAssertGreaterThan(BackgroundProcessingPolicy.recoveryInterval(after:3,pending:500,thermal:.serious,lowPower:false),normal)
        XCTAssertEqual(BackgroundProcessingPolicy.recoveryInterval(after:3,pending:500,thermal:.fair,lowPower:false),1.5)
        XCTAssertEqual(BackgroundProcessingPolicy.recoveryInterval(after:3,pending:500,thermal:.fair,lowPower:true),3)
        XCTAssertGreaterThan(BackgroundProcessingPolicy.recoveryInterval(after:3,pending:500,thermal:.nominal,lowPower:true),normal)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root)
        let date = Date()
        for i in 0..<70 {
            try store.save(MemoryFrame(timestamp:date.addingTimeInterval(Double(i)),appName:"Synthetic",bundleID:"test",title:"",imagePath:"frames/source.png",text:"",regions:[],indexingComplete:false))
        }
        let window = try store.pendingIndexWindow(limit:10000)
        XCTAssertEqual(window.ids.count,32);XCTAssertEqual(window.count,70)
        let times = try window.ids.compactMap {try store.frame($0)?.timestamp}
        XCTAssertEqual(times,times.sorted());XCTAssertEqual(times.first,date)
        let unblocked = try store.pendingIndexWindow(excluding:window.ids)
        XCTAssertEqual(unblocked.ids.count,32);XCTAssertEqual(unblocked.count,70)
        XCTAssertTrue(Set(unblocked.ids).isDisjoint(with:window.ids))
    }

    @MainActor func testFailedImageDoesNotHideLaterDurableWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root),date = Date()
        for i in 0..<35 {
            let frame = MemoryFrame(timestamp:date.addingTimeInterval(Double(i)),appName:"Test",bundleID:"test",title:"",imagePath:"frames/\(i == 0 ? "broken":"good-\(i)").png",text:"",regions:[],indexingComplete:false,visualTime:0)
            try store.save(frame)
        }
        let capture = CaptureEngine(store:store,indexFrame:{url,_ in
            if url.lastPathComponent == "broken.png" {throw RewindError.message("Permanent fixture failure")}
            return ScreenIndexResult(text:"indexed",regions:[],archive:ScreenArchive(data:Data(),fileExtension:"png"))
        })
        let finished = expectation(description:"Every healthy window drains")
        finished.expectedFulfillmentCount = 34
        capture.onIndexed = {_ in finished.fulfill()}
        capture.resumePendingIndexing()
        await fulfillment(of:[finished],timeout:30)
        await capture.suspendIndexing()
        XCTAssertEqual(try store.pendingIndexWindow().count,1,"The failed original stays durable while later captures finish")
    }

    @MainActor func testIndexingYieldsBetweenCachedJobsWithoutLosingSavedFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        let image = NSImage(size:NSSize(width:400,height:140),flipped:false) { rect in
            NSColor.white.setFill();rect.fill()
            ("Recall 81742" as NSString).draw(at:NSPoint(x:20,y:50),withAttributes:[.font:NSFont.systemFont(ofSize:30),.foregroundColor:NSColor.black])
            return true
        }
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect:nil,context:nil,hints:nil))
        var ids = Set<String>()
        for index in 0..<3 {
            let path = "frames/queued-\(index).png"
            try ScreenArchive.saveSource(pixels,to:root.appendingPathComponent(path))
            let frame = MemoryFrame(timestamp:Date().addingTimeInterval(Double(index)),appName:"Test",bundleID:"test",title:"",imagePath:path,text:"",regions:[],indexingComplete:false)
            try store.save(frame);ids.insert(frame.id)
        }
        let capture = CaptureEngine(store:store),finished = expectation(description:"All saved captures indexed")
        finished.expectedFulfillmentCount = ids.count
        var received = Set<String>(),commits:[Date] = [],captureTimes:[Date] = []
        capture.onIndexed = { frame in
            received.insert(frame.id);commits.append(Date());captureTimes.append(frame.timestamp)
            XCTAssertTrue(frame.indexingComplete == true)
            XCTAssertTrue(frame.text.contains("81742"))
            finished.fulfill()
        }
        capture.setInterfaceVisible(true)
        capture.resumePendingIndexing()
        await fulfillment(of:[finished],timeout:25)
        XCTAssertEqual(received,ids)
        XCTAssertEqual(captureTimes,captureTimes.sorted(),"Adjacent captures should reuse OCR line caches without starving older frames")
        XCTAssertTrue(try store.pendingIndexFrames().isEmpty)
        for (previous,next) in zip(commits,commits.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.timeIntervalSince(previous),0.12,"Even a cache hit must yield between background jobs")
        }
    }

    @MainActor func testHiddenOverlayStopsArchiveAndResumesWithLatestRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var settings = AppSettings();settings.glassArchiveEnabled = true;settings.onboardingComplete = true;settings.launchFilmSeen = true
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try JSONEncoder().encode(settings).write(to:root.appendingPathComponent("settings.json"))
        let model = try AppModel(root:root)
        let host = NSHostingView(rootView:RootView(model:model).frame(width:1100,height:750))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:750),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false;window.contentView = host
        defer { window.orderOut(nil);model.interfaceVisibilityChanged(false) }
        func archiveView(_ view:NSView)->ArchiveSceneView? {
            if let archive = view as? ArchiveSceneView { return archive }
            return view.subviews.lazy.compactMap { archiveView($0) }.first
        }
        model.interfaceVisibilityChanged(true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for:.milliseconds(120))
        let view = try XCTUnwrap(archiveView(host)),scene = try XCTUnwrap(view.archive)
        XCTAssertTrue(scene.isActive)
        model.interfaceVisibilityChanged(false)
        try await Task.sleep(for:.milliseconds(120))
        XCTAssertFalse(scene.isActive)
        XCTAssertTrue(view.isHidden)
        let count = scene.layoutUpdateCount
        let frame = MemoryFrame(timestamp:Date(),appName:"New saved frame",bundleID:"test",title:"",imagePath:"missing.png",text:"",regions:[])
        try model.store.save(frame);model.reload()
        try await Task.sleep(for:.milliseconds(120))
        XCTAssertEqual(scene.layoutUpdateCount,count,"Background captures must not rebuild a hidden 3D scene")
        model.interfaceVisibilityChanged(true)
        try await Task.sleep(for:.milliseconds(120))
        XCTAssertTrue(scene.isActive)
        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(scene.recordIDs.contains(frame.id),"Opening resumes with the current library")
        await model.storageOptimizer.stop()
    }

    /// Opt-in: uses local captures without printing their contents or changing
    /// the library. Run in release configuration for comparable codec timings.
    func testScreenshotPackingBenchmark() throws {
        guard let folder = ProcessInfo.processInfo.environment["RECALL_PERFORMANCE_SAMPLES"] else {
            throw XCTSkip("Opt-in local screenshot benchmark")
        }
        let files = try FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:folder),includingPropertiesForKeys:nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.path < $1.path }
        XCTAssertFalse(files.isEmpty)
        let samples = stride(from:0,to:files.count,by:max(1,files.count/6)).prefix(6).map { files[$0] }
        var uniquePaths = Set<String>(),bytes = 0,tileCount = 0,heicCount = 0
        let start = Date(),cpu = clock()
        for file in samples {
            try autoreleasepool {
                let image = try XCTUnwrap(StoredImage.load(file))
                let archive = try ScreenArchive.pack(image)
                let manifest = try PackedScreen.manifest(archive.data)
                XCTAssertEqual(manifest.width,image.width)
                XCTAssertEqual(manifest.height,image.height)
                bytes += archive.data.count
                for tile in archive.tiles where uniquePaths.insert(tile.path).inserted {
                    bytes += tile.data.count;tileCount += 1
                    if tile.path.hasSuffix(".heic") { heicCount += 1 }
                }
            }
        }
        print("SCREEN_PACK_PERF frames=\(samples.count) seconds=\(Date().timeIntervalSince(start)) cpuSeconds=\(Double(clock()-cpu)/Double(CLOCKS_PER_SEC)) bytes=\(bytes) uniqueTiles=\(tileCount) heicTiles=\(heicCount)")
    }
}
