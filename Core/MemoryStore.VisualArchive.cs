using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Rewind;

public sealed partial class MemoryStore
{
    /// <summary>Resolve all dependencies; damaged manifests fail closed so cleanup cannot guess which media is safe to delete.</summary>
    public IEnumerable<string> MediaDependencies(string path)
    {
        if (string.IsNullOrEmpty(path)) yield break;
        var full = ArchivePaths.Owned(Root, path);
        yield return path;
        if (path.EndsWith(".recallframe", StringComparison.OrdinalIgnoreCase))
        {
            foreach (var tile in ScreenManifest.Read(full).Tiles) yield return tile.Path;
        }
        else if (path.EndsWith(".recallvideo", StringComparison.OrdinalIgnoreCase))
        {
            var reference = VisualArchive.Read(full);
            reference.Validate(Root);
            yield return reference.Video;
        }
    }
    public HashSet<string> ReferencedMediaPaths()
    {
        lock (gate) return MetadataFrames().SelectMany(Media).Concat(Sessions().SelectMany(Media)).ToHashSet(ArchivePaths.MediaComparer);
    }
    public List<string> UnfinishedVisualSessions() => Rows<string>(
        "SELECT DISTINCT json_quote(s.id) FROM sessions s JOIN frames f ON json_extract(f.json,'$.SessionId')=s.id " +
        "WHERE json_extract(s.json,'$.UnifiedVisualArchive')=1 AND json_extract(s.json,'$.VisualArchiveReady')=1 " +
        "AND json_extract(s.json,'$.EndedAt') IS NOT NULL AND f.deleted IS NULL " +
        "AND json_extract(f.json,'$.TextState') IN (2,3) AND json_extract(f.json,'$.VisualSampleVerified')=1 " +
        "AND json_extract(f.json,'$.VisualTicks') IS NOT NULL AND json_extract(f.json,'$.VisualWidth') IS NOT NULL " +
        "AND json_extract(f.json,'$.VisualHeight') IS NOT NULL AND lower(json_extract(f.json,'$.ImagePath')) NOT LIKE '%.recallvideo'");
    private static bool IsVisualCandidate(MemoryFrame frame) => frame.DeletedAt == null &&
        frame.TextState is RecognitionState.Complete or RecognitionState.Empty && frame.VisualSampleVerified &&
        frame.VisualTicks != null && frame.VisualWidth != null && frame.VisualHeight != null &&
        !frame.ImagePath.EndsWith(".recallvideo", StringComparison.OrdinalIgnoreCase);

