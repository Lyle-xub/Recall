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
                var buckets = new long[6];
                // Directory enumeration supplies cached metadata. Avoid a
                // second filesystem query for every file and never follow links.
                var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = System.IO.FileAttributes.ReparsePoint };
                foreach (var file in new DirectoryInfo(store.Root).EnumerateFiles("*", options))
                {
                    try
                    {
                        var relative = Path.GetRelativePath(store.Root, file.FullName); var ext = file.Extension.ToLowerInvariant();
                        var index = relative.StartsWith("models" + Path.DirectorySeparatorChar) ? 3 : ext is ".jpg" or ".png" or ".heic" or ".recallframe" ? 0 : ext is ".mp4" or ".mov" ? 1 : ext is ".wav" or ".m4a" ? 2 : relative.StartsWith("memory.sqlite") ? 4 : 5;
                        buckets[index] += file.Length;
                    }
                    catch (IOException) { }
                }
                var drive = new DriveInfo(Path.GetPathRoot(store.Root)!);
                return new StorageReport(new[] { "Images", "Video", "Audio", "Models", "Search index", "Other" }.Select((name, i) => new StorageBucket(name, buckets[i], Design.Pastels[i])).ToList(), drive.AvailableFreeSpace, drive.TotalSize);
            });
            reports[store.Root] = (DateTime.UtcNow, work);
            return work;
        }
    }
    public static async Task<long> Optimize(MemoryStore store, IProgress<string> progress, CancellationToken ct)
    {
        long saved = 0;
        var frames = await Task.Run(store.MetadataFrames, ct);
        var images = frames.Where(f => f.ImageQuality == null || f.ImageQuality > .5).SelectMany(f => new[] { f.ImagePath, f.MeetingImagePath }).Where(x => x != null).Cast<string>().Distinct().ToArray();
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
                saved += await Task.Run(() => { using (var bitmap = new System.Drawing.Bitmap(path)) CaptureService.SaveJpeg(bitmap, temporary, .5); var before = new FileInfo(path).Length; var after = new FileInfo(temporary).Length; if (after >= before) { store.MarkOptimized(image); return 0L; } File.Move(temporary, path, true); store.MarkOptimized(image); return before - after; }, ct);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        foreach (var session in await Task.Run(store.Sessions, ct))
        {
            ct.ThrowIfCancellationRequested();
            if (session.EndedAt == null || store.SafePath(session.VideoPath) is not { } path || !File.Exists(path))
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
                if (after < before)
                {
                    File.Move(target.Path, path, true);
                    saved += before - after;
                }
            }
            finally { if (File.Exists(target.Path)) File.Delete(target.Path); }
        }
        return saved;
    }
}
