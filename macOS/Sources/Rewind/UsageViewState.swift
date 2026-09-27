import Foundation
import Combine

/// Date labels and calendar arithmetic use the same local calendar as usage buckets.
enum UsageDateLabel {
    static func navigation(_ date:Date,now:Date = Date(),calendar:Calendar = .current) -> String {
        if calendar.isDate(date,inSameDayAs:now) { return "Today" }
        if let yesterday = calendar.date(byAdding:.day,value:-1,to:now),calendar.isDate(date,inSameDayAs:yesterday) { return "Yesterday" }
        return absolute(date,calendar:calendar)
    }
    static func absolute(_ date:Date,calendar:Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = RecallLanguage.locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return formatter.string(from:date)
    }
}

/// Keeps the last successful report attributed to its own day while a new day loads.
/// A generation protects against loaders that finish after cancellation.
@MainActor final class UsageReportState:ObservableObject {
    @Published private(set) var selectedDay:Date
    @Published private(set) var report:UsageReport?
    @Published private(set) var loading = true
    @Published private(set) var error:String?
    private var generation = 0
    private var cache:[Date:UsageReport] = [:]
    init(date:Date = Date(),calendar:Calendar = .current) { selectedDay = calendar.startOfDay(for:date) }
    func select(_ date:Date,calendar:Calendar = .current) {
        let day = calendar.startOfDay(for:date)
        guard day != selectedDay else { return }
        generation += 1; selectedDay = day; error = nil; loading = true
        if let cached = cache[day] { report = cached }
    }
    func load(using loader:@Sendable (Date) async throws -> UsageReport) async {
        guard !Task.isCancelled else { return }
        generation += 1
        let request = generation,day = selectedDay
        loading = true; error = nil
        do {
            let value = try await loader(day)
            guard !Task.isCancelled,request == generation,selectedDay == day else { return }
            guard value.day.start == day else {
                error = "The activity report did not match the selected date."; loading = false; return
            }
            report = value; cache[day] = value
            if cache.count > 14,let oldest = cache.min(by:{$0.value.updated < $1.value.updated})?.key { cache.removeValue(forKey:oldest) }
            loading = false
        } catch {
            guard !Task.isCancelled,request == generation,selectedDay == day else { return }
            self.error = error.localizedDescription; loading = false
        }
    }
}

/// SQLite reads and interval aggregation run on this actor, never on the UI actor.
actor UsageDataSource {
    static let shared = UsageDataSource()
    private struct MonthKey:Hashable { let root:URL; let month:Date; let calendar:Calendar }
    private struct MonthEntry { let days:Set<Date>; let loaded:Date }
    private var months:[MonthKey:MonthEntry] = [:]
    func report(root:URL,date:Date,calendar:Calendar = .current) throws -> UsageReport {
        try Task.checkCancellation()
        let report = try UsageReport.load(root:root,date:date,calendar:calendar)
        try Task.checkCancellation()
        return report
    }
    func recordedDays(root:URL,month:Date,calendar:Calendar = .current,now:Date = Date()) throws -> Set<Date> {
        try Task.checkCancellation()
        let range = calendar.dateInterval(of:.month,for:month)!
        let key = MonthKey(root:root,month:range.start,calendar:calendar)
        if let cached = months[key],now.timeIntervalSince(cached.loaded) < 30 { return cached.days }
        let store = try MemoryStore(root:root,readOnly:true)
        let intervals = try store.usage(in:range)
        try Task.checkCancellation()
        let days = UsageReport.recordedDays(intervals,in:range,now:now,calendar:calendar)
        try Task.checkCancellation()
        months[key] = MonthEntry(days:days,loaded:now)
        if months.count > 12,let oldest = months.min(by:{$0.value.loaded < $1.value.loaded})?.key { months.removeValue(forKey:oldest) }
        return days
    }
}
