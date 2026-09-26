import XCTest
import AppKit
@testable import Rewind

final class NativeCLIIntegrationTests:XCTestCase {
    @MainActor func testDesktopRefreshesAfterCLIRequestAndKeepsOneOwner() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recall-cli-app-test-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store = try MemoryStore(root:root)
        let frame = MemoryFrame(id:"desktop-record",timestamp:Date(),appName:"Test",bundleID:"cli.test",title:"Application record",imagePath:"frames/test.png",text:"Shared Aurora data",regions:[],indexingComplete:true)
        try store.save(frame)
        var settings = AppSettings();settings.retentionDays = 0
        try JSONEncoder().encode(settings).write(to:root.appendingPathComponent("settings.json"))
        let lease = try CoreCLILease(root:root)
        XCTAssertThrowsError(try CoreCLILease(root:root))
        let model = try AppModel(root:root)
        await model.storageOptimizer.beginCleanup()
        try model.enableCLIControl(lease:lease)
        let owner = try JSONSerialization.jsonObject(with:Data(contentsOf:lease.directory.appendingPathComponent("owner.json"))) as! [String:Any]
        let id = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let request:[String:Any] = ["instance":owner["instance"]!,"operation":"star","args":["id":frame.id]]
        try JSONSerialization.data(withJSONObject:request).write(to:lease.directory.appendingPathComponent(id+".request.json"),options:.atomic)
        let reply = lease.directory.appendingPathComponent(id+".response.json")
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath:reply.path) {break}
            try await Task.sleep(for:.milliseconds(25))
        }
        let response = try JSONSerialization.jsonObject(with:Data(contentsOf:reply)) as! [String:Any]
        XCTAssertEqual(response["ok"] as? Bool,true)
        XCTAssertEqual(try store.frame(frame.id)?.starred,true)
        XCTAssertEqual(model.archiveFrames.first(where:{$0.id == frame.id})?.starred,true,"Published desktop cards reload after a CLI mutation")
        let reader = try MemoryStore(root:root,readOnly:true)
        let result = try NativeCoreCLI.execute("list",args:["query":"Aurora"],store:reader) as! [[String:Any]]
        XCTAssertEqual(result.first?["id"] as? String,frame.id,"Native headless service reads app-generated data")
        await model.stopCLIControl();model.prepareToQuit();await model.shutDownRecording();await model.storageOptimizer.stop()
    }
    func testReadCommandsPreserveMacSchemaAndCompressedOCR() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let writer = try MemoryStore(root:root)
        let region = TextRegion(text:"共享内容",x:0.1,y:0.2,width:0.4,height:0.1)
        let frame = MemoryFrame(id:"sample",timestamp:Date(),appName:"Test",bundleID:"cli.test",title:"Read-only reference",imagePath:"frames/test.png",text:"Aurora 共享内容",regions:[region],indexingComplete:true)
        try writer.save(frame)
        let reader = try MemoryStore(root:root,readOnly:true)
        let value = try NativeCoreCLI.execute("get",args:["id":"sample"],store:reader) as! [String:Any]
        XCTAssertEqual(value["text"] as? String,frame.text)
        XCTAssertTrue(value["timestamp"] is String,"Wire timestamps use ISO-8601, not Swift's reference epoch")
        XCTAssertEqual((value["regions"] as? [[String:Any]])?.first?["text"] as? String,region.text)
        XCTAssertEqual(try reader.cliIntegrity(),"ok")
        XCTAssertEqual(try writer.frame("sample")?.regions.first?.id,region.id,"Native region IDs remain unchanged")
    }
}
