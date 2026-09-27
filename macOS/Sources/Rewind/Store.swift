import Foundation
import CSQLite

final class MemoryStore: @unchecked Sendable {
    let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var ocrCache:[String:(String,SharedOCR)] = [:]
    private var ocrCacheOrder:[String] = []
    private(set) var needsIndexCompaction = false
    private var packedTileStore:TilePackStore?
    private var legacyTileIterator:FileManager.DirectoryEnumerator?
    private var legacyTilesFinished = false
    private var segmentMaintenance:[Int]?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(root: URL, readOnly:Bool = false, maintenanceOnly:Bool = false) throws {
        self.root = root
        // Maintenance opens an already initialized library on its own worker.
        // Never run startup recovery again or share the UI writer's mutex.
        if readOnly || maintenanceOnly {
            let access = readOnly ? SQLITE_OPEN_READONLY:SQLITE_OPEN_READWRITE
            guard sqlite3_open_v2(root.appendingPathComponent("memory.sqlite").path,&db,access | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { throw RewindError.message("Cannot open memory database for reading.") }
            sqlite3_busy_timeout(db,5000)
            return
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        guard sqlite3_open(root.appendingPathComponent("memory.sqlite").path, &db) == SQLITE_OK else { throw RewindError.message("Cannot open memory database.") }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS frames (id TEXT PRIMARY KEY, time REAL, app TEXT, text TEXT, starred INTEGER, deleted REAL, demo INTEGER, json TEXT)")
        try execute("CREATE INDEX IF NOT EXISTS frames_time ON frames(time DESC)")
        try execute("CREATE INDEX IF NOT EXISTS frames_app ON frames(app, time DESC)")
        try execute("CREATE INDEX IF NOT EXISTS frames_image ON frames(json_extract(json,'$.imagePath'))")
        try execute("CREATE INDEX IF NOT EXISTS frames_meeting_image ON frames(json_extract(json,'$.meetingImagePath'))")
        try execute("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, json TEXT)")
        try execute("CREATE TABLE IF NOT EXISTS transcripts (id TEXT PRIMARY KEY, session TEXT, time REAL, text TEXT, json TEXT)")
        try execute("CREATE INDEX IF NOT EXISTS transcripts_time ON transcripts(time)")
        try execute("CREATE INDEX IF NOT EXISTS transcripts_session_time ON transcripts(session,time)")
        try execute("CREATE TABLE IF NOT EXISTS recognition_outcomes (session TEXT PRIMARY KEY, json TEXT NOT NULL)")
        try execute("CREATE TRIGGER IF NOT EXISTS remove_recognition_outcome AFTER DELETE ON sessions BEGIN DELETE FROM recognition_outcomes WHERE session=OLD.id; END")
        try execute("CREATE TABLE IF NOT EXISTS app_usage (id TEXT PRIMARY KEY, start REAL NOT NULL, end REAL NOT NULL, json TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS app_usage_time ON app_usage(start,end)")
        try execute("CREATE TABLE IF NOT EXISTS image_archives (source TEXT PRIMARY KEY, destination TEXT NOT NULL, digest TEXT NOT NULL, version INTEGER NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS image_tiles (image TEXT NOT NULL, tile TEXT NOT NULL, PRIMARY KEY(image,tile))")
        if try jsonRows("SELECT json_quote(type) FROM sqlite_master WHERE name='image_tiles'",as:String.self).first == "table" {
            try execute("CREATE INDEX IF NOT EXISTS image_tiles_tile ON image_tiles(tile)")
        }
        try execute("CREATE TABLE IF NOT EXISTS image_archive_staging (destination TEXT PRIMARY KEY, digest TEXT NOT NULL)")
        try migrateSharedOCR()
        try recoverPendingCleanups()
        try recoverVideoArchives()
        try recoverImageArchives()
        try recoverInterruptedVisualSessions()
    }
    // The headless owner holds the same exclusive lease as the desktop, so it
    // can recover interrupted work without creating or migrating any tables.
    func recoverForHeadless()throws {
        try recoverPendingCleanups();try recoverVideoArchives();try recoverImageArchives();try recoverInterruptedVisualSessions()
        for var session in try sessions() where session.endedAt == nil {session.endedAt=Date();try saveSession(session)}
    }
    deinit { sqlite3_close(db) }

    @discardableResult private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
    private func prepare(_ sql: String, _ values: [Any?]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case let value as String: sqlite3_bind_text(stmt, i, value, -1, transient)
            case let value as Double: sqlite3_bind_double(stmt, i, value)
            case let value as Int: sqlite3_bind_int64(stmt, i, Int64(value))
            default: sqlite3_bind_null(stmt, i)
            }
        }
        return stmt
    }
    private func failure() -> RewindError { .message(String(cString: sqlite3_errmsg(db))) }
    private func execute(_ sql: String, _ values: [Any?] = []) throws {
        try synchronized {
            let stmt = try prepare(sql, values); defer { sqlite3_finalize(stmt) }
            let code = sqlite3_step(stmt)
            guard code == SQLITE_DONE || code == SQLITE_ROW else { throw failure() }
        }
    }
    private func jsonRows<T: Decodable>(_ sql: String, _ values: [Any?] = [], as type: T.Type) throws -> [T] {
        try synchronized {
            let stmt = try prepare(sql, values); defer { sqlite3_finalize(stmt) }
            var rows: [T] = []
            var code = sqlite3_step(stmt)
            while code == SQLITE_ROW {
                if let bytes = sqlite3_column_text(stmt, 0) {
                    let value = try decoder.decode(type, from: Data(String(cString: bytes).utf8))
                    if let frame = value as? MemoryFrame { rows.append(try hydrate(frame) as! T) }
                    else { rows.append(value) }
                }
                code = sqlite3_step(stmt)
            }
            guard code == SQLITE_DONE else { throw failure() }
            return rows
        }
    }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }

    func save(_ frame: MemoryFrame) throws {
        try synchronized {
            // A cached search result may still carry a pre-optimization path.
            // Resolve it before a star/trash action can republish that path.
            var frame = frame
            frame.imagePath = try canonicalImagePath(frame.imagePath)
            if let meeting = frame.meetingImagePath { frame.meetingImagePath = try canonicalImagePath(meeting) }
            try execute("BEGIN IMMEDIATE")
            do {
                try saveSharedFrame(frame)
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }
    /// Bounded day queries avoid loading today's thousands of captures just
    /// to reach yesterday. Deduplicate screenshots before applying the limit.
    func archiveFrames(around anchor:Date,calendar:Calendar = .current,near time:Date? = nil) throws -> [MemoryFrame] {
        var result:[MemoryFrame] = []
        for column in ArchiveDayLayout.columns(frames:[],around:anchor,calendar:calendar) {
            let end = calendar.date(byAdding:.day,value:1,to:column.day)!
            let ordering = time == nil ? "time DESC,id":"ABS(time-?),time DESC,id"
            var parameters:[Any?] = [column.day.timeIntervalSince1970,end.timeIntervalSince1970]
            if let time { parameters.append(time.timeIntervalSince1970) };parameters.append(ArchiveDayLayout.pageSize)
            result += try jsonRows("""
                SELECT json FROM (
                    SELECT json,time,id,ROW_NUMBER() OVER (
                        PARTITION BY json_extract(json,'$.imagePath') ORDER BY time DESC,id
                    ) AS duplicate FROM frames
                    WHERE time>=? AND time<? AND demo=0 AND deleted IS NULL
                ) WHERE duplicate=1 ORDER BY \(ordering) LIMIT ?
                """,parameters,as:MemoryFrame.self)
        }
        return result
    }
    /// Count, anchor rank and rows share one short WAL snapshot. Coordinates
    /// follow stable record anchors, never SQLite rowids (VACUUM may change them).
    func archiveWindow(_ request:ArchiveWindowQuery,calendar:Calendar = .current)throws->ArchiveWindow {
        try synchronized {
            try execute("BEGIN DEFERRED")
            do {
                var result=ArchiveWindow(epoch:request.epoch,focusRow:request.row)
                var center=request.row
                let days=ArchiveDayLayout.columns(frames:[],around:request.day,calendar:calendar)
                // Resolve the central timeline target before reading neighboring
                // columns, so all five windows cover the same world coordinate.
                for column in days.sorted(by:{abs($0.lane) < abs($1.lane)}) {
                    let end=calendar.date(byAdding:.day,value:1,to:column.day)!
                    let values:[Any?]=[column.day.timeIntervalSince1970,end.timeIntervalSince1970]
                    let rows="""
                        WITH duplicates AS (
                            SELECT json,time,id,ROW_NUMBER() OVER (
                                PARTITION BY json_extract(json,'$.imagePath') ORDER BY time DESC,id
                            ) AS duplicate FROM frames
                            WHERE time>=? AND time<? AND demo=0 AND deleted IS NULL
                              AND COALESCE(json_extract(json,'$.imagePath'),'')<>''
                        ), records AS (
                            SELECT json,time,id,ROW_NUMBER() OVER (ORDER BY time DESC,id)-1 AS ordinal
                            FROM duplicates WHERE duplicate=1
                        )
                        """
                    let count=try jsonRows(rows+" SELECT COUNT(*) FROM records",values,as:Int.self).first ?? 0
                    var origin=0
                    if request.near == nil,let anchor=request.anchors.first(where:{$0.day == column.day}) {
                        var rank:Int?,resolvedAnchor=anchor
                        for candidate in request.anchors where candidate.day == column.day {
                            if let found=try jsonRows(rows+" SELECT ordinal FROM records WHERE id=?",values+[candidate.id],as:Int.self).first {rank=found;resolvedAnchor=candidate;break}
                        }
                        // A deleted/merged anchor leaves its chronological insertion
                        // point as the fallback; it cannot retain a stale identity.
                        let position=try rank ?? jsonRows(rows+" SELECT COUNT(*) FROM records WHERE time>? OR (time=? AND id<?)",values+[anchor.timestamp.timeIntervalSince1970,anchor.timestamp.timeIntervalSince1970,anchor.id],as:Int.self).first ?? 0
                        origin=resolvedAnchor.row-position
                    }
                    if let time=request.near,column.lane == 0 {
                        let rank=try jsonRows(rows+" SELECT ordinal FROM records ORDER BY ABS(time-?),time DESC,id LIMIT 1",values+[time.timeIntervalSince1970],as:Int.self).first ?? 0
                        center=Double(rank);result.focusRow=center
                    }
                    let start=max(0,min(max(0,count-ArchiveDayLayout.windowSize),Int(center)-origin-ArchiveDayLayout.windowSize/2))
                    let frames=try jsonRows(rows+" SELECT json FROM records ORDER BY ordinal LIMIT ? OFFSET ?",values+[ArchiveDayLayout.windowSize,start],as:MemoryFrame.self)
                    result.columns.append(ArchiveDayColumn(day:column.day,lane:column.lane,records:frames,startIndex:start,totalCount:count,origin:origin))
                }
                for pin in request.pins.prefix(2) {
                    if let frame=try jsonRows("SELECT json FROM frames WHERE id=? AND deleted IS NULL AND demo=0",[pin.frame.id],as:MemoryFrame.self).first {
                        var current=pin;current.frame=frame;result.pins.append(current)
                    }
                }
                result.columns.sort {$0.lane < $1.lane}
                try execute("COMMIT")
                return result
            } catch {try? execute("ROLLBACK");throw error}
        }
    }
    func frames(query: String = "", app: String? = nil, starred: Bool = false, trash: Bool = false, since: Date? = nil, until: Date? = nil, demo: Bool? = nil, limit: Int = 500, offset: Int = 0, ascending: Bool = false) throws -> [MemoryFrame] {
        var conditions = [trash ? "deleted IS NOT NULL" : "deleted IS NULL"]
        var args: [Any?] = []
        let plan = MemorySearchPlan(query)
        if !plan.isEmpty {
            let screen = plan.predicate(column:"text"), speech = plan.predicate(column:"t.text")
            var sources:[String] = []
            if plan.fts != nil {
                // Each word can occur in either title or OCR, while OCR tokens
                // are indexed only once for all frames sharing that payload.
                let groups = plan.groups.map { group -> String in
                    let fts = "(" + group.map { "\"" + $0.replacingOccurrences(of:"\"",with:"\"\"") + "\"*" }.joined(separator:" OR ") + ")"
                    args += [fts,fts]
                    return "SELECT id FROM (SELECT id FROM frame_fts WHERE frame_fts MATCH ? UNION SELECT id FROM frames WHERE json_extract(json,'$.ocrKey') IN (SELECT key FROM ocr_payloads WHERE rowid IN (SELECT rowid FROM ocr_fts WHERE ocr_fts MATCH ?)))"
                }
                sources.append("SELECT id FROM (" + groups.joined(separator:" INTERSECT ") + ")")
            }
            // FTS handles word prefixes, accents and plurals without scanning OCR.
            // Literal fallback preserves punctuation and substrings within CJK runs.
            if plan.fts == nil || plan.phrase.contains(where:{ !$0.isASCII }) {
                sources.append("SELECT id FROM frame_search WHERE \(screen.0)"); args += screen.1
            }
            sources.append("SELECT id FROM frames WHERE app LIKE ? ESCAPE '\\'"); args.append(plan.literal)
            sources.append("SELECT f.id FROM transcripts t JOIN frames f ON json_extract(f.json,'$.sessionID')=t.session AND COALESCE(json_extract(f.json,'$.endTimestamp')+978307200,f.time)>t.time-15 AND f.time<t.time+15 WHERE \(speech.0)")
            args += speech.1
            conditions.append("id IN (" + sources.joined(separator:" UNION ") + ")")
        }
        if let app { conditions.append("app=?"); args.append(app) }
        if starred { conditions.append("starred=1") }
        if let since { conditions.append("COALESCE(json_extract(json,'$.endTimestamp')+978307200,time)>=?"); args.append(since.timeIntervalSince1970) }
        if let until { conditions.append("time<=?"); args.append(until.timeIntervalSince1970) }
        if let demo { conditions.append("demo=?"); args.append(demo ? 1 : 0) }
        let bounds:[Any?] = [max(1,min(limit,10000)),max(0,offset)]
        let whereClause = conditions.joined(separator:" AND ")
        if plan.isEmpty || ascending {
            return try jsonRows("SELECT json FROM frames WHERE \(whereClause) ORDER BY time \(ascending ? "ASC":"DESC"),id LIMIT ? OFFSET ?",args+bounds,as:MemoryFrame.self)
        }
        // Rank the complete matching set before paging. Show one best match per
        // app first, then interleave batches so frequent captures cannot bury an app.
        return try jsonRows("""
            WITH matches AS (
                SELECT id,app,time,
                    (CASE WHEN json_extract(json,'$.title') LIKE ? ESCAPE '\\' THEN 30 ELSE 0 END +
                     CASE WHEN app LIKE ? ESCAPE '\\' THEN 15 ELSE 0 END +
                     CASE WHEN (SELECT s.text FROM frame_search s WHERE s.id=frames.id) LIKE ? ESCAPE '\\' THEN 5 ELSE 0 END) AS relevance
                FROM frames WHERE \(whereClause)
            ), ranked AS (
                SELECT *,ROW_NUMBER() OVER (PARTITION BY app ORDER BY relevance DESC,time DESC,id) AS app_rank FROM matches
            ) SELECT f.json FROM ranked r JOIN frames f ON f.id=r.id
            ORDER BY CASE WHEN r.app_rank=1 THEN 0 ELSE 1+(r.app_rank-2)/4 END,r.relevance DESC,r.time DESC,r.id LIMIT ? OFFSET ?
            """,[plan.literal,plan.literal,plan.literal]+args+bounds,as:MemoryFrame.self)
    }

    func appNames(demo: Bool,trash: Bool,since: Date?) throws -> [String] {
        var sql = "SELECT DISTINCT json_quote(app) FROM frames WHERE demo=? AND " + (trash ? "deleted IS NOT NULL":"deleted IS NULL")
        var values: [Any?] = [demo ? 1:0];if let since {sql += " AND time>=?";values.append(since.timeIntervalSince1970)}
        return try jsonRows(sql + " ORDER BY app COLLATE NOCASE",values,as:String.self)
    }
    func retrieve(_ question: String, since: Date? = nil, app: String? = nil, demo: Bool = false, previous:String? = nil) throws -> [MemoryFrame] {
        let intent = RecallQuestion(question,previous:previous)
        let range = RecallQuestion.timeRange(question)
        let start = [since,range?.start].compactMap { $0 }.max(), end = range?.end.addingTimeInterval(-0.001)
        var candidates:[MemoryFrame] = []
        if intent.broad { candidates = try frames(app:app,since:start,until:end,demo:demo,limit:300) }
        else {
            if !intent.terms.isEmpty { candidates = try frames(query:intent.terms.joined(separator:" "),app:app,since:start,until:end,demo:demo,limit:80) }
            for term in intent.terms { candidates += try frames(query:term,app:app,since:start,until:end,demo:demo,limit:40) }
        }
        var seen = Set<String>(), signatures = Set<String>()
        let unique = candidates.filter { seen.insert($0.id).inserted }
        func score(_ frame:MemoryFrame) -> Int {
            let text = frame.title + " " + frame.text
            return intent.terms.reduce(0) { $0 + (text.localizedStandardContains($1) ? 1:0) }
        }
        let ranked = unique.sorted { let a = score($0),b = score($1);return a == b ? $0.timestamp > $1.timestamp:a > b }
        // Repeated captures of the same screen add no new evidence.
        let distinct = ranked.filter { signatures.insert($0.bundleID + "|" + $0.title + "|" + $0.text).inserted }
        var counts:[String:Int] = [:], selected:[MemoryFrame] = [], deferred:[MemoryFrame] = []
        for frame in distinct {
            if counts[frame.appName,default:0] < 3 { selected.append(frame); counts[frame.appName,default:0] += 1 }
            else { deferred.append(frame) }
        }
        return Array((selected+deferred).prefix(12))
    }
    func evidence(_ question:String,since:Date?,app:String?,previous:String?,limit:Int) throws -> RecallEvidence {
        let sources = Array(try retrieve(question,since:since,app:app,previous:previous).prefix(limit))
        var transcripts:[TranscriptLine] = []
        for session in Set(sources.compactMap(\.sessionID)) {
            let moments = sources.filter { $0.sessionID == session }
            transcripts += try transcript(session).filter { line in moments.contains { line.timestamp >= $0.timestamp.addingTimeInterval(-30) && line.timestamp <= ($0.endTimestamp ?? $0.timestamp).addingTimeInterval(30) } }
        }
        return RecallEvidence(sources:sources,transcripts:transcripts.sorted { $0.timestamp < $1.timestamp })
    }
    func saveSession(_ session: RecordingSession) throws { try execute("INSERT OR REPLACE INTO sessions VALUES (?,?)", [session.id,try json(session)]) }
    func saveUsage(_ interval:AppUsageInterval) throws {
        try execute("INSERT OR REPLACE INTO app_usage VALUES (?,?,?,?)",[interval.id,interval.start.timeIntervalSince1970,interval.end.timeIntervalSince1970,try json(interval)])
    }
    func usage(in range:DateInterval) throws -> [AppUsageInterval] {
        try jsonRows("SELECT json FROM app_usage WHERE end>=? AND start<=? ORDER BY start,id",[range.start.timeIntervalSince1970,range.end.timeIntervalSince1970],as:AppUsageInterval.self)
    }
    func firstUsageDate() throws -> Date? {
        try jsonRows("SELECT json_quote(MIN(start)) FROM app_usage WHERE start IS NOT NULL HAVING COUNT(*)>0",as:Double.self).first.map(Date.init(timeIntervalSince1970:))
    }
    func firstTimelineDate() throws -> Date? {
        try jsonRows("SELECT json_quote(MIN(time)) FROM (SELECT time FROM frames WHERE demo=0 AND deleted IS NULL UNION ALL SELECT start AS time FROM app_usage) HAVING COUNT(*)>0",as:Double.self).first.map(Date.init(timeIntervalSince1970:))
    }
    func capturedApps(in range:DateInterval) throws -> [CapturedAppMoment] {
        try jsonRows("""
            SELECT json_object('id',id,'appName',app,'bundleID',json_extract(json,'$.bundleID'),
                'timestamp',json_extract(json,'$.timestamp'),'sessionID',json_extract(json,'$.sessionID'),
                'continuityID',json_extract(json,'$.continuityID'),'endTimestamp',json_extract(json,'$.endTimestamp')) FROM frames
            WHERE demo=0 AND deleted IS NULL AND COALESCE(json_extract(json,'$.endTimestamp')+978307200,time)>=? AND time<=? ORDER BY time
            """,[range.start.timeIntervalSince1970,range.end.timeIntervalSince1970],as:CapturedAppMoment.self)
    }
    func timelineMoments(trash:Bool = false,since:Date? = nil,until:Date? = nil,limit:Int = 2000,ascending:Bool = false) throws -> [CapturedAppMoment] {
        var conditions = ["demo=0",trash ? "deleted IS NOT NULL":"deleted IS NULL"], values:[Any?] = []
        if let since { conditions.append("COALESCE(json_extract(json,'$.endTimestamp')+978307200,time)>=?"); values.append(since.timeIntervalSince1970) }
        if let until { conditions.append("time<=?"); values.append(until.timeIntervalSince1970) }
        values.append(max(1,min(10000,limit)))
        return try jsonRows("""
            SELECT json_object('id',id,'appName',app,'bundleID',json_extract(json,'$.bundleID'),
                'timestamp',json_extract(json,'$.timestamp'),'sessionID',json_extract(json,'$.sessionID'),
                'continuityID',json_extract(json,'$.continuityID'),'endTimestamp',json_extract(json,'$.endTimestamp')) FROM frames
            WHERE \(conditions.joined(separator:" AND ")) ORDER BY time \(ascending ? "ASC":"DESC") LIMIT ?
            """,values,as:CapturedAppMoment.self)
    }
    func frame(_ id: String) throws -> MemoryFrame? { try jsonRows("SELECT json FROM frames WHERE id=?",[id],as:MemoryFrame.self).first }
    func cliIntegrity() throws -> String { try jsonRows("SELECT json_quote(quick_check) FROM pragma_quick_check",as:String.self).first ?? "unknown" }
    func pendingIndexFrames() throws -> [MemoryFrame] { try jsonRows("SELECT json FROM frames WHERE demo=0 AND deleted IS NULL AND json_extract(json,'$.indexingComplete')=0 ORDER BY time",as:MemoryFrame.self) }
    func session(_ id: String) throws -> RecordingSession? { try jsonRows("SELECT json FROM sessions WHERE id=?",[id],as:RecordingSession.self).first }
    func sessions() throws -> [RecordingSession] { try jsonRows("SELECT json FROM sessions", as: RecordingSession.self) }
    func saveTranscript(_ line: TranscriptLine) throws { try execute("INSERT OR REPLACE INTO transcripts VALUES (?,?,?,?,?)", [line.id,line.sessionID,line.timestamp.timeIntervalSince1970,line.text,try json(line)]) }
    func replaceTranscript(sessionID: String, lines: [TranscriptLine]) throws {
        try synchronized {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("DELETE FROM transcripts WHERE session=?",[sessionID])
                for line in lines {try saveTranscript(line)}
                try saveRecognitionOutcome(sessionID, state:TranscriptPresentation.lines(lines).isEmpty ? .empty:.complete)
                try execute("COMMIT")
            }
            catch {try? execute("ROLLBACK");throw error}
        }
    }
    func transcript(_ session: String) throws -> [TranscriptLine] { try jsonRows("SELECT json FROM transcripts WHERE session=? ORDER BY time", [session], as:TranscriptLine.self) }
    func recognitionOutcome(_ session:String)throws->MediaRecognitionState? {
        try jsonRows("SELECT json FROM recognition_outcomes WHERE session=?",[session],as:MediaRecognitionState.self).first
    }
    func saveRecognitionOutcome(_ sessionID:String,state:MediaRecognitionState)throws {
        try synchronized {
            guard try session(sessionID) != nil else { return }
            try execute("INSERT OR REPLACE INTO recognition_outcomes VALUES (?,?)",[sessionID,try json(state)])
        }
    }
    func count(demo: Bool = false) throws -> Int {
        try synchronized {
            let stmt = try prepare("SELECT COUNT(*) FROM frames WHERE deleted IS NULL AND demo=?",[demo ? 1 : 0]); defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }; return Int(sqlite3_column_int64(stmt,0))
        }
    }
    func moveToTrash(_ frame: MemoryFrame) throws {
        try synchronized { guard var f = try self.frame(frame.id) else { return }; f.deletedAt = Date();try save(f) }
    }
    func restore(_ frame: MemoryFrame) throws {
        try synchronized { guard var f = try self.frame(frame.id) else { return }; f.deletedAt = nil;try save(f) }
    }
    func applyRetention(days: Int) throws {
        guard days > 0 else {return};let now = Date()
        try execute("UPDATE frames SET deleted=?,json=json_set(json,'$.deletedAt',?) WHERE deleted IS NULL AND starred=0 AND demo=0 AND time<? AND (json_extract(json,'$.sessionID') IS NULL OR json_extract(json,'$.sessionID') NOT IN (SELECT id FROM sessions WHERE json_extract(json,'$.endedAt') IS NULL))",[now.timeIntervalSince1970,now.timeIntervalSinceReferenceDate,now.addingTimeInterval(-Double(days)*86400).timeIntervalSince1970])
        try execute("DELETE FROM app_usage WHERE end<?",[now.addingTimeInterval(-Double(days)*86400).timeIntervalSince1970])
    }
    @discardableResult func emptyTrash() throws -> Int {
        try synchronized {
            let removed: [MemoryFrame] = try jsonRows("SELECT json FROM frames WHERE deleted IS NOT NULL",as:MemoryFrame.self)
            let remaining: [MemoryFrame] = try jsonRows("SELECT json FROM frames WHERE deleted IS NULL",as:MemoryFrame.self)
            let keptPaths = try expandedImagePaths(remaining.flatMap{[$0.imagePath,$0.meetingImagePath].compactMap{$0}})
            var paths = try expandedImagePaths(removed.flatMap{[$0.imagePath,$0.meetingImagePath].compactMap{$0}}).subtracting(keptPaths)
            let removedSessions = Set(removed.compactMap(\.sessionID)).subtracting(Set(remaining.compactMap(\.sessionID)))
            for id in removedSessions {if let session = try session(id),session.endedAt != nil {paths.formUnion([session.videoPath,session.systemAudioPath,session.microphoneAudioPath].compactMap{$0});paths.insert("recordings/\(id).wav");paths.insert("recordings/\(id).m4a")}}
            paths.subtract(keptPaths)
            try execute("BEGIN IMMEDIATE")
            do {
                // External-content FTS is maintained by row triggers.
                try execute("DELETE FROM frames WHERE deleted IS NOT NULL")
                for id in removedSessions {if let session = try session(id),session.endedAt != nil {try execute("DELETE FROM sessions WHERE id=?",[id]);try execute("DELETE FROM transcripts WHERE session=?",[id])}}
                try execute("COMMIT")
            } catch {try? execute("ROLLBACK");throw error}
            for path in paths {let url = root.appendingPathComponent(path).standardizedFileURL;if url.path.hasPrefix(root.standardizedFileURL.path + "/"),FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}}
            try removePackedTiles(Array(paths))
            try pruneTileReferences()
            try execute("PRAGMA wal_checkpoint(TRUNCATE)");return removed.count
        }
    }
    func export(to destination: URL, frames: [MemoryFrame]) throws {
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        var exported = Set<String>(),copies = frames
        for i in copies.indices {
            func exportImage(_ name:String) throws -> String {
                let container = [PackedScreen.fileExtension,VisualArchive.fileExtension].contains(URL(fileURLWithPath:name).pathExtension)
                let output = container ? URL(fileURLWithPath:name).deletingPathExtension().lastPathComponent+".png":name
                let relative = container ? "frames/"+output:output
                if exported.insert(relative).inserted {
                    let source = root.appendingPathComponent(name),target = destination.appendingPathComponent(relative)
                    if container {
                        guard let image = StoredImage.load(source) else {throw RewindError.message("A screenshot could not be exported.")}
                        try ScreenArchive.encode(image,type:.png).write(to:target,options:.atomic)
                    } else {guard FileManager.default.fileExists(atPath:source.path) else {throw CoreCLIError(code:"not_found",message:"A referenced screenshot is missing; no export was published.")};try FileManager.default.copyItem(at:source,to:target)}
                }
                return relative
            }
            copies[i].imagePath = try exportImage(copies[i].imagePath)
            if let meeting = copies[i].meetingImagePath {copies[i].meetingImagePath = try exportImage(meeting)}
        }
        let sessionIDs = Set(frames.compactMap(\.sessionID))
        let sessions = try sessions().filter { sessionIDs.contains($0.id) }
        for s in sessions {for path in [s.videoPath,s.systemAudioPath,s.microphoneAudioPath].compactMap({$0}) where !path.isEmpty {guard FileManager.default.fileExists(atPath:root.appendingPathComponent(path).path) else {throw CoreCLIError(code:"not_found",message:"A referenced recording is missing; no export was published.")};try FileManager.default.copyItem(at:root.appendingPathComponent(path),to:destination.appendingPathComponent(path))}}
        let lines = try sessions.flatMap { try transcript($0.id) }
        try encoder.encode(copies).write(to: destination.appendingPathComponent("frames.json"))
        try encoder.encode(sessions).write(to: destination.appendingPathComponent("sessions.json"))
        try encoder.encode(lines).write(to: destination.appendingPathComponent("transcripts.json"))
    }
}

