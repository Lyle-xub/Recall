import XCTest
@testable import Rewind

final class TranscriptTests: XCTestCase {
    private func line(_ text:String, _ speaker:String = "Meeting", _ second:Double = 0) -> TranscriptLine {
        TranscriptLine(sessionID:"s",timestamp:Date(timeIntervalSince1970:second),speaker:speaker,text:text)
    }
    func testSingleSourceHasOneSideAndPreservesWords() {
        for speaker in ["You","Meeting","Audio","Speaker 1"] {
            let input = [line("A single person is speaking here.",speaker)]
            XCTAssertEqual(TranscriptPresentation.lines(input),input)
            XCTAssertFalse(TranscriptPresentation.usesTwoSides(input))
        }
    }
    func testMicrophoneEchoAcrossSentenceBoundariesIsHiddenWithoutChangingRawText() {
        let input = [line("Once rewind is installed you can open it by hitting command shift space.","Meeting",1),
                     line("You can type in anything you have seen.","Meeting",5),
                     line("Once rewind is installed you can open it by hitting command shift space. You can type in anything", "You",0)]
        let page = TranscriptPage(input)
        XCTAssertEqual(page.lines.count,2)
        XCTAssertEqual(page.original,input)
        XCTAssertEqual(Set(page.lines.map(\.speaker)),["Meeting"])
    }
    func testEchoDoesNotRemoveAnotherStatementOrLaterRepeat() {
        let input = [line("The project needs six more days to finish."),
                     line("The project needs ten more days to finish.","You",2),
                     line("Yes","You",3),
                     line("The project needs six more days to finish.","You",60)]
        XCTAssertEqual(TranscriptPresentation.lines(input).count,4)
        // These labels describe devices, not identified people.
        XCTAssertFalse(TranscriptPresentation.usesTwoSides(input))
        XCTAssertTrue(TranscriptPresentation.usesTwoSides([line("Hello","Speaker 1"),line("Hi","Speaker 2")]))
    }
    func testCJKAndPunctuationEcho() {
        let input = [line("今天讨论论文检索，时间线与本地模型。"),line("今天讨论论文检索时间线与本地模型","You",2)]
        XCTAssertEqual(TranscriptPresentation.lines(input).count,1)
    }
    func testUnrelatedSessionAndSilence() {
        var other = line("Here is an example of this feature.","You",2);other.sessionID = "other"
        let input = [line("Here is an example of this feature."), other, line("[BLANK_AUDIO]","You",3)]
        XCTAssertEqual(TranscriptPresentation.lines(input).count,2)
    }
    func testLongTranscriptProcessingIsBounded() {
        let input = (0..<1200).flatMap { i in
            [line("Here is sentence number \(i) with its own content.","Meeting",Double(i)*4),
             line("Here is sentence number \(i) with its own content.","You",Double(i)*4+0.2)]
        }
        let began = Date(), result = TranscriptPresentation.lines(input)
        XCTAssertEqual(result.count,1200)
        XCTAssertLessThan(Date().timeIntervalSince(began),3)
    }
    func testInstalledReferenceTranscriptReadOnly() throws {
        guard let root = ProcessInfo.processInfo.environment["RECALL_TRANSCRIPT_LIBRARY"],let session = ProcessInfo.processInfo.environment["RECALL_TRANSCRIPT_SESSION"] else { throw XCTSkip("Opt-in read-only installed-library check") }
        let store = try MemoryStore(root:URL(fileURLWithPath:root),readOnly:true)
        let source = try store.transcript(session), page = TranscriptPage(source)
        XCTAssertFalse(source.isEmpty)
        XCTAssertLessThan(page.lines.count,source.count)
        XCTAssertFalse(TranscriptPresentation.usesTwoSides(page.lines))
        XCTAssertEqual(try store.transcript(session),source)
        print("REFERENCE_TRANSCRIPT: original=\(source.count), displayed=\(page.lines.count), singleColumn=true, originalsUnchanged=true")
    }
    func testSpeechLeaseIncludesAwaitingPreparation() async throws {
        let gate = SpeechOperationGate(), counter = ActiveSpeechCounter()
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await gate.acquire()
                    await counter.enter()
                    try await Task.sleep(for:.milliseconds(3))
                    await counter.leave()
                    await gate.release()
                }
            }
            try await group.waitForAll()
        }
        let maximum = await counter.maximum
        XCTAssertEqual(maximum,1)
    }
    func testCancelledSpeechWaiterDoesNotBlockNextJob() async throws {
        let gate = SpeechOperationGate()
        try await gate.acquire()
        let cancelled = Task { try await gate.acquire(); await gate.release() }
        try await Task.sleep(for:.milliseconds(10));cancelled.cancel()
        do { try await cancelled.value; XCTFail("Waiting job must cancel") } catch is CancellationError { }
        await gate.release()
        try await gate.acquire();await gate.release()
    }
}
private actor ActiveSpeechCounter {
    private var active = 0
    var maximum = 0
    func enter() { active += 1; maximum = max(maximum,active) }
    func leave() { active -= 1 }
}
