using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
namespace Recall;

internal record StorageBucket(string Name, long Bytes, Color Color);
internal record StorageReport(List<StorageBucket> Buckets, long Free, long Capacity)
{
    public long Total => Buckets.Sum(x => x.Bytes);
}
internal static class StorageService
{
    static readonly SemaphoreSlim optimizationGate = new(1, 1);
    public static bool IsOptimizing => optimizationGate.CurrentCount == 0;
    public static async Task<T> Maintain<T>(Func<Task<T>> work)
    {
        if (!await optimizationGate.WaitAsync(0)) throw new RecallException("busy", "Storage maintenance is already running.");
        try { return await work(); } finally { optimizationGate.Release(); }
    }
    static readonly object reportGate = new();
    static readonly Dictionary<string, (DateTime At, Task<StorageReport> Work)> reports = [];
    public static Task<StorageReport> Measure(MemoryStore store, bool refresh = false)
    {
        lock (reportGate)
        {
            if (reports.TryGetValue(store.Root, out var recent) &&
                (!recent.Work.IsCompleted || !refresh && recent.Work.IsCompletedSuccessfully && DateTime.UtcNow - recent.At < TimeSpan.FromSeconds(10))) return recent.Work;
            var work = Task.Run(() =>
            {
                var inventory = LibraryStorage.Measure(store.Root);
                var buckets = new[] { "images", "video", "audio", "models", "index", "other" }.Select(key => inventory.Buckets[key]).ToArray();
                var drive = new DriveInfo(Path.GetPathRoot(store.Root)!);
                return new StorageReport(new[] { "Images", "Video", "Audio", "Models", "Search index", "Other" }.Select((name, i) => new StorageBucket(name, buckets[i], Design.Pastels[i])).ToList(), drive.AvailableFreeSpace, drive.TotalSize);
            });
            reports[store.Root] = (DateTime.UtcNow, work);
            return work;
        }
    }
    public static async Task<long> Optimize(MemoryStore store, IProgress<string> progress, CancellationToken ct)
    {
        if (!await optimizationGate.WaitAsync(0, ct)) throw new RecallException("busy", "Storage optimization is already running.");
        try
        {
        long saved = 0;
        var frames = await Task.Run(store.MetadataFrames, ct);
        var referencedVideos = VisualDependencies(store, frames);
        var unifiedSessions = (await Task.Run(store.Sessions, ct)).Where(s => s.UnifiedVisualArchive).Select(s => s.Id).ToHashSet();
        var images = frames.Where(f => f.VisualTicks == null && !unifiedSessions.Contains(f.SessionId ?? "") &&
            f.TextState is RecognitionState.Complete or RecognitionState.Empty && (f.ImageQuality == null || f.ImageQuality > .5)).SelectMany(f => new[] { f.ImagePath, f.MeetingImagePath }).Where(x => x != null).Cast<string>().Where(x => !x.EndsWith(".ocr.png", StringComparison.OrdinalIgnoreCase) && !x.EndsWith(".recallvideo", StringComparison.OrdinalIgnoreCase) && !x.EndsWith(".recallframe", StringComparison.OrdinalIgnoreCase)).Distinct().ToArray();
        int count = 0;
        foreach (var image in images)
        {
            ct.ThrowIfCancellationRequested();
            progress.Report($"Optimizing images · {++count} / {images.Length}");
            if (store.SafePath(image) is not { } path || !File.Exists(path))
                continue;
            var temporary = path + ".opt.jpg";
            try
            {
                saved += await Task.Run(() =>
                {
                    using (var bitmap = ImageArchive.Load(store.Root, image))
                    {
                        CaptureService.SaveJpeg(bitmap, temporary, .5);
                        using var verified = new System.Drawing.Bitmap(temporary);
                        if (verified.Size != bitmap.Size) throw new InvalidDataException("Optimized image dimensions changed; the source was retained.");
                    }
                    var before = new FileInfo(path).Length;
                    var after = new FileInfo(temporary).Length;
                    if (after >= before) { store.MarkOptimized(image); return 0L; }
                    var replacement = "frames/optimized-" + Guid.NewGuid().ToString("N") + ".jpg";
                    var destination = store.SafePath(replacement)!;
                    store.WithMediaLock(() =>
                    {
                        File.Move(temporary, destination);
                        using (var durable = new FileStream(destination, FileMode.Open, FileAccess.ReadWrite, FileShare.Read)) durable.Flush(true);
                        store.ReplaceImage(image, replacement, .5);
                        if (!store.ReferencesImage(image)) File.Delete(path);
                    });
                    return before - after;
                }, ct);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        foreach (var session in await Task.Run(store.Sessions, ct))
        {
            ct.ThrowIfCancellationRequested();
            if (session.UnifiedVisualArchive || referencedVideos.Contains(session.VideoPath) ||
                session.EndedAt == null || store.SafePath(session.VideoPath) is not { } path || !File.Exists(path))
                continue;
            progress.Report("Optimizing video · " + session.StartedAt.ToLocalTime().ToString("MMM d HH:mm"));
            var source = await StorageFile.GetFileFromPathAsync(path);
            var props = await source.Properties.GetVideoPropertiesAsync();
            var scale = Math.Min(1, 720.0 / Math.Max(props.Width, props.Height));
            var output = await source.GetParentAsync();
            var target = await output.CreateFileAsync(session.Id + ".opt.mp4", CreationCollisionOption.ReplaceExisting);
            try
            {
                var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.Vga);
                profile.Video.Width = Math.Max(2, (uint)(props.Width * scale) / 2 * 2);
                profile.Video.Height = Math.Max(2, (uint)(props.Height * scale) / 2 * 2);
                profile.Video.Bitrate = 100000;
                profile.Video.FrameRate.Numerator = 1;
                profile.Video.FrameRate.Denominator = 1;
                // Existing legacy video keeps its only audio copy. New segments reference independent tracks.
                if (session.SeparateAudio || !session.HasAudio)
                    profile.Audio = null;
                var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
                var prepared = await transcoder.PrepareFileTranscodeAsync(source, target, profile);
                if (!prepared.CanTranscode)
                    continue;
                await prepared.TranscodeAsync().AsTask(ct);
                var before = new FileInfo(path).Length;
                var after = new FileInfo(target.Path).Length;
                var encoded = await target.Properties.GetVideoPropertiesAsync();
                var encodedProfile = await MediaEncodingProfile.CreateFromFileAsync(target);
                if (!session.SeparateAudio && session.HasAudio && encodedProfile.Audio == null)
                    throw new InvalidDataException("Optimized video lost its audio track; the original was retained.");
                var durationTolerance = TimeSpan.FromSeconds(2);
                if (encoded.Width != profile.Video.Width || encoded.Height != profile.Video.Height ||
                    encoded.Duration <= TimeSpan.Zero || (encoded.Duration - props.Duration).Duration() > durationTolerance)
                    throw new InvalidDataException("Optimized video validation failed; the original recording was retained.");
                // Decode the first actual sample as well as inspecting metadata.
                using (var check = VisualVideoReader.Load(Path.GetDirectoryName(output.Path)!,
                    new VisualArchive(1, "recordings/" + target.Name, 0, checked((int)encoded.Width), checked((int)encoded.Height)), 64)) { }
                if (after < before)
                {
                    store.WithMediaLock(() =>
                    {
                        if (VisualDependencies(store, store.MetadataFrames()).Contains(session.VideoPath))
                            throw new InvalidOperationException("A card now depends on this video; its original was retained.");
                        File.Move(target.Path, path, true);
                    });
                    saved += before - after;
                }
            }
            finally { if (File.Exists(target.Path)) File.Delete(target.Path); }
        }
        TileStorageBatch packed;
        do
        {
            ct.ThrowIfCancellationRequested();
            progress.Report("Packing existing screenshot blocks");
            packed = await Task.Run(() => store.PackLegacyTiles(128), ct);
            saved += packed.SavedBytes;
        } while (packed.More);
        ct.ThrowIfCancellationRequested();
        progress.Report("Compacting text recognition and search index");
        var indexPath = Path.Combine(store.Root, "memory.sqlite");
        var indexBefore = new FileInfo(indexPath).Length;
        await Task.Run(store.CompactIndex, ct);
        saved += indexBefore - new FileInfo(indexPath).Length;
        return Math.Max(0, saved);
        }
        finally { optimizationGate.Release(); }
    }
    private static HashSet<string> VisualDependencies(MemoryStore store, IEnumerable<MemoryFrame> frames)
    {
        var videos = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in frames.SelectMany(f => new[] { f.ImagePath, f.MeetingImagePath }).Where(p => p?.EndsWith(".recallvideo", StringComparison.OrdinalIgnoreCase) == true).Distinct())
        {
            var reference = VisualArchive.Read(store.SafePath(path!) ?? throw new InvalidDataException("Invalid visual archive path."));
            reference.Validate(store.Root);
            videos.Add(reference.Video);
        }
        return videos;
    }

}
