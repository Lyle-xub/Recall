import Foundation
import NaturalLanguage

/// One query plan for screen text, window titles and nearby speech. User input
/// is always bound as data; quoted queries keep their exact phrase semantics.
struct MemorySearchPlan {
    let phrase: String
    let groups: [[String]]
    let fts: String?
    var isEmpty: Bool { phrase.isEmpty }
    var literal: String { Self.like(phrase) }

    init(_ input: String) {
        let trimmed = input.trimmingCharacters(in:.whitespacesAndNewlines)
        let quoted = trimmed.count > 1 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
        phrase = quoted ? String(trimmed.dropFirst().dropLast()):trimmed
        let plain = !quoted && phrase.allSatisfy { $0.isLetter || $0.isNumber || $0.isWhitespace }
        if plain {
            groups = phrase.split(whereSeparator: { $0.isWhitespace }).map { Self.variants(String($0).lowercased()) }
            fts = groups.isEmpty ? nil:groups.map { group in
                "(" + group.map { "\"" + $0.replacingOccurrences(of:"\"",with:"\"\"") + "\"*" }.joined(separator:" OR ") + ")"
            }.joined(separator:" AND ")
        } else { groups = phrase.isEmpty ? []:[[phrase]]; fts = nil }
    }
    static func like(_ text:String) -> String {
        "%" + text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"%",with:"\\%").replacingOccurrences(of:"_",with:"\\_") + "%"
    }
    private static func variants(_ word:String) -> [String] {
        guard word.count > 3,word.allSatisfy({$0.isASCII && $0.isLetter}) else { return [word] }
        var result = [word]
        if word.hasSuffix("ies"),word.count > 4 { result.append(String(word.dropLast(3))+"y") }
        else if ["ches","shes","xes","zes","sses"].contains(where:word.hasSuffix) { result.append(String(word.dropLast(2))) }
        else if word.hasSuffix("s"),!["ss","us","is"].contains(where:word.hasSuffix) { result.append(String(word.dropLast())) }
        if word.hasSuffix("y"),let preceding = word.dropLast().last,!"aeiou".contains(preceding) { result.append(String(word.dropLast())+"ies") }
        return result
    }
    func highlights(_ text:String) -> Bool {
        groups.contains { group in group.contains { text.localizedStandardContains($0) } }
    }
    func predicate(column:String) -> (String,[Any?]) {
        let sql = groups.map { group in "(" + group.map { _ in "\(column) LIKE ? ESCAPE '\\'" }.joined(separator:" OR ") + ")" }.joined(separator:" AND ")
        return (sql,groups.flatMap { $0.map { Self.like($0) as Any? } })
    }
}

struct MemorySearchPage: Sendable {
    let frames:[MemoryFrame]
    let hasMore:Bool
    static func load(_ query:MemorySearchQuery,store:MemoryStore) throws -> Self {
        let rows = try store.frames(query:query.query,app:query.app,starred:query.starred,trash:query.trash,since:query.since,demo:false,limit:query.limit+1)
        return Self(frames:Array(rows.prefix(query.limit)),hasMore:rows.count > query.limit)
    }
}

