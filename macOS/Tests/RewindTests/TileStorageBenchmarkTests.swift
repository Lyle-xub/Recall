import XCTest
import Darwin
import CryptoKit
import CSQLite
@testable import Rewind

final class TileStorageBenchmarkTests:XCTestCase {
    func testReadOnlyFinalLayoutAgainstOriginalFiles()throws {
        guard let path=ProcessInfo.processInfo.environment["RECALL_STORAGE_READ_COPY"],
              let original=ProcessInfo.processInfo.environment["RECALL_STORAGE_READ_ORIGINAL"] else {throw XCTSkip("Opt-in read-only comparison")}
        let root=URL(fileURLWithPath:path),legacy=URL(fileURLWithPath:original)
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent(".benchmark-copy").path) else {throw XCTSkip("Requires a prepared copy")}
        let paths=try JSONDecoder().decode([String].self,from:Data(contentsOf:root.appendingPathComponent("sample-manifests.json")))
        var values:[String:Any]=[:]
        // Alternate the two layouts to reduce drift from other running apps.
        var times=["legacy":[Double](),"packed":[Double]()],cpu=["legacy":0.0,"packed":0.0]
        for i in 0..<40 {
            for name in (i%2 == 0 ? ["legacy","packed"]:["packed","legacy"]) {
                let base=name == "legacy" ? legacy:root,start=Date(),before=clock()
                try autoreleasepool {
                    let image=try PackedScreen.load(base.appendingPathComponent(paths[(i*37)%paths.count]),maxPixels:560,useCache:false)
                    XCTAssertEqual(max(image.width,image.height),560)
                }
                cpu[name,default:0] += Double(clock()-before)/Double(CLOCKS_PER_SEC)
                times[name,default:[]].append(Date().timeIntervalSince(start)*1000)
            }
        }
        for name in ["legacy","packed"] {
            let sorted=times[name]!.sorted()
            values[name+"MedianMilliseconds"]=sorted[sorted.count/2]
            values[name+"P95Milliseconds"]=sorted[Int(Double(sorted.count-1)*0.95)]
            values[name+"CPUSeconds"]=cpu[name]!
            values[name+"Seconds"]=sorted.reduce(0,+)/1000
        }
        let data=try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:root.deletingLastPathComponent().appendingPathComponent("final-read-results.json"))
        print("FINAL_TILE_READ "+String(decoding:data,as:UTF8.self))
    }
    func testIsolatedLibraryMigrationBenchmark()throws {
        guard let path=ProcessInfo.processInfo.environment["RECALL_STORAGE_BENCHMARK_ROOT"] else {throw XCTSkip("Opt-in cloned-library storage benchmark")}
        let root=URL(fileURLWithPath:path)
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent(".benchmark-copy").path) else {throw XCTSkip("Requires an explicitly prepared disposable copy")}
        let paths=try JSONDecoder().decode([String].self,from:Data(contentsOf:root.appendingPathComponent("sample-manifests.json")))
        func allocation(_ folder:URL)throws->(Int64,Int) {
            let files=FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey])!
            var bytes:Int64=0,count=0
            while let url=files.nextObject() as? URL {
                if try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {bytes += try CleanupFiles.size(url);count += 1}
            }
            return (bytes,count)
        }
        func metadataDigest()throws->Data {
            var db:OpaquePointer?;XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&db,SQLITE_OPEN_READONLY,nil),SQLITE_OK)
            defer {sqlite3_close(db)}
            var hash=SHA256()
            for table in ["frames","ocr_payloads","sessions","transcripts"] {
                var stmt:OpaquePointer?;XCTAssertEqual(sqlite3_prepare_v2(db,"SELECT * FROM \(table) ORDER BY 1",-1,&stmt,nil),SQLITE_OK)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    for column in 0..<sqlite3_column_count(stmt) {
                        if let text=sqlite3_column_text(stmt,column) {
                            let data=Data(bytes:text,count:Int(sqlite3_column_bytes(stmt,column)))
                            hash.update(data:Data("\(data.count):".utf8));hash.update(data:data)
                        } else {hash.update(data:Data("null:".utf8))}
                    }
                }
                sqlite3_finalize(stmt)
            }
            return Data(hash.finalize())
        }
        func readSample()->(Double,Double,Double,Double) {
            var durations:[Double]=[]
            let start=Date(),cpu=clock(),probe=StorageCPUProbe()
            for i in 0..<min(40,paths.count) {
                let index=(i*37)%paths.count,time=Date()
                autoreleasepool {
                    let image=try? PackedScreen.load(root.appendingPathComponent(paths[index]),maxPixels:560,useCache:false)
                    XCTAssertNotNil(image);XCTAssertEqual(max(image?.width ?? 0,image?.height ?? 0),560)
                }
                durations.append(Date().timeIntervalSince(time)*1000)
            }
            let elapsed=Date().timeIntervalSince(start),used=Double(clock()-cpu)/Double(CLOCKS_PER_SEC)
            return (elapsed,used,durations.sorted()[Int(Double(durations.count-1)*0.95)],probe.finish())
        }
        var store:MemoryStore?=try MemoryStore(root:root)
        let beforeFrames=try allocation(root.appendingPathComponent("frames")),beforeIndex=try CleanupFiles.size(root.appendingPathComponent("memory.sqlite"))
        let beforeMetadata=try metadataDigest(),beforeRead=readSample()
        let started=Date(),cpu=clock(),probe=StorageCPUProbe()
        var processed=0
        while true {
            let start=Date(),batch=try store!.packLegacyTiles()
            processed += batch.processed
            if !batch.more {break}
            Thread.sleep(forTimeInterval:BackgroundProcessingPolicy.recoveryInterval(after:Date().timeIntervalSince(start)))
        }
        let migrationSeconds=Date().timeIntervalSince(started),migrationCPU=Double(clock()-cpu)/Double(CLOCKS_PER_SEC),peak=probe.finish()
        store=nil // close the writer so WAL accounting includes completed checkpoints
        XCTAssertEqual(try metadataDigest(),beforeMetadata,"Screenshots' metadata, recognized text, timestamps and transcripts must be identical")
        let afterFrames=try allocation(root.appendingPathComponent("frames")),afterIndex=try CleanupFiles.size(root.appendingPathComponent("memory.sqlite")),afterRead=readSample()
        XCTAssertLessThan(afterFrames.0,beforeFrames.0)
        XCTAssertLessThan(afterFrames.1,beforeFrames.1)
        XCTAssertLessThan(afterIndex,beforeIndex)
        let result:[String:Any]=[
            "sampleImages":paths.count,"migratedTiles":processed,
            "framesAllocatedBefore":beforeFrames.0,"framesAllocatedAfter":afterFrames.0,"filesBefore":beforeFrames.1,"filesAfter":afterFrames.1,
            "indexAllocatedBefore":beforeIndex,"indexAllocatedAfter":afterIndex,
            "readSecondsBefore":beforeRead.0,"readSecondsAfter":afterRead.0,"readCPUSecondsBefore":beforeRead.1,"readCPUSecondsAfter":afterRead.1,
            "readP95MillisecondsBefore":beforeRead.2,"readP95MillisecondsAfter":afterRead.2,"readPeakCPUBefore":beforeRead.3,"readPeakCPUAfter":afterRead.3,
            "migrationSeconds":migrationSeconds,"migrationCPUSeconds":migrationCPU,"migrationPeakCPU":peak,"metadataIdentical":true]
        let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:root.deletingLastPathComponent().appendingPathComponent("benchmark-results.json"))
        print("TILE_STORAGE_BENCHMARK "+String(decoding:data,as:UTF8.self))
    }
}

private final class StorageCPUProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var lastTime=Date(),lastCPU=0.0,peak=0.0
    private let timer=DispatchSource.makeTimerSource(queue:DispatchQueue(label:"recall.storage-cpu-benchmark"))
    init() {
        lastCPU=Self.cpu()
        timer.schedule(deadline:.now()+0.25,repeating:0.25)
        timer.setEventHandler { [weak self] in self?.sample() };timer.resume()
    }
    private static func cpu()->Double {
        var value=rusage();getrusage(RUSAGE_SELF,&value)
        return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)+Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1_000_000
    }
    private func sample() {
        lock.withLock {
            let time=Date(),cpu=Self.cpu(),interval=time.timeIntervalSince(lastTime)
            if interval >= 0.05 {peak=max(peak,100*(cpu-lastCPU)/interval);lastTime=time;lastCPU=cpu}
        }
    }
    func finish()->Double {timer.cancel();sample();return lock.withLock {peak}}
    deinit {timer.cancel()}
}
