using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Text.Json;
using System.Net.Http;

namespace Recall;

/// An explicit, isolated native validation session. No recording or real library.
/// Commands drive app state; real pointer/keyboard interaction is tested separately.
internal sealed class VisualParitySession
{
    readonly RecallWindow window;
    readonly AppRuntime runtime;
    readonly string output;
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
    readonly List<double> renderIntervals = [];
    long lastRender;
    string? lastCommand;
    bool busy;
    static System.Windows.Forms.Form? referenceBackdrop;
    static bool stripedBackdrop;
    static bool desktopScene;
    static int sceneVariant;
    static readonly JsonSerializerOptions json = new() { PropertyNameCaseInsensitive = true, WriteIndented = true };
    readonly HttpClient? transport;
    VisualParitySession(RecallWindow window, AppRuntime runtime, string output)
    {
        this.window = window; this.runtime = runtime; this.output = output;
        // Explicit development-only transport. Normal app launches never read
        // this file or expose a server. Only typed JSON state and generated
        // synthetic evidence are transferred; there is no command execution.
        var transportFile = Path.Combine(output, "transport.json");
        if (File.Exists(transportFile))
        {
            using var config = JsonDocument.Parse(File.ReadAllText(transportFile));
            var address = new Uri(config.RootElement.GetProperty("url").GetString()!);
            if (address.Scheme != "http" || address.Host != "100.127.135.99" || address.Port != 18764)
                throw new InvalidDataException("Unexpected visual-validation transport endpoint.");
            transport = new HttpClient { BaseAddress = address, Timeout = TimeSpan.FromSeconds(10) };
        }
        timer = window.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(transport == null ? 200 : 1500);
        timer.Tick += async (_, _) => await Tick();
        timer.Start();
    }
    public static async Task Start(RecallWindow window, AppRuntime runtime, string output)
    {
        output = Path.GetFullPath(output);
        Directory.CreateDirectory(output);
        var fixtures = Path.Combine(output, "fixtures");
        using var manifest = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(fixtures, "fixture.json")));
        Directory.CreateDirectory(Path.Combine(runtime.Store.Root, "frames"));
        foreach (var item in manifest.RootElement.GetProperty("frames").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString()!;
            if (!id.StartsWith("parity-", StringComparison.Ordinal) || id.Any(c => !char.IsLetterOrDigit(c) && c != '-')) throw new InvalidDataException("Only controlled parity fixtures are accepted.");
            var relative = "frames/" + id + ".png";
            File.Copy(Path.Combine(fixtures, relative), Path.Combine(runtime.Store.Root, relative), true);
            if (item.TryGetProperty("archive", out var archive) && archive.GetBoolean())
            {
                using var source = new Bitmap(Path.Combine(runtime.Store.Root, relative));
                relative = await Task.Run(() => ImageArchive.Pack(runtime.Store.Root, source));
            }
            var timestamp = item.GetProperty("timestamp").GetDateTimeOffset();
            var appName = item.GetProperty("appName").GetString()!;
            var executable = item.TryGetProperty("executablePath", out var exe) ? exe.GetString() : null;
            var processName = item.TryGetProperty("processName", out var process) ? process.GetString() ?? "" : "parity-" + appName;
            runtime.Store.SaveUsage(new AppInterval(id + "-usage", new AppIdentity(appName, processName, executable), timestamp, timestamp.AddMinutes(7)));
            runtime.Store.Save(new MemoryFrame { Id = id, Timestamp = timestamp, EndTimestamp = timestamp.AddMinutes(7), AppName = item.GetProperty("appName").GetString()!, ProcessName = processName, ExecutablePath = executable, Title = item.GetProperty("title").GetString()!, ImagePath = relative, Text = item.GetProperty("text").GetString()!, Starred = item.GetProperty("starred").GetBoolean(), TextState = RecognitionState.Complete });
        }
        var videoImage = Path.Combine(fixtures, "video.png");
        if (File.Exists(videoImage))
        {
            Directory.CreateDirectory(Path.Combine(runtime.Store.Root, "recordings"));
            var destination = Path.Combine(runtime.Store.Root, "recordings", "parity-video.mp4");
            if (!File.Exists(destination))
            {
                var composition = new Windows.Media.Editing.MediaComposition();
                var imageFile = await Windows.Storage.StorageFile.GetFileFromPathAsync(videoImage);
                composition.Clips.Add(await Windows.Media.Editing.MediaClip.CreateFromImageFileAsync(imageFile, TimeSpan.FromSeconds(20)));
                var folder = await Windows.Storage.StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(destination)!);
                var outputFile = await folder.CreateFileAsync("parity-video.mp4", Windows.Storage.CreationCollisionOption.ReplaceExisting);
                var encoding = Windows.Media.MediaProperties.MediaEncodingProfile.CreateMp4(Windows.Media.MediaProperties.VideoEncodingQuality.HD720p);
                var result = await composition.RenderToFileAsync(outputFile, Windows.Media.Editing.MediaTrimmingPreference.Precise, encoding);
                if (result != Windows.Media.Transcoding.TranscodeFailureReason.None) throw new InvalidOperationException("Synthetic video encode failed: " + result);
            }
            if (runtime.Store.Frame("parity-0-0") is { } videoFrame)
            {
                runtime.Store.SaveSession(new RecordingSession("parity-video", videoFrame.Timestamp, videoFrame.Timestamp.AddSeconds(20), "recordings/parity-video.mp4", false));
                runtime.Store.Save(videoFrame with { SessionId = "parity-video" });
            }
        }
        runtime.Settings.RecordingRequested = false;
        foreach (var fixture in new[] { ("rotated", "parity-0-1"), ("broken", "parity-0-2") })
        {
            var input = Path.Combine(fixtures, "video-" + fixture.Item1 + ".mp4");
            if (!File.Exists(input) || runtime.Store.Frame(fixture.Item2) is not { } frame) continue;
            var relative = "recordings/parity-" + fixture.Item1 + ".mp4";
            Directory.CreateDirectory(Path.Combine(runtime.Store.Root, "recordings"));
            File.Copy(input, Path.Combine(runtime.Store.Root, relative), true);
            var id = "parity-" + fixture.Item1;
            runtime.Store.SaveSession(new RecordingSession(id, frame.Timestamp, frame.Timestamp.AddSeconds(20), relative, false));
            runtime.Store.Save(frame with { SessionId = id });
        }
        // Pixel-rotated fixtures deliberately have no MP4 rotation metadata.
        // Their still stays upright so acceptance exercises decoded-frame
        // alignment, not merely the old metadata correction branch.
        foreach (var name in new[] { "plain720", "pixel90", "pixel180", "pixel270", "pixel90squeezed" })
        {
            var id = "parity-video-" + name;
            var input = Path.Combine(fixtures, "video-" + name + ".png");
            if (!File.Exists(input) || runtime.Store.Frame(id) is not { } videoFrame) continue;
            var relative = "recordings/" + id + ".mp4";
            var destination = Path.Combine(runtime.Store.Root, relative);
            if (!File.Exists(destination))
            {
                var composition = new Windows.Media.Editing.MediaComposition();
                var source = await Windows.Storage.StorageFile.GetFileFromPathAsync(input);
                composition.Clips.Add(await Windows.Media.Editing.MediaClip.CreateFromImageFileAsync(source, TimeSpan.FromSeconds(10)));
                var folder = await Windows.Storage.StorageFolder.GetFolderFromPathAsync(Path.GetDirectoryName(destination)!);
                var outputFile = await folder.CreateFileAsync(Path.GetFileName(destination), Windows.Storage.CreationCollisionOption.ReplaceExisting);
                var profile = Windows.Media.MediaProperties.MediaEncodingProfile.CreateMp4(Windows.Media.MediaProperties.VideoEncodingQuality.HD720p);
                using var bitmap = new Bitmap(input);
                profile.Video.Width = (uint)bitmap.Width;
                profile.Video.Height = (uint)bitmap.Height;
                profile.Video.FrameRate.Numerator = 1; profile.Video.FrameRate.Denominator = 1;
                var result = await composition.RenderToFileAsync(outputFile, Windows.Media.Editing.MediaTrimmingPreference.Precise, profile);
                if (result != Windows.Media.Transcoding.TranscodeFailureReason.None) throw new InvalidOperationException("Orientation fixture encode failed: " + result);
            }
            runtime.Store.SaveSession(new RecordingSession(id, videoFrame.Timestamp, videoFrame.Timestamp.AddSeconds(10), relative, false));
            runtime.Store.Save(videoFrame with { SessionId = id });
        }
        // RDP can disable OS animations. Exercise the real spring path in
        // this isolated test session without changing the user's OS setting.
        var systemAnimationsEnabled = new Windows.UI.ViewManagement.UISettings().AnimationsEnabled;
        Design.ValidationMotion = true;
        // A controlled desktop prevents private windows leaking into evidence
        // and keeps acrylic comparisons independent of the user's wallpaper.
        var bounds = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position).Bounds;
        referenceBackdrop = new System.Windows.Forms.Form { FormBorderStyle = System.Windows.Forms.FormBorderStyle.None, Bounds = bounds, ShowInTaskbar = false, BackColor = System.Drawing.Color.FromArgb(219, 219, 216) };
        referenceBackdrop.Paint += (_, e) =>
        {
            if (desktopScene)
            {
                e.Graphics.Clear(System.Drawing.Color.FromArgb(26, 39, 64));
                System.Drawing.Color[] colors = [System.Drawing.Color.FromArgb(39, 101, 180), System.Drawing.Color.FromArgb(209, 85, 73), System.Drawing.Color.FromArgb(37, 151, 116)];
                for (var i = 0; i < 3; i++)
                {
                    using var fill = new System.Drawing.SolidBrush(colors[(i + sceneVariant) % colors.Length]);
                    var x = 40 + i * 410;
                    e.Graphics.FillRectangle(fill, x, 170, 360, 460);
                    using var font = new System.Drawing.Font("Segoe UI", 22);
                    e.Graphics.DrawString("Synthetic desktop", font, System.Drawing.Brushes.White, x + 15, 195);
                    for (var y = 290; y < 580; y += 20)
                        e.Graphics.FillRectangle(System.Drawing.Brushes.White, x + 18, y, 290, 2);
                }
                return;
            }
            if (stripedBackdrop)
            {
                e.Graphics.Clear(System.Drawing.Color.FromArgb(227, 232, 237));
                System.Drawing.Color[] colors = [System.Drawing.Color.FromArgb(69, 133, 212), System.Drawing.Color.FromArgb(207, 102, 125), System.Drawing.Color.FromArgb(235, 186, 89), System.Drawing.Color.FromArgb(82, 171, 148)];
                for (var i = 0; i < 16; i++)
                { using var fill = new System.Drawing.SolidBrush(colors[i % 4]); e.Graphics.FillRectangle(fill, i * 80, 0, 40, bounds.Height); }
                using var line = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(153, 0, 0, 0));
                for (var y = 100; y < bounds.Height; y += 160) e.Graphics.FillRectangle(line, 0, y, bounds.Width, 3);
                return;
            }
            using var gradient = new System.Drawing.Drawing2D.LinearGradientBrush(bounds, System.Drawing.Color.FromArgb(233, 230, 221), System.Drawing.Color.FromArgb(190, 204, 215), 35);
            e.Graphics.FillRectangle(gradient, bounds);
        };
        referenceBackdrop.Show();
        window.Show();
        window.Navigate("search");
        // First-load XAML attachment can exceed 500 ms on a cold machine. Do
        // not start capture commands or read RasterizationScale before it exists.
        var content = (FrameworkElement)window.Content;
        for (var attempt = 0; content.XamlRoot == null && attempt < 100; attempt++) await Task.Delay(100);
        if (content.XamlRoot == null) throw new InvalidOperationException("Validation window did not attach to the desktop.");
        var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position);
        await File.WriteAllTextAsync(Path.Combine(output, "environment.json"), JsonSerializer.Serialize(new { capturedAt = DateTimeOffset.UtcNow, os = Environment.OSVersion.ToString(), processorCount = Environment.ProcessorCount, screen = new { screen.Bounds.Width, screen.Bounds.Height }, scale = ((FrameworkElement)window.Content).XamlRoot.RasterizationScale, logicalWidth = ((FrameworkElement)window.Content).ActualWidth, logicalHeight = ((FrameworkElement)window.Content).ActualHeight, records = runtime.Store.Count, synthetic = true, systemAnimationsEnabled, validationAnimationsEnabled = Design.Motion }, json));
        _ = new VisualParitySession(window, runtime, output);
    }
    void OnRendering(object? sender, object e)
    {
        var now = Stopwatch.GetTimestamp();
        if (lastRender != 0 && renderIntervals.Count < 20000) renderIntervals.Add((now - lastRender) * 1000.0 / Stopwatch.Frequency);
        lastRender = now;
    }
    async Task Tick()
    {
        if (busy) return;
        var file = Path.Combine(output, "control.json");
        if (transport == null && !File.Exists(file)) return;
        busy = true;
        string? name = null;
        try
        {
            var text = transport == null ? await File.ReadAllTextAsync(file) : await transport.GetStringAsync("control.json");
            if (text == lastCommand) return;
            using var command = JsonDocument.Parse(text);
            lastCommand = text;
            var request = command.RootElement;
            name = request.GetProperty("name").GetString()!;
            if (string.IsNullOrWhiteSpace(name) || name is "." or ".." || name != Path.GetFileName(name)) throw new InvalidDataException("Capture name must be a filename.");
            string? Field(string key) => request.TryGetProperty(key, out var value) ? value.GetString() : null;
            bool? Flag(string key) => request.TryGetProperty(key, out var value) ? value.GetBoolean() : null;
            if (Field("action") == "quit")
            {
                timer.Stop();
                referenceBackdrop?.Close();
                window.FinishSmoke();
                await runtime.Shutdown();
                Application.Current.Exit();
                return;
            }
            if (Flag("stripedBackdrop") is bool striped) { stripedBackdrop = striped; referenceBackdrop?.Invalidate(); }
            if (Flag("desktopScene") is bool scene) { desktopScene = scene; referenceBackdrop?.Invalidate(); }
            if (request.TryGetProperty("sceneVariant", out var variant)) { sceneVariant = Math.Clamp(variant.GetInt32(), 0, 2); referenceBackdrop?.Invalidate(); }
            if (Flag("reducedMotion") is bool reducedMotion) Design.ValidationMotion = !reducedMotion;
            if (request.TryGetProperty("windowWidth", out var windowWidth) && request.TryGetProperty("windowHeight", out var windowHeight))
            {
                window.AppWindow.Resize(new Windows.Graphics.SizeInt32(Math.Clamp(windowWidth.GetInt32(), 640, 3840), Math.Clamp(windowHeight.GetInt32(), 480, 2160)));
                await Task.Delay(150);
            }
            if (Flag("backdropOnly") != true)
            {
                // Interaction-only probes must not rebuild every glass shader
                // before the action: that measures policy refresh, not user input.
                if (Flag("captureOnly") != true || request.TryGetProperty("fallback", out _) || request.TryGetProperty("hostFailure", out _) || request.TryGetProperty("parameters", out _))
                {
                    GlassMaterial.ValidationFallback = Flag("fallback") == true;
                    ClearBackdrop.ValidationHostFailure = Flag("hostFailure") == true;
                    GlassMaterial.ValidationParameters.Clear();
                    if (request.TryGetProperty("parameters", out var parameters)) GlassMaterial.Configure(parameters);
                    else GlassMaterial.SetDark(Design.Dark);
                }
                if (Flag("material") == true) window.ValidationMaterial(Flag("dark") == true, Flag("desktop") == true);
                else if (Flag("captureOnly") != true)
                    await window.ValidationState(Flag("rhine"), Flag("dark"), Field("page"), Field("query"), Field("app"), Field("selected"), DateTime.TryParse(Field("day"), out var day) ? day : null, Field("tab"), Flag("timeline") == true);
                if (Field("action") == "archive-append-fixture")
                {
                    var fixture = runtime.Store.Frame("parity-2-8")
                        ?? throw new InvalidOperationException("The controlled archive fixture is missing.");
                    var timestamp = new DateTimeOffset(fixture.Timestamp.LocalDateTime.Date.AddHours(23).AddMinutes(59));
                    await Task.Run(() => runtime.Store.Save(fixture with
                    {
                        Id = "parity-reopen-added", Title = "New synthetic memory", Timestamp = timestamp,
                        EndTimestamp = timestamp.AddSeconds(1), Starred = false, DeletedAt = null
                    }));
                }
                else if (Field("action") == "archive-trash-fixture")
                {
                    var fixture = runtime.Store.Frame("parity-reopen-added")
                        ?? throw new InvalidOperationException("The controlled archive fixture is missing.");
                    await Task.Run(() => runtime.Store.Trash(fixture));
                }
                else if (Field("action") == "reference-backdrop")
                {
                    referenceBackdrop?.BringToFront();
                    if (window.IsShown) window.Activate();
                }
                else if (Field("action") == "frame")
                    window.ValidationSelectFrame(Field("frameId") ?? throw new InvalidDataException("frame action requires frameId."));
                else if (Field("action") == "archive-seek")
                    window.ValidationSeekArchive(Field("frameId") ?? throw new InvalidDataException("archive-seek requires frameId."));
                else if (Field("action") == "archive-timeline-show")
                    window.ValidationShowArchiveTimeline();
                else if (Field("action") == "archive-pointer-top")
                    window.ValidationMoveArchivePointerToTop();
                else if (Field("action") == "archive-timeline-commit")
                    await window.ValidationCommitArchiveTimeline(Field("frameId") ?? throw new InvalidDataException("archive-timeline-commit requires frameId."));
                else window.ValidationAction(Field("action"));
            }
            await Task.Delay(request.TryGetProperty("settleMs", out var settle) ? Math.Clamp(settle.GetInt32(), 0, 10000) : 1200);
            renderIntervals.Clear(); lastRender = 0;
            var measureSeconds = request.TryGetProperty("measureSeconds", out var seconds) ? Math.Clamp(seconds.GetDouble(), 0, 60) : 0;
            if (Flag("sampleRendering") != false) CompositionTarget.Rendering += OnRendering;
            var count = request.TryGetProperty("frames", out var frames) ? Math.Clamp(frames.GetInt32(), 1, 120) : 1;
            if (Flag("capture") == false) count = 0; // Diagnostics on a non-interactive build desktop; never visual evidence.
            var directory = Path.Combine(output, name);
            Directory.CreateDirectory(directory);
            var process = Process.GetCurrentProcess();
            var cpu = process.TotalProcessorTime;
            var elapsed = Stopwatch.StartNew();
            if (request.TryGetProperty("motionSamples", out var motion))
                for (var step = 0; step < Math.Clamp(motion.GetInt32(), 0, 120); step++) { window.ValidationRetarget(step); await Task.Delay(250); }
            if (request.TryGetProperty("dragSamples", out var drag))
            {
                try
                {
                    for (var step = 0; step < Math.Clamp(drag.GetInt32(), 0, 600); step++)
                    { window.ValidationDrag(step); await Task.Delay(16); }
                }
                finally { window.ValidationEndDrag(); }
            }
            if (request.TryGetProperty("timelineDragSamples", out var timelineDrag))
            {
                window.ValidationBeginTimelineDrag();
                try
                {
                    for (var step = 0; step < Math.Clamp(timelineDrag.GetInt32(),0,600); step++)
                    { window.ValidationTimelineDrag(step); await Task.Delay(16); }
                }
                finally { await window.ValidationEndTimelineDrag(); }
            }
            if (measureSeconds > 0) await Task.Delay(TimeSpan.FromSeconds(measureSeconds));
            // Burst evidence defers PNG compression until the transition ends.
            // This reduces capture gaps; it still is not a GPU frame-time probe.
            var burst = request.TryGetProperty("captureIntervalMs", out var interval);
            var captureInterval = burst ? Math.Clamp(interval.GetInt32(), 16, 1000) : 100;
            var bufferedFrames = new List<Bitmap>();
            var captureTimesMs = new List<double>();
            var previewStates = new List<object?>();
            var mediaStates = new List<object?>();
            var archiveStates = new List<object>();
            try
            {
            for (var index = 0; index < count; index++)
            {
                // Each requested frame is selected immediately before its capture;
                // a fast sequence therefore exercises real decode cancellation.
                if (request.TryGetProperty("frameIds", out var frameIds) && frameIds.ValueKind == JsonValueKind.Array && index < frameIds.GetArrayLength())
                {
                    window.ValidationSelectFrame(frameIds[index].GetString() ?? throw new InvalidDataException("frameIds contains a null id."));
                    if (request.TryGetProperty("frameIntervalMs", out var frameDelay))
                        await Task.Delay(Math.Clamp(frameDelay.GetInt32(), 0, 1000));
                }
                var screen = System.Windows.Forms.Screen.FromHandle(WinRT.Interop.WindowNative.GetWindowHandle(window));
                var captured = false;
                for (var attempt = 0; attempt < 8 && !captured; attempt++)
                {
                    captured = await Task.Run(() =>
                    {
                        var bitmap = new Bitmap(screen.Bounds.Width, screen.Bounds.Height);
                        try
                        {
                        using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen(screen.Bounds.Location, System.Drawing.Point.Empty, screen.Bounds.Size);
                        // Cold compositor startup can return an all-white frame
                        // without an API error. Never count that as visual evidence.
                        var min = 765; var max = 0;
                        for (var y = 8; y < bitmap.Height; y += 19)
                            for (var x = 8; x < bitmap.Width; x += 19)
                            {
                                var pixel = bitmap.GetPixel(x, y); var value = pixel.R + pixel.G + pixel.B;
                                min = Math.Min(min, value); max = Math.Max(max, value);
                            }
                        if (max - min < 12) return false;
                        captureTimesMs.Add(elapsed.Elapsed.TotalMilliseconds);
                        if (burst) { bufferedFrames.Add(bitmap); bitmap = null!; }
                        else bitmap.Save(Path.Combine(directory, $"{index:000}.png"), ImageFormat.Png);
                        return true;
                        }
                        finally { bitmap?.Dispose(); }
                    });
                    if (!captured) await Task.Delay(400);
                }
                if (!captured) throw new InvalidOperationException("The compositor returned a uniform frame; no visual evidence was accepted.");
                previewStates.Add(window.ValidationPreviewDiagnostics);
                mediaStates.Add(window.ValidationMediaDiagnostics);
                archiveStates.Add(window.ValidationArchiveDiagnostics);
                if (count > 1) await Task.Delay(captureInterval);
            }
            if (burst) await Task.Run(() =>
            {
                for (var index = 0; index < bufferedFrames.Count; index++)
                    bufferedFrames[index].Save(Path.Combine(directory, $"{index:000}.png"), ImageFormat.Png);
            });
            }
            finally { foreach (var bitmap in bufferedFrames) bitmap.Dispose(); }
            process.Refresh();
            var cpuMs = (process.TotalProcessorTime - cpu).TotalMilliseconds;
            await File.WriteAllTextAsync(Path.Combine(directory, "metrics.json"), JsonSerializer.Serialize(new { glassError = GlassMaterial.Error, screenshotCount = count, captureTimesMs, previewStates, mediaStates, archiveStates, elapsedMs = elapsed.Elapsed.TotalMilliseconds, cpuMilliseconds = cpuMs, cpuPercentOfOneCore = cpuMs / elapsed.Elapsed.TotalMilliseconds * 100, workingSetBytes = process.WorkingSet64, peakWorkingSetBytes = process.PeakWorkingSet64, privateBytes = process.PrivateMemorySize64, renderingCallbackIntervalsMs = renderIntervals.ToArray(), state = window.ValidationDiagnostics, note = "Rendering callbacks measure UI scheduling, not GPU present time; capture overhead is included. sampleRendering=false measures idle without a rendering observer." }, json));
            await File.WriteAllTextAsync(Path.Combine(output, "completed.json"), JsonSerializer.Serialize(new { name, ok = true }, json));
            if (transport != null)
            {
                // Whitelist only files generated above, never enumerate the
                // library or unrelated output-directory contents for upload.
                using var bytes = new MemoryStream();
                using (var zip = new System.IO.Compression.ZipArchive(bytes, System.IO.Compression.ZipArchiveMode.Create, true))
                {
                    async Task Add(string path, string entry)
                    {
                        await using var source = File.OpenRead(path);
                        await using var target = zip.CreateEntry(entry).Open(); await source.CopyToAsync(target);
                    }
                    await Add(Path.Combine(output, "completed.json"), "completed.json");
                    await Add(Path.Combine(directory, "metrics.json"), "metrics.json");
                    for (var i = 0; i < count; i++) await Add(Path.Combine(directory, $"{i:000}.png"), $"{i:000}.png");
                }
                bytes.Position = 0;
                using var payload = new StreamContent(bytes);
                using var response = await transport.PutAsync("evidence.zip", payload); response.EnsureSuccessStatusCode();
            }
        }
        catch (Exception error) { await File.WriteAllTextAsync(Path.Combine(output, "completed.json"), JsonSerializer.Serialize(new { name, ok = false, error = error.ToString() }, json)); }
        finally { CompositionTarget.Rendering -= OnRendering; busy = false; }
    }
}
