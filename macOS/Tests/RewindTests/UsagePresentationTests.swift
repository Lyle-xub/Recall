import XCTest
@testable import Rewind

final class UsagePresentationTests:XCTestCase {
    private var calendar:Calendar {
        var value = Calendar(identifier:.gregorian)
        value.timeZone = TimeZone(identifier:"America/Los_Angeles")!; value.firstWeekday = 1
        return value
    }
    private func date(_ year:Int = 2026,_ month:Int = 9,_ day:Int = 25,_ hour:Int = 0,_ minute:Int = 0) -> Date {
        calendar.date(from:DateComponents(year:year,month:month,day:day,hour:hour,minute:minute))!
    }
    private func row(_ start:Date,_ end:Date,kind:AppUsageKind = .application) -> AppUsageInterval {
        AppUsageInterval(app:.init(name:kind == .excluded ? "Private activity":"Notes",bundleID:kind == .excluded ? "":"Notes",kind:kind),start:start,end:end)
    }
    private func report(_ day:Date) -> UsageReport { UsageReport.build([],date:day,now:date(2026,12,31),calendar:calendar) }

    func testNavigationLabelTracksTheSelectedDayAcrossYearAndDSTBoundaries() {
        let now = date(2026,1,1,0,15)
        XCTAssertEqual(UsageDateLabel.navigation(now,now:now,calendar:calendar),"Today")
        XCTAssertEqual(UsageDateLabel.navigation(date(2025,12,31),now:now,calendar:calendar),"Yesterday")
        XCTAssertEqual(UsageDateLabel.navigation(date(2025,12,30),now:now,calendar:calendar),"Dec 30, 2025")
        XCTAssertEqual(UsageDateLabel.navigation(date(2026,3,8),now:date(2026,3,9,0,15),calendar:calendar),"Yesterday")
        XCTAssertEqual(UsageDateLabel.navigation(date(2026,11,1),now:date(2026,11,2,0,15),calendar:calendar),"Yesterday")
    }
    func testCategoryPaletteAndSymbolsRemainDistinct() {
        let categories = UsageCategory.allCases
        XCTAssertEqual(Set(categories.map(\.symbol)).count,categories.count,"Icons distinguish categories without depending on color")
        for (index,a) in categories.enumerated() {
            for b in categories.dropFirst(index+1) {
                let x = a.rgb,y = b.rgb
                let distance = sqrt(pow(x.red-y.red,2)+pow(x.green-y.green,2)+pow(x.blue-y.blue,2))
                XCTAssertGreaterThan(distance,0.25,"\(a.rawValue) and \(b.rawValue) need distinct swatches")
            }
        }
    }
    func testRecordedDaysCrossMidnightAndMonthButExcludeEmptyBoundaries() {
        let january = calendar.dateInterval(of:.month,for:date(2026,1,31))!
        let february = calendar.dateInterval(of:.month,for:date(2026,2,1))!
        let rows = [row(date(2026,1,31,23,30),date(2026,2,1,1,30)),
                    row(date(2026,2,4,23),date(2026,2,5)),
                    row(date(2026,2,7),date(2026,2,7))]
        XCTAssertEqual(UsageReport.recordedDays(rows,in:january,now:date(2026,3,1),calendar:calendar),[date(2026,1,31)])
        XCTAssertEqual(UsageReport.recordedDays(rows,in:february,now:date(2026,3,1),calendar:calendar),[date(2026,2,1),date(2026,2,4)])
    }
    func testRecordedDaysRespectPrivateActivityUnavailableMaskingAndNow() {
        let range = calendar.dateInterval(of:.month,for:date())!
        let rows = [row(date(2026,9,1,23),date(2026,9,2,2)),
                    row(date(2026,9,2),date(2026,9,2,2),kind:.unavailable),
                    row(date(2026,9,3),date(2026,9,3,1),kind:.excluded),
                    row(date(2026,9,4),date(2026,9,4,1),kind:.unavailable),
                    row(date(2026,9,27),date(2026,9,28))]
        XCTAssertEqual(UsageReport.recordedDays(rows,in:range,now:date(),calendar:calendar),[date(2026,9,1),date(2026,9,3)])
    }
    func testRecordedDaysUseTheSelectedTimeZoneAndActualDSTDays() {
        let start = date(2026,9,25,23,30),end = date(2026,9,26,0,30)
        let range = DateInterval(start:date(2026,9,1),end:date(2026,10,1))
        let rows = [row(start,end)]
        XCTAssertEqual(UsageReport.recordedDays(rows,in:range,now:end,calendar:calendar),[date(2026,9,25),date(2026,9,26)])
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT:0)!
        XCTAssertEqual(UsageReport.recordedDays(rows,in:range,now:end,calendar:utc),[utc.startOfDay(for:start)])
        for (month,day) in [(3,8),(11,1)] {
            let first = date(2026,month,day),next = calendar.date(byAdding:.day,value:1,to:first)!
            XCTAssertEqual(UsageReport.recordedDays([row(first,next)],in:DateInterval(start:first,end:next),now:next,calendar:calendar),[first])
        }
    }
    func testRecordedDayQueryUsesUsageWithoutDependingOnScreenshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root)
        try store.save(MemoryFrame(timestamp:date(2026,9,2),appName:"Screenshot only",bundleID:"test",title:"",imagePath:"",text:"",regions:[]))
        try store.saveUsage(row(date(2026,9,3),date(2026,9,3,1),kind:.excluded))
        let days = try await UsageDataSource().recordedDays(root:root,month:date(),calendar:calendar,now:date(2026,10,1))
        XCTAssertEqual(days,[date(2026,9,3)])
    }
    @MainActor func testOutOfOrderLoadsCannotReplaceTheLatestSelection() async {
        let first = date(),second = date(2026,9,26),third = date(2026,9,27)
        let state = UsageReportState(date:first,calendar:calendar),loader = ControlledUsageLoader()
        let initial = report(first)
        await state.load { _ in initial }
        state.select(second,calendar:calendar)
        let old = Task { await state.load { try await loader.load($0) } }
        await loader.waitForRequests(1)
        XCTAssertEqual(state.report?.day.start,first,"The previous chart remains visible with its own report date")
        state.select(third,calendar:calendar)
        let latest = Task { await state.load { try await loader.load($0) } }
        await loader.waitForRequests(2)
        await loader.finish(1,with:report(third)); await latest.value
        await loader.finish(0,with:report(second)); await old.value
        XCTAssertEqual(state.selectedDay,third); XCTAssertEqual(state.report?.day.start,third)
        XCTAssertFalse(state.loading); XCTAssertNil(state.error)
    }
    @MainActor func testCancelledLoadAndLateErrorKeepReportAttribution() async {
        let first = date(),second = date(2026,9,26)
        let state = UsageReportState(date:first,calendar:calendar),loader = ControlledUsageLoader()
        let initial = report(first)
        await state.load { _ in initial }
        state.select(second,calendar:calendar)
        let cancelled = Task { await state.load { try await loader.load($0) } }
        await loader.waitForRequests(1); cancelled.cancel()
        await loader.finish(0,with:report(second)); await cancelled.value
        XCTAssertEqual(state.report?.day.start,first)
        await state.load { _ in throw UsageTestError.failed }
        XCTAssertEqual(state.selectedDay,second); XCTAssertEqual(state.report?.day.start,first)
        XCTAssertNotNil(state.error); XCTAssertFalse(state.loading)
        let pending = Task { await state.load { _ in initial } }
        pending.cancel(); await pending.value
        XCTAssertNotNil(state.error,"An already cancelled request cannot reset the latest error")
        XCTAssertFalse(state.loading,"An already cancelled request cannot restart the loading indicator")
        state.select(first,calendar:calendar)
        XCTAssertEqual(state.report?.day.start,first,"Previously loaded dates are restored from cache immediately")
        XCTAssertNil(state.error)
    }
    @MainActor func testLateFailureDoesNotOverwriteNewSuccessAndMisdatedReportsAreRejected() async {
        let first = date(),second = date(2026,9,26)
        let state = UsageReportState(date:first,calendar:calendar),loader = ControlledUsageLoader()
        let old = Task { await state.load { try await loader.load($0) } }
        await loader.waitForRequests(1)
        state.select(second,calendar:calendar)
        let value = report(second)
        await state.load { _ in value }
        await loader.fail(0); await old.value
        XCTAssertEqual(state.report?.day.start,second); XCTAssertNil(state.error)
        let wrong = report(first)
        await state.load { _ in wrong }
        XCTAssertEqual(state.report?.day.start,second); XCTAssertNotNil(state.error)
        XCTAssertFalse(state.loading)
    }
}

private enum UsageTestError:Error { case failed }
private actor ControlledUsageLoader {
    private var requests:[CheckedContinuation<UsageReport,Error>] = []
    private var waiters:[(Int,CheckedContinuation<Void,Never>)] = []
    func load(_ date:Date) async throws -> UsageReport {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            let ready = waiters.filter { $0.0 <= requests.count }
            waiters.removeAll { $0.0 <= requests.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForRequests(_ count:Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count,$0)) }
    }
    func finish(_ index:Int,with report:UsageReport) { requests[index].resume(returning:report) }
    func fail(_ index:Int) { requests[index].resume(throwing:UsageTestError.failed) }
}
