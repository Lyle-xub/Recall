using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace Rewind;

// One row in the archive's virtualized wall. Text, OCR regions, and recording
// details stay on disk until Frame(id) is requested for a selected card.
public sealed record ArchiveFrame(string Id, DateTimeOffset Timestamp, string AppName,
    string Title, string ImagePath, bool Starred);

public sealed partial class MemoryStore : IDisposable
{
    public string Root
    {
        get;
    }
    private readonly SqliteConnection db = null!;
    private readonly LibraryLocationLease? location;
    private readonly object gate = new();
    private readonly object mediaGate = new();
    private long archiveRevision;
    private long usageRevision;
    // This is a process-local generation, not a persisted SQLite change token.
    // Save covers Star/Trash/Restore/Recognition/ReplaceImage; Retain and
    // Cleanup are the direct frame writes. End-time and OCR-only writes do
    // not change ArchiveFrame's projection. Reading never scans the database.
    public long ArchiveRevision => Interlocked.Read(ref archiveRevision);
    public long UsageRevision => Interlocked.Read(ref usageRevision);
    public void WithMediaLock(Action action)
    {
        lock (mediaGate)
            action();
    }
    public MemoryStore(string root, bool readOnly = false, bool initialize = true, DefaultLibrary? locationPair = null)
    {
        Root = Path.GetFullPath(root);
        location = LibraryLocationLease.Access(Root, locationPair, createParent: !readOnly && initialize);
        try {
        var format = LibraryFormats.Detect(Root);
        if (format is LibraryFormat.MacOS or LibraryFormat.Unknown)
            throw new InvalidDataException("This database requires its original platform adapter; no schema changes were made.");
        if (readOnly || !initialize)
        {
            db = new(new SqliteConnectionStringBuilder { DataSource = Path.Combine(Root, "memory.sqlite"), Mode = readOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWrite, DefaultTimeout = 15, Pooling = false }.ToString());
            db.Open();
            try {if(!readOnly){RecoverPendingVisualArchives();RecoverPendingCleanups();}}catch {db.Dispose();throw;}
            return;
        }
        Directory.CreateDirectory(Root);
        foreach (var dir in new[] { "frames", "recordings", "icons" })
            Directory.CreateDirectory(Path.Combine(Root, dir));
        db = new(new SqliteConnectionStringBuilder { DataSource = Path.Combine(Root, "memory.sqlite"), DefaultTimeout = 15, Pooling = false }.ToString());
        db.Open();
        Execute("PRAGMA journal_mode=WAL");
        Execute("PRAGMA busy_timeout=15000");
        Execute("CREATE TABLE IF NOT EXISTS frames(id TEXT PRIMARY KEY,time REAL,app TEXT,text TEXT,starred INTEGER,deleted REAL,demo INTEGER,json TEXT)");
        Execute("CREATE INDEX IF NOT EXISTS frames_time ON frames(time DESC)");
        Execute("CREATE INDEX IF NOT EXISTS frames_archive_time ON frames(time DESC,id) WHERE demo=0 AND deleted IS NULL");
        Execute("CREATE INDEX IF NOT EXISTS frames_app ON frames(app,time DESC)");
        Execute("CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,json TEXT)");
        Execute("CREATE TABLE IF NOT EXISTS transcripts(id TEXT PRIMARY KEY,session TEXT,time REAL,text TEXT,json TEXT)");
        Execute("CREATE INDEX IF NOT EXISTS transcripts_session_time ON transcripts(session,time)");
        using (var command = Command("SELECT COUNT(*) FROM pragma_table_info('frames') WHERE name='ocr_id'"))
            if (Convert.ToInt32(command.ExecuteScalar()) == 0)
                Execute("ALTER TABLE frames ADD COLUMN ocr_id TEXT");
        Execute("CREATE INDEX IF NOT EXISTS frames_image ON frames(json_extract(json,'$.ImagePath'))");
        Execute("CREATE INDEX IF NOT EXISTS frames_meeting_image ON frames(json_extract(json,'$.MeetingImagePath'))");
        Execute("CREATE INDEX IF NOT EXISTS frames_ocr ON frames(ocr_id)");
        Execute("CREATE INDEX IF NOT EXISTS frames_pixel ON frames(json_extract(json,'$.PixelHash'))");
        Execute("CREATE INDEX IF NOT EXISTS frames_session ON frames(json_extract(json,'$.SessionId'))");
        Execute("CREATE TABLE IF NOT EXISTS ocr_payloads(id TEXT UNIQUE NOT NULL,text TEXT NOT NULL,regions TEXT NOT NULL,meeting_regions TEXT NOT NULL)");
        Execute("CREATE VIRTUAL TABLE IF NOT EXISTS ocr_fts USING fts5(text,content='ocr_payloads',content_rowid='rowid',tokenize='unicode61 remove_diacritics 2',prefix='2 3 4')");
        Execute("CREATE TRIGGER IF NOT EXISTS ocr_insert AFTER INSERT ON ocr_payloads BEGIN INSERT INTO ocr_fts(rowid,text) VALUES(new.rowid,new.text); END");
        Execute("CREATE TRIGGER IF NOT EXISTS ocr_delete AFTER DELETE ON ocr_payloads BEGIN INSERT INTO ocr_fts(ocr_fts,rowid,text) VALUES('delete',old.rowid,old.text); END");
        Execute("CREATE TABLE IF NOT EXISTS app_usage(id TEXT PRIMARY KEY,start REAL NOT NULL,end REAL NOT NULL,json TEXT NOT NULL)");
        Execute("CREATE INDEX IF NOT EXISTS app_usage_range ON app_usage(start,end)");
        // Migrate the old WPF library once, retaining identifiers and media paths.
        while (true)
        {
            var legacy = Rows<MemoryFrame>("SELECT json FROM frames WHERE ocr_id IS NULL LIMIT 200");
            if (legacy.Count == 0)
                break;
            foreach (var frame in legacy)
                Save(frame);
        }
        try {RecoverPendingVisualArchives();RecoverPendingCleanups();}catch {db.Dispose();throw;}
        } catch { db?.Dispose(); location?.Dispose(); throw; }
    }
    private static double Seconds(DateTimeOffset date) => date.ToUnixTimeMilliseconds() / 1000.0;
    private SqliteCommand Command(string sql, params object?[] values)
    {
        var cmd = db.CreateCommand();
        cmd.CommandText = sql;
        for (var i = 0; i < values.Length; i++)
            cmd.Parameters.AddWithValue("$p" + i, values[i] ?? DBNull.Value);
        return cmd;
    }
    private void Execute(string sql, params object?[] values)
    {
        lock (gate)
        {
            using var cmd = Command(sql, values);
            cmd.ExecuteNonQuery();
        }
    }
    private int ExecuteAffected(string sql, params object?[] values)
    {
        lock (gate)
        {
            using var cmd = Command(sql, values);
            return cmd.ExecuteNonQuery();
        }
    }
    private readonly record struct ArchiveProjection(double Time, string App, string Title,
        string ImagePath, bool Starred, bool Visible);
    private ArchiveProjection? CurrentArchiveProjection(string id)
    {
        using var cmd = Command("SELECT time,app,starred,deleted,demo,json_extract(json,'$.Title')," +
            "json_extract(json,'$.ImagePath') FROM frames WHERE id=$p0", id);
        using var reader = cmd.ExecuteReader();
        if (!reader.Read()) return null;
        return new ArchiveProjection(reader.GetDouble(0), reader.IsDBNull(1) ? "Desktop" : reader.GetString(1),
            reader.IsDBNull(5) ? "" : reader.GetString(5), reader.IsDBNull(6) ? "" : reader.GetString(6),
            !reader.IsDBNull(2) && reader.GetInt64(2) != 0,
            reader.IsDBNull(3) && !reader.IsDBNull(4) && reader.GetInt64(4) == 0);
    }
    private static ArchiveProjection Projection(MemoryFrame frame) =>
        new(Seconds(frame.Timestamp), frame.AppName, frame.Title, frame.ImagePath,
            frame.Starred, !frame.Demo && frame.DeletedAt == null);
    private static bool ArchiveChanged(ArchiveProjection? before, ArchiveProjection after) =>
        before is null ? after.Visible :
        (before.Value.Visible || after.Visible) && before.Value != after;
    private List<T> Rows<T>(string sql, params object?[] values)
    {
        lock (gate)
        {
            using var cmd = Command(sql, values);
            using var reader = cmd.ExecuteReader();
            var rows = new List<T>();
            while (reader.Read())
                rows.Add(JsonSerializer.Deserialize<T>(reader.GetString(0))!);
            return rows;
        }
    }
    private List<MemoryFrame> ReadFrames(string sql, params object?[] values)
    {
        lock (gate)
        {
            using var cmd = Command(sql, values);
            using var reader = cmd.ExecuteReader();
            var rows = new List<MemoryFrame>();
            while (reader.Read())
            {
                var f = JsonSerializer.Deserialize<MemoryFrame>(reader.GetString(0))!;
                if (!reader.IsDBNull(1))
                    f = f with
                    {
                        Text = reader.GetString(1),
                        Regions = CompactOcrRegions.Decode(reader.GetString(2)),
                        MeetingRegions = CompactOcrRegions.Decode(reader.GetString(3))
                    };
                rows.Add(f);
            }
            return rows;
        }
    }
    private const string SelectFrame = "SELECT f.json,o.text,o.regions,o.meeting_regions FROM frames f LEFT JOIN ocr_payloads o ON o.id=f.ocr_id ";
    public void Save(MemoryFrame frame)
    {
        lock (gate)
        {
            var before = CurrentArchiveProjection(frame.Id);
            var after = Projection(frame);
            var regions = JsonSerializer.Serialize(frame.Regions);
            var meeting = JsonSerializer.Serialize(frame.MeetingRegions);
            var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[] { frame.Text, regions, meeting }))));
            Execute("INSERT OR IGNORE INTO ocr_payloads(id,text,regions,meeting_regions) VALUES($p0,$p1,$p2,$p3)", hash, frame.Text, CompactOcrRegions.Encode(frame.Regions), CompactOcrRegions.Encode(frame.MeetingRegions));
            var compact = frame with
            {
                OcrId = hash,
                Text = "",
                Regions = [],
                MeetingRegions = []
            };
            Execute("INSERT OR REPLACE INTO frames(id,time,app,text,starred,deleted,demo,json,ocr_id) VALUES($p0,$p1,$p2,$p3,$p4,$p5,$p6,$p7,$p8)", frame.Id, Seconds(frame.Timestamp), frame.AppName, MemorySearch.Normalize(frame.AppName + "\n" + frame.Title), frame.Starred ? 1 : 0, frame.DeletedAt is { } d ? Seconds(d) : null, frame.Demo ? 1 : 0, JsonSerializer.Serialize(compact), hash);
            if (ArchiveChanged(before, after)) Interlocked.Increment(ref archiveRevision);
        }
    }
    public MemoryFrame? ExactImage(string hash) => ReadFrames(SelectFrame + "WHERE json_extract(f.json,'$.PixelHash')=$p0 AND json_extract(f.json,'$.TextState') IN (2,3) ORDER BY f.time DESC LIMIT 1", hash).FirstOrDefault();
    public void MarkOptimized(string path)
    {
        lock (gate)
        {
            foreach (var f in MetadataFrames().Where(f => f.ImagePath == path))
            {
                var full = Frame(f.Id);
                if (full != null)
                    Save(full with
                    {
                        ImageQuality = .5
                    });
            }
        }
    }
    public bool FinishSpeech(RecordingSession session, List<TranscriptLine> lines)
    {
        lock (gate)
        {
            var current = Session(session.Id);
            if (current == null)
                return false;
            ReplaceTranscript(session.Id, lines);
            SaveSession(current with
            {
                SpeechState = session.SpeechState,
                SpeechError = session.SpeechError
            });
            return true;
        }
    }
    public MemoryFrame? Frame(string id) => ReadFrames(SelectFrame + "WHERE f.id=$p0", id).FirstOrDefault();
    public void Extend(string id, DateTimeOffset end) => Execute("UPDATE frames SET json=json_set(json,'$.EndTimestamp',$p1) WHERE id=$p0 AND COALESCE(julianday(json_extract(json,'$.EndTimestamp')),julianday(json_extract(json,'$.Timestamp')))<julianday($p1)", id, end.ToString("O"));
    public void Recognized(string id, string text, List<TextRegion> regions, List<TextRegion>? meeting = null, string? imagePath = null, string? meetingPath = null)
    {
        lock (gate)
        {
            var f = Frame(id);
            if (f != null)
                Save(f with
                {
                    Text = text,
                    Regions = regions,
                    MeetingRegions = meeting ?? f.MeetingRegions,
                    ImagePath = imagePath ?? f.ImagePath,
                    MeetingImagePath = meetingPath ?? f.MeetingImagePath,
                    TextState = string.IsNullOrWhiteSpace(text) ? RecognitionState.Empty : RecognitionState.Complete,
                    TextError = null
                });
        }
    }
    public void Recognition(string id, RecognitionState state, string? error = null)
    {
        lock (gate)
        {
            var f = Frame(id);
            if (f != null)
                Save(f with
                {
                    TextState = state,
                    TextError = error
                });
        }
    }
    public List<MemoryFrame> Frames(string query = "", string? app = null, bool starred = false, bool trash = false, bool demo = false, DateTimeOffset? since = null, DateTimeOffset? until = null, int limit = 500, int offset = 0, bool ascending = false)
    {
        var conditions = new List<string> { trash ? "f.deleted IS NOT NULL" : "f.deleted IS NULL" };
        var args = new List<object?>();
        string Arg(object? v)
        {
            args.Add(v);
            return "$p" + (args.Count - 1);
        }
        conditions.Add("f.demo=" + Arg(demo ? 1 : 0));
        foreach (var term in MemorySearch.Terms(query))
        {
            var like = Arg(MemorySearch.Like(term));
            var prefix = MemorySearch.Prefix(term);
            var ocr = prefix != null ? $"o.rowid IN (SELECT rowid FROM ocr_fts WHERE ocr_fts MATCH {Arg(prefix)})" : $"lower(o.text) LIKE {like} ESCAPE '\\'";
            conditions.Add($"(f.text LIKE {like} ESCAPE '\\' OR {ocr} OR EXISTS(SELECT 1 FROM transcripts t WHERE t.session=json_extract(f.json,'$.SessionId') AND lower(t.text) LIKE {like} ESCAPE '\\' AND t.time>=f.time-15 AND t.time<=COALESCE((julianday(json_extract(f.json,'$.EndTimestamp'))-2440587.5)*86400,f.time)+15))");
        }
        if (app != null)
            conditions.Add("f.app=" + Arg(app));
        if (starred)
            conditions.Add("f.starred=1");
        if (since != null)
            conditions.Add("f.time>=" + Arg(Seconds(since.Value)));
        if (until != null)
            conditions.Add("f.time<" + Arg(Seconds(until.Value)));
        return ReadFrames(SelectFrame + $"WHERE {string.Join(" AND ", conditions)} ORDER BY f.time {(ascending ? "ASC" : "DESC")},f.id LIMIT {Arg(Math.Clamp(limit, 1, 10000))} OFFSET {Arg(Math.Max(0, offset))}", args.ToArray());
    }
    // The archive wall needs image paths and labels, not the OCR payload of
    // thousands of screenshots. Hydrate a selected frame with Frame(id) only
    // when opening it or performing a text-related action.
    public DateTime? LatestArchiveDay()
    {
        lock (gate)
        {
            using var command = Command("SELECT time FROM frames WHERE demo=0 AND deleted IS NULL ORDER BY time DESC LIMIT 1");
            var value = command.ExecuteScalar();
            return value == null || value == DBNull.Value ? null
                : DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(Convert.ToDouble(value) * 1000)).LocalDateTime.Date;
        }
    }
    public List<MemoryFrame> ArchiveFrames(DateTime day, int daysEachSide = 2, int perDayLimit = 2000)
    {
        var radius = Math.Clamp(daysEachSide, 0, 7);
        var limit = Math.Clamp(perDayLimit, 1, 10000);
        var frames = new List<MemoryFrame>();
        for (var lane = -radius; lane <= radius; lane++)
        {
            var date = DateTime.SpecifyKind(day.Date.AddDays(lane), DateTimeKind.Unspecified);
            // Convert each local midnight independently: a DST day can be
            // shorter or longer than 24 hours.
            var since = new DateTimeOffset(date);
            var until = new DateTimeOffset(date.AddDays(1));
            frames.AddRange(Rows<MemoryFrame>("SELECT json FROM frames WHERE demo=0 AND deleted IS NULL AND time>=$p0 AND time<$p1 ORDER BY time DESC,id LIMIT $p2",
                Seconds(since), Seconds(until), limit));
        }
        return frames.OrderByDescending(frame => frame.Timestamp).ThenBy(frame => frame.Id, StringComparer.Ordinal).ToList();
    }

    // Every matching row is represented once, so a busy day has its true row
    // count and both its newest and oldest cards remain reachable. The query
    // projects only wall fields; it never loads compact frame JSON or OCR.
    public List<ArchiveFrame> ArchiveIndex(DateTime day, int daysEachSide = 2,
        CancellationToken cancellation = default) =>
        ArchiveIndex(day, daysEachSide, cancellation, TimeZoneInfo.Local);

    internal List<ArchiveFrame> ArchiveIndex(DateTime day, int daysEachSide,
        CancellationToken cancellation, TimeZoneInfo zone, Action<int>? rowRead = null)
    {
        cancellation.ThrowIfCancellationRequested();
        var radius = Math.Clamp(daysEachSide, 0, 7);
        var since = ArchiveDayBounds(day.Date.AddDays(-radius), zone).Since;
        var until = ArchiveDayBounds(day.Date.AddDays(radius), zone).Until;
        lock (gate)
        {
            cancellation.ThrowIfCancellationRequested();
            using var command = Command("SELECT id,time,app,starred,json_extract(json,'$.Title'),json_extract(json,'$.ImagePath') " +
                "FROM frames WHERE demo=0 AND deleted IS NULL AND time>=$p0 AND time<$p1 " +
                "ORDER BY time DESC,id COLLATE BINARY ASC", Seconds(since), Seconds(until));
            using var reader = command.ExecuteReader();
            var result = new List<ArchiveFrame>();
            while (reader.Read())
            {
                cancellation.ThrowIfCancellationRequested();
                result.Add(new ArchiveFrame(reader.GetString(0),
                    DateTimeOffset.FromUnixTimeMilliseconds((long)Math.Round(reader.GetDouble(1) * 1000)).ToLocalTime(),
                    reader.IsDBNull(2) ? "Desktop" : reader.GetString(2),
                    reader.IsDBNull(4) ? "" : reader.GetString(4),
                    reader.IsDBNull(5) ? "" : reader.GetString(5), reader.GetInt64(3) != 0));
                rowRead?.Invoke(result.Count);
            }
            return result;
        }
    }

    internal static (DateTimeOffset Since, DateTimeOffset Until) ArchiveDayBounds(DateTime day, TimeZoneInfo zone)
    {
        var start = DateTime.SpecifyKind(day.Date, DateTimeKind.Unspecified);
        var end = start.AddDays(1);
        // Both offsets must be resolved at their own midnight. A local day at
        // a DST transition can contain 23 or 25 hours, not a fixed 24.
        return (new DateTimeOffset(start, zone.GetUtcOffset(start)),
            new DateTimeOffset(end, zone.GetUtcOffset(end)));
    }
    public MemoryFrame? At(DateTimeOffset date)
    {
        var f = ReadFrames(SelectFrame + "WHERE f.demo=0 AND f.deleted IS NULL AND f.time<=$p0 ORDER BY f.time DESC LIMIT 1", Seconds(date)).FirstOrDefault();
        return f != null && date <= (f.EndTimestamp ?? f.Timestamp.AddSeconds(10)).AddSeconds(2) ? f : null;
    }
    public MemoryFrame? Step(DateTimeOffset date, int direction) => ReadFrames(SelectFrame + $"WHERE f.demo=0 AND f.deleted IS NULL AND f.time {(direction < 0 ? "<" : ">")} $p0 ORDER BY f.time {(direction < 0 ? "DESC" : "ASC")} LIMIT 1", Seconds(date)).FirstOrDefault();
    public int Count
    {
        get
        {
            lock (gate)
            {
                using var cmd = Command("SELECT COUNT(*) FROM frames WHERE demo=0 AND deleted IS NULL");
                return Convert.ToInt32(cmd.ExecuteScalar());
            }
        }
    }
    public List<string> AppNames(bool demo = false, bool trash = false, DateTimeOffset? since = null)
    {
        var sql = "SELECT DISTINCT json_quote(app) FROM frames WHERE demo=$p0 AND " + (trash ? "deleted IS NOT NULL" : "deleted IS NULL");
        var args = new List<object?> { demo ? 1 : 0 };
        if (since != null)
        {
            sql += " AND time>=$p1";
            args.Add(Seconds(since.Value));
        }
        return Rows<string>(sql + " ORDER BY app COLLATE NOCASE", args.ToArray());
    }
    public List<MemoryFrame> Retrieve(string question, bool demo = false, DateTimeOffset? since = null, string? app = null, string? previous = null)
    {
        var plan = MemorySearch.Question(question, previous);
        since = plan.Since ?? since;
        if (plan.Broad)
            return Frames(app: app, demo: demo, since: since, until: plan.Until, limit: 12);
        if (plan.Terms.Length == 0)
            return [];
        var matches = Frames(string.Join(" ", plan.Terms), app: app, demo: demo, since: since, until: plan.Until, limit: 24);
        foreach (var term in plan.Terms)
            matches.AddRange(Frames(term, app: app, demo: demo, since: since, until: plan.Until, limit: 24));
        return matches.DistinctBy(x => x.Id).OrderByDescending(x => plan.Terms.Count(t => MemorySearch.Normalize(x.Text + x.Title).Contains(t))).ThenByDescending(x => x.Timestamp).Take(12).ToList();
    }
    public void SaveSession(RecordingSession s) => Execute("INSERT OR REPLACE INTO sessions VALUES($p0,$p1)", s.Id, JsonSerializer.Serialize(s));
    public bool SpeechStatus(string id, RecognitionState state, string? error = null)
    {
        lock (gate)
        {
            var current = Session(id);
            if (current == null)
                return false;
            SaveSession(current with
            {
                SpeechState = state,
                SpeechError = error
            });
            return true;
        }
    }
    public RecordingSession? Session(string id) => Rows<RecordingSession>("SELECT json FROM sessions WHERE id=$p0", id).FirstOrDefault();
    public List<RecordingSession> Sessions() => Rows<RecordingSession>("SELECT json FROM sessions");
    public void SaveTranscript(TranscriptLine t) => Execute("INSERT OR REPLACE INTO transcripts VALUES($p0,$p1,$p2,$p3,$p4)", t.Id, t.SessionId, Seconds(t.Timestamp), t.Text, JsonSerializer.Serialize(t));
    public void ReplaceTranscript(string session, List<TranscriptLine> lines)
    {
        lock (gate)
        {
            Execute("BEGIN IMMEDIATE");
            try
            {
                Execute("DELETE FROM transcripts WHERE session=$p0", session);
                foreach (var line in lines)
                    SaveTranscript(line);
                Execute("COMMIT");
            }
            catch { Execute("ROLLBACK"); throw; }
        }
    }
    public List<TranscriptLine> Transcript(string id) => Rows<TranscriptLine>("SELECT json FROM transcripts WHERE session=$p0 ORDER BY time", id);
    public void SaveUsage(AppInterval interval)
    {
        Execute("INSERT OR REPLACE INTO app_usage VALUES($p0,$p1,$p2,$p3)", interval.Id, Seconds(interval.Start), Seconds(interval.End), JsonSerializer.Serialize(interval));
        Interlocked.Increment(ref usageRevision);
    }
    public List<AppInterval> Usage(DateTimeOffset start, DateTimeOffset end) => Rows<AppInterval>("SELECT json FROM app_usage WHERE end>$p0 AND start<$p1 ORDER BY start", Seconds(start), Seconds(end));
    public void Trash(MemoryFrame f)
    {
        lock (gate)
        {
            var current = Frame(f.Id);
            if (current != null)
                Save(current with
                {
                    DeletedAt = DateTimeOffset.Now
                });
        }
    }
    public void Restore(MemoryFrame f)
    {
        lock (gate)
        {
            var current = Frame(f.Id);
            if (current != null)
                Save(current with
                {
                    DeletedAt = null
                });
        }
    }
    public void Star(string id)
    {
        lock (gate)
        {
            var f = Frame(id);
            if (f != null)
                Save(f with
                {
                    Starred = !f.Starred
                });
        }
    }
    public void Retain(int days)
    {
        if (days <= 0)
            return;
        var now = DateTimeOffset.Now;
        lock (gate)
            if (ExecuteAffected("UPDATE frames SET deleted=$p0,json=json_set(json,'$.DeletedAt',$p1) WHERE deleted IS NULL AND starred=0 AND demo=0 AND time<$p2 AND (json_extract(json,'$.SessionId') IS NULL OR json_extract(json,'$.SessionId') NOT IN (SELECT id FROM sessions WHERE json_extract(json,'$.EndedAt') IS NULL))", Seconds(now), now.ToString("O"), Seconds(now.AddDays(-days))) > 0)
                Interlocked.Increment(ref archiveRevision);
    }
    public List<MemoryFrame> MetadataFrames() => Rows<MemoryFrame>("SELECT json FROM frames");
    public List<MemoryFrame> PendingFrames() => Rows<MemoryFrame>("SELECT json FROM frames WHERE json_extract(json,'$.TextState') IN (0,1)");
    public List<MemoryFrame> IndexCandidates(int limit = 100) => ReadFrames(SelectFrame + "WHERE f.demo=0 AND f.deleted IS NULL AND json_extract(f.json,'$.TextState') IN (0,4) ORDER BY f.time,f.id LIMIT $p0", Math.Clamp(limit, 1, 10000));
    public List<MemoryFrame> AllFrames() => ReadFrames(SelectFrame);
    public int EmptyTrash() => Cleanup(CleanupPreview(CleanupScope.Trash, true));
    public CleanupPlan CleanupPreview(CleanupScope scope, bool keepStarred, DateTimeOffset? now = null)
    {
        lock (gate)
        {
            var all = MetadataFrames();
            var sessions = Sessions();
            var active = sessions.Where(s => s.EndedAt == null).Select(s => s.Id).ToHashSet();
            var date = now ?? DateTimeOffset.Now;
            var selected = all.Where(f => !f.Demo && (!keepStarred || !f.Starred) && (f.SessionId == null || !active.Contains(f.SessionId)) && (scope == CleanupScope.All || scope == CleanupScope.Trash && f.DeletedAt != null || scope == CleanupScope.Older7Days && f.Timestamp < date.AddDays(-7) || scope == CleanupScope.Older30Days && f.Timestamp < date.AddDays(-30))).ToList();
            var ids = selected.Select(f => f.Id).ToHashSet();
            var kept = all.Where(f => !ids.Contains(f.Id)).ToList();
            var removedSessions = sessions.Where(s => s.EndedAt != null && selected.Any(f => f.SessionId == s.Id) && !kept.Any(f => f.SessionId == s.Id)).ToList();
            var retained = kept.SelectMany(Media).Concat(sessions.Except(removedSessions).SelectMany(Media)).ToHashSet(ArchivePaths.MediaComparer);
            var files = selected.SelectMany(Media).Concat(removedSessions.SelectMany(Media)).Except(retained, ArchivePaths.MediaComparer).Distinct().Where(p => OwnedMediaPath(p) != null).ToArray();
            return new(selected.Select(f => f.Id).ToArray(), files, files.Sum(MediaSize), keepStarred);
        }
    }
    public int Cleanup(CleanupPlan plan)
    {
        lock (mediaGate)
            lock (gate)
            {
                RecoverPendingCleanups();
                var ids = plan.Ids.ToHashSet();
                var all = MetadataFrames();
                var sessions = Sessions();
                var active = sessions.Where(s => s.EndedAt == null).Select(s => s.Id).ToHashSet();
                var removed = all.Where(f => ids.Contains(f.Id) && (!plan.KeepStarred || !f.Starred) && (f.SessionId == null || !active.Contains(f.SessionId))).ToList();
                var actual = removed.Select(f => f.Id).ToHashSet();
                var kept = all.Where(f => !actual.Contains(f.Id)).ToList();
                var removedSessions = sessions.Where(s => s.EndedAt != null && removed.Any(f => f.SessionId == s.Id) && !kept.Any(f => f.SessionId == s.Id)).ToList();
                var retained = kept.SelectMany(Media).Concat(sessions.Except(removedSessions).SelectMany(Media)).ToHashSet(ArchivePaths.MediaComparer);
                var paths = removed.SelectMany(Media).Concat(removedSessions.SelectMany(Media)).Except(retained, ArchivePaths.MediaComparer).Distinct().ToList();
                var control=Path.Combine(Root,".recall-control");
                Directory.CreateDirectory(control);
                if(!OperatingSystem.IsWindows())File.SetUnixFileMode(control,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
                var receipt=Path.Combine(control,"cleanup-"+Guid.NewGuid().ToString("N")+".json");
                Wire.Atomic(receipt,new CleanupRecovery(removed.Select(f=>f.Id).ToArray(),removedSessions.Select(s=>s.Id).ToArray(),paths.ToArray()));
                Execute("BEGIN IMMEDIATE");
                var deletedFrames = 0;
                try
                {
                    foreach (var f in removed)
                        deletedFrames += ExecuteAffected("DELETE FROM frames WHERE id=$p0", f.Id);
                    foreach (var s in removedSessions)
                    {
                        Execute("DELETE FROM sessions WHERE id=$p0", s.Id);
                        Execute("DELETE FROM transcripts WHERE session=$p0", s.Id);
                    }
                    Execute("DELETE FROM ocr_payloads WHERE id NOT IN (SELECT ocr_id FROM frames WHERE ocr_id IS NOT NULL)");
                    Execute("COMMIT");
                    if (deletedFrames > 0) Interlocked.Increment(ref archiveRevision);
                }
                catch { Execute("ROLLBACK");File.Delete(receipt);throw; }
                RecoverPendingCleanups();
                Execute("PRAGMA wal_checkpoint(TRUNCATE)");
                return removed.Count;
            }
    }
    private record CleanupRecovery(string[] Ids,string[] Sessions,string[] Files);
    public void RecoverPendingCleanups()
    {
        var control=Path.Combine(Root,".recall-control");
        if(!Directory.Exists(control))return;
        if((File.GetAttributes(control)&FileAttributes.ReparsePoint)!=0)throw new RecallException("invalid_path","Cleanup directory must not be a symbolic link.");
        lock(mediaGate)lock(gate)
        foreach(var receipt in Directory.EnumerateFiles(control,"cleanup-*.json"))
        {
            if((File.GetAttributes(receipt)&FileAttributes.ReparsePoint)!=0)throw new RecallException("invalid_path","Cleanup receipt must not be a symbolic link.");
            var recovery=JsonSerializer.Deserialize<CleanupRecovery>(File.ReadAllText(receipt),Wire.Json)??throw new RecallException("invalid_data","Invalid cleanup recovery receipt.");
            // A prepared receipt precedes the SQLite transaction. Existing rows
            // mean rollback; absent rows mean its deletion committed before exit.
            if(recovery.Ids.Any(id=>Frame(id)!=null) || recovery.Sessions.Any(id=>Session(id)!=null)){File.Delete(receipt);continue;}
            var referenced=ReferencedMediaPaths();
            try
            {
                foreach(var relative in recovery.Files.Where(p=>!referenced.Contains(p)))
                    if(OwnedMediaPath(relative) is { } full && File.Exists(full))File.Delete(full);
                RemovePackedMedia(recovery.Files.Where(p=>!referenced.Contains(p)));
                File.Delete(receipt);
            }
            catch(Exception e) when(e is IOException or UnauthorizedAccessException)
            {throw new RecallException("cleanup_pending","Database cleanup committed; some media could not be removed. The next writable open resumes removal after file access is restored.",new {receipt,error=e.Message});}
        }
    }
    public void ReplaceImage(string source, string target,double? quality = null)
    {
        lock (gate)
        {
            Execute("BEGIN IMMEDIATE");
            try
            {
                foreach (var f in AllFrames().Where(f => f.ImagePath == source || f.MeetingImagePath == source))
                    Save(f with {ImagePath=f.ImagePath==source?target:f.ImagePath,MeetingImagePath=f.MeetingImagePath==source?target:f.MeetingImagePath,ImageQuality=quality??f.ImageQuality});
                Execute("COMMIT");
            }
            catch {Execute("ROLLBACK");throw;}
        }
    }
    private string? OwnedMediaPath(string relative)
    {
        var path=SafePath(relative);
        if(path==null)return null;
        var local=Path.GetRelativePath(Root,path);
        return local.StartsWith("frames"+Path.DirectorySeparatorChar,StringComparison.Ordinal) || local.StartsWith("recordings"+Path.DirectorySeparatorChar,StringComparison.Ordinal) ? path:null;
    }
    public string? SafePath(string relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative)) return null;
        try
        {
            var path = Path.GetFullPath(Path.Combine(Root, relative));
            var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
            if (!path.StartsWith(Path.TrimEndingDirectorySeparator(Root) + Path.DirectorySeparatorChar, comparison)) return null;
            var cursor = Root;
            foreach (var part in Path.GetRelativePath(Root, path).Split(Path.DirectorySeparatorChar))
            {
                cursor = Path.Combine(cursor, part);
                if ((File.Exists(cursor) || Directory.Exists(cursor)) && (File.GetAttributes(cursor) & FileAttributes.ReparsePoint) != 0) return null;
            }
            return path;
        }
        catch (Exception error) when (error is ArgumentException or IOException or UnauthorizedAccessException) { return null; }
    }
    public string CheckIntegrity()
    {
        lock (gate) { using var command = Command("PRAGMA quick_check"); return Convert.ToString(command.ExecuteScalar()) ?? "unknown"; }
    }
    public void CompactIndex()
    {
        lock (gate)
        {
            CompactOcrPayloads();
            Execute("INSERT INTO ocr_fts(ocr_fts,rank) VALUES('integrity-check',1)");
            Execute("PRAGMA wal_checkpoint(PASSIVE)");
            Execute("VACUUM");
            Execute("PRAGMA wal_checkpoint(TRUNCATE)");
        }
    }
    private IEnumerable<string> Media(MemoryFrame f)
    {
        foreach (var path in new[] { f.ImagePath, f.MeetingImagePath }.Where(p => !string.IsNullOrEmpty(p)).Cast<string>())
            foreach (var dependency in MediaDependencies(path)) yield return dependency;
        // The main lossless OCR spool becomes obsolete only after a completed
        // card is committed to an exact video reference. Meeting OCR is separate.
        if (!f.ImagePath.EndsWith(".recallvideo", StringComparison.OrdinalIgnoreCase) || f.TextState is not (RecognitionState.Complete or RecognitionState.Empty))
            if (OwnedMediaPath($"frames/{f.Id}.ocr.png") != null) yield return $"frames/{f.Id}.ocr.png";
        if (OwnedMediaPath($"frames/{f.Id}-meeting.ocr.png") != null) yield return $"frames/{f.Id}-meeting.ocr.png";
    }
    public bool ReferencesImage(string path)
    {
        lock (gate)
        {
            // Normal spool retirement is indexed and does not scan historical OCR.
            var collation = OperatingSystem.IsWindows() ? " COLLATE NOCASE" : "";
            using var command = Command("SELECT count(*) FROM frames WHERE json_extract(json,'$.ImagePath')=$p0" + collation + " OR json_extract(json,'$.MeetingImagePath')=$p0" + collation, path);
            if (Convert.ToInt64(command.ExecuteScalar()) > 0) return true;
            if (TilePackStore.IsTilePath(path) || path.StartsWith("recordings/", StringComparison.Ordinal))
                return ReferencedMediaPaths().Contains(path);
            return false;
        }
    }
    private static IEnumerable<string> Media(RecordingSession s) => new[] { s.VideoPath, s.SystemAudioPath, s.MicrophoneAudioPath, $"recordings/{s.Id}.wav" }.Where(p => !string.IsNullOrEmpty(p)).Cast<string>();
    public void Export(string destination, List<MemoryFrame> frames)
    {
        lock(mediaGate)
        lock(gate)
        {
        Directory.CreateDirectory(destination);
        var sessions = frames.Select(x => x.SessionId).Distinct().Where(x => x != null).Select(x => Session(x!)).Where(x => x != null).Cast<RecordingSession>().ToList();
        var required = frames.SelectMany(f => new[] { f.ImagePath, f.MeetingImagePath }.Where(p => !string.IsNullOrEmpty(p)).Cast<string>())
            .SelectMany(MediaDependencies).Concat(sessions.SelectMany(s => new[] { s.VideoPath, s.SystemAudioPath, s.MicrophoneAudioPath }.Where(p => !string.IsNullOrEmpty(p)).Cast<string>())).ToHashSet(StringComparer.Ordinal);
        foreach (var sidecar in frames.SelectMany(f => new[] { $"frames/{f.Id}.ocr.png", $"frames/{f.Id}-meeting.ocr.png" }).Where(p => File.Exists(SafePath(p)))) required.Add(sidecar);
        foreach (var wav in sessions.Select(s => $"recordings/{s.Id}.wav").Where(p => File.Exists(SafePath(p)))) required.Add(wav);
        foreach (var name in required)
        {
            var source = ArchivePaths.Owned(Root, name);
            var target = ArchivePaths.Owned(destination, name);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            if (TilePackStore.IsTilePath(name))
            {
                var bytes = TilePackStore.ReadTile(Root, name) ?? throw new RecallException("not_found", "A referenced screenshot block is missing; no export was published.");
                File.WriteAllBytes(target, bytes);
            }
            else if (File.Exists(source)) File.Copy(source, target, true);
            else throw new RecallException("not_found", "A referenced media file is missing or unsafe; no export was published.");
        }
        File.WriteAllText(Path.Combine(destination, "frames.json"), JsonSerializer.Serialize(frames));
        File.WriteAllText(Path.Combine(destination, "sessions.json"), JsonSerializer.Serialize(sessions));
        File.WriteAllText(Path.Combine(destination, "transcripts.json"), JsonSerializer.Serialize(sessions.SelectMany(s => Transcript(s.Id))));
        }
    }
    public void Dispose()
    {
        lock (gate)
        {
            db.Dispose();
            location?.Dispose();
        }
    }
}
public enum CleanupScope
{
    Trash, Older30Days, Older7Days, All
}
public record CleanupPlan(string[] Ids, string[] Files, long Bytes, bool KeepStarred);
