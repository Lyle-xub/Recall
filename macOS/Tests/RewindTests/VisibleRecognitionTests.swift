import XCTest
import AppKit
import Combine
@testable import Rewind

final class VisibleRecognitionTests:XCTestCase {
    @MainActor func testSavedScreenAndQueuedSpeechFinishWhileInterfaceStaysOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:800,pixelsHigh:220,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill();NSRect(x:0,y:0,width:800,height:220).fill()
        ("Recall background indexing 81742" as NSString).draw(at:NSPoint(x:30,y:90),withAttributes:[.font:NSFont.systemFont(ofSize:36),.foregroundColor:NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let path = "frames/saved-screen.png"
        try ScreenArchive.saveSource(bitmap.cgImage!,to:root.appendingPathComponent(path))
        var frame = MemoryFrame(timestamp:Date(),appName:"Test",bundleID:"test",title:"Saved before opening",imagePath:path,text:"",regions:[],indexingComplete:false)
        try store.save(frame)

        // Exercise the real queue and database with a deterministic speech API;
        // no microphone, screen recording, remote server or model download.
        var settings = AppSettings();settings.transcriptionEnabled = true
        settings.transcription = ModelProfile(provider:"Test",baseURL:"http://127.0.0.1/v1",model:"test",isLocal:true)
        try JSONEncoder().encode(settings).write(to:root.appendingPathComponent("settings.json"))
        var sessions:[RecordingSession] = []
        for index in 0..<2 {
            let audio = "recordings/saved-\(index).m4a"
            try Data("test speech payload".utf8).write(to:root.appendingPathComponent(audio))
            let session = RecordingSession(startedAt:Date().addingTimeInterval(-10),endedAt:Date(),videoPath:"recordings/no-video-\(index).mp4",appName:"Test",hasAudio:true,systemAudioPath:audio)
            try store.saveSession(session);sessions.append(session)
        }
        try JSONEncoder().encode(sessions.map(\.id)).write(to:root.appendingPathComponent("pending-transcriptions.json"))
        frame.sessionID = sessions[0].id;try store.save(frame)
        let config = URLSessionConfiguration.ephemeral;config.protocolClasses = [SavedSpeechProtocol.self]
        let previous = ModelClient.session, transport = URLSession(configuration:config)
        ModelClient.session = transport
        defer { ModelClient.session = previous;transport.invalidateAndCancel() }

        let model = try AppModel(root:root)
        model.select(frame)
        model.interfaceVisibilityChanged(true)
        await model.startRecording()
        XCTAssertTrue(model.recordingAutomaticallyPaused)
        XCTAssertFalse(model.recording,"Opening Recall must not start capture")
        let screenDone = expectation(description:"Saved screenshot indexed while open")
        let speechDone = expectation(description:"Both queued recordings transcribed while open")
        let originalCallback = model.capture.onIndexed
        model.capture.onIndexed = { saved in
            originalCallback?(saved)
            if saved.id == frame.id {
                XCTAssertTrue(model.screenRecognition.active,"Index commit belongs to the active operation")
                XCTAssertEqual(model.recognitionActivity[.image(frame.id)],.processing)
                XCTAssertEqual(model.selected?.indexingComplete,true)
                screenDone.fulfill()
            }
        }
        var speechRan = false
        let observer = model.$speechRecognition.sink { progress in
            speechRan = speechRan || progress.active
            if speechRan && !progress.active && progress.pending > 0 {
                XCTAssertGreaterThan((try? store.transcript(sessions[0].id).count) ?? 0,0,"Do not publish idle between inference and saving its result")
            }
            if speechRan && progress.pending == 0 { speechDone.fulfill() }
        }
        await fulfillment(of:[screenDone,speechDone],timeout:25)
        observer.cancel()
        XCTAssertTrue(model.recordingAutomaticallyPaused)
        XCTAssertFalse(model.recording)
        XCTAssertEqual(try store.count(demo:false),1,"Recognition must not create captures")
        XCTAssertTrue(try XCTUnwrap(store.frame(frame.id)).text.contains("81742"))
        for session in sessions {
            XCTAssertEqual(try store.transcript(session.id).map(\.text),["Saved audio continues while Recall is open."])
        }
        XCTAssertEqual(model.speechRecognition.pending,0)
        XCTAssertFalse(model.speechRecognition.active)
        let current = RecognitionStatusSnapshot.current(frame:try XCTUnwrap(model.selected),video:false,meeting:false,activity:model.recognitionActivity,recording:model.recordingDetail,speechEnabled:true)
        XCTAssertEqual(current.text,.complete);XCTAssertEqual(current.speech,.complete)
        XCTAssertEqual(try store.recognitionOutcome(sessions[0].id),.complete)
        await model.stopRecording()
        // Release any unfinished work if an assertion fails, without arming capture.
        model.interfaceVisibilityChanged(false)
        await model.storageOptimizer.stop()
    }
}

private final class SavedSpeechProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { request.url?.host == "127.0.0.1" }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(#"{"segments":[{"start":0,"text":"Saved audio continues while Recall is open."}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
