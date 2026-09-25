import XCTest
@testable import Rewind

final class SearchLogicTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);store = try MemoryStore(root:root) }
    override func tearDownWithError() throws { store = nil;try FileManager.default.removeItem(at:root) }
    private func frame(_ text:String,app:String = "Notes",title:String = "Window",time:Double = 100) -> MemoryFrame {
        MemoryFrame(timestamp:Date(timeIntervalSince1970:time),appName:app,bundleID:app,title:title,imagePath:"",text:text,regions:[])
    }
    func testOlderObsidianPaperSurvivesMoreThanTwoHundredNewerMatches() throws {
        let obsidian = frame("Papers: research notes",app:"Obsidian",time:1);try store.save(obsidian)
        for i in 0..<240 { try store.save(frame("paper mention \(i)",app:"ChatGPT",time:Double(i+100))) }
        let first = try store.frames(query:"paper",demo:false,limit:200)
        XCTAssertTrue(first.prefix(2).contains { $0.id == obsidian.id })
        XCTAssertTrue(try store.frames(query:"papers",limit:200).contains { $0.id == obsidian.id })
        let rest = try store.frames(query:"paper",limit:200,offset:200)
        XCTAssertEqual(Set((first+rest).map(\.id)).count,241)
        XCTAssertEqual(rest.count,41)
        let request = MemorySearchQuery(query:"paper",app:nil,starred:false,trash:false,since:nil,limit:200)
        XCTAssertTrue(try MemorySearchPage.load(request,store:store).hasMore)
    }
    func testWordsCanBeReorderedAndSplitByOCRNewlines() throws {
        let hit = frame("Paper\nmethods, preliminary research results");try store.save(hit)
        XCTAssertEqual(try store.frames(query:"research papers").map(\.id),[hit.id])
        XCTAssertTrue(try store.frames(query:"\"research papers\"").isEmpty)
        XCTAssertTrue(try store.frames(query:"research unknown").isEmpty)
        XCTAssertEqual(try store.frames(query:"PAPER").map(\.id),[hit.id])
    }
    func testPluralAccentsAndCJK() throws {
        let hit = frame("A study of café design. 会议记录与研究资料");try store.save(hit)
        XCTAssertEqual(try store.frames(query:"studies cafe").map(\.id),[hit.id])
        XCTAssertEqual(try store.frames(query:"研究 会议").map(\.id),[hit.id])
        XCTAssertEqual(try store.frames(query:"Notes").map(\.id),[hit.id])
        XCTAssertTrue(MemorySearchPlan("studies cafe").highlights("A study"))
        XCTAssertTrue(MemorySearchPlan("studies cafe").highlights("café"))
        XCTAssertFalse(MemorySearchPlan("").highlights("anything"))
    }
    func testRankedSearchPreservesScopeAndTitleRelevance() throws {
        var old = frame("content",app:"Obsidian",title:"Papers",time:1);old.starred = true;try store.save(old)
        try store.save(frame("paper",app:"Obsidian",time:2))
        var demo = frame("paper",app:"Demo");demo.demo = true;try store.save(demo)
        let deleted = frame("paper",app:"Trash");try store.save(deleted);try store.moveToTrash(deleted)
        XCTAssertEqual(try store.frames(query:"paper",app:"Obsidian").first?.id,old.id)
        XCTAssertEqual(try store.frames(query:"paper",starred:true).map(\.id),[old.id])
        XCTAssertEqual(try store.frames(query:"paper",trash:true).map(\.id),[deleted.id])
        XCTAssertEqual(try store.frames(query:"paper",since:Date(timeIntervalSince1970:2),demo:false).count,1)
    }
    func testRetrievalRejectsUnrelatedFallbackAndDeduplicatesSources() throws {
        try store.save(frame("unrelated",time:200))
        for i in 0..<10 { try store.save(frame("Research papers on quantum optics",app:"Obsidian",time:Double(i+1))) }
        XCTAssertTrue(try store.retrieve("Where is the unicornbanana?").isEmpty)
        XCTAssertEqual(try store.retrieve("Find my research papers").count,1)
        XCTAssertEqual(try store.retrieve("Tell me more about that",previous:"Find my research papers").first?.appName,"Obsidian")
        XCTAssertFalse(try store.retrieve("Summarize my recent work").isEmpty)
    }
    func testEvidenceOnlyIncludesNearbyTranscriptAndKeepsMatchingPassage() throws {
        var hit = frame("quantum optics",time:100);hit.sessionID = "s";try store.save(hit)
        try store.saveTranscript(.init(sessionID:"s",timestamp:Date(timeIntervalSince1970:100),speaker:"Audio",text:"quantum discussion"))
        try store.saveTranscript(.init(sessionID:"s",timestamp:Date(timeIntervalSince1970:900),speaker:"Audio",text:"unrelated meeting"))
        let evidence = try store.evidence("quantum",since:nil,app:nil,previous:nil,limit:5)
        XCTAssertEqual(evidence.transcripts.count,1)
        let excerpt = RecallExcerpt.text(String(repeating:"header ",count:1000)+"quantum optics result",question:"quantum",limit:500)
        XCTAssertTrue(excerpt.contains("quantum optics result"));XCTAssertLessThanOrEqual(excerpt.count,502)
    }
    func testChineseIntentAndExplicitDayScopes() throws {
        XCTAssertTrue(RecallQuestion("总结我今天的工作").broad)
        XCTAssertTrue(RecallQuestion("请帮我找到研究论文").terms.contains("论文"))
        let now = Date(), yesterday = Calendar.current.startOfDay(for:now).addingTimeInterval(-10)
        try store.save(frame("daymarker",time:yesterday.timeIntervalSince1970))
        try store.save(frame("daymarker",time:now.addingTimeInterval(-1).timeIntervalSince1970))
        XCTAssertEqual(try store.retrieve("Find daymarker today").count,1)
        XCTAssertEqual(try store.retrieve("Find daymarker yesterday").first?.timestamp,yesterday)
    }
    @MainActor func testRetryAfterPartialFailurePreservesEarlierConversation() throws {
        let model = try AppModel(root:root)
        let earlier = ChatMessage(role:"user",text:"Earlier question")
        model.messages = [earlier,ChatMessage(role:"assistant",text:"Earlier answer"),ChatMessage(role:"user",text:"research papers"),ChatMessage(role:"assistant",text:"Partial answer before a network failure")]
        model.askError = "Connection interrupted"
        model.retryAsk()
        XCTAssertTrue(model.asking)
        XCTAssertEqual(model.messages.count,3)
        XCTAssertEqual(model.messages.first?.id,earlier.id)
        XCTAssertEqual(model.messages.last?.text,"research papers")
        XCTAssertNil(model.askError)
        model.cancelAsk()
    }
    func testExistingLibraryReadOnlySearch() throws {
        guard let path = ProcessInfo.processInfo.environment["RECALL_LIVE_LIBRARY"] else { throw XCTSkip("Optional existing-library read-only check") }
        let db = try MemoryStore(root:URL(fileURLWithPath:path),readOnly:true)
        let start = Date(), rows = try db.frames(query:"paper",demo:false,limit:200)
        XCTAssertTrue(rows.contains { $0.appName == "Obsidian" })
        print("Live library: paper returned \(rows.count) results across \(Set(rows.map(\.appName)).count) apps in \(Date().timeIntervalSince(start)) seconds; Obsidian present.")
    }
}

