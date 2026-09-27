using System.Diagnostics;
using System.Text.Json;
using System.Threading.Channels;
using Microsoft.Win32;
namespace Recall;

internal sealed class AppRuntime
{
    public MemoryStore Store
    {
        get;
    }
    public bool HasMemories
    {
        get; private set;
    }
    public AppSettings Settings
    {
        get; private set;
    }
    public CaptureService Capture
    {
        get;
    }
    public RecordingCoordinator Recording
    {
        get;
    }
    public BuiltinModels Models => BuiltinModels.Shared;
    public event Action? Changed;
    public event Action<string>? Error;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Channel<RecordingSession> speech = Channel.CreateUnbounded<RecordingSession>(new() { SingleReader = true });
    private readonly UsageRecorder usage;
    private readonly Task usageWorker, speechWorker;
    private volatile bool sessionLocked, powerSuspended;
    private bool Suspended => sessionLocked || powerSuspended;
    private readonly bool visualParity, validationFakeCapture;
    private int validationCaptureStarts, validationCaptureStops, validationCaptureActive, validationFailNextStart;
    private readonly object settingsGate = new();
    private string? lastRecordingError;
    private int recordingDiagnosticsQueued, recordingDiagnosticsRunning;
    public AppRuntime()
    {
        var arguments = Environment.GetCommandLineArgs();
        visualParity = arguments.Contains("--visual-parity");
        validationFakeCapture = visualParity && arguments.Contains("--validation-fake-capture");
        Directory.CreateDirectory(AppPaths.DataRoot);
        var path = Path.Combine(AppPaths.DataRoot, "settings.json");
        try
        {
            Settings = File.Exists(path) ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new() : new();
        }
        catch { Settings = new(); }
        // Validation libraries can persist a fake request. Never let a later
        // visual-parity launch start the production capture backend from it.
        if (visualParity) Settings.RecordingRequested = false;
        Store = new(AppPaths.DataRoot);
        HasMemories = Store.Count > 0;
        usage = new(Store);
        Capture = new(Store);
        Recording = new(async () =>
        {
            if (validationFakeCapture)
            {
                Interlocked.Increment(ref validationCaptureStarts);
                if (Interlocked.Exchange(ref validationFailNextStart, 0) != 0)
                    throw new InvalidOperationException("Validation fake capture start failed.");
                Interlocked.Exchange(ref validationCaptureActive, 1);
                return;
            }
            await Capture.Start(Settings);
        }, async () =>
        {
            if (validationFakeCapture)
            {
                Interlocked.Increment(ref validationCaptureStops);
                Interlocked.Exchange(ref validationCaptureActive, 0);
                return;
            }
            var segment = await Capture.Stop();
            if (segment != null) QueueSpeech(segment);
        });
        Recording.Changed += state => { if (!state.Terminated && Settings.RecordingRequested != state.Requested) { Settings.RecordingRequested = state.Requested; _ = Task.Run(() => { try { PersistSettings(); } catch (Exception ex) { Error?.Invoke(ex.Message); } }); } QueueRecordingDiagnostics(); Changed?.Invoke(); };
        Recording.Failed += ex => ReportRecordingError(ex.Message);
        Capture.Error += ReportRecordingError;
        Capture.Interrupted += message => { Volatile.Write(ref lastRecordingError, message); Recording.Interrupted(); };
        Capture.FrameAdded += _ => { HasMemories = true; Changed?.Invoke(); };
        Capture.SegmentFinished += QueueSpeech;
        SystemEvents.SessionSwitch += SessionSwitch;
        SystemEvents.PowerModeChanged += PowerChange;
        usageWorker = Task.Run(UsageLoop);
        speechWorker = Task.Run(SpeechLoop);
        foreach (var session in Store.Sessions().Where(s => s.EndedAt != null && s.HasAudio && s.SpeechState is RecognitionState.Pending or RecognitionState.Working))
            QueueSpeech(session);
        Store.Retain(Settings.RetentionDays);
        if (Settings.RecordingRequested)
            Recording.Request(true);
        QueueRecordingDiagnostics();
    }
    private void ReportRecordingError(string message)
    {
        Volatile.Write(ref lastRecordingError, message);
        QueueRecordingDiagnostics();
        Error?.Invoke(message);
    }
    internal object ValidationCaptureDiagnostics => new
    {
        enabled = validationFakeCapture,
        starts = Volatile.Read(ref validationCaptureStarts),
        stops = Volatile.Read(ref validationCaptureStops),
        active = Volatile.Read(ref validationCaptureActive),
        failNextStart = Volatile.Read(ref validationFailNextStart) != 0
    };
    internal void ValidationRequestRecording(bool requested)
    {
        if (!validationFakeCapture) throw new InvalidOperationException("Fake capture is not enabled.");
        Recording.Request(requested);
    }
    internal void ValidationFailNextCaptureStart()
    {
        if (!validationFakeCapture) throw new InvalidOperationException("Fake capture is not enabled.");
        Interlocked.Exchange(ref validationFailNextStart, 1);
    }
    internal void ValidationInterruptCapture()
    {
        if (!validationFakeCapture) throw new InvalidOperationException("Fake capture is not enabled.");
        Volatile.Write(ref lastRecordingError, "Validation fake capture interrupted.");
        Recording.Interrupted();
    }
    private void QueueRecordingDiagnostics()
    {
        Interlocked.Exchange(ref recordingDiagnosticsQueued, 1);
        if (Interlocked.CompareExchange(ref recordingDiagnosticsRunning, 1, 0) == 0)
            _ = Task.Run(WriteRecordingDiagnostics);
    }
    private async Task WriteRecordingDiagnostics()
    {
        try
        {
            do
            {
                await Task.Delay(200).ConfigureAwait(false);
                Interlocked.Exchange(ref recordingDiagnosticsQueued, 0);
                try
                {
                    var state = Recording.State;
                    var report = new
                    {
                        capturedAt = DateTimeOffset.UtcNow,
                        state.Requested,
                        state.InterfaceVisible,
                        state.Active,
                        state.Transitioning,
                        state.CaptureFaulted,
                        captureIsRecording = Capture.IsRecording,
                        capturePrivacyPaused = Capture.IsPrivacyPaused,
                        validationFakeCapture,
                        validationCaptureActive = Volatile.Read(ref validationCaptureActive) != 0,
                        suspended = Suspended,
                        lastError = Volatile.Read(ref lastRecordingError)
                    };
                    var file = Path.Combine(Store.Root, "recording-diagnostics.json");
                    File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(report));
                    File.Move(file + ".tmp", file, true);
                }
                catch { /* Diagnostics must never change capture state. */ }
            } while (Volatile.Read(ref recordingDiagnosticsQueued) != 0);
        }
        finally
        {
            Interlocked.Exchange(ref recordingDiagnosticsRunning, 0);
            if (Volatile.Read(ref recordingDiagnosticsQueued) != 0)
                QueueRecordingDiagnostics();
        }
    }
    private void PersistSettings()
    {
        lock (settingsGate)
        {
            var file = Path.Combine(Store.Root, "settings.json");
            File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(Settings));
            File.Move(file + ".tmp", file, true);
        }
    }
    public void Save(AppSettings settings)
    {
        settings.Shortcuts.Validate();
        lock (settingsGate)
        {
            settings.RecordingRequested = Recording.State.Requested;
            Settings = settings;
            PersistSettings();
        }
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (settings.LaunchAtLogin)
            key.SetValue("Recall", $"\"{Environment.ProcessPath}\" --background");
        else
            key.DeleteValue("Recall", false);
        Store.Retain(settings.RetentionDays);
        Recording.Rotate();
        Changed?.Invoke();
    }
    public void MarkOnboarding(bool complete = false)
    {
        Settings.LaunchFilmSeen = true;
        if (complete)
            Settings.OnboardingComplete = true;
        Save(Settings);
    }
    public void SetInterfaceVisible(bool visible) => Recording.SetVisible(Suspended || visible);
    private void SessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock)
            sessionLocked = true;
        else if (e.Reason == SessionSwitchReason.SessionUnlock)
            sessionLocked = false;
        else
            return;
        SetInterfaceVisible(App.CurrentWindow?.IsShown == true);
    }
    private void PowerChange(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend)
            powerSuspended = true;
        else if (e.Mode == PowerModes.Resume)
            powerSuspended = false;
        else
            return;
        SetInterfaceVisible(App.CurrentWindow?.IsShown == true);
    }
    private async Task UsageLoop()
    {
        var last = DateTimeOffset.Now;
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                var now = DateTimeOffset.Now;
                // Never attribute sleep or long scheduler stalls to the foreground app.
                if (now - last > TimeSpan.FromSeconds(4))
                    usage.Stop(last);
                last = now;
                if (visualParity || Suspended || !Recording.State.Requested)
                {
                    usage.Stop(now);
                    await Task.Delay(300, lifetime.Token);
                    continue;
                }
                var info = NativeWindows.Info(NativeWindows.GetForegroundWindow());
                var hidden = Settings.ExcludedApps.Contains(info.Process, StringComparer.OrdinalIgnoreCase);
                var identity = hidden ? new AppIdentity("Private app", "", Kind: "private") : new AppIdentity(info.Pid == Environment.ProcessId ? "Recall" : info.App, info.Process, NativeWindows.Executable(info.Pid));
                usage.Transition(identity, now);
                await Task.Delay(350, lifetime.Token);
            }
        }
        catch (OperationCanceledException) { }
        finally { usage.Stop(DateTimeOffset.Now); }
    }
    private readonly HashSet<string> queued = [];
    public void QueueSpeech(RecordingSession session)
    {
        if (!session.HasAudio || !Settings.TranscriptionEnabled)
        {
            Store.SpeechStatus(session.Id, RecognitionState.Disabled);
            return;
        }
        lock (queued)
        {
            if (!queued.Add(session.Id))
                return;
        }
        speech.Writer.TryWrite(session);
    }
    private async Task SpeechLoop()
    {
        try
        {
            await foreach (var session in speech.Reader.ReadAllAsync(lifetime.Token))
            {
                if (!Store.SpeechStatus(session.Id, RecognitionState.Working))
                {
                    lock (queued)
                    {
                        queued.Remove(session.Id);
                    }
                    continue;
                }
                Changed?.Invoke();
                try
                {
                    var tracks = new List<(string Path, string Source, double Offset)>();
                    if (session.SystemAudioPath is { } system)
                        tracks.Add((system, "System", session.SystemAudioOffset));
                    if (session.MicrophoneAudioPath is { } microphone)
                        tracks.Add((microphone, "Microphone", session.MicrophoneAudioOffset));
                    if (tracks.Count == 0 && !session.SeparateAudio)
                        tracks.Add((session.VideoPath, "Audio", 0));
                    var lines = new List<TranscriptLine>();
                    foreach (var track in tracks)
                    {
                        var original = Store.SafePath(track.Path);
                        if (original == null || !File.Exists(original))
                            continue;
                        var temporary = Path.Combine(Store.Root, "recordings", Guid.NewGuid() + "-speech.wav");
                        try
                        {
                            await Task.Run(() => CaptureService.ConvertAudio(original, temporary), lifetime.Token);
                            var result = await ModelClient.Transcribe(temporary, session with
                            {
                                StartedAt = session.StartedAt.AddSeconds(track.Offset)
                            }, Settings.Speech, SecretStore.Read("speech"), lifetime.Token);
                            lines.AddRange(result.Select(x => x with { Speaker = track.Source }));
                        }
                        finally { if (File.Exists(temporary)) File.Delete(temporary); }
                    }
                    lines = TranscriptPresentation.Visible(lines);
                    Store.FinishSpeech(session with
                    {
                        SpeechState = lines.Count == 0 ? RecognitionState.Empty : RecognitionState.Complete,
                        SpeechError = null
                    }, lines);
                }
                catch (OperationCanceledException) { Store.SpeechStatus(session.Id, RecognitionState.Pending); break; }
                catch (Exception ex) { Store.SpeechStatus(session.Id, RecognitionState.Failed, ex.Message); }
                finally { lock (queued) { queued.Remove(session.Id); } Changed?.Invoke(); }
            }
        }
        catch (OperationCanceledException) { }
    }
    public async Task Shutdown()
    {
        lifetime.Cancel();
        speech.Writer.TryComplete();
        await Recording.Shutdown();
        await Capture.Shutdown();
        await Task.WhenAll(usageWorker, speechWorker);
        LocalInference.Stop();
        SystemEvents.SessionSwitch -= SessionSwitch;
        SystemEvents.PowerModeChanged -= PowerChange;
        Store.Dispose();
        lifetime.Dispose();
    }
}