extension MemoryStore {
    private func tilePacks()throws->TilePackStore {
        if let packedTileStore {return packedTileStore}
        let store = try TilePackStore(root:root,writable:true);packedTileStore = store;return store
    }
    private func removePackedTiles(_ paths:[String])throws {
        let tiles=paths.filter {TilePackStore.key($0) != nil}
        guard !tiles.isEmpty,FileManager.default.fileExists(atPath:root.appendingPathComponent("frames/packs/catalog.sqlite").path) else {return}
        try tilePacks().remove(tiles)
    }
    func imageBytes(_ path:String)throws->Data? {
        try synchronized {
            if TilePackStore.key(path) != nil,let data = try tilePacks().read(path) {return data}
            let url = try CleanupFiles.ownedURL(path,root:root)
            return FileManager.default.fileExists(atPath:url.path) ? try Data(contentsOf:url):nil
        }
    }
    private func imageStorageBytes(_ path:String,validatedURL:URL? = nil)throws->Int64 {
        let url = try validatedURL ?? CleanupFiles.ownedURL(path,root:root)
        if FileManager.default.fileExists(atPath:url.path) {return try CleanupFiles.size(url)}
        return TilePackStore.key(path) == nil ? 0:try tilePacks().size(path)
    }
    var needsTileStorageOptimization:Bool {
        (try? jsonRows("SELECT json_quote(type) FROM sqlite_master WHERE name='image_tiles'",as:String.self).first) == "table"
            || FileManager.default.fileExists(atPath:root.appendingPathComponent("frames/tiles").path)
            || FileManager.default.fileExists(atPath:root.appendingPathComponent("frames/packs").path)
    }
    /// Keep the public SQL shape for existing cleanup/recovery queries, but
    /// store long names once and use integer IDs in both association indexes.
    private func compactTileReferences(reclaim:Bool = true)throws {
        try execute("CREATE TABLE IF NOT EXISTS storage_maintenance(key TEXT PRIMARY KEY,value INTEGER NOT NULL)")
        if try jsonRows("SELECT json_quote(type) FROM sqlite_master WHERE name='image_tiles'",as:String.self).first == "table" {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("CREATE TABLE image_paths(id INTEGER PRIMARY KEY,path TEXT NOT NULL UNIQUE)")
                try execute("CREATE TABLE tile_links(image INTEGER NOT NULL,tile INTEGER NOT NULL,PRIMARY KEY(image,tile)) WITHOUT ROWID")
                try execute("CREATE INDEX tile_links_tile ON tile_links(tile)")
                try execute("""
                    CREATE TRIGGER prune_image_paths AFTER DELETE ON tile_links BEGIN
                        DELETE FROM image_paths WHERE id IN(OLD.image,OLD.tile)
                            AND NOT EXISTS(SELECT 1 FROM tile_links WHERE image=image_paths.id)
                            AND NOT EXISTS(SELECT 1 FROM tile_links WHERE tile=image_paths.id);
                    END
                    """)
                try execute("INSERT INTO image_paths(path) SELECT image FROM image_tiles UNION SELECT tile FROM image_tiles")
                try execute("INSERT INTO tile_links SELECT i.id,t.id FROM image_tiles old JOIN image_paths i ON i.path=old.image JOIN image_paths t ON t.path=old.tile")
                try execute("DROP TABLE image_tiles")
                try execute("CREATE VIEW image_tiles AS SELECT i.path AS image,t.path AS tile FROM tile_links l JOIN image_paths i ON i.id=l.image JOIN image_paths t ON t.id=l.tile")
                try execute("""
                    CREATE TRIGGER insert_image_tile INSTEAD OF INSERT ON image_tiles BEGIN
                        INSERT OR IGNORE INTO image_paths(path) VALUES(NEW.image),(NEW.tile);
                        INSERT OR IGNORE INTO tile_links SELECT i.id,t.id FROM image_paths i,image_paths t WHERE i.path=NEW.image AND t.path=NEW.tile;
                    END
                    """)
                try execute("""
                    CREATE TRIGGER delete_image_tile INSTEAD OF DELETE ON image_tiles BEGIN
                        DELETE FROM tile_links WHERE image=(SELECT id FROM image_paths WHERE path=OLD.image) AND tile=(SELECT id FROM image_paths WHERE path=OLD.tile);
                    END
                    """)
                try execute("INSERT OR REPLACE INTO storage_maintenance VALUES('tile-index-vacuum',1)")
                try execute("COMMIT")
            } catch {try? execute("ROLLBACK");throw error}
        }
        let pending = try jsonRows("SELECT value FROM storage_maintenance WHERE key='tile-index-vacuum'",as:Int.self).first == 1
        if pending && reclaim {
            try execute("VACUUM");try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try execute("UPDATE storage_maintenance SET value=0 WHERE key='tile-index-vacuum'")
        }
    }
    struct TileStorageBatch:Sendable {let processed:Int;let more:Bool;let savedBytes:Int64}
    /// Every batch leaves either the original file, or verified durable packed
    /// bytes, or both. Interruptions require no in-place rewrite or re-encoding.
    func packLegacyTiles(limit:Int = 128,restartScan:Bool = false)throws->TileStorageBatch {
        try synchronized {
            if restartScan {legacyTileIterator = nil;legacyTilesFinished = false;segmentMaintenance = nil}
            sqlite3_progress_handler(db,4000,{_ in Task.isCancelled ? 1:0},nil)
            defer {sqlite3_progress_handler(db,0,nil,nil)}
            do {
                try Task.checkCancellation()
                let beforeIndex = try CleanupFiles.size(root.appendingPathComponent("memory.sqlite"))
                try compactTileReferences()
                let indexSavings = max(0,beforeIndex-(try CleanupFiles.size(root.appendingPathComponent("memory.sqlite"))))
                guard FileManager.default.fileExists(atPath:root.appendingPathComponent("frames/tiles").path)
                        || FileManager.default.fileExists(atPath:root.appendingPathComponent("frames/packs/catalog.sqlite").path) else {
                    return TileStorageBatch(processed:0,more:false,savedBytes:indexSavings)
                }
                let packs = try tilePacks()
                if !legacyTilesFinished {
                    if legacyTileIterator == nil {legacyTileIterator = FileManager.default.enumerator(at:root.appendingPathComponent("frames/tiles"),includingPropertiesForKeys:nil,options:[.skipsSubdirectoryDescendants])}
                    var files:[ScreenTile] = [],allocated:Int64 = 0
                    while files.count < max(1,limit) {
                        guard let url = legacyTileIterator?.nextObject() as? URL else {legacyTilesFinished = true;break}
                        let path = "frames/tiles/"+url.lastPathComponent
                        guard TilePackStore.key(path) != nil else {continue}
                        let owned = try CleanupFiles.ownedURL(path,root:root)
                        guard FileManager.default.fileExists(atPath:owned.path) else {continue}
                        let data = try Data(contentsOf:owned)
                        allocated += try CleanupFiles.size(owned);files.append(ScreenTile(path:path,data:data))
                    }
                    if !files.isEmpty {
                        let beforePacks = try packs.allocatedBytes()
                        try packs.install(files)
                        for file in files {
                            try Task.checkCancellation()
                            guard try packs.read(file.path) == file.data else {throw RewindError.message("Screenshot packing could not be verified. Originals were kept.")}
                            try FileManager.default.removeItem(at:CleanupFiles.ownedURL(file.path,root:root))
                        }
                        let afterPacks = try packs.allocatedBytes()
                        return TileStorageBatch(processed:files.count,more:true,savedBytes:indexSavings+allocated+beforePacks-afterPacks)
                    }
                }
                if segmentMaintenance == nil {segmentMaintenance = try packs.segmentIDs()}
                if let id = segmentMaintenance?.first {
                    try packs.reclaimSegment(id);segmentMaintenance?.removeFirst()
                    return TileStorageBatch(processed:0,more:true,savedBytes:indexSavings)
                }
                let beforePacks = try packs.allocatedBytes()
                try packs.checkpoint()
                return TileStorageBatch(processed:0,more:false,savedBytes:indexSavings+beforePacks-(try packs.allocatedBytes()))
            } catch {
                sqlite3_progress_handler(db,0,nil,nil)
                try? execute("ROLLBACK")
                legacyTileIterator = nil;legacyTilesFinished = false
                if Task.isCancelled {throw CancellationError()};throw error
            }
        }
    }
    private func expandedImagePaths(_ paths:[String]) throws -> Set<String> {
        var result = Set(paths)
        for path in paths where path.hasSuffix("."+PackedScreen.fileExtension) || path.hasSuffix("."+VisualArchive.fileExtension) {
            result.formUnion(try jsonRows("SELECT json_quote(tile) FROM image_tiles WHERE image=?",[path],as:String.self))
        }
        return result
    }
    private func pruneTileReferences() throws {
        try execute("DELETE FROM ocr_payloads WHERE key NOT IN (SELECT json_extract(json,'$.ocrKey') FROM frames WHERE json_extract(json,'$.ocrKey') IS NOT NULL)")
        let retained = "SELECT json_extract(json,'$.imagePath') FROM frames UNION SELECT json_extract(json,'$.meetingImagePath') FROM frames WHERE json_extract(json,'$.meetingImagePath') IS NOT NULL"
        if try jsonRows("SELECT json_quote(type) FROM sqlite_master WHERE name='image_tiles'",as:String.self).first == "view" {
            // Delete integer associations directly; routing millions of links
            // through the compatibility view repeats path lookups per tile.
            try execute("DELETE FROM tile_links WHERE image IN (SELECT id FROM image_paths WHERE path NOT IN (\(retained)))")
        } else { try execute("DELETE FROM image_tiles WHERE image NOT IN (\(retained))") }
        try execute("DELETE FROM image_archives WHERE source NOT IN (\(retained)) AND destination NOT IN (\(retained))")
    }
    private func archiveIsComplete(_ path:String,data:Data)->Bool {
        if path.hasSuffix("."+VisualArchive.fileExtension) {
            guard let reference=try? JSONDecoder().decode(VisualArchive.self,from:data),let file=try? reference.validate(root:root) else {return false}
            return ((try? CleanupFiles.size(file)) ?? 0)>0
        }
        guard path.hasSuffix("."+PackedScreen.fileExtension) else {return true}
        guard let manifest = try? PackedScreen.manifest(data) else {return false}
        return manifest.tiles.allSatisfy {tile in
            guard let bytes = try? imageBytes(tile.path) else {return false}
            return tile.path.contains(ImageArchive.digest(bytes))
        }
    }
    private func archiveAdditionalBytes(_ archive:ScreenArchive) throws -> Int64 {
        try (archive.tiles+[ScreenTile(path:archive.path,data:archive.data)]).reduce(Int64(0)) {sum,file in
            if let data = try imageBytes(file.path) {
                guard data == file.data else {throw RewindError.message("An existing screenshot could not be verified. The original has been kept.")}
                return sum
            }
            return sum+Int64(file.data.count)
        }
    }
    /// Publish each immutable tile durably before the manifest, and the manifest
    /// before any frame reference. Staging receipts cover interrupted writes.
    private func installArchive(_ archive:ScreenArchive) throws {
        if archive.fileExtension == PackedScreen.fileExtension {
            let manifest = try PackedScreen.manifest(archive.data)
            guard Set(manifest.tiles.map(\.path)) == Set(archive.tiles.map(\.path)) else {throw RewindError.message("Incomplete screenshot archive.")}
        }
        _ = try archiveAdditionalBytes(archive)
        let files = archive.tiles+[ScreenTile(path:archive.path,data:archive.data)]
        let pending = try files.filter {try imageBytes($0.path) == nil}
        try execute("BEGIN IMMEDIATE")
        do {
            for file in pending {try execute("INSERT OR REPLACE INTO image_archive_staging VALUES(?,?)",[file.path,ImageArchive.digest(file.data)])}
            try execute("COMMIT")
        } catch {try? execute("ROLLBACK");throw error}
        let tiles=pending.filter {TilePackStore.key($0.path) != nil}
        if !tiles.isEmpty {try tilePacks().install(tiles)}
        for file in pending where TilePackStore.key(file.path) == nil {
            let url = try CleanupFiles.ownedURL(file.path,root:root)
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try file.data.write(to:url,options:.atomic)
            let handle = try FileHandle(forWritingTo:url)
            do {try handle.synchronize();try handle.close()} catch {try? handle.close();throw error}
        }
        try execute("BEGIN IMMEDIATE")
        do {
            for tile in archive.tiles {try execute("INSERT OR IGNORE INTO image_tiles VALUES(?,?)",[archive.path,tile.path])}
            try execute("COMMIT")
        } catch {try? execute("ROLLBACK");throw error}
    }
    private func finishArchive(_ archive:ScreenArchive) throws {
        let paths = archive.tiles.map(\.path)+[archive.path]
        for start in stride(from:0,to:paths.count,by:300) {
            let batch = Array(paths[start..<min(start+300,paths.count)])
            try execute("DELETE FROM image_archive_staging WHERE destination IN (\(batch.map {_ in "?"}.joined(separator:",")))",batch)
        }
    }
    private func canonicalImagePath(_ path:String) throws -> String {
        var current = path,seen = Set<String>()
        while seen.insert(current).inserted,let next = try jsonRows("SELECT json_quote(destination) FROM image_archives WHERE source=?",[current],as:String.self).first,next != current {current = next}
        return current
    }
    func imageArchiveCandidates() throws -> [String] {
        try jsonRows("""
            WITH images(path) AS (
                SELECT json_extract(json,'$.imagePath') FROM frames WHERE demo=0
                UNION SELECT json_extract(json,'$.meetingImagePath') FROM frames WHERE demo=0
            )
            SELECT json_quote(path) FROM images WHERE path IS NOT NULL AND path!=''
                AND path NOT LIKE 'frames/pack1-%.recallframe'
                AND path NOT LIKE 'frames/%.recallvideo'
                AND NOT EXISTS(SELECT 1 FROM frames WHERE json_extract(json,'$.imagePath')=path AND json_extract(json,'$.visualTime') IS NOT NULL)
                AND NOT EXISTS(SELECT 1 FROM image_archives WHERE source=path AND version>=?)
                AND NOT EXISTS(SELECT 1 FROM frames WHERE json_extract(json,'$.imagePath')=path
                    AND json_extract(json,'$.indexingComplete')=0)
            ORDER BY path
            """,[ImageArchive.policyVersion],as:String.self)
    }
    /// Update every live/trash/main/meeting reference in one transaction. Text,
    /// regions, timestamps, search indexes and user metadata are untouched.
    func commitImageArchive(originalPath:String,result:ImageArchiveResult) throws -> ImageArchiveCommit {
        try synchronized {
            guard try canonicalImagePath(originalPath) == originalPath else { return .skipped }
            let references:[String] = try jsonRows("SELECT json_quote(id) FROM frames WHERE json_extract(json,'$.imagePath')=? OR json_extract(json,'$.meetingImagePath')=?",[originalPath,originalPath],as:String.self)
            guard !references.isEmpty else { return .skipped }
            let pending:[String] = try jsonRows("SELECT json_quote(id) FROM frames WHERE json_extract(json,'$.imagePath')=? AND json_extract(json,'$.indexingComplete')=0 LIMIT 1",[originalPath],as:String.self)
            guard pending.isEmpty else { return .skipped }
            let source = try CleanupFiles.ownedURL(originalPath,root:root)
            guard FileManager.default.fileExists(atPath:source.path),ImageArchive.digest(try Data(contentsOf:source)) == result.sourceDigest else { return .skipped }
            let destination = try CleanupFiles.ownedURL(result.archive.path,root:root)
            guard source != destination else {
                try execute("INSERT OR REPLACE INTO image_archives VALUES(?,?,?,?)",[originalPath,originalPath,result.sourceDigest,ImageArchive.policyVersion])
                return .skipped
            }
            let bytes = try CleanupFiles.size(source)
            let added = try archiveAdditionalBytes(result.archive)
            // A single-image conversion must not increase the library. Later
            // images can reuse tiles already installed by earlier moments.
            if added > bytes || (added == bytes && !result.archive.tiles.isEmpty) {
                try execute("INSERT OR REPLACE INTO image_archives VALUES(?,?,?,?)",[originalPath,originalPath,result.sourceDigest,ImageArchive.policyVersion])
                return .skipped
            }
            try installArchive(result.archive)
            do {
                try execute("BEGIN IMMEDIATE")
                try execute("UPDATE frames SET json=json_set(json,'$.imagePath',?) WHERE json_extract(json,'$.imagePath')=?",[result.archive.path,originalPath])
                try execute("UPDATE frames SET json=json_set(json,'$.meetingImagePath',?) WHERE json_extract(json,'$.meetingImagePath')=?",[result.archive.path,originalPath])
                // This is also the durable cleanup receipt. Recovery only removes
                // the old file after checking the canonical file's content hash.
                try execute("INSERT OR REPLACE INTO image_archives VALUES(?,?,?,?)",[originalPath,result.archive.path,ImageArchive.digest(result.archive.data),ImageArchive.policyVersion])
                try execute("INSERT OR IGNORE INTO image_archives VALUES(?,?,?,?)",[result.archive.path,result.archive.path,ImageArchive.digest(result.archive.data),ImageArchive.policyVersion])
                try finishArchive(result.archive)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                removeUnreferencedImage(result.archive.path)
                throw error
            }
            removeUnreferencedImage(originalPath)
            return ImageArchiveCommit(savedBytes:FileManager.default.fileExists(atPath:source.path) ? 0:max(0,bytes-added),changed:true,destination:result.archive.path)
        }
    }
    private struct ImageReceipt:Decodable {let source:String;let destination:String;let digest:String}
    private func recoverImageArchives() throws {
        let staged = try jsonRows("SELECT json_object('source',destination,'destination',destination,'digest',digest) FROM image_archive_staging ORDER BY destination",as:ImageReceipt.self)
        for receipt in staged {
            if let data = try? imageBytes(receipt.destination),ImageArchive.digest(data) == receipt.digest {
                removeUnreferencedImage(receipt.destination)
            }
            try execute("DELETE FROM image_archive_staging WHERE destination=?",[receipt.destination])
        }
        let receipts = try jsonRows("SELECT json_object('source',source,'destination',destination,'digest',digest) FROM image_archives",as:ImageReceipt.self)
        for receipt in receipts where receipt.source != receipt.destination {
            guard let original = try? CleanupFiles.ownedURL(receipt.source,root:root),FileManager.default.fileExists(atPath:original.path),
                  let archived = try? CleanupFiles.ownedURL(receipt.destination,root:root),let data = try? Data(contentsOf:archived),
                  ImageArchive.digest(data) == receipt.digest,archiveIsComplete(receipt.destination,data:data) else { continue }
            removeUnreferencedImage(receipt.source)
        }
    }
    private func cleanupFrames() throws -> [CleanupFrameRecord] {
        try jsonRows("""
            SELECT json_object('id',id,'time',time,'image',json_extract(json,'$.imagePath'),
                'meeting',json_extract(json,'$.meetingImagePath'),'session',json_extract(json,'$.sessionID'),
                'starred',starred,'deleted',deleted) FROM frames
            """,as:CleanupFrameRecord.self)
    }
    func cleanupPlan(scope:StorageCleanupScope,keepStarred:Bool = true,at date:Date = Date()) throws -> StorageCleanupPlan {
        try synchronized { try makeCleanupPlan(scope:scope,keepStarred:keepStarred,at:date,allowedIDs:nil) }
    }
    private func makeCleanupPlan(scope:StorageCleanupScope,keepStarred:Bool,at date:Date,allowedIDs:Set<String>?,allowedSessions:Set<String>? = nil) throws -> StorageCleanupPlan {
        let records = try cleanupFrames(), sessions = try sessions()
        let active = Set(sessions.filter { $0.endedAt == nil }.map(\.id)), cutoff = scope.cutoff(at:date)
        var skippedActive = 0, skippedStarred = 0
        let removed = records.filter { frame in
            guard allowedIDs?.contains(frame.id) != false,frame.time <= date.timeIntervalSince1970 else { return false }
            if scope == .trash,frame.deleted == nil { return false }
            if let cutoff,frame.time >= cutoff.timeIntervalSince1970 { return false }
            if let session = frame.session,active.contains(session) { skippedActive += 1; return false }
            if keepStarred,frame.starred != 0 { skippedStarred += 1; return false }
            return true
        }
        let ids = Set(removed.map(\.id)), remaining = records.filter { !ids.contains($0.id) }
        var removedSessions = Set(removed.compactMap(\.session)).subtracting(Set(remaining.compactMap(\.session))).subtracting(active)
        // All memories also includes completed empty recordings. Revalidation
        // can only remove session IDs present in the confirmed preview.
        if scope == .all {
            let used = Set(records.compactMap(\.session))
            removedSessions.formUnion(sessions.filter { !used.contains($0.id) && $0.endedAt != nil && $0.startedAt <= date && allowedSessions?.contains($0.id) != false }.map(\.id))
        }
        let closedSessions = sessions.filter { removedSessions.contains($0.id) && $0.endedAt != nil }
        func sessionPaths(_ session:RecordingSession) -> [String] {
            [session.videoPath,session.systemAudioPath,session.microphoneAudioPath,session.supersededVideoPath,"recordings/\(session.id).wav","recordings/\(session.id).m4a"].compactMap { $0 }.filter { !$0.isEmpty }
        }
        var protected = Set<URL>()
        for path in try expandedImagePaths(remaining.flatMap(\.paths) + sessions.filter({ !removedSessions.contains($0.id) }).flatMap(sessionPaths)) {
            if let url = try? CleanupFiles.ownedURL(path,root:root) { protected.insert(url) }
        }
        let candidates = try expandedImagePaths(removed.flatMap(\.paths) + closedSessions.flatMap(sessionPaths))
        var paths:[String] = [], bytes:Int64 = 0, seen = Set<URL>()
        for path in candidates.sorted() {
            try Task.checkCancellation()
            let url = try CleanupFiles.ownedURL(path,root:root)
            guard !protected.contains(url),seen.insert(url).inserted else { continue }
            bytes += try imageStorageBytes(path,validatedURL:url); paths.append(path)
        }
        return StorageCleanupPlan(scope:scope,keepStarred:keepStarred,preparedAt:date,frameIDs:ids,sessionIDs:Set(closedSessions.map(\.id)),paths:paths,bytes:bytes,skippedActive:skippedActive,skippedStarred:skippedStarred)
    }
    /// Confirmation authorizes this snapshot only. Revalidate stars, active
    /// sessions and shared media under the writer lock before changing anything.
    func clearStorage(_ preview:StorageCleanupPlan,progress:(@Sendable (String)->Void)? = nil) throws -> StorageCleanupResult {
        try synchronized {
            try execute("BEGIN IMMEDIATE")
            var stage:URL?
            do {
                progress?("Checking shared media and protected memories…")
                let plan = try makeCleanupPlan(scope:preview.scope,keepStarred:preview.keepStarred,at:preview.preparedAt,allowedIDs:preview.frameIDs,allowedSessions:preview.sessionIDs)
                guard !plan.frameIDs.isEmpty || !plan.sessionIDs.isEmpty else { try execute("COMMIT");return StorageCleanupResult(memories:0,recordings:0,bytes:0,pendingFileRemoval:false) }
                let folder = root.appendingPathComponent(".cleanup-"+UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false);stage = folder
                let journal = CleanupJournal(frameIDs:Array(plan.frameIDs),paths:plan.paths,sessionIDs:Array(plan.sessionIDs))
                try encoder.encode(journal).write(to:folder.appendingPathComponent("journal.json"),options:.atomic)
                for (index,path) in plan.paths.enumerated() {
                    if index % 256 == 0 { progress?("Removing media · \(index) of \(plan.paths.count) files") }
                    let source = try CleanupFiles.ownedURL(path,root:root)
                    if FileManager.default.fileExists(atPath:source.path) { try FileManager.default.moveItem(at:source,to:folder.appendingPathComponent(String(index))) }
                }
                progress?("Updating the search index…")
                let ids = Array(plan.frameIDs)
                for start in stride(from:0,to:ids.count,by:400) {
                    let batch = Array(ids[start..<min(start+400,ids.count)]), placeholders = batch.map { _ in "?" }.joined(separator:",")
                    // External-content FTS is maintained by row triggers.
                    try execute("DELETE FROM frames WHERE id IN (\(placeholders))",batch)
                }
                for session in plan.sessionIDs {
                    try execute("DELETE FROM transcripts WHERE session=?",[session])
                    try execute("DELETE FROM sessions WHERE id=?",[session])
                }
                try pruneTileReferences()
                try execute("COMMIT")
                // If interrupted after commit, the journal lets startup finish
                // removing quarantined files without touching unrelated content.
                progress?("Reclaiming disk space…")
                var pending = false
                do { try removePackedTiles(plan.paths);try FileManager.default.removeItem(at:folder) } catch { pending = true }
                try? execute("PRAGMA wal_checkpoint(PASSIVE)")
                return StorageCleanupResult(memories:plan.frameIDs.count,recordings:plan.sessionIDs.count,bytes:pending ? 0:plan.bytes,pendingFileRemoval:pending)
            } catch {
                try? execute("ROLLBACK")
                if let stage { try recoverCleanup(stage) }
                throw error
            }
        }
    }
    private func recoverCleanup(_ folder:URL) throws {
        guard let data = try? Data(contentsOf:folder.appendingPathComponent("journal.json")) else { return }
        let journal = try decoder.decode(CleanupJournal.self,from:data)
        guard !journal.frameIDs.isEmpty || journal.sessionIDs?.isEmpty == false else { return }
        var uncommitted = false
        for id in journal.frameIDs {
            if try !jsonRows("SELECT json_quote(id) FROM frames WHERE id=?",[id],as:String.self).isEmpty { uncommitted = true; break }
        }
        if !uncommitted {
            for id in journal.sessionIDs ?? [] {
                if try session(id) != nil { uncommitted = true;break }
            }
        }
        if uncommitted {
            for (index,path) in journal.paths.enumerated() {
                let source = folder.appendingPathComponent(String(index)), destination = try CleanupFiles.ownedURL(path,root:root)
                if FileManager.default.fileExists(atPath:source.path) {
                    // Never replace a file that appeared after an interruption.
                    guard !FileManager.default.fileExists(atPath:destination.path) else { throw RewindError.message("A storage cleanup needs recovery. Its original media was preserved.") }
                    try FileManager.default.moveItem(at:source,to:destination)
                }
            }
        } else {
            try removePackedTiles(journal.paths)
        }
        try FileManager.default.removeItem(at:folder)
    }
    func recoverPendingCleanups() throws {
        try synchronized {
            for folder in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) where folder.lastPathComponent.hasPrefix(".cleanup-") {
                let values = try folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
                guard values.isDirectory == true,values.isSymbolicLink != true else { continue }
                try recoverCleanup(folder)
            }
        }
    }
    func toggleStar(_ id:String) throws -> MemoryFrame? {
        try synchronized {
            guard var frame = try frame(id) else { return nil }
            frame.starred.toggle(); try save(frame); return frame
        }
    }
    /// A background transcription may finish after its recording was cleared.
    func replaceExistingSessionTranscript(sessionID:String,lines:[TranscriptLine]) throws -> Bool {
        try synchronized {
            guard try session(sessionID) != nil else { return false }
            try replaceTranscript(sessionID:sessionID,lines:lines);return true
        }
    }
    /// Keep the existence check and write atomic with respect to media cleanup.
    func updateIndex(frameID:String,text:String,regions:[TextRegion],archive:ScreenArchive? = nil,sourceURL:String? = nil) throws -> MemoryFrame? {
        try synchronized {
            guard var saved = try frame(frameID),saved.deletedAt == nil else { return nil }
            let original = saved.imagePath
            if let archive {
                do {
                    try installArchive(archive)
                    saved.imagePath = archive.path
                } catch {
                    // Space may run out while optimizing. Keep the already
                    // durable lossless source and still publish its OCR text.
                    guard FileManager.default.fileExists(atPath:root.appendingPathComponent(original).path) else { throw error }
                }
            }
            saved.text = ([text] + saved.meetingRegions.map(\.text)).joined(separator:"\n")
            saved.regions = regions
            saved.sourceURL = sourceURL ?? saved.sourceURL
            saved.indexingComplete = true
            try save(saved)
            if let archive,saved.imagePath == archive.path {try finishArchive(archive)}
            if saved.imagePath != original { removeUnreferencedImage(original) }
            return try finalizeVisualFrame(saved)
        }
    }
    private func removeUnreferencedImage(_ path:String) {
        if path.hasPrefix("recordings/"),
           ((try? sessions().contains {$0.videoPath==path || $0.systemAudioPath==path || $0.microphoneAudioPath==path}) ?? true) {return}
        guard let matches = try? jsonRows("SELECT json_quote(id) FROM frames WHERE json_extract(json,'$.imagePath')=? OR json_extract(json,'$.meetingImagePath')=? LIMIT 1",[path,path],as:String.self),matches.isEmpty,
              let users = try? jsonRows("SELECT json_quote(image) FROM image_tiles WHERE tile=? LIMIT 1",[path],as:String.self),users.isEmpty,
              let url = try? CleanupFiles.ownedURL(path,root:root) else {return}
        let tiles = (try? jsonRows("SELECT json_quote(tile) FROM image_tiles WHERE image=?",[path],as:String.self)) ?? []
        // Remove the manifest before its references. A failed unlink keeps all
        // of its tile data intact; recovery retries the durable staging receipt.
        if FileManager.default.fileExists(atPath:url.path) {do {try FileManager.default.removeItem(at:url)} catch {return}}
        if TilePackStore.key(path) != nil {do {try removePackedTiles([path])} catch {return}}
        try? execute("DELETE FROM image_tiles WHERE image=?",[path])
        for tile in tiles {removeUnreferencedImage(tile)}
    }
    func saveRecognizedFrame(_ frame:MemoryFrame,archive:ScreenArchive) throws {
        try synchronized {
            try installArchive(archive)
            var frame = frame;frame.imagePath = archive.path
            try save(frame);try finishArchive(archive)
        }
    }
    /// Only a finalized native capture can replace the OCR spool. These paths
    /// also participate in shared-media cleanup via image_tiles.
    private func finalizeVisualFrame(_ source:MemoryFrame)throws->MemoryFrame {
        guard source.indexingComplete == true,!source.imagePath.hasSuffix("."+VisualArchive.fileExtension),
              let time=source.visualTime,let width=source.visualWidth,let height=source.visualHeight,
              let id=source.sessionID,let session=try session(id),session.visualArchiveReady == true,let end=session.endedAt,
              time.isFinite,time>=0,time<end.timeIntervalSince(session.startedAt)+0.01 else {return source}
        let reference=VisualArchive(video:session.videoPath,time:time,width:width,height:height)
        let video=try reference.validate(root:root)
        guard (try CleanupFiles.size(video))>0 else {return source}
        let path="frames/visual-\(source.id)."+VisualArchive.fileExtension
        let file=try CleanupFiles.ownedURL(path,root:root),data=try encoder.encode(reference),digest=ImageArchive.digest(data)
        try execute("INSERT OR REPLACE INTO image_archive_staging VALUES(?,?)",[path,digest])
        try data.write(to:file,options:.atomic)
        let handle=try FileHandle(forWritingTo:file);defer {try? handle.close()};try handle.synchronize()
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("INSERT OR IGNORE INTO image_tiles VALUES(?,?)",[path,session.videoPath])
            try execute("UPDATE frames SET json=json_set(json,'$.imagePath',?) WHERE id=?",[path,source.id])
            try execute("INSERT OR REPLACE INTO image_archives VALUES(?,?,?,?)",[source.imagePath,path,digest,ImageArchive.policyVersion])
            try execute("DELETE FROM image_archive_staging WHERE destination=?",[path])
            try execute("COMMIT")
        } catch {try? execute("ROLLBACK");throw error}
        removeUnreferencedImage(source.imagePath)
        var saved=source;saved.imagePath=path;return saved
    }
    func finalizeVisualSession(_ id:String)throws->[MemoryFrame] {
        try synchronized {
            if try session(id)?.visualArchiveReady == false {
                try execute("UPDATE frames SET json=json_remove(json,'$.visualTime','$.visualWidth','$.visualHeight') WHERE json_extract(json,'$.sessionID')=?",[id])
            }
            let frames=try jsonRows("SELECT json FROM frames WHERE json_extract(json,'$.sessionID')=? AND deleted IS NULL",[id],as:MemoryFrame.self)
            return try frames.compactMap { source in
                try Task.checkCancellation()
                let saved=try finalizeVisualFrame(hydrate(source))
                return saved.imagePath == source.imagePath ? nil:saved
            }
        }
    }
    func unfinishedVisualSessions()throws->[String] {
        try jsonRows("""
            SELECT DISTINCT json_quote(s.id) FROM sessions s JOIN frames f
            ON json_extract(f.json,'$.sessionID')=s.id WHERE json_extract(s.json,'$.visualArchiveReady')=1
            AND f.deleted IS NULL AND json_extract(f.json,'$.indexingComplete')=1
            AND json_extract(f.json,'$.visualTime') IS NOT NULL
            AND json_extract(f.json,'$.imagePath') NOT LIKE '%.recallvideo'
            """,as:String.self)
    }
    /// An interrupted open movie is never trusted as a replacement for original
    /// OCR pixels. Preserve it for recovery/playback and use ordinary image
    /// archives for that unfinished segment. Fully committed segments stay shared.
    private func recoverInterruptedVisualSessions()throws {
        for var session in try sessions() where session.unifiedVisualArchive == true && session.endedAt == nil {
            let frames=try jsonRows("SELECT json FROM frames WHERE json_extract(json,'$.sessionID')=?",[session.id],as:MemoryFrame.self)
            session.endedAt=frames.map {$0.endTimestamp ?? $0.timestamp}.max() ?? session.startedAt
            session.visualArchiveReady=false
            try execute("BEGIN IMMEDIATE")
            do {
                try saveSession(session)
                try execute("UPDATE frames SET json=json_remove(json,'$.visualTime','$.visualWidth','$.visualHeight') WHERE json_extract(json,'$.sessionID')=?",[session.id])
                try execute("COMMIT")
            } catch {try? execute("ROLLBACK");throw error}
        }
    }
    func interruptedVisualImages()throws->[String] {
        try jsonRows("""
            SELECT DISTINCT json_quote(json_extract(f.json,'$.imagePath')) FROM frames f JOIN sessions s
            ON json_extract(f.json,'$.sessionID')=s.id WHERE json_extract(s.json,'$.unifiedVisualArchive')=1
            AND json_extract(s.json,'$.visualArchiveReady')=0 AND json_extract(f.json,'$.indexingComplete')=1
            AND json_extract(f.json,'$.imagePath') LIKE 'frames/source-%.png'
            """,as:String.self)
    }
    func updateMeetingIndex(frameID:String,result:ScreenIndexResult) throws -> MemoryFrame? {
        try synchronized {
            guard var saved = try frame(frameID),saved.deletedAt == nil else { return nil }
            try installArchive(result.archive)
            let original = saved.meetingImagePath
            saved.meetingImagePath = result.archive.path;saved.meetingRegions = result.regions
            saved.sourceURL = saved.sourceURL ?? result.sourceURL
            saved.text = (saved.regions.map(\.text)+[result.text]).joined(separator:"\n")
            try save(saved);try finishArchive(result.archive)
            if let original,original != saved.meetingImagePath { removeUnreferencedImage(original) }
            return saved
        }
    }
    /// Publish the new path before removing an unused original. A failed or
    /// interrupted encode can never replace the session's playable recording.
    func commitVideoArchive(sessionID:String,originalPath:String,candidatePath:String,result:VideoArchiveResult,originalModifiedAt:Date? = nil) throws -> Int64 {
        try synchronized {
            guard var session = try session(sessionID),session.endedAt != nil,session.videoPath == originalPath else { return 0 }
            let original = try CleanupFiles.ownedURL(originalPath,root:root)
            guard try CleanupFiles.size(original) == result.originalBytes else { return 0 }
            if let originalModifiedAt {
                guard try original.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate == originalModifiedAt else { return 0 }
            }
            for reference in result.externalAudio {
                guard [session.systemAudioPath,session.microphoneAudioPath].contains(reference.path),try reference.isUnchanged(root:root) else { throw RewindError.message("The independent audio changed during optimization. Keeping the original recording.") }
            }
            if !result.externalAudio.isEmpty { session.usesExternalAudio = true }
            session.videoOptimizationChecked = true
            session.videoOptimizationVersion = VideoArchive.policyVersion
            guard result.accepted else { try saveSession(session);return 0 }
            let candidate = try CleanupFiles.ownedURL(candidatePath,root:root)
            guard try CleanupFiles.size(candidate) == result.archivedBytes else { throw RewindError.message("The optimized recording changed before it could be saved.") }
            let handle = try FileHandle(forWritingTo:candidate)
            do { try handle.synchronize();try handle.close() } catch { try? handle.close();throw error }
            session.videoPath = candidatePath
            session.supersededVideoPath = originalPath
            session.originalVideoBytes = result.originalBytes;session.archivedVideoBytes = result.archivedBytes
            try saveSession(session)
            // A legacy library may contain sessions that share one media file.
            let references = try sessions().contains { $0.videoPath == originalPath || $0.systemAudioPath == originalPath || $0.microphoneAudioPath == originalPath }
            if !references { try? FileManager.default.removeItem(at:original) }
            if !FileManager.default.fileExists(atPath:original.path) { session.supersededVideoPath = nil;try saveSession(session) }
            return FileManager.default.fileExists(atPath:original.path) ? 0:max(0,result.originalBytes-result.archivedBytes)
        }
    }
    private func recoverVideoArchives() throws {
        try synchronized {
            let all = try sessions()
            for var session in all {
                guard let old = session.supersededVideoPath,old != session.videoPath,
                      let archived = try? CleanupFiles.ownedURL(session.videoPath,root:root),
                      let size = try? CleanupFiles.size(archived),size > 0,size == session.archivedVideoBytes,
                      !all.contains(where:{$0.videoPath == old || $0.systemAudioPath == old || $0.microphoneAudioPath == old}),
                      let original = try? CleanupFiles.ownedURL(old,root:root) else { continue }
                if FileManager.default.fileExists(atPath:original.path) { try? FileManager.default.removeItem(at:original) }
                if !FileManager.default.fileExists(atPath:original.path) { session.supersededVideoPath = nil;try saveSession(session) }
            }
        }
    }
}

