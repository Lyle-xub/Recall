using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
namespace Rewind;

public sealed class MemoryStore : IDisposable
{
    public string Root
    {
        get;
    }
    private readonly SqliteConnection db;
    private readonly object gate = new();
    private readonly object mediaGate = new();
    public void WithMediaLock(Action action)
    {
        lock (mediaGate)
            action();
    }
    public MemoryStore(string root)
    {
        Root = Path.GetFullPath(root);
        Directory.CreateDirectory(Root);
        foreach (var dir in new[] { "frames", "recordings", "icons" })
            Directory.CreateDirectory(Path.Combine(Root, dir));
        db = new(new SqliteConnectionStringBuilder { DataSource = Path.Combine(Root, "memory.sqlite"), DefaultTimeout = 15 }.ToString());
        db.Open();
        Execute("PRAGMA journal_mode=WAL");
        Execute("PRAGMA busy_timeout=15000");
        Execute("CREATE TABLE IF NOT EXISTS frames(id TEXT PRIMARY KEY,time REAL,app TEXT,text TEXT,starred INTEGER,deleted REAL,demo INTEGER,json TEXT)");
        Execute("CREATE INDEX IF NOT EXISTS frames_time ON frames(time DESC)");
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
                        Regions = JsonSerializer.Deserialize<List<TextRegion>>(reader.GetString(2)) ?? [],
                        MeetingRegions = JsonSerializer.Deserialize<List<TextRegion>>(reader.GetString(3)) ?? []
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
            var regions = JsonSerializer.Serialize(frame.Regions);
            var meeting = JsonSerializer.Serialize(frame.MeetingRegions);
            var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new[] { frame.Text, regions, meeting }))));
            Execute("INSERT OR IGNORE INTO ocr_payloads(id,text,regions,meeting_regions) VALUES($p0,$p1,$p2,$p3)", hash, frame.Text, regions, meeting);
            var compact = frame with
            {
                OcrId = hash,
                Text = "",
                Regions = [],
                MeetingRegions = []
            };
            Execute("INSERT OR REPLACE INTO frames(id,time,app,text,starred,deleted,demo,json,ocr_id) VALUES($p0,$p1,$p2,$p3,$p4,$p5,$p6,$p7,$p8)", frame.Id, Seconds(frame.Timestamp), frame.AppName, MemorySearch.Normalize(frame.AppName + "\n" + frame.Title), frame.Starred ? 1 : 0, frame.DeletedAt is { } d ? Seconds(d) : null, frame.Demo ? 1 : 0, JsonSerializer.Serialize(compact), hash);
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
    public void SaveUsage(AppInterval interval) => Execute("INSERT OR REPLACE INTO app_usage VALUES($p0,$p1,$p2,$p3)", interval.Id, Seconds(interval.Start), Seconds(interval.End), JsonSerializer.Serialize(interval));
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
        Execute("UPDATE frames SET deleted=$p0,json=json_set(json,'$.DeletedAt',$p1) WHERE deleted IS NULL AND starred=0 AND demo=0 AND time<$p2", Seconds(now), now.ToString("O"), Seconds(now.AddDays(-days)));
    }
    public List<MemoryFrame> MetadataFrames() => Rows<MemoryFrame>("SELECT json FROM frames");
    public List<MemoryFrame> PendingFrames() => Rows<MemoryFrame>("SELECT json FROM frames WHERE json_extract(json,'$.TextState') IN (0,1)");
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
            var files = selected.SelectMany(Media).Except(kept.SelectMany(Media)).Concat(removedSessions.SelectMany(Media)).Distinct().Where(p => SafePath(p) != null).ToArray();
            return new(selected.Select(f => f.Id).ToArray(), files, files.Sum(p => File.Exists(SafePath(p)) ? new FileInfo(SafePath(p)!).Length : 0), keepStarred);
        }
    }
    public int Cleanup(CleanupPlan plan)
    {
        lock (mediaGate)
            lock (gate)
            {
                var ids = plan.Ids.ToHashSet();
                var all = MetadataFrames();
                var sessions = Sessions();
                var active = sessions.Where(s => s.EndedAt == null).Select(s => s.Id).ToHashSet();
                var removed = all.Where(f => ids.Contains(f.Id) && (!plan.KeepStarred || !f.Starred) && (f.SessionId == null || !active.Contains(f.SessionId))).ToList();
                var actual = removed.Select(f => f.Id).ToHashSet();
                var kept = all.Where(f => !actual.Contains(f.Id)).ToList();
                var removedSessions = sessions.Where(s => s.EndedAt != null && removed.Any(f => f.SessionId == s.Id) && !kept.Any(f => f.SessionId == s.Id)).ToList();
                var paths = removed.SelectMany(Media).Except(kept.SelectMany(Media)).Concat(removedSessions.SelectMany(Media)).Distinct().ToList();
                Execute("BEGIN IMMEDIATE");
                try
                {
                    foreach (var f in removed)
                        Execute("DELETE FROM frames WHERE id=$p0", f.Id);
                    foreach (var s in removedSessions)
                    {
                        Execute("DELETE FROM sessions WHERE id=$p0", s.Id);
                        Execute("DELETE FROM transcripts WHERE session=$p0", s.Id);
                    }
                    Execute("DELETE FROM ocr_payloads WHERE id NOT IN (SELECT ocr_id FROM frames WHERE ocr_id IS NOT NULL)");
                    Execute("COMMIT");
                }
                catch { Execute("ROLLBACK"); throw; }
                foreach (var p in paths)
                {
                    var full = SafePath(p);
                    if (full != null && File.Exists(full))
                        File.Delete(full);
                }
                Execute("PRAGMA wal_checkpoint(TRUNCATE)");
                return removed.Count;
            }
    }
    public void ReplaceImage(string source, string target)
    {
        lock (gate)
        {
            foreach (var f in AllFrames().Where(f => f.ImagePath == source || f.MeetingImagePath == source))
                Save(f with
                {
                    ImagePath = f.ImagePath == source ? target : f.ImagePath,
                    MeetingImagePath = f.MeetingImagePath == source ? target : f.MeetingImagePath
                });
        }
    }
    public string? SafePath(string relative)
    {
        if (Path.IsPathRooted(relative))
            return null;
        var path = Path.GetFullPath(Path.Combine(Root, relative));
        return path.StartsWith(Root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ? path : null;
    }
    private IEnumerable<string> Media(MemoryFrame f)
    {
        foreach (var path in new[] { f.ImagePath, f.MeetingImagePath, $"frames/{f.Id}.ocr.png", $"frames/{f.Id}-meeting.ocr.png" }.Where(p => !string.IsNullOrEmpty(p)).Cast<string>())
        {
            yield return path;
            if (path.EndsWith(".recallframe") && SafePath(path) is { } full && File.Exists(full))
            {
                foreach (var tile in ScreenManifest.Read(full).Tiles)
                    yield return tile.Path;
            }
        }
    }
    public bool ReferencesImage(string path)
    {
        lock (gate)
        {
            using var cmd = Command("SELECT COUNT(*) FROM frames WHERE json_extract(json,'$.ImagePath')=$p0 OR json_extract(json,'$.MeetingImagePath')=$p0", path);
            return Convert.ToInt32(cmd.ExecuteScalar()) > 0;
        }
    }
    private static IEnumerable<string> Media(RecordingSession s) => new[] { s.VideoPath, s.SystemAudioPath, s.MicrophoneAudioPath, $"recordings/{s.Id}.wav" }.Where(p => !string.IsNullOrEmpty(p)).Cast<string>();
    public void Export(string destination, List<MemoryFrame> frames)
    {
        Directory.CreateDirectory(destination);
        var sessions = frames.Select(x => x.SessionId).Distinct().Where(x => x != null).Select(x => Session(x!)).Where(x => x != null).Cast<RecordingSession>().ToList();
        foreach (var name in frames.SelectMany(Media).Concat(sessions.SelectMany(Media)).Distinct())
            if (SafePath(name) is { } source && File.Exists(source))
            {
                var target = Path.GetFullPath(Path.Combine(destination, name));
                if (!target.StartsWith(Path.GetFullPath(destination) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    continue;
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.Copy(source, target, true);
            }
        File.WriteAllText(Path.Combine(destination, "frames.json"), JsonSerializer.Serialize(frames));
        File.WriteAllText(Path.Combine(destination, "sessions.json"), JsonSerializer.Serialize(sessions));
        File.WriteAllText(Path.Combine(destination, "transcripts.json"), JsonSerializer.Serialize(sessions.SelectMany(s => Transcript(s.Id))));
    }
    public void Dispose()
    {
        lock (gate)
        {
            db.Dispose();
        }
    }
}
public enum CleanupScope
{
    Trash, Older30Days, Older7Days, All
}
public record CleanupPlan(string[] Ids, string[] Files, long Bytes, bool KeepStarred);
