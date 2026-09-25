import XCTest
import AppKit
@testable import Rewind

final class MemoryTests: XCTestCase {
    var root: URL!
    var store: MemoryStore!
    override func setUpWithError() throws {root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store = try MemoryStore(root:root)}
    override func tearDownWithError() throws {store = nil;try FileManager.default.removeItem(at:root)}
    func frame(_ text:String, app:String = "Chrome", time:Date = Date()) -> MemoryFrame {MemoryFrame(timestamp:time,appName:app,bundleID:"test",title:"Test",imagePath:"frames/test.jpg",text:text,regions:[])}
    func testLiteralAndChineseSearch() throws {
        try store.save(frame("TPS reports 100% _literal 会议记录"));try store.save(frame("unrelated"))
        XCTAssertEqual(try store.frames(query:"TPS reports").count,1)
        XCTAssertEqual(try store.frames(query:"会议记录").count,1)
        XCTAssertEqual(try store.frames(query:"%").count,1)
        XCTAssertEqual(try store.frames(query:"_").count,1)
        XCTAssertEqual(try store.frames(query:"' OR 1=1 --").count,0)
    }
    func testFilterTrashRestoreAndPersistence() throws {
        let old = frame("old",app:"Word",time:Date().addingTimeInterval(-86400));let recent = frame("new")
        try store.save(old);try store.save(recent)
        XCTAssertEqual(try store.frames(app:"Word").map(\.id),[old.id])
        XCTAssertEqual(try store.frames(limit:1,ascending:true).first?.id,old.id)
        XCTAssertEqual(try store.appNames(demo:false,trash:false,since:nil),["Chrome","Word"])
        XCTAssertEqual(try store.frames(since:Date().addingTimeInterval(-60)).map(\.id),[recent.id])
        try store.moveToTrash(recent);XCTAssertEqual(try store.frames().count,1);XCTAssertEqual(try store.frames(trash:true).count,1)
        try store.restore(recent);store = nil;store = try MemoryStore(root:root);XCTAssertEqual(try store.frames().count,2)
    }
    func testTranscriptSearchUsesTimeAndSession() throws {
        let now = Date();var a = frame("slide",time:now);a.sessionID = "meeting"
        var b = frame("slide",time:now.addingTimeInterval(60));b.sessionID = "meeting"
        try store.save(a);try store.save(b)
        try store.saveTranscript(TranscriptLine(sessionID:"meeting",timestamp:now,speaker:"Audio",text:"cover sheet"))
        XCTAssertEqual(try store.frames(query:"cover sheet").map(\.id),[a.id])
        try store.replaceTranscript(sessionID:"meeting",lines:[TranscriptLine(sessionID:"meeting",timestamp:now,speaker:"Audio",text:"cover sheet revised")])
        XCTAssertEqual(try store.transcript("meeting").count,1)
        try store.moveToTrash(a);XCTAssertTrue(try store.frames(query:"cover sheet").isEmpty)
    }
    func testRetentionPreservesStarsAndRetrievalScope() throws {
        var a = frame("report",time:Date().addingTimeInterval(-86400*40));a.starred = true
        let b = frame("report",time:Date().addingTimeInterval(-86400*40));var c = frame("report");c.demo = true
        try store.save(a);try store.save(b);try store.save(c);try store.applyRetention(days:30)
        XCTAssertEqual(try store.frames(demo:false).map(\.id),[a.id]);XCTAssertEqual(try store.frames(trash:true).map(\.id),[b.id])
        XCTAssertEqual(try store.retrieve("report",demo:false).map(\.id),[a.id])
    }
    func testProviderValidationAndLinks() throws {
        XCTAssertEqual(try ModelClient.endpoint(ModelProfile(),path:"models").absoluteString,"http://127.0.0.1:11434/v1/models")
        XCTAssertThrowsError(try ModelClient.endpoint(ModelProfile(baseURL:"https://example.com/v1"),path:"models"))
        XCTAssertThrowsError(try ModelClient.endpoint(ModelProfile(baseURL:"http://example.com/v1",isLocal:false),path:"models"))
        XCTAssertTrue(LinkDetector.links(in:"file:///etc/passwd javascript:alert(1)").isEmpty)
        XCTAssertEqual(LinkDetector.links(in:"Visit https://example.com/report").first?.host,"example.com")
    }
    func testEmptyTrashPreservesSharedRecordingAndClearsUnusedMedia() throws {
        var a = frame("remove"),b = frame("keep");a.sessionID = "shared";b.sessionID = "shared";a.imagePath = "frames/a.jpg";b.imagePath = "frames/b.jpg"
        let video = "recordings/shared.mp4";try store.saveSession(RecordingSession(id:"shared",startedAt:Date(),endedAt:Date(),videoPath:video,appName:"Test",hasAudio:false))
        for path in [a.imagePath,b.imagePath,video] {try Data([1,2,3]).write(to:root.appendingPathComponent(path))}
        try store.save(a);try store.save(b);try store.moveToTrash(a)
        XCTAssertEqual(try store.emptyTrash(),1);XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(a.imagePath).path));XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(video).path))
        try store.moveToTrash(b);XCTAssertEqual(try store.emptyTrash(),1);XCTAssertNil(try store.session("shared"));XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(video).path))
    }
    @MainActor func testNativeOCRCoordinates() async throws {
        let image = NSImage(size:NSSize(width:1000,height:240));image.lockFocusFlipped(true)
        NSColor.white.setFill();NSRect(x:0,y:0,width:1000,height:240).fill()
        ("TPS reports 2026" as NSString).draw(at:NSPoint(x:50,y:50),withAttributes:[.font:NSFont.systemFont(ofSize:48),.foregroundColor:NSColor.black])
        ("会议记录" as NSString).draw(at:NSPoint(x:50,y:125),withAttributes:[.font:NSFont.systemFont(ofSize:40),.foregroundColor:NSColor.black])
        image.unlockFocus();var rect = NSRect(origin:.zero,size:image.size);let cg = image.cgImage(forProposedRect:&rect,context:nil,hints:nil)!
        let result = try await Task.detached {try NativeOCR.recognize(cg)}.value
        XCTAssertTrue(result.0.localizedCaseInsensitiveContains("TPS reports"),"OCR output: \(result.0)")
        XCTAssertTrue(result.0.contains("会议记录"),"OCR output: \(result.0)")
        for region in result.1 {XCTAssertGreaterThanOrEqual(region.x,0);XCTAssertLessThanOrEqual(region.x+region.width,1);XCTAssertGreaterThanOrEqual(region.y,0);XCTAssertLessThanOrEqual(region.y+region.height,1)}
    }
}