final class UsageReportTests:XCTestCase {
    var calendar:Calendar { var c = Calendar(identifier:.gregorian);c.timeZone = TimeZone(identifier:"America/Los_Angeles")!;c.firstWeekday = 1;return c }
    private func date(_ y:Int = 2026,_ m:Int = 9,_ d:Int = 25,_ h:Int = 0,_ minute:Int = 0) -> Date {
        calendar.date(from:DateComponents(year:y,month:m,day:d,hour:h,minute:minute))!
    }
    private func interval(_ name:String,_ start:Date,_ end:Date,kind:AppUsageKind = .application) -> AppUsageInterval {
        .init(app:.init(name:name,bundleID:kind == .excluded ? "":name,kind:kind),start:start,end:end)
    }
    func testCrossMidnightAndHourlyConservation() {
        let rows = [interval("Notes",date(2026,9,24,23,30),date(2026,9,25,1,30))]
        let report = UsageReport.build(rows,date:date(),now:date(2026,9,26),calendar:calendar)
        XCTAssertEqual(report.total,5400)
        XCTAssertEqual(report.hours.map(\.seconds).reduce(0,+),report.total)
        XCTAssertEqual(report.days.map(\.seconds).reduce(0,+),7200)
        XCTAssertEqual(report.hours[0].seconds,3600);XCTAssertEqual(report.hours[1].seconds,1800)
    }
    func testOverlapsAndDuplicateIntervalsNeverDoubleCount() {
        let a = interval("A",date(2026,9,25,1),date(2026,9,25,4))
        let b = interval("B",date(2026,9,25,2),date(2026,9,25,3))
        let report = UsageReport.build([a,a,b],date:date(),now:date(2026,9,26),calendar:calendar)
        XCTAssertEqual(report.total,10800)
        XCTAssertEqual(report.apps.first(where:{$0.id == "A"})?.seconds,7200)
        XCTAssertEqual(report.apps.first(where:{$0.id == "B"})?.seconds,3600)
    }
    func testNowClampGapsUnavailableAndPrivacy() {
        let rows = [interval("A",date(2026,9,25,0),date(2026,9,25,2)),
                    interval("unavailable",date(2026,9,25,1),date(2026,9,25,2),kind:.unavailable),
                    interval("Private activity",date(2026,9,25,3),date(2026,9,25,5),kind:.excluded)]
        let report = UsageReport.build(rows,date:date(),now:date(2026,9,25,4),calendar:calendar)
        XCTAssertEqual(report.total,7200)
        XCTAssertEqual(report.apps.first(where:{$0.id == "private"})?.seconds,3600)
        XCTAssertEqual(report.hours[1].seconds,0);XCTAssertEqual(report.hours[2].seconds,0)
        XCTAssertFalse(report.apps.contains { $0.app.kind == .unavailable })
    }
    func testDaylightSavingUsesActualDayLength() {
        for (month,day,hours) in [(3,8,23),(11,1,25)] {
            let start = date(2026,month,day),end = calendar.date(byAdding:.day,value:1,to:start)!
            let report = UsageReport.build([interval("A",start,end)],date:start,now:end,calendar:calendar)
            XCTAssertEqual(report.hours.count,hours)
            XCTAssertEqual(report.total,Double(hours)*3600)
            XCTAssertEqual(report.hours.map(\.seconds).reduce(0,+),report.total)
            XCTAssertEqual(Set(report.hours.map(\.id)).count,hours)
        }
    }
    func testEmptyDayAndInvalidIntervals() {
        let report = UsageReport.build([interval("A",date(2026,9,25,2),date(2026,9,25,1))],date:date(),now:date(2026,9,26),calendar:calendar)
        XCTAssertEqual(report.total,0);XCTAssertEqual(report.dailyAverage,0);XCTAssertTrue(report.apps.isEmpty)
    }
}

final class RecallChatIntegrationTests:XCTestCase {
    func testInstalledChatAnswersRetrievedEvidence() async throws {
        guard ProcessInfo.processInfo.environment["RECALL_CHAT_TEST"] == "1" else { throw XCTSkip("Optional installed local chat model check") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        try store.save(MemoryFrame(timestamp:Date(),appName:"Notes",bundleID:"test",title:"Project budget",imagePath:"",text:String(repeating:"Routine log entry. ",count:200)+"The agreed project budget is 42 dollars.",regions:[]))
        let evidence = try store.evidence("What is the project budget?",since:nil,app:nil,previous:nil,limit:5)
        XCTAssertEqual(evidence.sources.count,1)
        do {
            let answer = try await ModelClient.answer(question:"What is the project budget? Cite the source.",sources:evidence.sources,transcripts:evidence.transcripts,history:[],profile:.builtinChat,key:"") { partial in XCTAssertFalse(partial.isEmpty) }
            XCTAssertTrue(answer.contains("42"));XCTAssertTrue(answer.contains("[1]"))
            await LocalInference.shared.stop()
        } catch { await LocalInference.shared.stop(); throw error }
    }
}
