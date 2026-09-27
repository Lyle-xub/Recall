using System.Globalization;
using Rewind;
namespace Rewind;

public static class OcrEngine
{
    public static async Task<(string Text, List<TextRegion> Regions)> Recognize(string image, string language, CancellationToken ct)
    {
        image = Path.GetFullPath(image);
        if (!File.Exists(image)) throw new FileNotFoundException("Image not found.", image);
        if (Path.GetExtension(image).ToLowerInvariant() is ".recallframe" or ".recallvisual") throw new RecallException("unsupported_media", "Use the desktop indexing service for packed media, or export it as PNG first.");
        var engine = Environment.GetEnvironmentVariable("RECALL_TESSERACT") ?? "tesseract";
        var result = await ChildProcess.Run(engine, [image, "stdout", "-l", language, "--psm", "11", "tsv"], null, ct, 60);
        if (result.ExitCode != 0) throw new RecallException("ocr_failed", "Tesseract failed. Check the image and installed language data.");
        var regions = Parse(result.Output);
        return (string.Join("\n", regions.Select(r => r.Text)), regions);
    }
    public static List<TextRegion> Parse(string tsv)
    {
        var lines = new Dictionary<string, (string Text, double X, double Y, double Right, double Bottom)>();
        double width = 0, height = 0;
        foreach (var row in tsv.Split('\n'))
        {
            var cells = row.TrimEnd('\r').Split('\t', 12);
            if (cells.Length != 12 || !double.TryParse(cells[8], NumberStyles.Float, CultureInfo.InvariantCulture, out var w) || !double.TryParse(cells[9], NumberStyles.Float, CultureInfo.InvariantCulture, out var h)) continue;
            if (cells[0] == "1") { width = w; height = h; continue; }
            if (cells[0] != "5" || width <= 0 || height <= 0 || string.IsNullOrWhiteSpace(cells[11])) continue;
            var x = double.Parse(cells[6], CultureInfo.InvariantCulture); var y = double.Parse(cells[7], CultureInfo.InvariantCulture);
            var key = string.Join('/', cells.Skip(1).Take(4));
            if (lines.TryGetValue(key, out var line)) lines[key] = (line.Text + " " + cells[11], Math.Min(line.X, x), Math.Min(line.Y, y), Math.Max(line.Right, x + w), Math.Max(line.Bottom, y + h));
            else lines[key] = (cells[11], x, y, x + w, y + h);
        }
        return lines.Values.Select(line => new TextRegion(line.Text, line.X / width, line.Y / height, (line.Right - line.X) / width, (line.Bottom - line.Y) / height)).ToList();
    }
}
