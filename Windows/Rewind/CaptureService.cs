using System.Diagnostics;
using System.Security.Cryptography;
using System.Threading.Channels;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using Tesseract;
using NAudio.Wave;
using NAudio.CoreAudioApi;
using Screen = System.Windows.Forms.Screen;
using ImageFormat = System.Drawing.Imaging.ImageFormat;
namespace Rewind;

public sealed class CaptureService : IDisposable
{
    private readonly MemoryStore store;
    private VisualVideoWriter? recorder;
    private Stopwatch? segmentClock;
    private AudioTrackCapture? systemTrack, microphoneTrack;
    private TesseractEngine? ocr;
    private readonly NeuralOcrClient neural = new();
    private CancellationTokenSource? cts;
    private Task? loop;
    private RecordingSession? session;
    private volatile bool privacyPaused;
    private MemoryFrame? previous;
    private readonly Channel<string> indexing = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });
    private readonly HashSet<string> queuedIndex = [];
    private readonly SemaphoreSlim indexGate = new(1,1);
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task indexingWorker;
    private readonly VisualPromotionWorker visualPromotion;
    private RecordingSession? stoppedSession;
    private readonly SemaphoreSlim ocrGate = new(1);
    public event Action<MemoryFrame>? FrameAdded;
    public event Action<string>? Error;
    public event Action<string>? Interrupted;
    public event Action<RecordingSession>? SegmentFinished;
    public bool IsRecording => cts is { IsCancellationRequested: false };
    public bool IsPrivacyPaused => privacyPaused;
    public CaptureService(MemoryStore store)
    {
        this.store = store;
        visualPromotion = new VisualPromotionWorker((sessionId, token) =>
        {
            token.ThrowIfCancellationRequested();
            foreach (var frame in store.FinalizeVisualSession(sessionId, reference =>
            {
                token.ThrowIfCancellationRequested();
                return VisualVideoReader.Verify(store.Root, reference, token);
            })) FrameAdded?.Invoke(frame);
            return Task.CompletedTask;
        }, error => Error?.Invoke("Visual archive verification retained original captures. " + error.Message), lifetime.Token);
        // Discovery scans historical metadata only once at startup. Steady-state
        // OCR and segment completion signal their specific ready session IDs.
        foreach (var sessionId in store.UnfinishedVisualSessions()) visualPromotion.Request(sessionId);
        indexingWorker = Task.Run(IndexLoop);
        foreach (var frame in store.PendingFrames())
            QueueIndex(frame.Id);
    }
    private void QueueVisualPromotion(string sessionId)
    {
        if (store.Session(sessionId) is { UnifiedVisualArchive: true, VisualArchiveReady: true, EndedAt: not null })
            visualPromotion.Request(sessionId);
    }
    private void QueueIndex(string id)
    {
        lock (queuedIndex) { if (queuedIndex.Add(id) && !indexing.Writer.TryWrite(id)) queuedIndex.Remove(id); }
    }
    private async Task IndexLoop()
    {
        await foreach (var id in indexing.Reader.ReadAllAsync())
        {
            if (lifetime.IsCancellationRequested)
                break;
            try { await indexGate.WaitAsync(lifetime.Token); }
            catch (OperationCanceledException) { break; }
            try
            {
            var frame = store.Frame(id);
            if (frame == null || frame.TextState is RecognitionState.Complete or RecognitionState.Empty) { lock (queuedIndex) queuedIndex.Remove(id); continue; }
            var original = Path.Combine(store.Root, "frames", id + ".ocr.png");
            try
            {
                store.Recognition(id, RecognitionState.Working);
                FrameAdded?.Invoke(store.Frame(id)!);
                var recognitionFile = File.Exists(original) ? original : store.SafePath(frame.ImagePath)!;
                if (recognitionFile.EndsWith(".recallframe", StringComparison.OrdinalIgnoreCase) || recognitionFile.EndsWith(".recallvideo", StringComparison.OrdinalIgnoreCase))
                {
                    using var source = ImageArchive.Load(store.Root, frame.ImagePath);
                    source.Save(original, ImageFormat.Png);
                    recognitionFile = original;
                }
                var recognized = await Recognize(recognitionFile, lifetime.Token);
                var meetingOriginal = Path.Combine(store.Root, "frames", id + "-meeting.ocr.png");
                (string Text, List<TextRegion> Regions)? meeting = null;
                if (File.Exists(meetingOriginal))
                    meeting = await Recognize(meetingOriginal, lifetime.Token);
                store.WithMediaLock(() =>
                {
                    if (store.Frame(id) == null)
                        return;
                    var archived = frame.ImagePath;
                    if (File.Exists(original) && !(frame.SessionId is { } archiveSession && store.Session(archiveSession)?.UnifiedVisualArchive == true))
                    {
                        using var bitmap = new Bitmap(original);
                        archived = ImageArchive.Pack(store.Root, bitmap);
                    }
                    var meetingArchive = frame.MeetingImagePath;
                    if (meeting != null)
                    {
                        using var bitmap = new Bitmap(meetingOriginal);
                        meetingArchive = ImageArchive.Pack(store.Root, bitmap);
                    }
                    store.Recognized(id, recognized.Text + (meeting != null ? "\n" + meeting.Value.Text : ""), recognized.Regions, meeting?.Regions, imagePath: archived, meetingPath: meetingArchive);
                    if (meetingArchive != frame.MeetingImagePath && frame.MeetingImagePath != null && !store.ReferencesImage(frame.MeetingImagePath))
                    {
                        try
                        {
                            File.Delete(store.SafePath(frame.MeetingImagePath)!);
                        }
                        catch (IOException) { }
                    }
                    if (archived != frame.ImagePath && !store.ReferencesImage(frame.ImagePath))
                    {
                        try
                        {
                            File.Delete(store.SafePath(frame.ImagePath)!);
                        }
                        catch (IOException) { }
                    }
                });
                if (frame.SessionId is { } visualSession && store.Session(visualSession)?.UnifiedVisualArchive == true)
                {
                    QueueVisualPromotion(visualSession);
                    if (frame.ImagePath.EndsWith(".recallvideo", StringComparison.OrdinalIgnoreCase) && File.Exists(original)) File.Delete(original);
                }
                else if (File.Exists(original))
                    File.Delete(original);
                if (File.Exists(meetingOriginal))
                    File.Delete(meetingOriginal);
            }
            catch (OperationCanceledException) { store.Recognition(id, RecognitionState.Pending); break; }
            catch (Exception ex) { store.Recognition(id, RecognitionState.Failed, ex.Message); }
            lock (queuedIndex) queuedIndex.Remove(id);
            if (store.Frame(id) is { } updated)
                FrameAdded?.Invoke(updated);
            }
            finally { indexGate.Release(); }
        }
    }
    public async Task<object> IndexOne(string id,string language,CancellationToken ct)
    {
        await indexGate.WaitAsync(ct);
        var temporary=Path.Combine(Path.GetTempPath(),Guid.NewGuid()+".png");
        try
        {
            string? sessionId = null;
            store.WithMediaLock(() =>
            {
                var frame = store.Frame(id) ?? throw new RecallException("not_found", "Memory not found.");
                using var image = ImageArchive.Load(store.Root, frame.ImagePath);
                image.Save(temporary, ImageFormat.Png);
                sessionId = frame.SessionId;
            });
            var result=await OcrEngine.Recognize(temporary,language,ct);
            store.Recognized(id,result.Text,result.Regions);
            if (sessionId != null) QueueVisualPromotion(sessionId);
            FrameAdded?.Invoke(store.Frame(id)!);
            return new {completed=1,id};
        }
        finally {if(File.Exists(temporary))File.Delete(temporary);indexGate.Release();}
    }
    public async Task<MemoryFrame> Import(string file)
    {
        return await Task.Run(() =>
        {
            using var bitmap = new Bitmap(file);
            var id = Guid.NewGuid().ToString();
            var relative = $"frames/{id}.jpg";
            bitmap.Save(Path.Combine(store.Root, "frames", id + ".ocr.png"), ImageFormat.Png);
            SaveJpeg(bitmap, Path.Combine(store.Root, relative), .5);
            var frame = new MemoryFrame { Id = id, AppName = "Imported", Title = Path.GetFileNameWithoutExtension(file), ImagePath = relative, ImageQuality = .5, TextState = RecognitionState.Pending };
            store.Save(frame);
            QueueIndex(id);
            FrameAdded?.Invoke(frame);
            return frame;
        });
    }
    public void Retry(MemoryFrame frame)
    {
        lock (queuedIndex)
        {
            if (queuedIndex.Contains(frame.Id)) return;
            store.Recognition(frame.Id, RecognitionState.Pending);
            QueueIndex(frame.Id);
        }
    }
    public async Task Start(AppSettings settings)
    {
        if (IsRecording)
            return;
        if (loop != null)
            await loop;
        cts?.Dispose();
        loop = null;
        cts = new();
        stoppedSession = null;
        previous = null;
        try
        {
            privacyPaused = VisibleExcluded(settings.ExcludedApps);
            if (!privacyPaused)
                StartSegment(settings);
        }
        catch { cts.Dispose(); cts = null; recorder?.Dispose(); recorder = null; session = null; throw; }
        var workerSource = cts!;
        loop = Task.Run(async () =>
        {
            var last = DateTimeOffset.MinValue;
            var lastWindow = IntPtr.Zero;
            var lastVideo = DateTimeOffset.MinValue;
            Task? snapshot = null;
            CancellationTokenSource? snapshotCancellation = null;
            try
            {
                while (!workerSource.IsCancellationRequested)
                {
                    var excluded = VisibleExcluded(settings.ExcludedApps);
                    if (excluded && !privacyPaused)
                    {
                        snapshotCancellation?.Cancel();
                        var done = await StopSegment();
                        if (done != null)
                            SegmentFinished?.Invoke(done);
                        if (snapshot != null)
                        {
                            try
                            {
                                await snapshot;
                            }
                            catch (OperationCanceledException) { }
                        }
                        privacyPaused = true;
                    }
                    else if (!excluded && privacyPaused)
                    {
                        StartSegment(settings);
                        privacyPaused = false;
                    }
                    if (snapshot is { IsFaulted: true })
                    {
                        await snapshot;
                    }
                    var cardDue = DateTimeOffset.Now - last >= TimeSpan.FromSeconds(settings.CaptureInterval) || NativeWindows.GetForegroundWindow() != lastWindow;
                    if (!excluded && (snapshot == null || snapshot.IsCompleted) && (cardDue || DateTimeOffset.Now - lastVideo >= TimeSpan.FromSeconds(1)))
                    {
                        snapshotCancellation?.Dispose();
                        snapshotCancellation = CancellationTokenSource.CreateLinkedTokenSource(workerSource.Token);
                        lastVideo = DateTimeOffset.Now;
                        if (cardDue) { last = lastVideo; lastWindow = NativeWindows.GetForegroundWindow(); }
                        snapshot = Snapshot(settings, snapshotCancellation.Token, cardDue);
                    }
                    if (session != null && DateTimeOffset.Now - session.StartedAt > TimeSpan.FromMinutes(5))
                    {
                        if (snapshot != null)
                        {
                            try
                            {
                                await snapshot;
                            }
                            catch (OperationCanceledException) { }
                        }
                        var done = await StopSegment();
                        if (done != null)
                            SegmentFinished?.Invoke(done);
                        StartSegment(settings);
                    }
                    await Task.Delay(150, workerSource.Token);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                var expectedStop = workerSource.IsCancellationRequested;
                if (!expectedStop) workerSource.Cancel();
                Error?.Invoke(ex.Message);
                if (!expectedStop) Interrupted?.Invoke(ex.Message);
            }
            finally
            {
                snapshotCancellation?.Cancel();
                if (snapshot != null)
                {
                    try
                    {
                        await snapshot;
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception ex) { Error?.Invoke(ex.Message); }
                }
                snapshotCancellation?.Dispose();
                try
                {
                    stoppedSession = await StopSegment();
                }
                catch (Exception ex) { Error?.Invoke(ex.Message); }
            }
        });
    }
    private void StartSegment(AppSettings settings)
    {
        var screen = Screen.AllScreens.FirstOrDefault(x => x.DeviceName == settings.DisplayName) ?? Screen.PrimaryScreen!;
        var s = new RecordingSession(Guid.NewGuid().ToString(), DateTimeOffset.Now, null, $"recordings/{Guid.NewGuid()}.mp4", settings.SystemAudio || settings.Microphone,
            SpeechState: settings.TranscriptionEnabled ? RecognitionState.Pending : RecognitionState.Disabled, SeparateAudio: true,
            UnifiedVisualArchive: true, VideoWidth: screen.Bounds.Width, VideoHeight: screen.Bounds.Height);
        var writer = new VisualVideoWriter(Path.Combine(store.Root, s.VideoPath), screen.Bounds.Width, screen.Bounds.Height);
        recorder = writer;
        segmentClock = Stopwatch.StartNew();
        s = s with { VideoCodec = writer.Codec, VideoDiagnostic = writer.Diagnostic };
        session = s;
        privacyPaused = false;
        store.SaveSession(s);
        try
        {
            if (settings.SystemAudio)
                systemTrack = new(store.Root, $"recordings/{s.Id}-system.m4a", s.StartedAt, false);
            if (settings.Microphone)
                microphoneTrack = new(store.Root, $"recordings/{s.Id}-microphone.m4a", s.StartedAt, true);
        }
        catch
        {
            if (systemTrack != null) _ = systemTrack.Stop();
            if (microphoneTrack != null) _ = microphoneTrack.Stop();
            systemTrack = microphoneTrack = null;
            writer.Dispose(); recorder = null; session = null; segmentClock = null;
            store.SaveSession(s with { EndedAt = DateTimeOffset.Now, SpeechState = RecognitionState.Failed, SpeechError = "Capture could not start." });
            throw;
        }
    }
    private async Task<RecordingSession?> StopSegment()
    {
        if (recorder == null || session == null) return null;
        var writer = recorder;
        var s = session;
        recorder = null; session = null;
        var endTicks = segmentClock?.Elapsed.Ticks ?? 0;
        segmentClock = null;
        if (previous != null) { store.Extend(previous.Id, DateTimeOffset.Now); previous = null; }
        var system = systemTrack; var microphone = microphoneTrack;
        systemTrack = microphoneTrack = null;
        // Stop both live audio sources immediately, before video finalization
        // can wait on a driver or decoder. Each task retains its own resources.
        var systemStop = system?.Stop(); var microphoneStop = microphone?.Stop();
        // Each track owns its finalization. Failure or timeout in video cannot
        // abandon audio, release a writer still in use, or affect a new segment.
        var finalization = Task.Run(() => { try { writer.Finish(endTicks); } finally { writer.Dispose(); } });
        try
        {
            await finalization.WaitAsync(TimeSpan.FromSeconds(20));
            // Check an exact decoded native sample before marking the container
            // ready; individual card samples are checked again at promotion.
            using (var decoded = VisualVideoReader.Load(store.Root, new VisualArchive(1, s.VideoPath, 0, writer.Width, writer.Height))) { }
            s = s with { VisualArchiveReady = true, VideoCodec = writer.Codec, VideoDiagnostic = writer.Diagnostic,
                VideoDurationTicks = writer.DurationTicks, VideoSampleCount = writer.SampleCount };
        }
        catch (Exception ex)
        {
            if (writer.Codec == "hevc") VisualVideoWriter.DisableHevc("HEVC failed video verification in this process.");
            s = s with { VideoCodec = writer.Codec, VideoDiagnostic = "Video finalization or decoding failed; original captures were retained. " + ex.Message };
            Error?.Invoke(s.VideoDiagnostic);
            _ = finalization.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
        }
        try
        {
            if (systemStop != null && await systemStop)
                s = s with { SystemAudioPath = system!.RelativePath, SystemAudioOffset = system.Offset };
        }
        catch (Exception ex) { Error?.Invoke("System audio track: " + ex.Message); }
        try
        {
            if (microphoneStop != null && await microphoneStop)
                s = s with { MicrophoneAudioPath = microphone!.RelativePath, MicrophoneAudioOffset = microphone.Offset };
        }
        catch (Exception ex) { Error?.Invoke("Microphone track: " + ex.Message); }
        s = s with { EndedAt = DateTimeOffset.Now };
        store.SaveSession(s);
        if (s.VisualArchiveReady) visualPromotion.Request(s.Id);
        return s;
    }
    public async Task<RecordingSession?> Stop()
    {
        cts?.Cancel();
        if (loop != null)
            await loop;
        loop = null;
        cts?.Dispose();
        cts = null;
        return stoppedSession;
    }
    private async Task EnsureOCR()
    {
        await ocrGate.WaitAsync();
        try
        {
            if (ocr != null)
                return;
            var path = Path.Combine(AppContext.BaseDirectory, "tessdata");
            if (!File.Exists(Path.Combine(path, "eng.traineddata")))
                throw new InvalidOperationException("OCR models are missing. Run scripts/prepare-windows.ps1 before building.");
            ocr = await Task.Run(() => new TesseractEngine(path, "eng+chi_sim", EngineMode.LstmOnly));
        }
        finally { ocrGate.Release(); }
    }
    public async Task<(string Text, List<TextRegion> Regions)> Recognize(string file, CancellationToken token = default)
    {
        if (NeuralOcrClient.Available)
            return await neural.Recognize(file, token);
        await EnsureOCR();
        await ocrGate.WaitAsync(token);
        try
        {
            return await Task.Run(() =>
            {
                using var pix = Pix.LoadFromFile(file);
                using var page = ocr!.Process(pix, PageSegMode.Auto);
                var regions = new List<TextRegion>();
                using var iterator = page.GetIterator();
                iterator.Begin();
                do
                {
                    var text = iterator.GetText(PageIteratorLevel.TextLine);
                    if (!string.IsNullOrWhiteSpace(text) && iterator.TryGetBoundingBox(PageIteratorLevel.TextLine, out var box))
                        regions.Add(new(text.Trim(), (double)box.X1 / pix.Width, (double)box.Y1 / pix.Height, (double)box.Width / pix.Width, (double)box.Height / pix.Height));
                } while (iterator.Next(PageIteratorLevel.TextLine));
                return (page.GetText(), regions);
            }, token);
        }
        finally { ocrGate.Release(); }
    }
    private Task Snapshot(AppSettings settings, CancellationToken token, bool makeCard = true)
    {
        var foregroundHandle = NativeWindows.GetForegroundWindow();
        var foreground = NativeWindows.Info(foregroundHandle);
        if (VisibleExcluded(settings.ExcludedApps))
            return Task.CompletedTask;
        var screen = Screen.AllScreens.FirstOrDefault(s => s.DeviceName == settings.DisplayName) ?? Screen.PrimaryScreen ?? Screen.AllScreens[0];
        var now = DateTimeOffset.Now;
        using var bitmap = new Bitmap(screen.Bounds.Width, screen.Bounds.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
            graphics.CopyFromScreen(screen.Bounds.Location, System.Drawing.Point.Empty, screen.Bounds.Size);
        token.ThrowIfCancellationRequested();
        // Reject a capture spanning a focus/privacy transition: its window
        // attribution and sample must describe the same observed desktop.
        if (foregroundHandle != NativeWindows.GetForegroundWindow() || VisibleExcluded(settings.ExcludedApps)) return Task.CompletedTask;
        var visualTicks = recorder?.Append(bitmap, segmentClock?.Elapsed.Ticks ?? 0);
        if (session != null && recorder != null && session.VideoCodec != recorder.Codec)
        {
            session = session with { VideoCodec = recorder.Codec, VideoDiagnostic = recorder.Diagnostic };
            store.SaveSession(session);
        }
        if (!makeCard || foreground.Pid == Environment.ProcessId) return Task.CompletedTask;
        var data = bitmap.LockBits(new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        string hash;
        try
        {
            var pixels = new byte[Math.Abs(data.Stride) * data.Height];
            Marshal.Copy(data.Scan0, pixels, 0, pixels.Length);
            for (var i = 3; i < pixels.Length; i += 4)
                pixels[i] = 255;
            Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
            hash = $"{bitmap.Width}x{bitmap.Height}:" + Convert.ToHexString(SHA256.HashData(pixels));
        }
        finally { bitmap.UnlockBits(data); }
        if (previous is { } p && p.SessionId == session?.Id && p.PixelHash == hash && p.ProcessName == foreground.Process && p.Title == foreground.Title)
        {
            store.Extend(p.Id, now);
            return Task.CompletedTask;
        }
        if (previous != null)
            store.Extend(previous.Id, now);
        var id = Guid.NewGuid().ToString();
        var relative = $"frames/{id}.ocr.png";
        var original = Path.Combine(store.Root, relative);
        // Every unified card retains its own lossless full-size source until
        // its exact video sample AND OCR are durable. Reuse only recognition.
        bitmap.Save(original, ImageFormat.Png);
        var shared = store.ExactImage(hash);
        var meetingPath = CaptureMeetingCrop(bitmap, screen.Bounds, id);
        var frame = new MemoryFrame { Id = id, Timestamp = now, MeetingImagePath = meetingPath, EndTimestamp = now,
            AppName = foreground.App, ProcessName = foreground.Process, ExecutablePath = NativeWindows.Executable(foreground.Pid), Title = foreground.Title,
            ImagePath = relative, SessionId = session?.Id, PixelHash = hash, ImageQuality = 1,
            Text = shared?.Text ?? "", Regions = shared?.Regions ?? [], TextState = meetingPath == null && shared?.MeetingImagePath == null &&
                shared?.TextState is RecognitionState.Complete or RecognitionState.Empty ? shared.TextState : RecognitionState.Pending,
            VisualTicks = visualTicks, VisualWidth = bitmap.Width, VisualHeight = bitmap.Height, VisualSampleVerified = visualTicks != null };
        store.Save(frame);
        previous = frame;
        FrameAdded?.Invoke(frame);
        if (frame.TextState is not (RecognitionState.Complete or RecognitionState.Empty)) QueueIndex(frame.Id);
        return Task.CompletedTask;
    }
    private string? CaptureMeetingCrop(Bitmap screen, System.Drawing.Rectangle bounds, string id)
    {
        var meeting = NativeWindows.Visible().FirstOrDefault(w => new[] { "Zoom", "ms-teams", "Teams", "CiscoCollabHost" }.Contains(w.Process, StringComparer.OrdinalIgnoreCase));
        if (meeting.Handle == IntPtr.Zero || !NativeWindows.GetWindowRect(meeting.Handle, out var rect))
            return null;
        var clipped = System.Drawing.Rectangle.Intersect(bounds, new System.Drawing.Rectangle(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top));
        if (clipped.Width < 200 || clipped.Height < 150)
            return null;
        using var crop = screen.Clone(new System.Drawing.Rectangle(clipped.X - bounds.X, clipped.Y - bounds.Y, clipped.Width, clipped.Height), PixelFormat.Format32bppArgb);
        var relative = $"frames/{id}-meeting.jpg";
        crop.Save(Path.Combine(store.Root, "frames", id + "-meeting.ocr.png"), ImageFormat.Png);
        SaveJpeg(crop, Path.Combine(store.Root, relative), .5);
        return relative;
    }
    public static void SaveJpeg(Bitmap bitmap, string path, double quality)
    {
        var encoder = ImageCodecInfo.GetImageEncoders().First(x => x.FormatID == ImageFormat.Jpeg.Guid);
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)(Math.Clamp(quality, .1, 1) * 100));
        bitmap.Save(path, encoder, parameters);
    }
    private static bool VisibleExcluded(string[] excluded) => NativeWindows.Visible().Any(w => excluded.Contains(w.Process, StringComparer.OrdinalIgnoreCase));
    public static string ExtractAudio(RecordingSession session, string root) => ConvertAudio(Path.Combine(root, session.VideoPath), Path.Combine(root, "recordings", session.Id + ".wav"));
    public static string ConvertAudio(string source, string target)
    {
        using var reader = new MediaFoundationReader(source);
        using var resampler = new MediaFoundationResampler(reader, new WaveFormat(16000, 16, 1)) { ResamplerQuality = 60 };
        WaveFileWriter.CreateWaveFile(target, resampler);
        return target;
    }
    public async Task Shutdown()
    {
        try { await Stop(); }
        finally
        {
            lifetime.Cancel();
            indexing.Writer.TryComplete();
            try { await indexingWorker; }
            finally
            {
                try { await visualPromotion.Stop(); }
                finally
                {
                    neural.Dispose();
                    ocr?.Dispose();
                    ocrGate.Dispose();
                    lifetime.Dispose();
                }
            }
        }
    }
    public void Dispose()
    {
        cts?.Cancel();
        lifetime.Cancel();
        indexing.Writer.TryComplete();
    }
}
public record struct WindowInfo(IntPtr Handle, int Pid, string Process, string App, string Title);
public static class NativeWindows
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left, Top, Right, Bottom;
    }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out Rect rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int pid);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc proc, IntPtr param);
    private delegate bool EnumProc(IntPtr hWnd, IntPtr param);
    public static string? Executable(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            return p.MainModule?.FileName;
        }
        catch { return null; }
    }
    public static WindowInfo Info(IntPtr h)
    {
        var text = new StringBuilder(1024);
        GetWindowText(h, text, text.Capacity);
        GetWindowThreadProcessId(h, out var pid);
        string process = "Desktop", app = "Desktop";
        try
        {
            using var p = Process.GetProcessById(pid);
            process = p.ProcessName;
            app = process.ToLowerInvariant() switch
            {
                "chrome" => "Chrome",
                "winword" => "Word",
                "ms-teams" => "Teams",
                "slack" => "Slack",
                "zoom" => "zoom.us",
                _ => process
            };
        }
        catch (ArgumentException) { }
        return new(h, pid, process, app, text.Length > 0 ? text.ToString() : app);
    }
    public static List<WindowInfo> Visible()
    {
        var result = new List<WindowInfo>();
        EnumWindows((h, _) => { if (IsWindowVisible(h) && !IsIconic(h)) result.Add(Info(h)); return true; }, IntPtr.Zero);
        return result;
    }
}

