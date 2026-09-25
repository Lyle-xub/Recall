using System.Drawing;
using System.Drawing.Imaging;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text.Json;
namespace Rewind;

public static class ImageArchive
{
    static readonly object gate = new(); static readonly Dictionary<string, string> encoded = []; static readonly Queue<string> order = [];
    static byte[] Encode(Bitmap image, ImageFormat format)
    {
        using var stream = new MemoryStream();
        if (format.Guid == ImageFormat.Jpeg.Guid)
        {
            using var options = new EncoderParameters(1);
            options.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 50L);
            image.Save(stream, ImageCodecInfo.GetImageEncoders().First(x => x.FormatID == format.Guid), options);
        }
        else
            image.Save(stream, format);
        return stream.ToArray();
    }
    static void Atomic(string path, byte[] bytes)
    {
        if (File.Exists(path))
            return;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid() + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        try
        {
            File.Move(temporary, path, false);
        }
        catch (IOException) when (File.Exists(path)) { }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static string Pack(string root, Bitmap image)
    {
        lock (gate)
        {
            if ((long)image.Width * image.Height > 40_000_000 || image.Width > 16000 || image.Height > 16000)
                throw new InvalidDataException("The screenshot is too large to archive.");
            var tiles = new List<ScreenTile>();
            for (var y = 0; y < image.Height; y += 384)
                for (var x = 0; x < image.Width; x += 384)
                {
                    int width = Math.Min(384, image.Width - x), height = Math.Min(384, image.Height - y);
                    using var tile = image.Clone(new System.Drawing.Rectangle(x, y, width, height), PixelFormat.Format32bppArgb);
                    var data = tile.LockBits(new System.Drawing.Rectangle(0, 0, width, height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                    var pixels = new byte[Math.Abs(data.Stride) * height];
                    try
                    {
                        Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
                    }
                    finally { tile.UnlockBits(data); }
                    var key = $"{root}/{width}x{height}/" + Convert.ToHexString(SHA256.HashData(pixels));
                    if (!encoded.TryGetValue(key, out var relative) || !File.Exists(Path.Combine(root, relative)))
                    {
                        var png = Encode(tile, ImageFormat.Png);
                        var jpg = Encode(tile, ImageFormat.Jpeg);
                        var opaque = Enumerable.Range(0, width * height).All(i => pixels[i * 4 + 3] == 255);
                        var lossy = opaque && jpg.Length * 1.12 < png.Length;
                        var bytes = lossy ? jpg : png;
                        relative = "frames/tiles/t1-" + Convert.ToHexString(SHA256.HashData(bytes)) + (lossy ? ".jpg" : ".png");
                        Atomic(Path.Combine(root, relative), bytes);
                        encoded[key] = relative;
                        order.Enqueue(key);
                        while (order.Count > 384)
                            encoded.Remove(order.Dequeue());
                    }
                    tiles.Add(new(relative, x, y, width, height));
                }
            var manifest = JsonSerializer.SerializeToUtf8Bytes(new ScreenManifest(1, image.Width, image.Height, tiles));
            var path = "frames/pack1-" + Convert.ToHexString(SHA256.HashData(manifest)) + ".recallframe";
            Atomic(Path.Combine(root, path), manifest);
            return path;
        }
    }
    public static Bitmap Load(string root, string relative, int maxEdge = 0)
    {
        var path = Path.GetFullPath(Path.Combine(root, relative));
        if (!path.StartsWith(Path.GetFullPath(root) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Invalid image path.");
        if (Path.GetExtension(path) != ".recallframe")
            return new Bitmap(path);
        var manifest = ScreenManifest.Read(path);
        double scale = maxEdge > 0 ? Math.Min(1, (double)maxEdge / Math.Max(manifest.Width, manifest.Height)) : 1;
        var result = new Bitmap(Math.Max(1, (int)(manifest.Width * scale)), Math.Max(1, (int)(manifest.Height * scale)), PixelFormat.Format32bppArgb);
        try
        {
            using var g = Graphics.FromImage(result);
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            foreach (var tile in manifest.Tiles)
            {
                using var part = new Bitmap(Path.Combine(root, tile.Path));
                if (part.Width != tile.Width || part.Height != tile.Height)
                    throw new InvalidDataException("Screenshot tile dimensions differ.");
                var left = (int)(tile.X * scale);
                var top = (int)(tile.Y * scale);
                var right = (int)((tile.X + tile.Width) * scale);
                var bottom = (int)((tile.Y + tile.Height) * scale);
                g.DrawImage(part, new System.Drawing.Rectangle(left, top, right - left, bottom - top));
            }
            return result;
        }
        catch { result.Dispose(); throw; }
    }
    public static byte[] Display(string root, string path, int maxEdge)
    {
        using var image = Load(root, path, maxEdge);
        return Encode(image, ImageFormat.Png);
    }
}