/// Retrieval queries omit conversational filler and carry forward a prior topic
/// only for an explicit follow-up. An unknown topic never falls back to random history.
struct RecallQuestion {
    let terms:[String]
    let broad:Bool
    let followup:Bool
    static func timeRange(_ question:String,now:Date = Date(),calendar:Calendar = .current) -> DateInterval? {
        let lower = question.lowercased(), today = calendar.startOfDay(for:now)
        if lower.contains("yesterday") || lower.contains("昨天") {
            return DateInterval(start:calendar.date(byAdding:.day,value:-1,to:today)!,end:today)
        }
        if lower.contains("today") || lower.contains("今天") || lower.contains("今日") { return DateInterval(start:today,end:now) }
        if lower.contains("this week") || lower.contains("本周") || lower.contains("这周") {
            return DateInterval(start:calendar.dateInterval(of:.weekOfYear,for:now)!.start,end:now)
        }
        if lower.contains("last 7 days") || lower.contains("过去七天") || lower.contains("最近一周") {
            return DateInterval(start:calendar.date(byAdding:.day,value:-7,to:now)!,end:now)
        }
        return nil
    }
    init(_ question:String,previous:String? = nil) {
        let stop:Set<String> = ["what","where","when","which","who","how","why","was","were","did","does","the","a","an","i","my","me","you","your","we","our","is","are","of","for","to","in","on","and","or","about","with","that","this","it","them","those","these","please","find","show","tell","recent","today","yesterday","work","week","days","last","summary","summarize","summarise","explain","more","detail","details","discussed","reading","read","have","has","had","been","do","can","could","would","get","done","doing","worked","working","happened","accomplish","accomplished","completed","finish","finished","activity","activities","recap","overview","spent","spend","time"]
        let chineseStop:Set<String> = ["我","我的","我们","你","你的","请","请问","帮","帮我","告诉","告诉我","之前","刚才","最近","今天","今日","昨天","总结","回顾","梳理","工作","活动","事情","内容","的","了","过","看","看到","看过","读","阅读","讨论","什么","哪些","哪个","关于","一下","更多","这个","那个","它","它们","继续","详细","解释","在","中","有","是","做了","干了","忙了","做","干","都","一天","一整天","一点","细节","本周","这周","包含","项目名","明确","数字","给出","来源","列成","要点","分点","中文"]
        func extract(_ text:String) -> [String] {
            var text = text.lowercased()
            for filler in ["干了些什么","做了些什么","忙了些什么","干了什么","做了什么","忙了什么","干了哪些","做了哪些","干了啥","做了啥","包含项目名","明确的数字","给出来源"] {text=text.replacingOccurrences(of:filler,with:" ")}
            let tokenizer = NLTokenizer(unit:.word)
            tokenizer.string = text
            var words:[String] = []
            tokenizer.enumerateTokens(in:text.startIndex..<text.endIndex) { range,_ in
                let word = String(text[range])
                if word.count > 1,!stop.contains(word),!chineseStop.contains(word) { words.append(word) }
                return true
            }
            return words
        }
        var found = extract(question)
        let lower = question.lowercased()
        followup = [" it","that","them","those","more","detail","这个","那个","它","继续","详细","更多"].contains { lower.contains($0) }
        let overview = found.isEmpty && (Self.timeRange(question) != nil || ["summar","recent work","today","yesterday","总结","回顾","今天","今日","昨天","最近"].contains { lower.contains($0) })
        if !overview,followup,let previous { found += extract(previous) }
        var seen = Set<String>(); terms = Array(found.filter {seen.insert($0).inserted}.prefix(10))
        broad = terms.isEmpty && (overview || (followup && previous.map {RecallQuestion($0).broad} == true))
    }
}

struct RecallEvidence: Sendable {
    let sources:[MemoryFrame]
    let transcripts:[TranscriptLine]
    var context:String = ""
}

enum RecallSelection {
    /// Overview evidence covers the complete requested period before filling
    /// remaining slots. Frequent captures in one app cannot erase the morning.
    static func overview(_ frames:[MemoryFrame],limit:Int)->[MemoryFrame] {
        guard limit>0 else {return []}
        var signatures=Set<String>()
        let ordered=frames.sorted {$0.timestamp == $1.timestamp ? $0.id<$1.id:$0.timestamp<$1.timestamp}
            .filter {signatures.insert($0.bundleID+"|"+$0.title+"|"+$0.text).inserted}
        guard ordered.count>limit else {return ordered}
        var selected=[ordered[0],ordered[ordered.count-1]],ids=Set([ordered[0].id,ordered[ordered.count-1].id])
        for app in Set(ordered.map(\.appName)).sorted() where selected.count<limit {
            if selected.contains(where:{$0.appName==app}) {continue}
            if let frame=ordered.first(where:{$0.appName==app && !ids.contains($0.id)}) {selected.append(frame);ids.insert(frame.id)}
        }
        while selected.count<limit {
            guard let frame=ordered.filter({!ids.contains($0.id)}).max(by:{a,b in
                let da=selected.map {abs($0.timestamp.timeIntervalSince(a.timestamp))}.min() ?? 0
                let db=selected.map {abs($0.timestamp.timeIntervalSince(b.timestamp))}.min() ?? 0
                return da == db ? a.timestamp>b.timestamp:da<db
            }) else {break}
            selected.append(frame);ids.insert(frame.id)
        }
        return Array(selected.sorted {$0.timestamp<$1.timestamp}.prefix(limit))
    }
}

/// Keep the matching passage in a bounded prompt, even when OCR is very long.
enum RecallExcerpt {
    static func text(_ text:String,question:String,limit:Int) -> String {
        guard text.count > limit else { return text }
        let matches = RecallQuestion(question).terms.compactMap { text.range(of:$0,options:[.caseInsensitive,.diacriticInsensitive]) }
        guard let first = matches.min(by:{$0.lowerBound < $1.lowerBound}) else { return String(text.prefix(limit)) }
        let start = text.index(first.lowerBound,offsetBy:-min(160,limit/4),limitedBy:text.startIndex) ?? text.startIndex
        let end = text.index(start,offsetBy:limit,limitedBy:text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…":"") + String(text[start..<end]) + (end < text.endIndex ? "…":"")
    }
}
