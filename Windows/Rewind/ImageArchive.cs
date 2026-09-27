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
    static void VerifyManifest(string path, byte[] expected)
    {
        if (new FileInfo(path).Length != expected.Length || !File.ReadAllBytes(path).AsSpan().SequenceEqual(expected))
            throw new InvalidDataException("The screenshot manifest failed verification. Original captures were retained.");
    }
    static void Atomic(string path, byte[] bytes)
    {
        if (File.Exists(path)) { VerifyManifest(path, bytes); return; }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid() + ".tmp";
        try
        {
            using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                file.Write(bytes);
                file.Flush(true);
            }
            try { File.Move(temporary, path, false); }
            catch (IOException) when (File.Exists(path)) { }
            VerifyManifest(path, bytes);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    public static string Pack(string root, Bitmap image)
    {
        lock (gate)
        {
            if ((long)image.Width * image.Height > 40_000_000 || image.Width > 16000 || image.Height > 16000)
                throw new InvalidDataException("The screenshot is too large to archive.");
            using var packs = new TilePackStore(root, writable: true);
            var payloads = new List<TilePayload>();
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
                    if (!encoded.TryGetValue(key, out var relative) || packs.ReadTile(relative) == null)
                    {
                        var png = Encode(tile, ImageFormat.Png);
                        var jpg = Encode(tile, ImageFormat.Jpeg);
                        var opaque = Enumerable.Range(0, width * height).All(i => pixels[i * 4 + 3] == 255);
                        var lossy = opaque && jpg.Length * 1.12 < png.Length;
                        var bytes = lossy ? jpg : png;
                        relative = "frames/tiles/t1-" + Convert.ToHexString(SHA256.HashData(bytes)) + (lossy ? ".jpg" : ".png");
                        payloads.Add(new TilePayload(relative, bytes));
                        encoded[key] = relative;
                        order.Enqueue(key);
                        while (order.Count > 384)
                            encoded.Remove(order.Dequeue());
                    }
                    tiles.Add(new(relative, x, y, width, height));
                }
            packs.Install(payloads);
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
        if (Path.GetExtension(path).Equals(".recallvideo", StringComparison.OrdinalIgnoreCase))
            return VisualVideoReader.Load(root, VisualArchive.Read(path), maxEdge);
        if (Path.GetExtension(path) != ".recallframe")
            return new Bitmap(path);
        var manifest = ScreenManifest.Read(path);
        using var packs = File.Exists(Path.Combine(root, "frames", "packs", "catalog.sqlite")) ? new TilePackStore(root) : null;
        // Assemble at native resolution. Scaling each 384px tile independently
        // makes bicubic interpolation sample its own edge instead of the next
        // tile, which draws a visible grid across otherwise continuous images.
        var result = new Bitmap(manifest.Width, manifest.Height, PixelFormat.Format32bppArgb);
        try
        {
            using (var g = Graphics.FromImage(result))
            {
                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.NearestNeighbor;
                var tilesByPath = manifest.Tiles.GroupBy(t => t.Path).ToDictionary(group => group.Key, group => group.ToArray());
                var payloads = packs != null ? packs.ReadTiles(tilesByPath.Keys) : tilesByPath.Keys.Select(tile => new TilePayload(tile,
                    TilePackStore.ReadTile(root, tile) ?? throw new InvalidDataException("Screenshot block is missing.")));
                foreach (var payload in payloads)
                {
                    using var stream = new MemoryStream(payload.Data, writable: false);
                    using var part = new Bitmap(stream);
                    foreach (var tile in tilesByPath[payload.Path])
                    {
                        if (part.Width != tile.Width || part.Height != tile.Height)
                            throw new InvalidDataException("Screenshot tile dimensions differ.");
                        g.DrawImageUnscaled(part, tile.X, tile.Y);
                    }
                }
            }
            if (maxEdge <= 0 || Math.Max(manifest.Width, manifest.Height) <= maxEdge)
                return result;
            var scale = (double)maxEdge / Math.Max(manifest.Width, manifest.Height);
            var thumbnail = new Bitmap(Math.Max(1, (int)(manifest.Width * scale)), Math.Max(1, (int)(manifest.Height * scale)), PixelFormat.Format32bppArgb);
            try
            {
                using (var resized = Graphics.FromImage(thumbnail))
                {
                    using var attributes = new ImageAttributes();
                    attributes.SetWrapMode(System.Drawing.Drawing2D.WrapMode.TileFlipXY);
                    resized.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    resized.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                    resized.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                    resized.DrawImage(result, new System.Drawing.Rectangle(0, 0, thumbnail.Width, thumbnail.Height), 0, 0, result.Width, result.Height, GraphicsUnit.Pixel, attributes);
                }
            }
            catch { thumbnail.Dispose(); throw; }
            result.Dispose();
            return thumbnail;
        }
        catch { result.Dispose(); throw; }
    }
    public static byte[] Display(string root, string path, int maxEdge)
    {
        using var image = Load(root, path, maxEdge);
        // Imported PNG/JPEG files do not pass through the tile decoder's size
        // limit. Bound their thumbnails too, before WinUI retains the pixels.
        if (maxEdge > 0 && Math.Max(image.Width, image.Height) > maxEdge)
        {
            var scale = (double)maxEdge / Math.Max(image.Width, image.Height);
            using var thumbnail = new Bitmap(Math.Max(1, (int)(image.Width * scale)), Math.Max(1, (int)(image.Height * scale)), PixelFormat.Format32bppArgb);
            using (var graphics = Graphics.FromImage(thumbnail))
            {
                using var attributes = new ImageAttributes();
                attributes.SetWrapMode(System.Drawing.Drawing2D.WrapMode.TileFlipXY);
                graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                graphics.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
                graphics.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                graphics.DrawImage(image, new System.Drawing.Rectangle(0, 0, thumbnail.Width, thumbnail.Height), 0, 0, image.Width, image.Height, GraphicsUnit.Pixel, attributes);
            }
            return Encode(thumbnail, ImageFormat.Png);
        }
        return Encode(image, ImageFormat.Png);
    }
}
