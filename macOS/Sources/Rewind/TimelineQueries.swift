import Foundation

struct MemorySearchQuery:Sendable {
    let query:String
    let app:String?
    let starred:Bool
    let trash:Bool
    let since:Date?
    let limit:Int
}

struct TimelineNavigationQuery: Sendable { let date:Date; let trash:Bool; let since:Date? }
struct TimelineNavigationResult: Sendable {
    let moments:[CapturedAppMoment]
    let coverage:DateInterval
    static func load(_ query:TimelineNavigationQuery,store:MemoryStore) throws -> Self {
        let older = try store.timelineMoments(trash:query.trash,since:query.since,until:query.date,limit:500)
        let newer = try store.timelineMoments(trash:query.trash,since:query.date,limit:500,ascending:true)
        var seen = Set<String>()
        let moments = (older+newer).filter { seen.insert($0.id).inserted }.sorted { $0.timestamp < $1.timestamp }
        return Self(moments:moments,coverage:DateInterval(start:older.count < 500 ? .distantPast:older.last!.timestamp,end:newer.count < 500 ? .distantFuture:newer.last!.timestamp))
    }
}

struct TimelineActivityQuery:Sendable { let range:DateInterval; let interval:Double }
struct TimelineActivityResult:Sendable {
    let range:DateInterval
    let segments:[AppTimeSegment]
    let firstDate:Date?
    static func load(_ query:TimelineActivityQuery,store:MemoryStore) throws -> Self {
        let cutover = try store.firstUsageDate(), range = query.range
        let legacyEnd = min(range.end,cutover ?? range.end)
        let legacy = legacyEnd >= range.start ? TimelineGeometry.legacySegments(try store.capturedApps(in:DateInterval(start:range.start.addingTimeInterval(-max(15,query.interval*4)),end:legacyEnd)),interval:query.interval):[]
        return Self(range:range,segments:TimelineGeometry.continuous(legacy:legacy,usage:try store.usage(in:range),range:range,cutover:cutover),firstDate:try store.firstTimelineDate())
    }
}

enum TimelineFrameLookup {
    /// Find neighboring timestamps with binary search, then match provenance
    /// inside this application interval. No 2,000-element filtered array per move.
    static func nearest(to date:Date,in moments:[CapturedAppMoment],segment:AppTimeSegment) -> CapturedAppMoment? {
        var low = 0, high = moments.count
        while low < high { let middle = (low+high)/2; if moments[middle].timestamp < date { low = middle+1 } else { high = middle } }
        var before:CapturedAppMoment?, after:CapturedAppMoment?
        var i = low-1
        while i >= 0,(moments[i].endTimestamp ?? moments[i].timestamp) >= segment.start {
            if moments[i].timestamp <= segment.end,moments[i].bundleID == segment.bundleID { before = moments[i]; break }; i -= 1
        }
        i = low
        while i < moments.count,moments[i].timestamp <= segment.end {
            if moments[i].timestamp >= segment.start,moments[i].bundleID == segment.bundleID { after = moments[i]; break }; i += 1
        }
        if let before,let end = before.endTimestamp,end >= date { return before }
        guard let before else { return after }; guard let after else { return before }
        return date.timeIntervalSince(before.timestamp) <= after.timestamp.timeIntervalSince(date) ? before:after
    }
}
