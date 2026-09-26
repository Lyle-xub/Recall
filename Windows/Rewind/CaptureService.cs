using System.Diagnostics;
using System.Security.Cryptography;
using System.Threading.Channels;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using ScreenRecorderLib;
using Tesseract;
using NAudio.Wave;
using NAudio.CoreAudioApi;
using Screen = System.Windows.Forms.Screen;
using ImageFormat = System.Drawing.Imaging.ImageFormat;
namespace Rewind;

public sealed class CaptureService : IDisposable
{
    private readonly MemoryStore store;
    private Recorder? recorder;
    private AudioTrackCapture? systemTrack, microphoneTrack;
    private TesseractEngine? ocr;
    private readonly NeuralOcrClient neural = new();
    private CancellationTokenSource? cts;
    private Task? loop;
    private RecordingSession? session;
    private TaskCompletionSource? finished;
    private volatile bool privacyPaused;
    private MemoryFrame? previous;
    private readonly Channel<string> indexing = Channel.CreateUnbounded<string>(new UnboundedChannelOptions { SingleReader = true });
    private readonly HashSet<string> queuedIndex = [];
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task indexingWorker;
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
        indexingWorker = Task.Run(IndexLoop);
        foreach (var frame in store.PendingFrames())
            QueueIndex(frame.Id);
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
            var frame = store.Frame(id);
            if (frame == null) { lock (queuedIndex) queuedIndex.Remove(id); continue; }
            var original = Path.Combine(store.Root, "frames", id + ".ocr.png");
            try
            {
                store.Recognition(id, RecognitionState.Working);
                FrameAdded?.Invoke(store.Frame(id)!);
                var recognitionFile = File.Exists(original) ? original : store.SafePath(frame.ImagePath)!;
                if (recognitionFile.EndsWith(".recallframe"))
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
                    if (File.Exists(original))
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
                if (File.Exists(original))
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
        loop = Task.Run(async () =>
        {
            var last = DateTimeOffset.MinValue;
            var lastWindow = IntPtr.Zero;
            Task? snapshot = null;
            CancellationTokenSource? snapshotCancellation = null;
            try
            {
                while (!cts.IsCancellationRequested)
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
                    if (!excluded && (snapshot == null || snapshot.IsCompleted) && (DateTimeOffset.Now - last >= TimeSpan.FromSeconds(settings.CaptureInterval) || NativeWindows.GetForegroundWindow() != lastWindow))
                    {
                        snapshotCancellation?.Dispose();
                        snapshotCancellation = CancellationTokenSource.CreateLinkedTokenSource(cts.Token);
                        last = DateTimeOffset.Now;
                        lastWindow = NativeWindows.GetForegroundWindow();
                        snapshot = Snapshot(settings, snapshotCancellation.Token);
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
                    await Task.Delay(150, cts.Token);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex) { cts.Cancel(); Error?.Invoke(ex.Message); Interrupted?.Invoke(ex.Message); }
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
        var s = new RecordingSession(Guid.NewGuid().ToString(), DateTimeOffset.Now, null, $"recordings/{Guid.NewGuid()}.mp4", settings.SystemAudio || settings.Microphone, SpeechState: settings.TranscriptionEnabled ? RecognitionState.Pending : RecognitionState.Disabled, SeparateAudio: true);
        var options = RecorderOptions.DefaultMainMonitor;
        if (settings.DisplayName != null)
            options.SourceOptions = new SourceOptions { RecordingSources = [new DisplayRecordingSource(settings.DisplayName)] };
        var screen = Screen.AllScreens.FirstOrDefault(x => x.DeviceName == settings.DisplayName) ?? Screen.PrimaryScreen!;
        var scale = Math.Min(1.0, (double)settings.VideoMaxEdge / Math.Max(screen.Bounds.Width, screen.Bounds.Height));
        options.OutputOptions.OutputFrameSize = new ScreenSize(Math.Max(2, (int)(screen.Bounds.Width * scale) / 2 * 2), Math.Max(2, (int)(screen.Bounds.Height * scale) / 2 * 2));
        options.VideoEncoderOptions = new VideoEncoderOptions { Encoder = new H264VideoEncoder { BitrateMode = H264BitrateControlMode.CBR }, Framerate = 1, Bitrate = settings.VideoBitrate, IsHardwareEncodingEnabled = true, IsFixedFramerate = true };
        options.AudioOptions = new AudioOptions { IsAudioEnabled = false };
        options.MouseOptions = new MouseOptions { IsMousePointerEnabled = true, IsMouseClicksDetected = false };
        var r = Recorder.CreateRecorder(options);
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        finished = completion;
        r.OnRecordingComplete += (_, _) => completion.TrySetResult();
        r.OnRecordingFailed += (_, e) => { completion.TrySetException(new InvalidOperationException(e.Error)); cts?.Cancel(); Error?.Invoke(e.Error); Interrupted?.Invoke(e.Error); };
        recorder = r;
        session = s;
        privacyPaused = false;
        store.SaveSession(s);
        try
        {
            if (settings.SystemAudio)
                systemTrack = new(store.Root, $"recordings/{s.Id}-system.m4a", s.StartedAt, false);
            if (settings.Microphone)
                microphoneTrack = new(store.Root, $"recordings/{s.Id}-microphone.m4a", s.StartedAt, true);
            r.Record(Path.Combine(store.Root, s.VideoPath));
        }
        catch { if (systemTrack != null) _ = systemTrack.Stop(); if (microphoneTrack != null) _ = microphoneTrack.Stop(); systemTrack = microphoneTrack = null; r.Dispose(); recorder = null; session = null; store.SaveSession(s with { EndedAt = DateTimeOffset.Now, SpeechState = RecognitionState.Failed, SpeechError = "Capture could not start." }); throw; }
    }
    private async Task<RecordingSession?> StopSegment()
    {
        if (recorder == null || session == null)
            return null;
        var r = recorder;
        var s = session;
        if (previous != null)
        {
            store.Extend(previous.Id, DateTimeOffset.Now);
            previous = null;
        }
        try
        {
            r.Stop();
            if (finished != null)
                await finished.Task.WaitAsync(TimeSpan.FromSeconds(20));
        }
        finally
        {
            r.Dispose();
            recorder = null;
            session = null;
            try
            {
                if (systemTrack != null && await systemTrack.Stop())
                    s = s with
                    {
                        SystemAudioPath = systemTrack.RelativePath,
                        SystemAudioOffset = systemTrack.Offset
                    };
            }
            catch (Exception ex) { Error?.Invoke("System audio track: " + ex.Message); }
            finally { systemTrack = null; }
            try
            {
                if (microphoneTrack != null && await microphoneTrack.Stop())
                    s = s with
                    {
                        MicrophoneAudioPath = microphoneTrack.RelativePath,
                        MicrophoneAudioOffset = microphoneTrack.Offset
                    };
            }
            catch (Exception ex) { Error?.Invoke("Microphone track: " + ex.Message); }
            finally { microphoneTrack = null; }
        }
        s = s with
        {
            EndedAt = DateTimeOffset.Now
        };
        store.SaveSession(s);
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
    private Task Snapshot(AppSettings settings, CancellationToken token)
    {
        var foreground = NativeWindows.Info(NativeWindows.GetForegroundWindow());
        if (foreground.Pid == Environment.ProcessId || settings.ExcludedApps.Contains(foreground.Process, StringComparer.OrdinalIgnoreCase))
            return Task.CompletedTask;
        var screen = Screen.AllScreens.FirstOrDefault(s => s.DeviceName == settings.DisplayName) ?? Screen.PrimaryScreen ?? Screen.AllScreens[0];
        var now = DateTimeOffset.Now;
        using var bitmap = new Bitmap(screen.Bounds.Width, screen.Bounds.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap))
            graphics.CopyFromScreen(screen.Bounds.Location, System.Drawing.Point.Empty, screen.Bounds.Size);
        token.ThrowIfCancellationRequested();
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
        var relative = $"frames/{id}.jpg";
        var original = Path.Combine(store.Root, "frames", id + ".ocr.png");
        var shared = store.ExactImage(hash);
        if (shared == null || !File.Exists(store.SafePath(shared.ImagePath)))
        {
            shared = null;
            bitmap.Save(original, ImageFormat.Png);
            SaveJpeg(bitmap, Path.Combine(store.Root, relative), settings.ImageQuality);
        }
        else
            relative = shared.ImagePath;
        var meetingPath = shared != null ? shared.MeetingImagePath : CaptureMeetingCrop(bitmap, screen.Bounds, id);
        var frame = new MemoryFrame { Id = id, Timestamp = now, MeetingImagePath = meetingPath, MeetingRegions = shared?.MeetingRegions ?? [], EndTimestamp = now, AppName = foreground.App, ProcessName = foreground.Process, ExecutablePath = NativeWindows.Executable(foreground.Pid), Title = foreground.Title, ImagePath = relative, SessionId = session?.Id, PixelHash = hash, ImageQuality = shared?.ImageQuality ?? settings.ImageQuality, Text = shared?.Text ?? "", Regions = shared?.Regions ?? [], TextState = shared?.TextState ?? RecognitionState.Pending };
        store.Save(frame);
        previous = frame;
        FrameAdded?.Invoke(frame);
        if (shared == null)
            QueueIndex(frame.Id);
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
        await Stop();
        lifetime.Cancel();
        indexing.Writer.TryComplete();
        await indexingWorker;
        neural.Dispose();
        ocr?.Dispose();
        ocrGate.Dispose();
        lifetime.Dispose();
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
    private bool received;
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
        capture.DataAvailable += (_, e) => { lock (gate) { if (!received) { Offset = Math.Max(0, (DateTimeOffset.Now - start).TotalSeconds); received = true; } writer.Write(e.Buffer, 0, e.BytesRecorded); } };
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
            if (!received)
                return false;
            await Task.Run(() => { using var reader = new WaveFileReader(temporary); MediaFoundationEncoder.EncodeToAac(reader, target, 96000); });
            return true;
        }
        finally { capture.Dispose(); lock (gate) { writer.Dispose(); } if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
