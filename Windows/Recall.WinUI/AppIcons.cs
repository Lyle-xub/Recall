using System.Collections.Concurrent;
using System.Drawing;
using System.Drawing.Imaging;
using Microsoft.UI.Xaml.Media.Imaging;
namespace Recall;

internal static class AppIcons
{
    public record Entry(byte[] Png, Windows.UI.Color Color);
    static readonly ConcurrentDictionary<string, Task<Entry>> cache = new();
    public static Task<Entry> Load(AppIdentity app) => cache.GetOrAdd(app.ExecutablePath ?? app.Process, _ => Task.Run(() =>
    {
        try
        {
            using var icon = app.Name == "Recall" ? new Icon(Path.Combine(AppContext.BaseDirectory, "Assets", "Recall.ico")) : Icon.ExtractAssociatedIcon(app.ExecutablePath ?? "");
            using var bitmap = icon!.ToBitmap();
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
    }));
    public static FrameworkElement View(AppIdentity app, double size = 28)
    {
        var image = new Microsoft.UI.Xaml.Controls.Image { Width = size, Height = size, Stretch = Stretch.Uniform };
        var host = new Border { Width = size, Height = size, CornerRadius = new(size * .2), Child = image };
        host.Loaded += async (_, _) => { var entry = await Load(app); if (entry.Png.Length == 0) { host.Child = Design.Text(app.Name.Length > 0 ? app.Name[..1] : "·", size * .65, true); return; } using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream(); using (var writer = new Windows.Storage.Streams.DataWriter(stream)) { writer.WriteBytes(entry.Png); await writer.StoreAsync(); writer.DetachStream(); } stream.Seek(0); var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream); image.Source = bitmap; };
        return host;
    }
    public static AppIdentity Identity(MemoryFrame frame) => new(frame.AppName, frame.ProcessName, frame.ExecutablePath);
}