// Audio sources remain separate for reliable “You” versus “Meeting” attribution.
internal sealed class AudioTrackCapture
{
    private readonly WasapiCapture capture;
    private readonly WaveFileWriter writer;
    private readonly string temporary, target;
    private readonly DateTimeOffset start;
    private readonly object gate = new();
    private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private long writtenBytes;
    public double Offset
    {
        get; private set;
    }
    public string RelativePath
    {
        get;
    }
    public AudioTrackCapture(string root, string relative, DateTimeOffset start, bool microphone)
    {
        this.start = start;
        RelativePath = relative;
        target = Path.Combine(root, relative);
        temporary = target + ".wav";
        capture = microphone ? new WasapiCapture() : new WasapiLoopbackCapture();
        writer = new WaveFileWriter(temporary, capture.WaveFormat);
        capture.DataAvailable += (_, e) =>
        {
            if (e.BytesRecorded <= 0) return;
            lock (gate)
            {
                if (writtenBytes == 0) Offset = Math.Max(0, (DateTimeOffset.Now - start).TotalSeconds);
                writer.Write(e.Buffer, 0, e.BytesRecorded);
                writtenBytes += e.BytesRecorded;
            }
        };
        capture.RecordingStopped += (_, e) => { lock (gate) { writer.Dispose(); } if (e.Exception != null) stopped.TrySetException(e.Exception); else stopped.TrySetResult(); };
        try
        {
            capture.StartRecording();
        }
        catch { capture.Dispose(); writer.Dispose(); if (File.Exists(temporary)) File.Delete(temporary); throw; }
    }
    public async Task<bool> Stop()
    {
        try
        {
            capture.StopRecording();
            await stopped.Task.WaitAsync(TimeSpan.FromSeconds(10));
            long bytes;
            lock (gate) bytes = writtenBytes;
            if (!AudioTrackPolicy.HasEncodableSamples(bytes, capture.WaveFormat.SampleRate, capture.WaveFormat.BlockAlign))
                return false;
            await Task.Run(() => { using var reader = new WaveFileReader(temporary); MediaFoundationEncoder.EncodeToAac(reader, target, 96000); });
            return true;
        }
        finally { capture.Dispose(); lock (gate) { writer.Dispose(); } if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
