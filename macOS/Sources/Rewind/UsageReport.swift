import Foundation

struct UsageAppTotal: Identifiable, Sendable {
    let id:String
    let app:AppUsageIdentity
    var seconds:Double
}
struct UsageBucket: Identifiable, Sendable {
    var id:Date { start }
    let start:Date
    let end:Date
    var apps:[String:Double] = [:]
    var seconds:Double { apps.values.reduce(0,+) }
}
struct UsageReport: Sendable {
    let day:DateInterval
    let week:DateInterval
    let days:[UsageBucket]
    let hours:[UsageBucket]
    let apps:[UsageAppTotal]
    let identities:[String:AppUsageIdentity]
    let firstRecorded:Date?
    let updated:Date
    var total:Double { apps.reduce(0) { $0+$1.seconds } }
    var dailyAverage:Double {
        let recordedDays = days.filter { $0.seconds > 0 }
        return recordedDays.isEmpty ? 0:recordedDays.reduce(0) { $0+$1.seconds }/Double(recordedDays.count)
    }
    static func key(_ app:AppUsageIdentity) -> String {
        app.kind == .excluded ? "private":app.bundleID.isEmpty ? "name:"+app.name:app.bundleID
    }
    static func build(_ intervals:[AppUsageInterval],date:Date,now:Date = Date(),calendar:Calendar = .current,firstRecorded:Date? = nil) -> Self {
        let day = calendar.dateInterval(of:.day,for:date)!
        let week = calendar.dateInterval(of:.weekOfYear,for:date)!
        func buckets(_ range:DateInterval,component:Calendar.Component) -> [UsageBucket] {
            var result:[UsageBucket] = [], cursor = range.start
            while cursor < range.end {
                let end = min(range.end,calendar.date(byAdding:component,value:1,to:cursor)!)
                result.append(UsageBucket(start:cursor,end:end)); cursor = end
            }
            return result
        }
        var days = buckets(week,component:.day), hours = buckets(day,component:.hour)
        var identities:[String:AppUsageIdentity] = [:], totals:[String:Double] = [:]
        // A sweep resolves overlaps once: the latest foreground transition wins.
        // An unavailable interval also masks older records rather than extending them.
        let valid = intervals.filter { $0.end > $0.start && $0.start < min(now,week.end) && $0.end > week.start }
        struct Edge { let date:Date; let index:Int; let entering:Bool }
        var edges:[Edge] = []
        for (index,interval) in valid.enumerated() {
            edges.append(Edge(date:max(interval.start,week.start),index:index,entering:true))
            edges.append(Edge(date:min(interval.end,now,week.end),index:index,entering:false))
        }
        edges.sort { $0.date < $1.date }
        var active = Set<Int>(), previous:Date?, winner:Int?, cursor = 0
        func accumulate(_ start:Date,_ end:Date,_ app:AppUsageIdentity) {
            guard end > start,app.kind != .unavailable else { return }
            let key = Self.key(app); identities[key] = app
            for i in days.indices {
                let duration = min(end,days[i].end).timeIntervalSince(max(start,days[i].start))
                if duration > 0 { days[i].apps[key,default:0] += duration }
            }
            for i in hours.indices {
                let duration = min(end,hours[i].end).timeIntervalSince(max(start,hours[i].start))
                if duration > 0 { hours[i].apps[key,default:0] += duration; totals[key,default:0] += duration }
            }
        }
        while cursor < edges.count {
            let point = edges[cursor].date
            if let previous,let winner { accumulate(previous,point,valid[winner].app) }
            var entering:[Int] = [], leaving:[Int] = []
            while cursor < edges.count,edges[cursor].date == point {
                if edges[cursor].entering { entering.append(edges[cursor].index) } else { leaving.append(edges[cursor].index) }
                cursor += 1
            }
            for index in leaving { active.remove(index) }; for index in entering { active.insert(index) }
            winner = active.max {
                let a = valid[$0],b = valid[$1]
                return a.start == b.start ? a.id < b.id:a.start < b.start
            }
            previous = point
        }
        var apps:[UsageAppTotal] = []
        for (key,seconds) in totals {
            if let identity = identities[key] { apps.append(UsageAppTotal(id:key,app:identity,seconds:seconds)) }
        }
        apps.sort { a,b in
            if a.seconds == b.seconds { return a.id < b.id }
            return a.seconds > b.seconds
        }
        return Self(day:day,week:week,days:days,hours:hours,apps:apps,identities:identities,firstRecorded:firstRecorded,updated:now)
    }
    static func load(root:URL,date:Date,now:Date = Date(),calendar:Calendar = .current) throws -> Self {
        let store = try MemoryStore(root:root,readOnly:true)
        let range = calendar.dateInterval(of:.weekOfYear,for:date)!
        return build(try store.usage(in:range),date:date,now:now,calendar:calendar,firstRecorded:try store.firstUsageDate())
    }
    static func duration(_ seconds:Double) -> String {
        let minutes = Int(max(0,seconds)/60)
        if seconds > 0,minutes == 0 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes/60) hr":"\(minutes/60) hr \(minutes%60) min"
    }
}