extension MemoryStore {
    private func hydrate(_ source:MemoryFrame)throws->MemoryFrame {
        guard let key = source.ocrKey else { return source }
        let text:String,payload:SharedOCR
        if let cached = ocrCache[key] { (text,payload) = cached }
        else {
            guard let encoded = try jsonRows("SELECT json_quote(json) FROM ocr_payloads WHERE key=?",[key],as:String.self).first,
                  let value = try jsonRows("SELECT json_quote(text) FROM ocr_payloads WHERE key=?",[key],as:String.self).first else {
                throw RewindError.message("A shared text index is missing. The screenshot is still saved.")
            }
            let loaded = try CompactOCR.payload(encoded)
            text = value;payload = loaded;ocrCache[key] = (value,loaded);ocrCacheOrder.append(key)
            while ocrCacheOrder.count > 32 { ocrCache.removeValue(forKey:ocrCacheOrder.removeFirst()) }
        }
        var frame = source;frame.text = text;frame.regions = payload.regions;frame.meetingRegions = payload.meetingRegions
        if let ids = try CompactOCR.regionIDs(frame.compactRegionIDs) ?? frame.ocrRegionIDs,ids.count == frame.regions.count { for i in ids.indices { frame.regions[i].id = ids[i] } }
        if let ids = try CompactOCR.regionIDs(frame.compactMeetingRegionIDs) ?? frame.ocrMeetingRegionIDs,ids.count == frame.meetingRegions.count { for i in ids.indices { frame.meetingRegions[i].id = ids[i] } }
        return frame
    }
    private func saveSharedFrame(_ source:MemoryFrame)throws {
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(SharedOCR(source)),key = SharedOCR.key(text:source.text,data:data)
        try execute("INSERT OR IGNORE INTO ocr_payloads (key,text,json) VALUES (?,?,?)",[key,source.text,try CompactOCR.payload(data)])
        var frame = source;frame.ocrKey = key
        frame.compactRegionIDs = try CompactOCR.regionIDs(source.regions.map(\.id))
        frame.compactMeetingRegionIDs = try CompactOCR.regionIDs(source.meetingRegions.map(\.id))
        frame.ocrRegionIDs = nil;frame.ocrMeetingRegionIDs = nil
        frame.text = "";frame.regions = [];frame.meetingRegions = []
        try execute("""
            INSERT INTO frames (id,time,app,text,starred,deleted,demo,json) VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET time=excluded.time,app=excluded.app,text=excluded.text,
                starred=excluded.starred,deleted=excluded.deleted,demo=excluded.demo,json=excluded.json
            """,[frame.id,frame.timestamp.timeIntervalSince1970,frame.appName,frame.title,frame.starred ? 1:0,frame.deletedAt?.timeIntervalSince1970,frame.demo ? 1:0,try json(frame)])
    }
    private func migrateSharedOCR()throws {
        let version = try jsonRows("PRAGMA user_version",as:Int.self).first ?? 0
        guard version < 2 else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("CREATE TABLE IF NOT EXISTS ocr_payloads (key TEXT PRIMARY KEY,text TEXT NOT NULL,json TEXT NOT NULL)")
            let ids = try jsonRows("SELECT json_quote(id) FROM frames ORDER BY rowid",as:String.self)
            for id in ids { if let frame = try frame(id) { try saveSharedFrame(frame) } }
            try execute("DROP TABLE IF EXISTS frame_fts")
            try execute("CREATE VIRTUAL TABLE frame_fts USING fts5(id UNINDEXED,text,content='frames',content_rowid='rowid',tokenize='unicode61')")
            try execute("CREATE VIRTUAL TABLE ocr_fts USING fts5(text,content='ocr_payloads',content_rowid='rowid',tokenize='unicode61')")
            try execute("INSERT INTO frame_fts(frame_fts) VALUES ('rebuild')")
            try execute("INSERT INTO ocr_fts(ocr_fts) VALUES ('rebuild')")
            try execute("CREATE TRIGGER frame_search_insert AFTER INSERT ON frames BEGIN INSERT INTO frame_fts(rowid,id,text) VALUES(new.rowid,new.id,new.text); END")
            try execute("CREATE TRIGGER frame_search_delete AFTER DELETE ON frames BEGIN INSERT INTO frame_fts(frame_fts,rowid,id,text) VALUES('delete',old.rowid,old.id,old.text); END")
            try execute("CREATE TRIGGER frame_search_update AFTER UPDATE OF text ON frames WHEN old.text!=new.text BEGIN INSERT INTO frame_fts(frame_fts,rowid,id,text) VALUES('delete',old.rowid,old.id,old.text); INSERT INTO frame_fts(rowid,id,text) VALUES(new.rowid,new.id,new.text); END")
            try execute("CREATE TRIGGER ocr_search_insert AFTER INSERT ON ocr_payloads BEGIN INSERT INTO ocr_fts(rowid,text) VALUES(new.rowid,new.text); END")
            try execute("CREATE TRIGGER ocr_search_delete AFTER DELETE ON ocr_payloads BEGIN INSERT INTO ocr_fts(ocr_fts,rowid,text) VALUES('delete',old.rowid,old.text); END")
            try execute("CREATE VIEW frame_search AS SELECT f.id,f.text||char(10)||COALESCE(p.text,'') AS text FROM frames f LEFT JOIN ocr_payloads p ON p.key=json_extract(f.json,'$.ocrKey')")
            try execute("CREATE INDEX frames_ocr ON frames(json_extract(json,'$.ocrKey'))")
            try execute("CREATE INDEX frames_pixels ON frames(json_extract(json,'$.pixelDigest'))")
            try execute("CREATE INDEX frames_end ON frames(COALESCE(json_extract(json,'$.endTimestamp')+978307200,time))")
            try execute("PRAGMA user_version=2");try execute("COMMIT");needsIndexCompaction = !ids.isEmpty
        } catch { try? execute("ROLLBACK");throw error }
    }
    func compactIndex()throws {
        try synchronized {
            try Task.checkCancellation()
            sqlite3_progress_handler(db,4000,{_ in Task.isCancelled ? 1:0},nil)
            defer {sqlite3_progress_handler(db,0,nil,nil)}
            // Fold layout migration into this vacuum instead of copying the
            // database once for each optimizer job.
            try compactTileReferences(reclaim:false)
            try pruneTileReferences()
            try execute("INSERT INTO frame_fts(frame_fts,rank) VALUES('integrity-check',1)")
            try execute("INSERT INTO ocr_fts(ocr_fts,rank) VALUES('integrity-check',1)")
            try execute("PRAGMA wal_checkpoint(PASSIVE)")
            let freePages = try jsonRows("PRAGMA freelist_count",as:Int.self).first ?? 0
            if freePages > 128 || needsIndexCompaction {try execute("VACUUM")}
            try execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try execute("UPDATE storage_maintenance SET value=0 WHERE key='tile-index-vacuum'")
            needsIndexCompaction = false
        }
    }
    func extendCapture(_ id:String,through date:Date)throws->Bool {
        try synchronized {
            try execute("UPDATE frames SET json=json_set(json,'$.endTimestamp',MAX(COALESCE(json_extract(json,'$.endTimestamp'),json_extract(json,'$.timestamp')),?)) WHERE id=? AND deleted IS NULL AND time<=?",[date.timeIntervalSinceReferenceDate,id,date.timeIntervalSince1970])
            return sqlite3_changes(db) > 0
        }
    }
    func frameWithPixels(_ digest:String)throws->MemoryFrame? {
        try jsonRows("SELECT json FROM frames WHERE json_extract(json,'$.pixelDigest')=? AND deleted IS NULL ORDER BY json_extract(json,'$.indexingComplete') DESC,time DESC LIMIT 1",[digest],as:MemoryFrame.self).first
    }
}
