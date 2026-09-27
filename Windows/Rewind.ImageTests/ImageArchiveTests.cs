using System.Drawing;
using System.Drawing.Imaging;

namespace Rewind;

internal static class ImageArchiveTests
{
    static (int Alpha, int Red) FormerTileJoin(string root, string relative)
    {
        var manifest = ScreenManifest.Read(Path.Combine(root, relative));
        var scale = 601d / manifest.Width;
        using var legacy = new Bitmap(601, (int)(manifest.Height * scale), PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(legacy);
        g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
        foreach (var tile in manifest.Tiles)
        {
            using var stream = new MemoryStream(TilePackStore.ReadTile(root, tile.Path)!);
            using var part = new Bitmap(stream);
            var left = (int)(tile.X * scale);
            var top = (int)(tile.Y * scale);
            var right = (int)((tile.X + tile.Width) * scale);
            var bottom = (int)((tile.Y + tile.Height) * scale);
            g.DrawImage(part, new Rectangle(left, top, right - left, bottom - top));
        }
        var pixel = legacy.GetPixel(200, 100);
        return (pixel.A, pixel.R);
    }

    static void Assert(bool ok, string message)
    {
        if (!ok) throw new Exception(message);
    }

    static void Uniform(Bitmap image, Color expected, string caseName)
    {
        var testRows = new[] { 0, 1, 191, 383, 384, 385, image.Height / 2, image.Height - 2, image.Height - 1 };
        var testColumns = new[] { 0, 1, 191, 383, 384, 385, image.Width / 2, image.Width - 2, image.Width - 1 };
        foreach (var y in testRows.Where(y => y < image.Height))
            foreach (var x in testColumns.Where(x => x < image.Width))
            {
                var actual = image.GetPixel(x, y);
                Assert(actual.ToArgb() == expected.ToArgb(), $"{caseName}: pixel {x},{y} became {actual} instead of {expected}.");
            }
    }

    public static int Run(string root)
    {
        var checks = 0;
        using var source = new Bitmap(1152, 768, PixelFormat.Format32bppArgb);
        var field = Color.FromArgb(255, 236, 241, 247);
        using (var g = Graphics.FromImage(source)) g.Clear(field);
        var relative = ImageArchive.Pack(root, source);
        var former = FormerTileJoin(root, relative);
        Console.WriteLine($"Former per-tile interpolation at internal join: alpha {former.Alpha}, red {former.Red}; source alpha 255, red {field.R}.");
        using (var native = ImageArchive.Load(root, relative))
        {
            Assert(native.Size == source.Size, "Native packed screenshot changed dimensions."); checks++;
            Uniform(native, field, "Native tile joins"); checks++;
        }
        using (var thumb = ImageArchive.Load(root, relative, 601))
        {
            Assert(thumb.Width == 601 && thumb.Height == 400, "Packed thumbnail changed dimensions."); checks++;
            Uniform(thumb, field, "Scaled tile joins"); checks++;
        }
        using (var stream = new MemoryStream(ImageArchive.Display(root, relative, 601)))
        using (var displayed = new Bitmap(stream))
        {
            Uniform(displayed, field, "Encoded display thumbnail"); checks++;
        }

        // A continuous cross-tile ramp catches interpolation halos that a
        // solid field could conceal through edge color clamping.
        using var gradient = new Bitmap(1152, 768, PixelFormat.Format32bppArgb);
        for (var y = 0; y < gradient.Height; y++)
            for (var x = 0; x < gradient.Width; x++)
            {
                var value = 70 + x / 12;
                gradient.SetPixel(x, y, Color.FromArgb(255, value, value, value));
            }
        relative = ImageArchive.Pack(root, gradient);
        using (var native = ImageArchive.Load(root, relative))
            foreach (var boundary in new[] { 384, 768 })
            {
                for (var y = 0; y < native.Height; y += 67)
                {
                    var left = native.GetPixel(boundary - 1, y).R;
                    var right = native.GetPixel(boundary, y).R;
                    Assert(Math.Abs(left - right) <= 3, $"Native ramp has a tile edge at {boundary},{y}: {left}/{right}.");
                }
                checks++;
            }
        using (var thumb = ImageArchive.Load(root, relative, 601))
            foreach (var x in new[] { 200, 401 })
            {
                for (var y = 0; y < thumb.Height; y += 47)
                {
                    var left = thumb.GetPixel(x - 1, y).R;
                    var mid = thumb.GetPixel(x, y).R;
                    var right = thumb.GetPixel(x + 1, y).R;
                    Assert(mid >= left - 3 && mid <= right + 3 && right - left <= 5,
                        $"Scaled ramp has a tile edge at {x},{y}: {left}/{mid}/{right}.");
                }
                checks++;
            }
        return checks;
    }
}
