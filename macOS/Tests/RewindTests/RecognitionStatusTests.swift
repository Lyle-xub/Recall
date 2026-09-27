import XCTest
import Combine
@testable import Rewind

final class RecognitionStatusTests:XCTestCase {
    @MainActor func testTransientQueueAndIdleNeverReachVisibleStatus() async throws {
        let clock=RecognitionTransitionClock(count:5)
        let presenter = RecognitionStatusPresentation(delay:.milliseconds(35),waitForTransition:{await clock.wait($0)})
        let running = RecognitionStatusSnapshot(contextID:"image-A",text:.processing)
        var seen:[RecognitionStatusSnapshot] = []
        let observer = presenter.$snapshot.compactMap { $0 }.sink { seen.append($0) }
        defer {observer.cancel();presenter.cancel()}
        presenter.receive(running)
        let transient:[MediaRecognitionState]=[.queued,.processing,.complete,.processing]
        var pending:[Task<Void,Never>]=[]
        for (index,state) in transient.enumerated() {
            presenter.receive(RecognitionStatusSnapshot(contextID:"image-A",text:state))
            pending.append(try XCTUnwrap(presenter.pendingTransition))
            await fulfillment(of:[clock.started[index]],timeout:2)
        }
        // Release even cancelled waits: obsolete callbacks must be harmless,
        // regardless of execution order or the host's wall-clock scheduling.
        for (index,task) in pending.enumerated() {await clock.release(index);await task.value}
        XCTAssertTrue(seen.allSatisfy { $0.text == .processing })
        presenter.receive(RecognitionStatusSnapshot(contextID:"image-A",text:.complete))
        let completion=try XCTUnwrap(presenter.pendingTransition)
        await fulfillment(of:[clock.started[4]],timeout:2)
        await clock.release(4);await completion.value
        XCTAssertEqual(presenter.snapshot?.text,.complete,"Completion must not stay stuck on processing")
    }
    @MainActor func testErrorsImmediateButNeverFollowAnotherSelection() async throws {
        let clock=RecognitionTransitionClock(count:2)
        let presenter = RecognitionStatusPresentation(delay:.milliseconds(35),waitForTransition:{await clock.wait($0)})
        defer {presenter.cancel()}
        let running = RecognitionStatusSnapshot(contextID:"image-A",speech:.processing)
        presenter.receive(running)
        let failure = RecognitionStatusSnapshot(contextID:"image-A",speech:.failed("Audio needs attention"))
        presenter.receive(failure)
        XCTAssertEqual(presenter.snapshot,failure)
        let complete=RecognitionStatusSnapshot(contextID:"image-A",speech:.complete)
        presenter.receive(complete)
        let dismissed=try XCTUnwrap(presenter.pendingTransition)
        await fulfillment(of:[clock.started[0]],timeout:2)
        presenter.cancel();await clock.release(0);await dismissed.value
        XCTAssertEqual(presenter.snapshot,failure,"A dismissed view must not apply a delayed transition")
        presenter.receive(complete)
        let obsolete=try XCTUnwrap(presenter.pendingTransition)
        await fulfillment(of:[clock.started[1]],timeout:2)
        let other = RecognitionStatusSnapshot(contextID:"image-B",text:.queued)
        presenter.receive(other)
        XCTAssertEqual(presenter.snapshot,other,"Selection changes must bypass debounce immediately")
        await clock.release(1);await obsolete.value
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

private actor RecognitionTransitionClock {
    let started:[XCTestExpectation]
    private var pending:[Int:CheckedContinuation<Void,Never>]=[:]
    private var next=0
    init(count:Int) {started=(0..<count).map {XCTestExpectation(description:"Transition \($0) is waiting")}}
    func wait(_ delay:Duration)async {
        let index=next;next += 1
        await withCheckedContinuation {pending[index]=$0;started[index].fulfill()}
    }
    func release(_ index:Int) {pending.removeValue(forKey:index)?.resume()}
}
