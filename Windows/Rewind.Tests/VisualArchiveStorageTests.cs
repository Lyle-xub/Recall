using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Rewind;

static class VisualArchiveStorageTests
{
    public static void Run(Action<bool, string> check, string parent)
    {
        var root = Path.Combine(parent, "visual-storage");
        Directory.CreateDirectory(root);
        void Reject(Action action, string message)
        {
            try { action(); } catch (Exception e) when (e is InvalidDataException or JsonException or SqliteException or FileNotFoundException or ArgumentException) { check(true, message); return; }
            check(false, message);
        }
        var valid = new VisualArchive(1, "recordings/native.mp4", 3_000_000, 1201, 801);
        check(VisualArchive.Parse(JsonSerializer.Serialize(valid)) == valid, "Native sample ticks and dimensions round trip without wall-clock conversion");
        var mac = VisualArchive.Parse("{\"version\":1,\"video\":\"recordings/mac.mp4\",\"ticks\":180,\"width\":1200,\"height\":800}");
        check(mac.Timescale == 600 && mac.Seconds == .3, "Existing Mac references keep their 600 tick timescale");
        foreach (var path in new[] { "recordings/../secret.mp4", "recordings/a/../../secret.mp4", "recordings/../../recordings/a.mp4", "recordings/a\\b.mp4", "/recordings/a.mp4", "frames/a.mp4" })
            Reject(() => (valid with { Video = path }).Validate(root), "Visual references reject traversal and non-recording paths");
        Reject(() => (valid with { Width = 16000, Height = 16000 }).Validate(root), "Visual references bound decoded pixel count");
        Reject(() => VisualArchive.Parse(JsonSerializer.Serialize(valid with { Timescale = 0 })), "Visual references reject invalid timescales");
        Reject(() => VisualArchive.Parse(new string(' ', 4097)), "Visual reference parsing has a strict size bound");

        var packRoot = Path.Combine(root, "packs");
        var one = Tile([1, 2, 3, 4, 5, 6, 7, 8]);
        var two = Tile([2, 3, 4, 5, 6, 7, 8, 9]);
        var three = Tile([3, 4, 5, 6, 7, 8, 9, 10]);
        using (var packs = new TilePackStore(packRoot, true, 16))
        {
            packs.Install([one, two, one, three]);
            check(packs.SegmentIds().Length == 2 && packs.Statistics().PayloadBytes == 24 && packs.Statistics().Tiles == 3, "Tile deduplication respects bounded segment payloads");
            check(packs.ReadTiles(new[] { one.Path, two.Path, three.Path }).SelectMany(x => x.Data).SequenceEqual(one.Data.Concat(two.Data).Concat(three.Data)), "Batch readers copy bytes from bounded segment handles");
            Reject(() => packs.Install([new TilePayload(one.Path, [0])]), "Tile installation rejects checksum mismatches before publication");
            check(packs.Read(one.Path)!.SequenceEqual(one.Data), "Rejected installation leaves committed bytes readable");
            var pending = Tile([21, 22, 23]); Write(packRoot, pending.Path, pending.Data);
            var catalog = Path.Combine(packRoot, "frames/packs/catalog.sqlite");
            Sql(catalog, "UPDATE segments SET bytes=-1 WHERE id=2");
            Reject(() => packs.Install([pending]), "Corrupt negative catalog counters cannot bypass bounded segments");
            check(File.Exists(Path.Combine(packRoot, pending.Path)) && packs.Read(pending.Path) == null && packs.Read(three.Path)!.SequenceEqual(three.Data), "Invalid segment metadata preserves incoming originals and previously published tiles");
            Sql(catalog, "UPDATE segments SET bytes=8 WHERE id=2");
            var segment = Path.Combine(packRoot, "frames/packs/segment-1.sqlite");
            Sql(segment, "UPDATE tiles SET data=zeroblob(8) WHERE key=$p0", TilePackStore.Key(one.Path)!);
            Reject(() => packs.Read(one.Path), "Corrupt segment bytes cannot be decoded as screenshots");
            Sql(segment, "UPDATE tiles SET data=$p1 WHERE key=$p0", TilePackStore.Key(one.Path)!, one.Data);
            Sql(segment, "UPDATE tiles SET data=zeroblob(100000) WHERE key=$p0", TilePackStore.Key(one.Path)!);
            Reject(() => packs.Read(one.Path), "Unexpected segment BLOB lengths are rejected before copying payloads");
            Sql(segment, "UPDATE tiles SET data=$p1 WHERE key=$p0", TilePackStore.Key(one.Path)!, one.Data);
            var orphan = Tile([4, 5, 6]);
            Sql(segment, "INSERT INTO tiles VALUES($p0,$p1)", TilePackStore.Key(orphan.Path)!, orphan.Data);
            packs.ReclaimSegment(1);
            check(packs.Read(one.Path)!.SequenceEqual(one.Data) && Count(segment) == 2, "Interrupted publication orphan bytes are reclaimed without touching live blocks");
            packs.Remove([one.Path]);
            check(packs.Read(one.Path) == null && packs.Read(two.Path)!.SequenceEqual(two.Data), "Removing one packed tile preserves other segment references");
            packs.Remove([two.Path]);
            check(!File.Exists(segment) && packs.Read(three.Path)!.SequenceEqual(three.Data), "Empty segments unlink after catalog removal without leaving reader handles");
        }

        using (var smaller = new TilePackStore(packRoot, true, 4))
        {
            smaller.Install([Tile([21, 22, 23])]);
            check(smaller.SegmentIds().Length == 2 && smaller.Read(three.Path)!.SequenceEqual(three.Data), "A smaller configured bound starts a new segment and preserves older larger segments");
        }
        var library = Path.Combine(root, "library");
        using (var store = new MemoryStore(library))
        {
            var path = "frames/legacy.recallframe";
            Write(library, one.Path, one.Data);
            var manifest = new ScreenManifest(1, 10, 10, [new(one.Path, 0, 0, 10, 10)]);
            Write(library, path, JsonSerializer.SerializeToUtf8Bytes(manifest));
            store.Save(new MemoryFrame { Id = "legacy", ImagePath = path });
            check(TilePackStore.ReadTile(library, one.Path)!.SequenceEqual(one.Data), "Historical loose tiles retain checksum-verified reads");
            var batch = store.PackLegacyTiles();
            check(batch.Processed == 1 && !batch.More && !File.Exists(Path.Combine(library, one.Path)), "Legacy packing removes loose bytes only after durable verification");
            check(TilePackStore.ReadTile(library, one.Path)!.SequenceEqual(one.Data), "Packed legacy screenshot remains readable through unchanged manifest");
            var exported = Path.Combine(root, "packed-export");
            store.Export(exported, [store.Frame("legacy")!]);
            check(File.ReadAllBytes(Path.Combine(exported, one.Path)).SequenceEqual(one.Data), "Exports materialize packed bytes into portable loose tiles");
            var alias = one.Path.ToLowerInvariant();
            Write(library, "frames/lower.recallframe", JsonSerializer.SerializeToUtf8Bytes(new ScreenManifest(1, 10, 10, [new(alias, 0, 0, 10, 10)])));
            store.Save(new MemoryFrame { Id = "lower", ImagePath = "frames/lower.recallframe" });
            store.Trash(store.Frame("legacy")!); store.EmptyTrash();
            check(TilePackStore.ReadTile(library, alias)!.SequenceEqual(one.Data), "Lowercase historical tile references retain the same packed key when uppercase dependents are deleted");
            store.Trash(store.Frame("lower")!);
            var plan = store.CleanupPreview(CleanupScope.Trash, true);
            check(plan.Bytes >= one.Data.Length, "Cleanup preview counts logical packed tile bytes");
            store.Cleanup(plan);
            using var packs = new TilePackStore(library);
            check(packs.Read(one.Path) == null, "Frame cleanup reclaims unreferenced packed tiles");
        }
        var nativeRoot = Path.Combine(root, "native");
        using (var store = new MemoryStore(nativeRoot))
        {
            var session = Session("native");
            Write(nativeRoot, session.VideoPath, [9, 8, 7, 6]);
            store.SaveSession(session);
            var source = Frame("sample", session.Id) with { TextState = RecognitionState.Pending };
            Write(nativeRoot, source.ImagePath, [1, 3, 5]);
            store.Save(source);
            check(store.FinalizeVisualSession(session.Id, _ => true).Count == 0 && File.Exists(Path.Combine(nativeRoot, source.ImagePath)), "OCR spool remains until recognition completes");
            store.Recognized(source.Id, "中文 0123456789", [new("中文 0123456789", .123456789123, .2, .3, .4)]);
            check(store.FinalizeVisualSession(session.Id, _ => false).Count == 0 && store.Frame(source.Id)!.ImagePath == source.ImagePath, "Failed exact-sample validation never promotes an image");
            store.Save(store.Frame(source.Id)! with { VisualSampleVerified = false });
            check(store.FinalizeVisualSession(session.Id, _ => true).Count == 0, "A timestamp estimate without exact-sample proof never promotes an image");
            store.Save(store.Frame(source.Id)! with { VisualSampleVerified = true });
            store.SaveSession(session with { VisualArchiveReady = false });
            check(store.FinalizeVisualSession(session.Id, _ => true).Count == 0, "An unfinished or failed movie never replaces OCR pixels");
            store.SaveSession(session);
            var wrongSize = store.Frame(source.Id)! with { VisualWidth = 1200 };
            store.Save(wrongSize);
            check(store.FinalizeVisualSession(session.Id, _ => true).Count == 0, "Native dimension mismatches retain source pixels");
            store.Save(wrongSize with { VisualWidth = 1201, VisualTicks = 20_000_000 });
            check(store.FinalizeVisualSession(session.Id, _ => true).Count == 0, "Samples outside the finalized media duration cannot promote");
            store.Save(wrongSize with { VisualWidth = 1201, VisualTicks = 3_000_000 });
            check(store.UnfinishedVisualSessions().SequenceEqual(new[] { session.Id }), "Ready recognized exact samples remain discoverable after reopening before promotion");
            Reject(() => store.FinalizeVisualSession(session.Id, null!), "Promotion requires an explicit exact-sample verifier");
            var archived = store.FinalizeVisualSession(session.Id, reference =>
            {
                // A concurrent database mutation must finish while validation is
                // running and survive the eventual media metadata transaction.
                var edit = Task.Run(() => store.Star(source.Id));
                check(edit.Wait(TimeSpan.FromSeconds(5)), "Exact sample decoding does not hold the database query lock");
                return reference.Ticks == 3_000_000 && reference.Width == 1201;
            }).Single();
            check(archived.Starred, "Promotion preserves edits completed during sample validation");
            check(archived.ImagePath.EndsWith(".recallvideo") && !File.Exists(Path.Combine(nativeRoot, source.ImagePath)), "Verified finalized native movie replaces the OCR spool transactionally");
            check(store.Frame(source.Id)!.Regions[0].X == .123456789123 && store.Frames("0123456789").Single().Id == source.Id, "Visual promotion preserves OCR coordinates and indexed search text");
            check(store.UnfinishedVisualSessions().Count == 0, "Completed promotion leaves no unfinished session work");
            var other = Session("second") with { VideoPath = "recordings/second.mp4" };
            Write(nativeRoot, other.VideoPath, [2]); store.SaveSession(other);
            var reused = archived with { Id = "reused", SessionId = other.Id, Starred = false };
            store.Star(archived.Id); store.Trash(store.Frame(archived.Id)!);
            var stalePlan = store.CleanupPreview(CleanupScope.Trash, true);
            store.Save(reused);
            store.Cleanup(stalePlan);
            check(store.Session(session.Id) == null && File.Exists(Path.Combine(nativeRoot, session.VideoPath)), "Cleanup rechecks stale plans and keeps a newly cloned card's video after its original session is deleted");
            var exported = Path.Combine(root, "native-export"); store.Export(exported, [reused]);
            check(File.Exists(VisualArchive.Read(Path.Combine(exported, reused.ImagePath)).Validate(exported)), "Export follows visual references even when the owner session differs or no longer exists");
            store.Trash(reused); store.EmptyTrash();
            check(!File.Exists(Path.Combine(nativeRoot, session.VideoPath)) && !File.Exists(Path.Combine(nativeRoot, other.VideoPath)), "Last dependent removal reclaims videos through transitive references");
        }
        var corruptRoot = Path.Combine(root, "corrupt-dependency");
        using (var store = new MemoryStore(corruptRoot))
        {
            var session = Session("corrupt");
            Write(corruptRoot, session.VideoPath, [7]); store.SaveSession(session);
            var removed = new MemoryFrame { Id = "removed", SessionId = session.Id, ImagePath = "frames/removed.png", DeletedAt = DateTimeOffset.UtcNow };
            Write(corruptRoot, removed.ImagePath, [2]); store.Save(removed);
            Write(corruptRoot, "frames/invalid.recallvideo", Encoding.UTF8.GetBytes("{}"));
            store.Save(new MemoryFrame { Id = "dependent", ImagePath = "frames/invalid.recallvideo" });
            Reject(() => store.CleanupPreview(CleanupScope.Trash, true), "Corrupt retained references stop cleanup instead of guessing video reachability");
            check(store.Frame(removed.Id) != null && File.Exists(Path.Combine(corruptRoot, session.VideoPath)), "Failed dependency validation leaves original database rows and videos intact");
        }
        CrashRecovery(check, root);
        var interrupted = Path.Combine(root, "interrupted");
        using (var store = new MemoryStore(interrupted))
        {
            var session = Session("interrupted") with { EndedAt = null, VisualArchiveReady = false };
            store.SaveSession(session); var frame = Frame("interrupted", session.Id);
            Write(interrupted, frame.ImagePath, [1, 2, 3]); store.Save(frame);
            using (var second = new MemoryStore(interrupted)) check(second.Session(session.Id)!.EndedAt == null, "Opening a writable observer does not interrupt an active native recorder");
            store.RecoverInterruptedVisualSessions();
            check(store.Session(session.Id)!.EndedAt != null && !store.Session(session.Id)!.VisualArchiveReady && store.Frame(frame.Id)!.VisualTicks == null && File.Exists(Path.Combine(interrupted, frame.ImagePath)), "Owner recovery preserves interrupted OCR originals and clears unusable sample proof");
        }
    }
    private static void CrashRecovery(Action<bool, string> check, string parent)
    {
        foreach (var state in new[] { "prepared", "committed", "corrupt" })
        {
            var root = Path.Combine(parent, "crash-" + state);
            var session = Session("crash"); var frame = Frame("crash", session.Id);
            var destination = "frames/crash.recallvideo";
            var reference = new VisualArchive(1, session.VideoPath, frame.VisualTicks!.Value, frame.VisualWidth!.Value, frame.VisualHeight!.Value);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(reference);
            using (var store = new MemoryStore(root))
            {
                Write(root, session.VideoPath, [9, 9]); Write(root, frame.ImagePath, [1, 1]); Write(root, destination, state == "corrupt" ? [0] : bytes);
                store.SaveSession(session); store.Save(state == "prepared" ? frame : frame with { ImagePath = destination });
                var video = new FileInfo(Path.Combine(root, session.VideoPath));
                Directory.CreateDirectory(Path.Combine(root, ".recall-control"));
                Wire.Atomic(Path.Combine(root, ".recall-control/visual-test.json"), new
                {
                    FrameId = frame.Id, Source = frame.ImagePath, Destination = destination, Digest = Convert.ToHexString(SHA256.HashData(bytes)),
                    Video = session.VideoPath, VideoLength = video.Length, VideoModifiedTicks = video.LastWriteTimeUtc.Ticks, SourceFiles = new[] { frame.ImagePath }
                });
            }
            using (var recovered = new MemoryStore(root))
            {
                if (state == "prepared") check(File.Exists(Path.Combine(root, frame.ImagePath)) && !File.Exists(Path.Combine(root, destination)) && recovered.Frame(frame.Id)!.ImagePath == frame.ImagePath, "A crash before metadata commit discards staging and preserves source pixels");
                if (state == "committed") check(!File.Exists(Path.Combine(root, frame.ImagePath)) && recovered.Frame(frame.Id)!.ImagePath == destination, "A crash after metadata commit resumes source removal from the durable receipt");
                if (state == "corrupt") check(File.Exists(Path.Combine(root, frame.ImagePath)) && recovered.Frame(frame.Id)!.ImagePath == frame.ImagePath && !recovered.Frame(frame.Id)!.VisualSampleVerified, "A damaged committed reference restores its retained OCR source instead of deleting it");
            }
        }
    }
    private static TilePayload Tile(byte[] data) => new("frames/tiles/t1-" + Convert.ToHexString(SHA256.HashData(data)) + ".png", data);
    private static RecordingSession Session(string id) => new(id, DateTimeOffset.UtcNow.AddSeconds(-2), DateTimeOffset.UtcNow, "recordings/" + id + ".mp4", false,
        UnifiedVisualArchive: true, VisualArchiveReady: true, VideoCodec: "H264", VideoWidth: 1201, VideoHeight: 801, VideoDurationTicks: 20_000_000, VideoSampleCount: 2);
    private static MemoryFrame Frame(string id, string session) => new() { Id = id, SessionId = session, ImagePath = "frames/" + id + ".ocr.png", VisualTicks = 3_000_000, VisualWidth = 1201, VisualHeight = 801, VisualSampleVerified = true };
    private static void Write(string root, string path, byte[] data) { var full = Path.Combine(root, path); Directory.CreateDirectory(Path.GetDirectoryName(full)!); File.WriteAllBytes(full, data); }
    private static void Sql(string path, string sql, params object[] values)
    {
        using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString()); db.Open(); using var cmd = db.CreateCommand(); cmd.CommandText = sql;
        for (var i = 0; i < values.Length; i++) cmd.Parameters.AddWithValue("$p" + i, values[i]); cmd.ExecuteNonQuery();
    }
    private static long Count(string path)
    {
        using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString()); db.Open(); using var cmd = db.CreateCommand(); cmd.CommandText = "SELECT count(*) FROM tiles"; return (long)cmd.ExecuteScalar()!;
    }
}
