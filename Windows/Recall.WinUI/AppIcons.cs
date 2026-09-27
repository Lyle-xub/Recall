using System.Collections.Concurrent;
using System.Drawing;
using System.Drawing.Imaging;
using System.Diagnostics;
using Microsoft.Win32;
using System.Xml.Linq;
using Microsoft.UI.Xaml.Media.Imaging;
namespace Recall;

internal static class AppIcons
{
    public record Entry(byte[] Png, Windows.UI.Color Color);
    sealed class Cached(AppIdentity app)
    {
        public DateTimeOffset Created { get; } = DateTimeOffset.UtcNow;
        public long LastUse;
        public int CompletionRegistered;
        readonly Lazy<Task<Entry>> value = new(() => Task.Run(() => Extract(app)), LazyThreadSafetyMode.ExecutionAndPublication);
        public Task<Entry> Value => value.Value;
        public bool Completed => value.IsValueCreated && value.Value.IsCompleted;
    }
    sealed class Decoded(Task<BitmapImage?> value, long lastUse)
    {
        public DateTimeOffset Created { get; } = DateTimeOffset.UtcNow;
        public Task<BitmapImage?> Value { get; } = value;
        public long LastUse = lastUse;
    }
    const int EntryLimit = 512;
    const int ImageLimit = 256;
    static readonly TimeSpan MissingTtl = TimeSpan.FromSeconds(30);
    static readonly ConcurrentDictionary<string, Cached> cache = new(StringComparer.OrdinalIgnoreCase);
    static long entryClock;
    static int trimmingEntries;
    // BitmapImage belongs to its WinUI thread. Each UI thread reuses completed
    // and in-flight decodes independently, including across rebuilt icon views.
    [ThreadStatic] static Dictionary<string, Decoded>? images;
    [ThreadStatic] static long imageClock;
    static Dictionary<string, Decoded> Images => images ??= new(StringComparer.OrdinalIgnoreCase);
    static string Key(AppIdentity app) => string.Join("|", app.ExecutablePath, app.Process, app.Name, app.Kind);
    public static Task<Entry> Load(AppIdentity app)
    {
        var key = Key(app);
        var current = cache.GetOrAdd(key, _ => new Cached(app));
        if (current.Value.IsCompletedSuccessfully && current.Value.Result.Png.Length == 0 && DateTimeOffset.UtcNow - current.Created > MissingTtl)
        {
            var replacement = new Cached(app);
            current = cache.TryUpdate(key, replacement, current) ? replacement : cache.GetOrAdd(key, _ => new Cached(app));
        }
        Interlocked.Exchange(ref current.LastUse, Interlocked.Increment(ref entryClock));
        var result = current.Value;
        if (Interlocked.Exchange(ref current.CompletionRegistered, 1) == 0)
            _ = result.ContinueWith(static _ => TrimEntries(), CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
        TrimEntries();
        return result;
    }
    static void TrimEntries()
    {
        if (cache.Count <= EntryLimit || Interlocked.CompareExchange(ref trimmingEntries, 1, 0) != 0) return;
        try
        {
            var excess = cache.Count - EntryLimit;
            foreach (var pair in cache.Where(pair => pair.Value.Completed).OrderBy(pair => pair.Value.LastUse).Take(excess))
                ((ICollection<KeyValuePair<string, Cached>>)cache).Remove(pair);
        }
        finally { Volatile.Write(ref trimmingEntries, 0); }
    }
    static string? Resolve(AppIdentity app)
    {
        if (!string.IsNullOrWhiteSpace(app.ExecutablePath) && File.Exists(app.ExecutablePath)) return app.ExecutablePath;
        var process = Path.GetFileNameWithoutExtension(app.Process ?? "");
        if (process.Length == 0) return null;
        foreach (var candidate in Process.GetProcessesByName(process))
            using (candidate) { try { var path = candidate.MainModule?.FileName; if (File.Exists(path)) return path; } catch { } }
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
            using (var key = hive.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths" + Path.DirectorySeparatorChar + process + ".exe"))
                if (key?.GetValue(null) is string value && File.Exists(value.Trim('"'))) return value.Trim('"');
        return null;
    }
    static Bitmap? PackageLogo(string? executable)
    {
        try { return ReadPackageLogo(executable); }
        catch { return null; } // A protected/broken package must still try its executable icon.
    }
    static Bitmap? ReadPackageLogo(string? executable)
    {
        if (executable == null) return null;
        var folder = Path.GetDirectoryName(executable);
        for (int depth = 0; depth < 3 && folder != null; depth++, folder = Path.GetDirectoryName(folder))
        {
            var manifest = Path.Combine(folder, "AppxManifest.xml");
            if (!File.Exists(manifest)) continue;
            var document = XDocument.Load(manifest);
            var app = document.Descendants().FirstOrDefault(e => e.Name.LocalName == "Application" && executable.EndsWith(((string?)e.Attribute("Executable") ?? "::missing::").Replace('/', Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase));
            var visual = app?.Elements().FirstOrDefault(e => e.Name.LocalName.EndsWith("VisualElements"));
            var logo = (string?)visual?.Attribute("Square44x44Logo") ?? (string?)visual?.Attribute("Logo");
            if (string.IsNullOrWhiteSpace(logo)) return null;
            var full = Path.GetFullPath(Path.Combine(folder, logo));
            if (!full.StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return null;
            var directory = Path.GetDirectoryName(full)!;
            if (!Directory.Exists(directory)) return null;
            var image = File.Exists(full) ? full : Directory.EnumerateFiles(directory, Path.GetFileNameWithoutExtension(full) + "*.png").OrderByDescending(p => p.Contains("targetsize-64_altform-unplated")).ThenByDescending(p => p.Contains("targetsize-48")).FirstOrDefault();
            if (image != null) { using var original = new Bitmap(image); return new Bitmap(original); }
        }
        return null;
    }
    static Entry Extract(AppIdentity app)
    {
        try
        {
            var path = Resolve(app);
            using var packaged = PackageLogo(path);
            using var icon = packaged != null ? null : app.Name == "Recall" ? new Icon(Path.Combine(AppContext.BaseDirectory, "Assets", "Recall.ico")) : path != null ? Icon.ExtractAssociatedIcon(path) : null;
            using var bitmap = packaged != null ? new Bitmap(packaged) : icon?.ToBitmap();
            if (bitmap == null) return new Entry([], Design.Muted);
            using var small = new Bitmap(bitmap, 32, 32);
            var groups = new Dictionary<int, (double Weight, double R, double G, double B)>();
            for (var y = 0; y < 32; y++)
                for (var x = 0; x < 32; x++)
                {
                    var c = small.GetPixel(x, y);
                    var max = Math.Max(c.R, Math.Max(c.G, c.B));
                    var min = Math.Min(c.R, Math.Min(c.G, c.B));
                    if (c.A < 180 || max > 248 && min > 230 || max < 35)
                        continue;
                    double saturation = (max - min) / 255.0;
                    var weight = .15 + saturation * saturation * 3;
                    var key = (c.R / 40) * 49 + (c.G / 40) * 7 + c.B / 40;
                    var b = groups.GetValueOrDefault(key);
                    groups[key] = (b.Weight + weight, b.R + c.R * weight, b.G + c.G * weight, b.B + c.B * weight);
                }
            var best = groups.Values.OrderByDescending(c => c.Weight).FirstOrDefault();
            var color = best.Weight > 0 ? Windows.UI.Color.FromArgb(255, (byte)(best.R / best.Weight), (byte)(best.G / best.Weight), (byte)(best.B / best.Weight)) : Design.Muted;
            using var memory = new MemoryStream();
            bitmap.Save(memory, ImageFormat.Png);
            return new Entry(memory.ToArray(), color);
        }
        catch { return new Entry([], Design.Muted); }
    }
    static bool TryCachedImage(string key, out BitmapImage? bitmap)
    {
        bitmap = null;
        if (!Images.TryGetValue(key, out var cached) || !cached.Value.IsCompletedSuccessfully)
            return false;
        bitmap = cached.Value.Result;
        if (bitmap == null) return false;
        cached.LastUse = ++imageClock;
        return true;
    }
    static Task<BitmapImage?> ImageFor(AppIdentity app, string key)
    {
        var store = Images;
        if (store.TryGetValue(key, out var cached))
        {
            if (cached.Value.IsFaulted || cached.Value.IsCanceled ||
                cached.Value.IsCompletedSuccessfully && cached.Value.Result == null && DateTimeOffset.UtcNow - cached.Created > MissingTtl)
                store.Remove(key);
            else
            {
                cached.LastUse = ++imageClock;
                return cached.Value;
            }
        }
        var task = Decode(app);
        store[key] = new Decoded(task, ++imageClock);
        TrimImages(store);
        return task;
    }
    static void TrimImages(Dictionary<string, Decoded> store)
    {
        if (store.Count <= ImageLimit) return;
        foreach (var key in store.Where(pair => pair.Value.Value.IsCompleted)
            .OrderBy(pair => pair.Value.LastUse).Take(store.Count - ImageLimit)
            .Select(pair => pair.Key).ToArray())
            store.Remove(key);
    }
    static async Task<BitmapImage?> Decode(AppIdentity app)
    {
        var entry = await Load(app);
        if (entry.Png.Length == 0) return null;
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        using (var writer = new Windows.Storage.Streams.DataWriter(stream))
        {
            writer.WriteBytes(entry.Png);
            await writer.StoreAsync();
            writer.DetachStream();
        }
        stream.Seek(0);
        var bitmap = new BitmapImage();
        await bitmap.SetSourceAsync(stream);
        return bitmap;
    }
    static Windows.UI.Color PlateColor(bool dark) => dark
        ? Windows.UI.Color.FromArgb(255, 110, 118, 130)
        : Windows.UI.Color.FromArgb(255, 146, 153, 163);
    public static FrameworkElement View(AppIdentity app, double size = 28)
    {
        var image = new Microsoft.UI.Xaml.Controls.Image { Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var placeholder = new FontIcon { Glyph = "\uE737", FontFamily = new("Segoe Fluent Icons"), FontSize = size * .58, Foreground = Design.Brush(Windows.UI.Color.FromArgb(255, 24, 30, 38)) };
        var host = new Border
        {
            Width = size, Height = size, Padding = new(Math.Clamp(size * .12, 2, 5)),
            CornerRadius = new(Math.Max(5, size * .24)),
            Background = Design.Brush(PlateColor(Design.Dark)),
            Child = placeholder, UseLayoutRounding = true
        };
        var key = Key(app);
        if (TryCachedImage(key, out var bitmap)) { image.Source = bitmap; host.Child = image; }
        ToolTipService.SetToolTip(host, app.Name); Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(host, app.Name);
        host.ActualThemeChanged += (_, _) => host.Background = Design.Brush(PlateColor(host.ActualTheme == ElementTheme.Dark));
        int revision = 0;
        host.Unloaded += (_, _) => revision++;
        host.Loaded += async (_, _) =>
        {
            var current = ++revision;
            try
            {
                var decoded = await ImageFor(app, key);
                TrimImages(Images);
                if (current != revision) return;
                if (decoded == null) { host.Child = placeholder; return; }
                image.Source = decoded; host.Child = image;
            }
            catch { if (current == revision) host.Child = placeholder; }
        };
        return host;
    }
    public static AppIdentity Identity(MemoryFrame frame) => new(frame.AppName, frame.ProcessName, frame.ExecutablePath);
}