final class ModelMockProtocol: URLProtocol {
    static var handler: ((URLRequest)throws->(Int,Data))!
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {do {let (status,data) = try Self.handler(request);client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)} catch {client?.urlProtocol(self,didFailWithError:error)}}
    override func stopLoading() {}
}
final class ModelContractTests: XCTestCase {
    var original:URLSession!
    override func setUp() {original = ModelClient.session;let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [ModelMockProtocol.self];ModelClient.session = URLSession(configuration:config)}
    override func tearDown() {ModelClient.session.invalidateAndCancel();ModelClient.session = original}
    func testModelsAndChatUseConfiguredEndpoint() async throws {
        ModelMockProtocol.handler = {request in
            if request.url!.path.hasSuffix("models") {return(200,Data(#"{"data":[{"id":"local-test"}]}"#.utf8))}
            XCTAssertEqual(request.url!.path,"/v1/chat/completions");XCTAssertEqual(request.httpMethod,"POST")
            return(200,Data(#"{"choices":[{"message":{"content":"Use the cover sheet [1]."}}]}"#.utf8))
        }
        let names = try await ModelClient.models(profile:ModelProfile(),key:"");XCTAssertEqual(names,["local-test"])
        let answer = try await ModelClient.answer(question:"Which sheet?",sources:[],transcripts:[],history:[],profile:ModelProfile(),key:"")
        XCTAssertTrue(answer.contains("[1]"))
    }
    func testTranscriptionTimestampsAndErrors() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".m4a");try Data([1,2,3]).write(to:file);defer{try? FileManager.default.removeItem(at:file)}
        ModelMockProtocol.handler = {_ in (200,Data(#"{"segments":[{"start":12.5,"text":"Meeting note"}]}"#.utf8))}
        let time = Date();let lines = try await ModelClient.transcribe(file:file,sessionID:"s",start:time,profile:ModelProfile(),key:"")
        XCTAssertEqual(lines[0].timestamp.timeIntervalSince(time),12.5,accuracy:0.01)
        ModelMockProtocol.handler = {_ in (401,Data(#"{"error":{"message":"Unauthorized"}}"#.utf8))}
        do {_ = try await ModelClient.models(profile:ModelProfile(),key:"");XCTFail("Expected HTTP error")} catch {XCTAssertTrue(error.localizedDescription.contains("401"))}
    }
}
