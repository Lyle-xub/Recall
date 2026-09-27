using System.ComponentModel;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Recall.Cli;
using Rewind;

static class ArchiveMediaChecks
{
    public static async Task Run(string directory, Action<bool, string> assert, Func<string, int, string[], Task<JsonElement>> command)
    {
        var root = Path.Combine(directory, "archive media 中文 with spaces");
        using var store = new MemoryStore(root);
        var engine = Environment.GetEnvironmentVariable("RECALL_FFMPEG") ?? "ffmpeg";
        var configured = Environment.GetEnvironmentVariable("RECALL_WINDOWS_APP");
        Environment.SetEnvironmentVariable("RECALL_WINDOWS_APP", null);
        try
        {
            var installation = Path.Combine(directory, "desktop location 中文");
            assert(WindowsDesktop.Discover(true, installation) == null, "Absent desktop preserves explicit portable fallback");
            var native = Path.Combine(installation, "Programs", "Recall", "Recall.exe"); Directory.CreateDirectory(Path.GetDirectoryName(native)!); File.WriteAllText(native, "test executable identity");
            assert(WindowsDesktop.Discover(true, installation) == native, "Native desktop discovery uses the installer location, not CLI PATH");
            assert(WindowsDesktop.Arguments(root).SequenceEqual(new[] { "--background", "--cli-service", "--data-dir", root }), "Native launch keeps the full spaced library path as one argument and remains headless");
            try { WindowsDesktop.Discover(true, installation, "relative.exe"); assert(false, "Invalid explicit native override must not fall back"); }
            catch (RecallException e) { assert(e.Code == "engine_missing", "Invalid native override has an actionable dependency error"); }
            try { WindowsDesktop.Discover(true, installation, Environment.ProcessPath); assert(false, "CLI host must not recursively launch itself"); }
            catch (RecallException e) { assert(e.Code == "engine_missing", "CLI host identity is rejected for native launch"); }
        }
        finally { Environment.SetEnvironmentVariable("RECALL_WINDOWS_APP", configured); }

        // Dependency and path failures are verified even on hosts without FFmpeg.
        var reference = new VisualArchive(1, "recordings/exact.mp4", 3_000_000, 34, 26);
        var referencePath = Path.Combine(root, "frames", "exact.recallvideo");
        File.WriteAllText(referencePath, JsonSerializer.Serialize(reference));
        var videoPath = Path.Combine(root, "recordings", "exact.mp4"); File.WriteAllText(videoPath, "placeholder");
        var originalEngine = Environment.GetEnvironmentVariable("RECALL_FFMPEG");
        var originalProbeEngine = Environment.GetEnvironmentVariable("RECALL_FFPROBE");
        try
        {
            Environment.SetEnvironmentVariable("RECALL_FFMPEG", Path.Combine(directory, "missing-ffmpeg"));
            Environment.SetEnvironmentVariable("RECALL_FFPROBE", Path.Combine(directory, "missing-ffprobe"));
            try { using var image = await PortableImage.Open(root, "frames/exact.recallvideo"); assert(false, "Archive decoding cannot claim success without FFmpeg"); }
            catch (RecallException e) { assert(e.Code == "engine_missing" && e.Message.Contains("RECALL_FFMPEG"), "Archive dependency error names the executable override"); }
        }
        finally { Environment.SetEnvironmentVariable("RECALL_FFMPEG", originalEngine); Environment.SetEnvironmentVariable("RECALL_FFPROBE", originalProbeEngine); }
        try { using var image = await PortableImage.Open(root, "frames/../outside.recallvideo"); assert(false, "Traversal reference must be rejected"); }
        catch (InvalidDataException) { assert(true, "Archive materialization rejects traversal before opening media"); }
        try { using var image = await PortableImage.OpenFile(referencePath, Path.Combine(directory, "other root")); assert(false, "Mismatched explicit source root must fail"); }
        catch (InvalidDataException) { assert(true, "Explicit OCR root cannot escape into another library"); }
        var beforeDirectories = Directory.EnumerateDirectories(Path.GetTempPath(), "recall-image-*").ToHashSet();
        using (var stop = new CancellationTokenSource())
        {
            stop.Cancel();
            try { using var image = await PortableImage.Open(root, "frames/exact.recallvideo", stop.Token); assert(false, "Cancelled materialization must stop"); }
            catch (OperationCanceledException) { assert(true, "Cancellation is propagated before decoding"); }
        }
        assert(!Directory.EnumerateDirectories(Path.GetTempPath(), "recall-image-*").Except(beforeDirectories).Any(), "Cancelled materialization leaves no temporary directory");
        try
        {
            var available = await ChildProcess.Run(engine, ["-version"], null, default, 10);
            if (available.ExitCode != 0) throw new InvalidOperationException("ffmpeg -version failed");
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException)
        {
            if (Environment.GetEnvironmentVariable("RECALL_ARCHIVE_TESTS") == "1") throw new Exception("RECALL_ARCHIVE_TESTS=1 requires FFmpeg integration tests.", e);
            Console.WriteLine("SKIP archive bitmap/video integration: FFmpeg is unavailable (set RECALL_ARCHIVE_TESTS=1 to require it)."); return;
        }
        async Task Ffmpeg(params string[] arguments)
        {
            var result = await ChildProcess.Run(engine, new[] { "-v", "error", "-nostdin", "-threads", "1" }.Concat(arguments), null, default, 60);
            if (result.ExitCode != 0) throw new Exception("Fixture FFmpeg failed: " + result.Error);
        }
        async Task<string> Png(string name, int width, int height, byte red, byte green, byte blue)
        {
            var ppm = Path.Combine(directory, name + ".ppm");
            using (var file = File.Create(ppm))
            {
                file.Write(Encoding.ASCII.GetBytes($"P6\n{width} {height}\n255\n"));
                for (var n = 0; n < width * height; n++) file.Write(new[] { red, green, blue });
            }
            var png = Path.Combine(directory, name + ".png");
            await Ffmpeg("-i", ppm, "-frames:v", "1", "-threads", "1", "-y", png); return png;
        }
        async Task<byte[]> Pixels(string path)
        {
            var result = Path.Combine(directory, Guid.NewGuid() + ".rgb");
            await Ffmpeg("-i", path, "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", "-threads", "1", "-y", result);
            var bytes = File.ReadAllBytes(result); File.Delete(result); return bytes;
        }
        var red = await Png("red", 34, 26, 255, 0, 0);
        var blue = await Png("blue", 34, 26, 0, 0, 255);
        var sequence = Path.Combine(directory, "video frames"); Directory.CreateDirectory(sequence);
        for (var n = 0; n < 10; n++) File.Copy(n == 3 ? red : blue, Path.Combine(sequence, n.ToString("D2") + ".png"));
        await Ffmpeg("-framerate", "10", "-i", Path.Combine(sequence, "%02d.png"), "-c:v", "libx264", "-crf", "0", "-pix_fmt", "yuv444p", "-threads", "1", "-y", videoPath);
        var videoBytes = File.ReadAllBytes(videoPath);
        string decodedPath;
        using (var image = await PortableImage.Open(root, "frames/exact.recallvideo"))
        {
            decodedPath = image.Path; var pixels = await Pixels(image.Path);
            assert(pixels[0] > 240 && pixels[1] < 15 && pixels[2] < 15, "Windows timescale reference decodes the red 0.3-second frame, not its blue keyframe");
            PortableImage.VerifyPng(image.Path, 34, 26);
        }
        assert(!File.Exists(decodedPath) && !Directory.Exists(Path.GetDirectoryName(decodedPath)), "Materialized pixels and their private directory are deleted on disposal");
        File.WriteAllText(referencePath, "{\"version\":1,\"video\":\"recordings/exact.mp4\",\"ticks\":180,\"width\":34,\"height\":26}");
        using (var image = await PortableImage.OpenFile(referencePath))
        { var pixels = await Pixels(image.Path); assert(pixels[0] > 240 && pixels[2] < 15, "Existing Mac 600-timescale references decode the same exact frame"); }
        File.WriteAllText(referencePath, JsonSerializer.Serialize(reference with { Width = 33, Height = 25 }));
        using (var image = await PortableImage.Open(root, "frames/exact.recallvideo"))
        { PortableImage.VerifyPng(image.Path, 33, 25); var pixels = await Pixels(image.Path); assert(pixels.Length == 33 * 25 * 3 && pixels[^3] > 240, "Only deterministic right/bottom even padding is cropped to original odd dimensions"); }
        foreach (var invalid in new[] { reference with { Ticks = 3_500_000 }, reference with { Width = 31 } })
        {
            File.WriteAllText(referencePath, JsonSerializer.Serialize(invalid));
            try { using var image = await PortableImage.Open(root, "frames/exact.recallvideo"); assert(false, "Missing PTS or wrong dimensions must not substitute pixels"); }
            catch (RecallException e) { assert(e.Code == "unsupported_media", "Unavailable exact frame/dimensions fail explicitly"); }
        }
        assert(File.ReadAllBytes(videoPath).SequenceEqual(videoBytes), "Decoding failures never modify recorded video");
        File.WriteAllText(referencePath, JsonSerializer.Serialize(reference));

        var adjacent = Path.Combine(root, "recordings", "adjacent.mp4");
        await Ffmpeg("-i", red, "-vf", "settb=1/1000000,setpts=300500", "-frames:v", "1", "-fps_mode", "passthrough", "-enc_time_base", "1:1000000", "-video_track_timescale", "1000000", "-c:v", "libx264", "-crf", "0", "-threads", "1", "-y", adjacent);
        File.WriteAllText(referencePath, JsonSerializer.Serialize(reference with { Video = "recordings/adjacent.mp4", Ticks = 180, Timescale = 600 }));
        try { using var image = await PortableImage.Open(root, "frames/exact.recallvideo"); assert(false, "A .3005-second VFR sample must not stand in for a .3000-second reference"); }
        catch (RecallException e) { assert(e.Code == "unsupported_media", "Low-timescale rounding cannot accept an adjacent VFR sample"); }
        File.WriteAllText(referencePath, JsonSerializer.Serialize(reference with { Video = "recordings/adjacent.mp4", Ticks = 3_005_000 }));
        using (var image = await PortableImage.Open(root, "frames/exact.recallvideo")) assert((await Pixels(image.Path))[0] > 240, "The same VFR sample is available at its exact native timestamp");
        File.WriteAllText(referencePath, JsonSerializer.Serialize(reference)); File.Delete(adjacent);

        var left = File.ReadAllBytes(await Png("left tile", 384, 2, 255, 0, 0));
        var right = File.ReadAllBytes(await Png("right tile", 1, 2, 0, 255, 0));
        string Tile(byte[] bytes)
        {
            var path = "frames/tiles/t1-" + Convert.ToHexString(SHA256.HashData(bytes)) + ".png";
            var full = Path.Combine(root, path); Directory.CreateDirectory(Path.GetDirectoryName(full)!); File.WriteAllBytes(full, bytes); return path;
        }
        var leftPath = Tile(left); var rightPath = Tile(right);
        var manifest = new ScreenManifest(1, 385, 2, [new(leftPath, 0, 0, 384, 2), new(rightPath, 384, 0, 1, 2)]);
        var tiledPath = Path.Combine(root, "frames", "tiled.recallframe"); File.WriteAllText(tiledPath, JsonSerializer.Serialize(manifest));
        byte[] loosePixels;
        using (var image = await PortableImage.Open(root, "frames/tiled.recallframe")) loosePixels = await Pixels(image.Path);
        assert(loosePixels[0] == 255 && loosePixels[384 * 3 + 1] == 255 && loosePixels[385 * 3] == 255, "Legacy loose tiles materialize at exact canvas positions and row order");
        store.Save(new MemoryFrame { Id = "video", ImagePath = "frames/exact.recallvideo", Text = "Original video OCR", TextState = RecognitionState.Complete });
        store.Save(new MemoryFrame { Id = "tiled", ImagePath = "frames/tiled.recallframe", Text = "Original tile OCR", TextState = RecognitionState.Complete });
        var optimization = await command(root, 0, ["storage", "optimize"]);
        assert(optimization.GetProperty("packedTiles").GetInt32() == 2 && optimization.GetProperty("completed").GetInt32() == 0 && optimization.GetProperty("videoBackedImages").GetInt32() == 1, "Portable optimization really packs two tiles and does not recompress archived video");
        assert(!File.Exists(Path.Combine(root, leftPath)) && !File.Exists(Path.Combine(root, rightPath)), "Verified packed blocks replace loose files");
        using (var image = await PortableImage.Open(root, "frames/tiled.recallframe")) assert((await Pixels(image.Path)).SequenceEqual(loosePixels), "Packed and legacy screenshot materialization have identical pixels");
        var repeated = await command(root, 0, ["storage", "optimize"]);
        assert(repeated.GetProperty("packedTiles").GetInt32() == 0 && File.ReadAllBytes(videoPath).SequenceEqual(videoBytes), "Optimization is idempotent and preserves encoded frame bytes");
        var statistics = LibraryStorage.Measure(root);
        assert(statistics.Archives is { VideoReferences: 1, TileReferences: 1, PackedTiles: 2, LooseTiles: 0 } && statistics.Archives.PackedPayloadBytes == left.Length + right.Length, "Storage distinguishes logical image references and logical packed payloads");
        assert(statistics.TotalBytes == statistics.Buckets.Values.Sum() && statistics.Buckets["video"] == videoBytes.Length && statistics.Archives.PackBytes >= statistics.Archives.PackedPayloadBytes && statistics.Buckets["images"] == statistics.Archives.PackBytes + new FileInfo(referencePath).Length + new FileInfo(tiledPath).Length, "Storage counts physical SQLite allocation and video once, without multiplying reference sizes");
        foreach (var language in new[] { "en", "zh" })
        {
            var output = new StringWriter(); var error = new StringWriter();
            var exit = await CliApplication.Run(["--data-dir", root, "--lang", language, "storage", "stats"], output, error);
            assert(exit == 0 && output.ToString().Contains(language == "en" ? "physical" : "实际占用") && output.ToString().Contains("2 / 0"), "Human storage output explains physical bytes and logical counts in " + language);
        }
        var export = Path.Combine(directory, "archive export");
        await command(root, 0, ["records", "export", "--output", export]);
        assert(File.ReadAllBytes(Path.Combine(export, "recordings", "exact.mp4")).SequenceEqual(videoBytes) && File.ReadAllBytes(Path.Combine(export, leftPath)).SequenceEqual(left), "Export includes exact video and unpacks tile dependencies into a portable bundle");
        using (var image = await PortableImage.OpenFile(Path.Combine(export, "frames", "tiled.recallframe"))) assert((await Pixels(image.Path)).SequenceEqual(loosePixels), "Exported tile archives are independently readable without the source catalog");
        var destination = Path.Combine(directory, "archive import");
        await command(destination, 0, ["library", "init", "--format", "windows"]);
        var imported = await command(destination, 0, ["records", "import", "--image", referencePath]);
        assert(imported.GetProperty("title").GetString() == "exact" && imported.GetProperty("imagePath").GetString()!.EndsWith(".png"), "Import materializes external archives and preserves the original title");
        using (var importedStore = new MemoryStore(destination))
        { var pixels = await Pixels(importedStore.SafePath(imported.GetProperty("imagePath").GetString()!)!); assert(pixels[0] > 240 && pixels[2] < 15, "Imported archive pixels use the selected exact frame"); }
        var originalOcr = Environment.GetEnvironmentVariable("RECALL_TESSERACT");
        try
        {
            Environment.SetEnvironmentVariable("RECALL_TESSERACT", Path.Combine(directory, "missing-tesseract"));
            try { await ArchiveOcr.Recognize(store, store.Frame("video")!, "eng", default); assert(false, "Failed OCR must not publish partial results"); }
            catch (Win32Exception) { assert(store.Frame("video")!.Text == "Original video OCR" && store.Frame("video")!.ImagePath == "frames/exact.recallvideo", "OCR dependency failure preserves text and the original archive reference"); }
        }
        finally { Environment.SetEnvironmentVariable("RECALL_TESSERACT", originalOcr); }

        // A fake OCR executable checks the real process boundary, while actual
        // archive decoding remains FFmpeg-backed. Both image planes must arrive
        // as PNG and retain their separate regions through offline and IPC jobs.
        var originalProbe = Environment.GetEnvironmentVariable("RECALL_TEST_ARCHIVE_OCR");
        var originalDotnet = Environment.GetEnvironmentVariable("DOTNET_ROOT");
        var probe = Path.ChangeExtension(typeof(ArchiveMediaChecks).Assembly.Location, OperatingSystem.IsWindows() ? ".exe" : null);
        try
        {
            Environment.SetEnvironmentVariable("RECALL_TEST_ARCHIVE_OCR", "1");
            Environment.SetEnvironmentVariable("RECALL_TESSERACT", probe);
            Environment.SetEnvironmentVariable("DOTNET_ROOT", new DirectoryInfo(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory()).Parent!.Parent!.Parent!.FullName);
            store.Save(store.Frame("video")! with { MeetingImagePath = "frames/tiled.recallframe" });
            var job = await command(root, 0, ["index", "run", "--id", "video"]);
            var indexed = store.Frame("video")!;
            assert(job.GetProperty("completed").GetInt32() == 1 && indexed.Text.Contains("Bitmap34x26") && indexed.Text.Contains("Bitmap385x2") && indexed.Regions.Count == 1 && indexed.MeetingRegions?.Count == 1, "Offline index decodes both archive planes and preserves separate OCR regions");
            assert(indexed.ImagePath == "frames/exact.recallvideo" && indexed.MeetingImagePath == "frames/tiled.recallframe", "OCR does not replace durable archive paths with temporary PNGs");
            var ocr = await command(root, 0, ["ocr", "image", referencePath]);
            assert(ocr.GetProperty("text").GetString() == "Bitmap34x26", "Standalone archive OCR reaches the real PNG process boundary");
            await command(root, 0, ["service", "start"]);
            try
            {
                var online = await command(root, 0, ["index", "run", "--id", "video"]);
                assert(online.GetProperty("completed").GetInt32() == 1 && store.Frame("video")!.MeetingRegions?.Count == 1, "Headless IPC indexing supports the same packed/video archive planes");
            }
            finally
            {
                await command(root, 0, ["service", "stop"]);
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                while (LibraryControlClient.Owner(root) != null) await Task.Delay(20, deadline.Token);
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable("RECALL_TEST_ARCHIVE_OCR", originalProbe);
            Environment.SetEnvironmentVariable("RECALL_TESSERACT", originalOcr);
            Environment.SetEnvironmentVariable("DOTNET_ROOT", originalDotnet);
        }

        var preserved = "frames/unpromoted.png"; File.Copy(red, Path.Combine(root, preserved));
        var originalBytes = File.ReadAllBytes(Path.Combine(root, preserved));
        store.SaveSession(new RecordingSession("failed-promotion", DateTimeOffset.UtcNow.AddSeconds(-1), DateTimeOffset.UtcNow, "recordings/exact.mp4", false,
            UnifiedVisualArchive: true, VisualArchiveReady: true, VideoWidth: 34, VideoHeight: 26, VideoDurationTicks: 10_000_000, VideoSampleCount: 10));
        store.Save(new MemoryFrame { Id = "unpromoted", ImagePath = preserved, SessionId = "failed-promotion", TextState = RecognitionState.Complete, ImageQuality = 1, VisualTicks = 3_000_000, VisualWidth = 34, VisualHeight = 26, VisualSampleVerified = true });
        assert(store.FinalizeVisualSession("failed-promotion", _=>false).Count == 0, "A failed exact decoder leaves the authoritative source intact");
        File.Copy(red, Path.Combine(root, "frames", "pending.ocr.png"));
        store.Save(new MemoryFrame { Id = "ocr-spool", ImagePath = "frames/pending.ocr.png", TextState = RecognitionState.Complete, ImageQuality = 1 });
        var protectedOptimization = await command(root, 0, ["storage", "optimize"]);
        assert(protectedOptimization.GetProperty("preservedOriginals").GetInt32() == 2 && store.Frame("unpromoted")!.ImageQuality == 1 && store.Frame("ocr-spool")!.ImageQuality == 1 && File.ReadAllBytes(Path.Combine(root, preserved)).SequenceEqual(originalBytes), "Optimization never downgrades failed unified-video originals or OCR spool PNGs");

        await command(root, 0, ["records", "star", "video"]);
        await command(root, 0, ["storage", "cleanup", "--scope", "all", "--yes"]);
        assert(store.Frame("tiled") == null && File.Exists(videoPath) && TilePackStore.ReadTile(root, leftPath)!.SequenceEqual(left), "Cleanup retains video and packed tiles referenced by a surviving starred record");
        await command(root, 0, ["storage", "cleanup", "--scope", "all", "--include-starred", "--yes"]);
        using (var packs = new TilePackStore(root)) assert(!File.Exists(videoPath) && packs.Statistics().Tiles == 0 && store.CheckIntegrity() == "ok", "Removing the last references reclaims video and packed tiles through CLI cleanup");
        assert(!Directory.EnumerateDirectories(Path.GetTempPath(), "recall-image-*").Except(beforeDirectories).Any(), "Successful imports, failures, and OCR leave no materialized files behind");
    }
}