    /// <summary>The verifier must decode the exact presentation timestamp at the native dimensions. No nearest-frame fallback is allowed.</summary>
    public List<MemoryFrame> FinalizeVisualSession(string id, Func<VisualArchive, bool> validateSample)
    {
        ArgumentNullException.ThrowIfNull(validateSample);
        lock (mediaGate)
        {
            var session = Session(id);
            if (!Ready(session)) return [];
            var changed = new List<MemoryFrame>();
            var candidates = Rows<MemoryFrame>("SELECT json FROM frames WHERE json_extract(json,'$.SessionId')=$p0 AND deleted IS NULL", id).Where(IsVisualCandidate).ToList();
            foreach (var candidate in candidates)
            {
                if (!MatchesSample(candidate, session!)) continue;
                var reference = new VisualArchive(1, session!.VideoPath, candidate.VisualTicks!.Value, candidate.VisualWidth!.Value, candidate.VisualHeight!.Value);
                var video = reference.Validate(Root);
                var original = ArchivePaths.Owned(Root, candidate.ImagePath);
                var before = new FileInfo(video);
                if (!before.Exists || before.Length == 0 || !File.Exists(original)) continue;
                var length = before.Length; var modified = before.LastWriteTimeUtc.Ticks;
                // Exact decoding may seek a long GOP; no database lock is held.
                if (!validateSample(reference)) continue;
                lock (gate)
                {
                    var currentSession = Session(id);
                    var source = Frame(candidate.Id);
                    var after = new FileInfo(video);
                    if (!Ready(currentSession) || source == null || !IsVisualCandidate(source) || !MatchesSample(source, currentSession!) ||
                        source.ImagePath != candidate.ImagePath || source.SessionId != id || source.VisualTicks != candidate.VisualTicks ||
                        source.VisualWidth != candidate.VisualWidth || source.VisualHeight != candidate.VisualHeight || currentSession!.VideoPath != reference.Video ||
                        !after.Exists || after.Length != length || after.LastWriteTimeUtc.Ticks != modified || !File.Exists(original)) continue;
                    var bytes = JsonSerializer.SerializeToUtf8Bytes(reference);
                    var digest = Convert.ToHexString(SHA256.HashData(bytes));
                    var token = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(source.Id + "\n" + digest)));
                    var destination = "frames/visual-" + token + ".recallvideo";
                    var recovery = new VisualRecovery(source.Id, source.ImagePath, destination, digest, reference.Video, length, modified, MediaDependencies(source.ImagePath).ToArray());
                    var receipt = Path.Combine(ControlDirectory(), "visual-" + token + ".json");
                    DurableWrite(receipt, JsonSerializer.SerializeToUtf8Bytes(recovery, Wire.Json));
                    DurableWrite(ArchivePaths.Owned(Root, destination), bytes);
                    if (VisualArchive.Read(ArchivePaths.Owned(Root, destination)) != reference) throw new InvalidDataException("Visual archive verification failed.");
                    Execute("BEGIN IMMEDIATE");
                    try
                    {
                        // Rehydration preserves OCR, stars and other edits made during decode.
                        var saved = source with { ImagePath = destination };
                        Save(saved);
                        Execute("COMMIT");
                        changed.Add(saved);
                    }
                    catch { Execute("ROLLBACK"); throw; }
                    RecoverVisualReceipt(receipt, recovery);
                }
            }
            return changed;
        }
    }
    private static bool Ready(RecordingSession? session) => session is { UnifiedVisualArchive: true, VisualArchiveReady: true, EndedAt: not null, VideoWidth: not null, VideoHeight: not null, VideoDurationTicks: > 0 };
    private static bool MatchesSample(MemoryFrame frame, RecordingSession session) => frame.VisualTicks is >= 0 && frame.VisualTicks < session.VideoDurationTicks && frame.VisualWidth == session.VideoWidth && frame.VisualHeight == session.VideoHeight;
    /// <summary>Call only after taking the exclusive desktop/library owner lease at startup.</summary>
    public void RecoverInterruptedVisualSessions()
    {
        lock (mediaGate) lock (gate)
        {
            foreach (var session in Sessions().Where(s => s.UnifiedVisualArchive && s.EndedAt == null))
            {
                var frames = ReadFrames(SelectFrame + "WHERE json_extract(f.json,'$.SessionId')=$p0", session.Id);
                Execute("BEGIN IMMEDIATE");
                try
                {
                    SaveSession(session with { EndedAt = frames.Select(f => f.EndTimestamp ?? f.Timestamp).DefaultIfEmpty(session.StartedAt).Max(), VisualArchiveReady = false });
                    foreach (var frame in frames) Save(frame with { VisualTicks = null, VisualWidth = null, VisualHeight = null, VisualSampleVerified = false });
                    Execute("COMMIT");
                }
                catch { Execute("ROLLBACK"); throw; }
            }
        }
    }
    private sealed record VisualRecovery(string FrameId, string Source, string Destination, string Digest, string Video, long VideoLength, long VideoModifiedTicks, string[] SourceFiles);
    private string ControlDirectory()
    {
        var control = Path.Combine(Root, ".recall-control");
        Directory.CreateDirectory(control);
        if ((File.GetAttributes(control) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Archive control directory must not be a symbolic link.");
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(control, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        return control;
    }
    private static void DurableWrite(string path, byte[] data)
    {
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { stream.Write(data); stream.Flush(true); }
            File.Move(temp, path, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    public void RecoverPendingVisualArchives()
    {
        var control = Path.Combine(Root, ".recall-control");
        if (!Directory.Exists(control)) return;
        if ((File.GetAttributes(control) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Archive control directory must not be a symbolic link.");
        lock (mediaGate) lock (gate)
            foreach (var receipt in Directory.EnumerateFiles(control, "visual-*.json"))
            {
                if ((File.GetAttributes(receipt) & FileAttributes.ReparsePoint) != 0 || new FileInfo(receipt).Length > 2_000_000)
                    throw new InvalidDataException("Invalid visual archive recovery receipt.");
                var recovery = JsonSerializer.Deserialize<VisualRecovery>(File.ReadAllText(receipt), Wire.Json) ?? throw new InvalidDataException("Invalid visual archive recovery receipt.");
                if (recovery.SourceFiles == null || recovery.SourceFiles.Length is < 1 or > 4096) throw new InvalidDataException("Invalid visual archive recovery dependencies.");
                RecoverVisualReceipt(receipt, recovery);
            }
    }
    private void RecoverVisualReceipt(string receipt, VisualRecovery recovery)
    {
        var source = ArchivePaths.Owned(Root, recovery.Source);
        var destination = ArchivePaths.Owned(Root, recovery.Destination);
        var video = ArchivePaths.Owned(Root, recovery.Video);
        var frame = Frame(recovery.FrameId);
        if (frame?.ImagePath == recovery.Destination)
        {
            var info = new FileInfo(video);
            var valid = File.Exists(destination) && new FileInfo(destination).Length <= 4096 && info.Exists &&
                info.Length == recovery.VideoLength && info.LastWriteTimeUtc.Ticks == recovery.VideoModifiedTicks &&
                Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(destination))) == recovery.Digest;
            if (!valid)
            {
                // If publication survived but its media did not, preserve and
                // restore the lossless spool rather than completing deletion.
                if (File.Exists(source)) Save(frame with { ImagePath = recovery.Source, VisualSampleVerified = false });
                return;
            }
            var removable = recovery.SourceFiles.Where(p => !ReferencesImage(p)).ToArray();
            foreach (var candidate in removable)
            {
                var full = ArchivePaths.Owned(Root, candidate);
                if (File.Exists(full)) File.Delete(full);
            }
            RemovePackedMedia(removable);
        }
        else
        {
            // Pre-commit interruption: leave source bytes and metadata intact.
            if (!ReferencesImage(recovery.Destination) && File.Exists(destination)) File.Delete(destination);
        }
        File.Delete(receipt);
    }
    private void RemovePackedMedia(IEnumerable<string> paths)
    {
        var tiles = paths.Where(TilePackStore.IsTilePath).Distinct().ToArray();
        if (tiles.Length == 0 || !File.Exists(ArchivePaths.Owned(Root, "frames/packs/catalog.sqlite"))) return;
        using var packs = new TilePackStore(Root, true); packs.Remove(tiles);
    }
    private long MediaSize(string path)
    {
        if (SafePath(path) is { } full && File.Exists(full)) return new FileInfo(full).Length;
        if (TilePackStore.IsTilePath(path) && File.Exists(ArchivePaths.Owned(Root, "frames/packs/catalog.sqlite")))
        { using var packs = new TilePackStore(Root); return packs.Size(path); }
        return 0;
    }
    private Queue<int>? tileMaintenance;
    public TileStorageBatch PackLegacyTiles(int limit = 128)
    {
        lock (mediaGate) lock (gate)
        {
            var directory = ArchivePaths.Owned(Root, "frames/tiles");
            var catalogExists = File.Exists(ArchivePaths.Owned(Root, "frames/packs/catalog.sqlite"));
            if (!Directory.Exists(directory) && !catalogExists) return new(0, false, 0);
            var tiles = new List<TilePayload>();
            long payload = 0;
            var more = false;
            foreach (var path in (Directory.Exists(directory) ? Directory.EnumerateFiles(directory) : []).Select(file => "frames/tiles/" + Path.GetFileName(file)).Where(TilePackStore.IsTilePath))
            {
                var full = ArchivePaths.Owned(Root, path);
                var size = new FileInfo(full).Length;
                if (size is <= 0 or > TilePackStore.PayloadLimit) throw new InvalidDataException("Invalid screenshot block size.");
                if (tiles.Count == Math.Clamp(limit, 1, 512) || payload + size > TilePackStore.PayloadLimit) { more = true; break; }
                tiles.Add(new(path, File.ReadAllBytes(full))); payload += size;
            }
            if (tiles.Count == 0 && !File.Exists(ArchivePaths.Owned(Root, "frames/packs/catalog.sqlite"))) return new(0, false, 0);
            var packDirectory = ArchivePaths.Owned(Root, "frames/packs");
            var before = Directory.Exists(packDirectory) ? Directory.EnumerateFiles(packDirectory).Sum(path => new FileInfo(path).Length) : 0;
            using var packs = new TilePackStore(Root, true);
            packs.Install(tiles);
            foreach (var tile in tiles)
                if (!(packs.Read(tile.Path)?.AsSpan().SequenceEqual(tile.Data) ?? false)) throw new InvalidDataException("Screenshot packing verification failed. Originals were kept.");
            // Publish and verify every block before deleting any legacy bytes.
            foreach (var tile in tiles) File.Delete(ArchivePaths.Owned(Root, tile.Path));
            if (!more)
            {
                tileMaintenance ??= new Queue<int>(packs.SegmentIds());
                if (tileMaintenance.TryDequeue(out var segment)) packs.ReclaimSegment(segment);
                more = tileMaintenance.Count > 0;
                if (!more) tileMaintenance = null;
            }
            packs.Checkpoint();
            return new(tiles.Count, more, tiles.Sum(t => (long)t.Data.Length) + before - packs.AllocatedBytes());
        }
    }
    private void CompactOcrPayloads()
    {
        var last = "";
        while (true)
        {
            var batch = new List<(string Id, string Regions, string Meeting)>();
            using (var cmd = Command("SELECT id,regions,meeting_regions FROM ocr_payloads WHERE id>$p0 ORDER BY id LIMIT 128", last))
            using (var reader = cmd.ExecuteReader())
                while (reader.Read()) batch.Add((reader.GetString(0), reader.GetString(1), reader.GetString(2)));
            if (batch.Count == 0) return;
            Execute("BEGIN IMMEDIATE");
            try
            {
                foreach (var row in batch)
                {
                    var regions = CompactOcrRegions.Encode(CompactOcrRegions.Decode(row.Regions));
                    var meeting = CompactOcrRegions.Encode(CompactOcrRegions.Decode(row.Meeting));
                    if (regions != row.Regions || meeting != row.Meeting)
                        Execute("UPDATE ocr_payloads SET regions=$p1,meeting_regions=$p2 WHERE id=$p0", row.Id, regions, meeting);
                }
                Execute("COMMIT");
            }
            catch { Execute("ROLLBACK"); throw; }
            last = batch[^1].Id;
        }
    }
}
