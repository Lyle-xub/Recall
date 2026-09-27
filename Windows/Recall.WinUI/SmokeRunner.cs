using System.Text.Json;
using System.Drawing;
using System.Drawing.Imaging;
namespace Recall;

internal static class SmokeRunner
{
    public static async Task Run(RecallWindow window, AppRuntime runtime, string output)
    {
        Directory.CreateDirectory(output);
        var results = new List<object>();
        bool success = false;
        try
        {
            void Check(bool condition, string name)
            {
                results.Add(new
                {
                    name,
                    passed = condition
                });
                if (!condition)
                    throw new InvalidOperationException(name);
            }
            var path = Path.Combine(runtime.Store.Root, "smoke-source.png");
            using (var image = new Bitmap(1000, 500))
            {
                using var g = Graphics.FromImage(image);
                g.Clear(System.Drawing.Color.White);
                using var font = new Font("Segoe UI", 34);
                g.DrawString("Recall papers 12345", font, System.Drawing.Brushes.Black, 45, 70);
                g.DrawString("Native Windows capture", font, System.Drawing.Brushes.Black, 45, 160);
                image.Save(path, ImageFormat.Png);
            }
            var frame = await runtime.Capture.Import(path);
            var deadline = DateTime.UtcNow.AddSeconds(70);
            while (DateTime.UtcNow < deadline)
            {
                await Task.Delay(300);
                frame = runtime.Store.Frame(frame.Id)!;
                if (frame.TextState is RecognitionState.Complete or RecognitionState.Empty or RecognitionState.Failed)
                    break;
            }
            Check(frame.Text.Contains("12345") && frame.Text.Contains("papers", StringComparison.OrdinalIgnoreCase), "Original-resolution OCR worker recognizes fixture");
            Check(runtime.Store.Frames("paper").Any(x => x.Id == frame.Id), "Prefix search reaches recognized fixture");
            Check(frame.ImagePath.EndsWith(".recallframe"), "New images use shared tile archives");
            using (var decoded = ImageArchive.Load(runtime.Store.Root, frame.ImagePath))
                Check(decoded.Width == 1000 && decoded.Height == 500, "Archive preserves pixel dimensions");
            window.Show();
            await Task.Delay(700);
            foreach (var page in new[] { "home", "search", "usage", "ask", "settings" })
            {
                window.Navigate(page);
                await Task.Delay(1000);
                var content = (FrameworkElement)window.Content;
                Check(content.ActualWidth > 500 && content.ActualHeight > 300, "Layout opens: " + page);
                var screen = System.Windows.Forms.Screen.FromPoint(System.Windows.Forms.Cursor.Position);
                using var screenshot = new Bitmap(screen.Bounds.Width, screen.Bounds.Height);
                using (var g = Graphics.FromImage(screenshot))
                    g.CopyFromScreen(screen.Bounds.Location, System.Drawing.Point.Empty, screen.Bounds.Size);
                screenshot.Save(Path.Combine(output, page + ".png"), ImageFormat.Png);
            }
            await window.Hide();
            runtime.Recording.Request(true);
            await runtime.Recording.Settled();
            Check(runtime.Recording.State.Active, "Native video capture starts");
            await Task.Delay(3500);
            runtime.Recording.Request(false);
            await runtime.Recording.Settled();
            var session = runtime.Store.Sessions().OrderByDescending(x => x.StartedAt).First();
            Check(session.EndedAt != null && new FileInfo(runtime.Store.SafePath(session.VideoPath)!).Length > 1000, "Native video capture finalizes MP4");
            Check(session.SeparateAudio, "New archive separates audio");
            Check(session.UnifiedVisualArchive && session.VisualArchiveReady, "Native capture commits a unified visual archive");
            Check(session.VideoCodec is "hevc" or "h264", "Native capture reports the codec actually selected");
            Check(session.VideoWidth > 0 && session.VideoHeight > 0 && session.VideoSampleCount > 0, "Native capture records dimensions and sample evidence");
            var archiveDeadline = DateTime.UtcNow.AddSeconds(60);
            MemoryFrame? recorded = null;
            while (DateTime.UtcNow < archiveDeadline)
            {
                recorded = runtime.Store.AllFrames().FirstOrDefault(x => x.SessionId == session.Id && x.ImagePath.EndsWith(".recallvideo", StringComparison.OrdinalIgnoreCase));
                if (recorded != null) break;
                await Task.Delay(250);
            }
            Check(recorded != null, "Real screen capture finishes OCR and promotes an exact video-backed card");
            var reference = VisualArchive.Read(runtime.Store.SafePath(recorded!.ImagePath)!);
            Check(reference.Video == session.VideoPath && reference.Ticks == recorded.VisualTicks,
                "Card points to its submitted recording sample, not a wall-clock estimate");
            using (var decoded = ImageArchive.Load(runtime.Store.Root, recorded.ImagePath))
                Check(decoded.Width == reference.Width && decoded.Height == reference.Height && decoded.Width == session.VideoWidth && decoded.Height == session.VideoHeight,
                    "Native archive card decodes at original capture dimensions");
            Check(!File.Exists(Path.Combine(runtime.Store.Root, "frames", recorded.Id + ".ocr.png")),
                "Validated video replaces the temporary OCR pixels after indexing");
            var export = Path.Combine(output, "archive-export");
            runtime.Store.Export(export, [recorded]);
            using (var decoded = ImageArchive.Load(export, recorded.ImagePath))
                Check(decoded.Width == reference.Width && decoded.Height == reference.Height,
                    "Exported video-backed card decodes independently of the live library");
            await File.WriteAllTextAsync(Path.Combine(output, "unified-archive.json"), JsonSerializer.Serialize(new
            {
                session.Id, session.VideoCodec, session.VideoWidth, session.VideoHeight, session.VideoSampleCount,
                session.VideoDurationTicks, reference.Ticks, reference.Timescale,
                archiveBytes = new FileInfo(runtime.Store.SafePath(session.VideoPath)!).Length,
                exactNativeDecodeVerified = true,
                originalOcrSpoolReleased = true,
                exportDecodeVerified = true
            }, new JsonSerializerOptions { WriteIndented = true }));
            success = true;
        }
        catch (Exception ex) { results.Add(new { error = ex.ToString() }); }
        finally { await File.WriteAllTextAsync(Path.Combine(output, "smoke.json"), JsonSerializer.Serialize(new { passed = success, checks = results }, new JsonSerializerOptions { WriteIndented = true })); window.FinishSmoke(); await runtime.Shutdown(); Environment.ExitCode = success ? 0 : 1; Application.Current.Exit(); }
    }
}
