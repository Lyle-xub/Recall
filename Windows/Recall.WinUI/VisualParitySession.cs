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
    readonly string output;
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
    readonly List<double> renderIntervals = [];
    long lastRender;
    string? lastCommand;
    bool busy;
    static System.Windows.Forms.Form? referenceBackdrop;
    static bool stripedBackdrop;
    static readonly JsonSerializerOptions json = new() { PropertyNameCaseInsensitive = true, WriteIndented = true };
    readonly HttpClient? transport;
    VisualParitySession(RecallWindow window, string output)
    {
        this.window = window; this.output = output;
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
            runtime.Store.Save(new MemoryFrame { Id = id, Timestamp = item.GetProperty("timestamp").GetDateTimeOffset(), AppName = item.GetProperty("appName").GetString()!, Title = item.GetProperty("title").GetString()!, ImagePath = relative, Text = item.GetProperty("text").GetString()!, Starred = item.GetProperty("starred").GetBoolean(), TextState = RecognitionState.Complete });
        }
        runtime.Settings.RecordingRequested = false;
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
        await Task.Delay(500);
        _ = new VisualParitySession(window, output);
        var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position);
        await File.WriteAllTextAsync(Path.Combine(output, "environment.json"), JsonSerializer.Serialize(new { capturedAt = DateTimeOffset.UtcNow, os = Environment.OSVersion.ToString(), processorCount = Environment.ProcessorCount, screen = new { screen.Bounds.Width, screen.Bounds.Height }, scale = ((FrameworkElement)window.Content).XamlRoot.RasterizationScale, logicalWidth = ((FrameworkElement)window.Content).ActualWidth, logicalHeight = ((FrameworkElement)window.Content).ActualHeight, records = runtime.Store.Count, synthetic = true, systemAnimationsEnabled, validationAnimationsEnabled = Design.Motion }, json));
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
            if (Field("action") == "quit") { referenceBackdrop?.Close(); Application.Current.Exit(); return; }
            if (Flag("stripedBackdrop") is bool striped) { stripedBackdrop = striped; referenceBackdrop?.Invalidate(); }
            GlassMaterial.ValidationFallback = Flag("fallback") == true;
            if (request.TryGetProperty("parameters", out var parameters)) GlassMaterial.Configure(parameters);
            if (Flag("material") == true) window.ValidationMaterial(Flag("dark") == true, Flag("desktop") == true);
            else if (Flag("captureOnly") != true)
                await window.ValidationState(Flag("rhine"), Flag("dark"), Field("page"), Field("query"), Field("app"), Field("selected"), DateTime.TryParse(Field("day"), out var day) ? day : null, Field("tab"), Flag("timeline") == true);
            window.ValidationAction(Field("action"));
            await Task.Delay(request.TryGetProperty("settleMs", out var settle) ? Math.Clamp(settle.GetInt32(), 0, 10000) : 1200);
            renderIntervals.Clear(); lastRender = 0;
            var measureSeconds = request.TryGetProperty("measureSeconds", out var seconds) ? Math.Clamp(seconds.GetDouble(), 0, 60) : 0;
            if (Flag("sampleRendering") != false) CompositionTarget.Rendering += OnRendering;
            var count = request.TryGetProperty("frames", out var frames) ? Math.Clamp(frames.GetInt32(), 1, 120) : 1;
            var directory = Path.Combine(output, name);
            Directory.CreateDirectory(directory);
            var process = Process.GetCurrentProcess();
            var cpu = process.TotalProcessorTime;
            var elapsed = Stopwatch.StartNew();
            if (request.TryGetProperty("motionSamples", out var motion))
                for (var step = 0; step < Math.Clamp(motion.GetInt32(), 0, 120); step++) { window.ValidationRetarget(step); await Task.Delay(250); }
            if (measureSeconds > 0) await Task.Delay(TimeSpan.FromSeconds(measureSeconds));
            for (var index = 0; index < count; index++)
            {
                var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position);
                await Task.Run(() =>
                {
                    using var bitmap = new Bitmap(screen.Bounds.Width, screen.Bounds.Height);
                    using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen(screen.Bounds.Location, System.Drawing.Point.Empty, screen.Bounds.Size);
                    bitmap.Save(Path.Combine(directory, $"{index:000}.png"), ImageFormat.Png);
                });
                if (count > 1) await Task.Delay(100);
            }
            process.Refresh();
            var cpuMs = (process.TotalProcessorTime - cpu).TotalMilliseconds;
            await File.WriteAllTextAsync(Path.Combine(directory, "metrics.json"), JsonSerializer.Serialize(new { glassError = GlassMaterial.Error, screenshotCount = count, elapsedMs = elapsed.Elapsed.TotalMilliseconds, cpuMilliseconds = cpuMs, cpuPercentOfOneCore = cpuMs / elapsed.Elapsed.TotalMilliseconds * 100, workingSetBytes = process.WorkingSet64, peakWorkingSetBytes = process.PeakWorkingSet64, privateBytes = process.PrivateMemorySize64, renderingCallbackIntervalsMs = renderIntervals.ToArray(), state = window.ValidationDiagnostics, note = "Rendering callbacks measure UI scheduling, not GPU present time; capture overhead is included. sampleRendering=false measures idle without a rendering observer." }, json));
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
