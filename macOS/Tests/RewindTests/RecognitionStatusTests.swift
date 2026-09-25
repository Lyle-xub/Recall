import XCTest
import Combine
@testable import Rewind

final class RecognitionStatusTests:XCTestCase {
    @MainActor func testTransientQueueAndIdleNeverReachVisibleStatus() async throws {
        let presenter = RecognitionStatusPresentation(delay:.milliseconds(35))
        let running = RecognitionStatusSnapshot(contextID:"image-A",text:.processing)
        var seen:[RecognitionStatusSnapshot] = []
        let observer = presenter.$snapshot.compactMap { $0 }.sink { seen.append($0) }
        presenter.receive(running)
        presenter.receive(RecognitionStatusSnapshot(contextID:"image-A",text:.queued))
        try await Task.sleep(for:.milliseconds(5));presenter.receive(running)
        presenter.receive(RecognitionStatusSnapshot(contextID:"image-A",text:.complete))
        try await Task.sleep(for:.milliseconds(5));presenter.receive(running)
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertTrue(seen.allSatisfy { $0.text == .processing })
        presenter.receive(RecognitionStatusSnapshot(contextID:"image-A",text:.complete))
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertEqual(presenter.snapshot?.text,.complete,"Completion must not stay stuck on processing")
        observer.cancel();presenter.cancel()
    }
    @MainActor func testErrorsImmediateButNeverFollowAnotherSelection() async throws {
        let presenter = RecognitionStatusPresentation(delay:.milliseconds(35))
        let running = RecognitionStatusSnapshot(contextID:"image-A",speech:.processing)
        presenter.receive(running)
        let failure = RecognitionStatusSnapshot(contextID:"image-A",speech:.failed("Audio needs attention"))
        presenter.receive(failure)
        XCTAssertEqual(presenter.snapshot,failure)
        presenter.receive(RecognitionStatusSnapshot(contextID:"image-A",speech:.complete));presenter.cancel()
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertEqual(presenter.snapshot,failure,"A dismissed view must not apply a delayed transition")
        let other = RecognitionStatusSnapshot(contextID:"image-B",text:.queued)
        presenter.receive(other)
        XCTAssertEqual(presenter.snapshot,other,"Selection changes must bypass debounce immediately")
        try await Task.sleep(for:.milliseconds(60))
        XCTAssertEqual(presenter.snapshot,other,"An old completion must not overwrite the new selection")
    }
    @MainActor func testActivityBelongsOnlyToDisplayedImageAndRecording() {
        let activity = RecognitionActivity()
        let a = MemoryFrame(id:"a",timestamp:Date(),appName:"A",bundleID:"a",title:"A",imagePath:"a.png",text:"Ready",regions:[],sessionID:"audio-a",indexingComplete:true)
        var b = a;b.id = "b";b.sessionID = "audio-b";b.text = "";b.indexingComplete = false
        let recording = RecordingRecognitionDetail(sessionID:"audio-a",session:nil,transcript:TranscriptPage([]),outcome:.complete)
        func state(_ frame:MemoryFrame,video:Bool = false,meeting:Bool = false)->RecognitionStatusSnapshot {
            .current(frame:frame,video:video,meeting:meeting,activity:activity,recording:recording,speechEnabled:true)
        }
        activity.set(.processing,for:.image("b"));activity.set(.failed("Only B failed"),for:.recording("audio-b"))
        XCTAssertEqual(state(a).text,.complete);XCTAssertEqual(state(a).speech,.complete)
        XCTAssertEqual(state(b).text,.processing);XCTAssertEqual(state(b).speech,.failed("Only B failed"))
        activity.set(.queued,for:.image("b"))
        XCTAssertEqual(state(a).text,.complete);XCTAssertEqual(state(b).text,.queued)
        XCTAssertNil(state(a,video:true).text,"Video is not sent to OCR")
        XCTAssertEqual(state(a,video:true).speech,.complete)
        b.sessionID = nil
        XCTAssertNil(state(b).speech,"Standalone images have no speech badge")
        b.meetingImagePath = "meeting.png"
        XCTAssertEqual(state(b,meeting:true).text,.empty,"Meeting image status cannot inherit desktop OCR activity")
    }
    func testRecordingOutcomesSurviveReloadAndDistinguishSilenceNoAudioAndLegacy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        let session = RecordingSession(startedAt:Date(),endedAt:Date(),videoPath:"video.mp4",appName:"Test",hasAudio:true)
        try store.saveSession(session)
        XCTAssertEqual(try RecordingRecognitionDetail.load(session.id,store:store).state(enabled:true),.notProcessed)
        XCTAssertEqual(try RecordingRecognitionDetail.load(session.id,store:store).state(enabled:false),.disabled)
        try store.replaceTranscript(sessionID:session.id,lines:[])
        let reader = try MemoryStore(root:root,readOnly:true)
        XCTAssertEqual(try RecordingRecognitionDetail.load(session.id,store:reader).state(enabled:true),.empty)
        try store.saveRecognitionOutcome(session.id,state:.failed("Test failure"))
        XCTAssertEqual(try RecordingRecognitionDetail.load(session.id,store:reader).state(enabled:true),.failed("Test failure"))
        try store.replaceTranscript(sessionID:session.id,lines:[TranscriptLine(sessionID:session.id,timestamp:Date(),speaker:"Audio",text:"Recovered result")])
        XCTAssertEqual(try RecordingRecognitionDetail.load(session.id,store:reader).state(enabled:false),.complete)
        let silent = RecordingSession(startedAt:Date(),endedAt:Date(),videoPath:"silent.mp4",appName:"Test",hasAudio:false)
        try store.saveSession(silent)
        XCTAssertEqual(try RecordingRecognitionDetail.load(silent.id,store:reader).state(enabled:true),.noAudio)
        try store.saveRecognitionOutcome("deleted-session",state:.complete)
        XCTAssertNil(try store.recognitionOutcome("deleted-session"),"Late recognition cannot recreate deleted metadata")
    }
}
