using System.Drawing;
using System.Drawing.Imaging;
using System.Text.Json;

namespace Rewind;

internal static class VisualVideoArchiveTests
{
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static void ColorNear(Color actual, Color expected, string message)
    {
        Check(Math.Abs(actual.R - expected.R) < 35 && Math.Abs(actual.G - expected.G) < 35 && Math.Abs(actual.B - expected.B) < 35,
            $"{message}: expected {expected}, received {actual}.");
    }
    static Bitmap Pattern(int width, int height, Color top, Color bottom)
    {
        var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb);
        using var graphics = Graphics.FromImage(bitmap);
        using var first = new SolidBrush(top);
        using var second = new SolidBrush(bottom);
        graphics.FillRectangle(first, 0, 0, width, height / 2);
        graphics.FillRectangle(second, 0, height / 2, width, height - height / 2);
        return bitmap;
    }
    public static int Run(string parent)
    {
        var root = Path.Combine(parent, "native-video");
        using var store = new MemoryStore(root);
        const int width = 641, height = 359; // exercise explicit even codec padding
        var relative = "recordings/synthetic.mp4";
        var path = Path.Combine(root, relative);
        long redTime, blueTime, greenTime, duration, count;
        using var red = Pattern(width, height, Color.Red, Color.Lime);
        using var blue = Pattern(width, height, Color.Blue, Color.Yellow);
        using var green = Pattern(width, height, Color.Lime, Color.Red);
        // Actual Windows MF encoder/decoder; deterministic unavailable-HEVC
        // injection verifies fallback without depending on runner GPU hardware.
        using (var writer = new VisualVideoWriter(path, width, height, true, () => false))
        {
            Check(writer.Codec == "h264" && writer.Diagnostic?.Contains("H.264") == true, "HEVC fallback must report the actual compatible codec.");
            redTime = writer.Append(red, 0);
            blueTime = writer.Append(blue, 13_750_000);
            greenTime = writer.Append(green, 26_250_000);
            writer.Finish(32_000_000);
            duration = writer.DurationTicks; count = writer.SampleCount;
            Check(redTime == 0 && blueTime == 13_750_000 && greenTime == 26_250_000 && count == 3, "The submitted sample PTS must be retained exactly.");
        }
        var reference = new VisualArchive(1, relative, blueTime, width, height);
        using (var decoded = VisualVideoReader.Load(root, reference))
        {
            Check(decoded.Width == width && decoded.Height == height, "Native decoding must remove only codec padding.");
            ColorNear(decoded.GetPixel(50, 50), Color.Blue, "Exact blue sample/top orientation");
            ColorNear(decoded.GetPixel(50, height - 50), Color.Yellow, "Exact blue sample/bottom orientation");
        }
        using (var decoded = VisualVideoReader.Load(root, reference with { Ticks = redTime }))
            ColorNear(decoded.GetPixel(50, 50), Color.Red, "First exact sample");
        using (var decoded = VisualVideoReader.Load(root, reference with { Ticks = greenTime }))
            ColorNear(decoded.GetPixel(50, 50), Color.Lime, "Final exact sample");
        Check(!VisualVideoReader.Verify(root, reference with { Ticks = blueTime - 100_000 }), "A nearby frame must not validate an absent PTS.");
        Check(!VisualVideoReader.Verify(root, reference with { Width = width - 8 }), "A mismatched reference must not resize the decoded sample.");
        Check(!VisualVideoReader.Verify(root, reference with { Video = "recordings/missing.mp4" }), "A missing recording must fail verification.");
        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel();
            try { using var unexpected = VisualVideoReader.Load(root, reference, cancellation: cancelled.Token); throw new Exception("Decode ignored cancellation."); }
            catch (OperationCanceledException) { }
        }
        // Exercise the common entry point used by thumbnails/OCR/Ask/export.
        var manifestPath = "frames/synthetic.recallvideo";
        File.WriteAllText(Path.Combine(root, manifestPath), JsonSerializer.Serialize(reference));
        using (var thumbnail = ImageArchive.Load(root, manifestPath, 120))
        {
            Check(thumbnail.Width == 120 && thumbnail.Height == 67, "Video thumbnail dimensions must remain proportional to the original.");
            ColorNear(thumbnail.GetPixel(15, 15), Color.Blue, "Video thumbnail source");
        }
        using (var stream = new MemoryStream(ImageArchive.Display(root, manifestPath, 120)))
        using (var display = new Bitmap(stream)) Check(display.Width == 120, "Display must materialize a normal PNG.");
        Task.WaitAll(Enumerable.Range(0, 6).Select(_ => Task.Run(() =>
        {
            using var thumbnail = ImageArchive.Load(root, manifestPath, 120);
            ColorNear(thumbnail.GetPixel(15, 15), Color.Blue, "Concurrent bounded decoder");
        })).ToArray());

        var now = DateTimeOffset.UtcNow;
        var session = new RecordingSession("native", now, now.AddSeconds(3.2), relative, false,
            UnifiedVisualArchive: true, VisualArchiveReady: false, VideoCodec: "h264", VideoWidth: width, VideoHeight: height,
            VideoDurationTicks: duration, VideoSampleCount: count);
        store.SaveSession(session);
        var spool = "frames/promotion.ocr.png";
        blue.Save(Path.Combine(root, spool), ImageFormat.Png);
        var card = new MemoryFrame { Id = "promotion", Timestamp = now, ImagePath = spool, SessionId = session.Id, TextState = RecognitionState.Pending,
            VisualTicks = blueTime, VisualWidth = width, VisualHeight = height, VisualSampleVerified = true };
        store.Save(card);
        Check(store.FinalizeVisualSession(session.Id, r => VisualVideoReader.Verify(root, r)).Count == 0 && File.Exists(Path.Combine(root, spool)), "Unfinalized video must keep OCR originals.");
        store.SaveSession(session with { VisualArchiveReady = true });
        Check(store.FinalizeVisualSession(session.Id, r => VisualVideoReader.Verify(root, r)).Count == 0, "Pending OCR must keep its original.");
        store.Recognized(card.Id, "Synthetic readable card", []);
        Check(store.FinalizeVisualSession(session.Id, _ => false).Count == 0 && File.Exists(Path.Combine(root, spool)), "Decoder failure must keep its original.");
        var promoted = store.FinalizeVisualSession(session.Id, r => VisualVideoReader.Verify(root, r));
        Check(promoted.Count == 1 && promoted[0].ImagePath.EndsWith(".recallvideo") && !File.Exists(Path.Combine(root, spool)), "Only durable video + OCR + exact decode may promote and delete the spool.");
        using (var materialized = ImageArchive.Load(root, promoted[0].ImagePath)) ColorNear(materialized.GetPixel(50, 50), Color.Blue, "Promoted card pixels");
        Check(store.FinalizeVisualSession(session.Id, r => VisualVideoReader.Verify(root, r)).Count == 0, "Promotion retry must be idempotent.");

        // Abandoning a writer leaves a spool, never an archive-ready session.
        var failedPath = Path.Combine(root, "recordings/abandoned.mp4");
        using (var abandoned = new VisualVideoWriter(failedPath, width, height, false)) abandoned.Append(red, 0);
        var abandonedSpool = "frames/abandoned.ocr.png";
        red.Save(Path.Combine(root, abandonedSpool), ImageFormat.Png);
        store.SaveSession(session with { Id = "abandoned", VideoPath = "recordings/abandoned.mp4", EndedAt = null, VisualArchiveReady = false });
        store.Save(card with { Id = "abandoned", ImagePath = abandonedSpool, SessionId = "abandoned", TextState = RecognitionState.Complete });
        store.RecoverInterruptedVisualSessions();
        Check(File.Exists(Path.Combine(root, abandonedSpool)) && store.Frame("abandoned")!.VisualSampleVerified == false && store.Session("abandoned")!.EndedAt != null,
            "Interrupted encoder recovery must retain the only source and clear unproven sample metadata.");
        return 20;
    }
}
