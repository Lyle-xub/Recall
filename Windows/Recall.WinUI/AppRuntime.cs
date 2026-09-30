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
    public event Action? LibraryChanged;
    public event Action<string>? Error;
    private readonly CancellationTokenSource lifetime = new();
    private readonly Channel<RecordingSession> speech = Channel.CreateUnbounded<RecordingSession>(new() { SingleReader = true });
    private readonly UsageRecorder usage;
    private readonly Task usageWorker, speechWorker;
    private Task backgroundStartup = Task.CompletedTask;
    private readonly object backgroundStartupGate = new();
    private bool backgroundStartupStarted;
    private volatile bool sessionLocked, powerSuspended;
    private volatile bool interfaceVisible;
    private bool Suspended => sessionLocked || powerSuspended;
    private readonly bool visualParity, validationFakeCapture;
    private readonly bool cliService;
    private readonly TaskCompletionSource<Action> serviceExit = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int serviceStopping;
    private int validationCaptureStarts, validationCaptureStops, validationCaptureActive, validationFailNextStart;
    private readonly object settingsGate = new();
    private readonly LibraryControlHost cliControl;
    private Task? cliOptimization;
    private string? cliTaskError;
    private readonly RecordingControl recordingControl;
    private readonly object recordingDiagnosticsGate = new();
    private Task? recordingDiagnosticsWorker;
    private bool recordingDiagnosticsQueued, recordingDiagnosticsStopped;
    public AppRuntime()
    {
        LocalInference.ShareWithCLI = true;
        var ownership = new LibraryLease(AppPaths.DataRoot);
        var arguments = Environment.GetCommandLineArgs();
        cliService = arguments.Contains("--cli-service");
        visualParity = arguments.Contains("--visual-parity");
        interfaceVisible = !cliService && !visualParity && !arguments.Contains("--background") && !arguments.Contains("--smoke-test");
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
        Store.RecoverInterruptedVisualSessions();
        HasMemories = Store.LatestArchiveDay() != null;
        usage = new(Store);
        Capture = new(Store, deferBackgroundDiscovery: true, interfaceVisible: interfaceVisible);
        Capture.SetInterfaceVisible(interfaceVisible);
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
        recordingControl = new(Recording);
        Recording.Changed += state => { if (!state.Terminated && Settings.RecordingRequested != state.Requested) { Settings.RecordingRequested = state.Requested; _ = Task.Run(() => { try { PersistSettings(); } catch (Exception ex) { Error?.Invoke(ex.Message); } }); } QueueRecordingDiagnostics(); Changed?.Invoke(); };
        Recording.Failed += ex => { QueueRecordingDiagnostics(); Error?.Invoke(ex.Message); };
        Capture.Error += ReportRecordingError;
        Capture.Interrupted += message => { recordingControl.ReportError(message); Recording.Interrupted(); };
        Capture.FrameAdded += _ => { HasMemories = true; Changed?.Invoke(); };
        Capture.SegmentFinished += QueueSpeech;
        SystemEvents.SessionSwitch += SessionSwitch;
        SystemEvents.PowerModeChanged += PowerChange;
        usageWorker = Task.Run(UsageLoop);
        speechWorker = Task.Run(SpeechLoop);
        cliControl = new(Store.Root, "windows", Control, ownership);
        if (Settings.RecordingRequested)
            Recording.Request(true);
        QueueRecordingDiagnostics();
    }
    public void StartBackgroundWork()
    {
        lock (backgroundStartupGate)
        {
            if (backgroundStartupStarted || lifetime.IsCancellationRequested) return;
            backgroundStartupStarted = true;
            backgroundStartup = Task.Run(async () =>
            {
                try
                {
                    if (lifetime.IsCancellationRequested) return;
                    Store.Retain(Settings.RetentionDays);
                    HasMemories = Store.LatestArchiveDay() != null;
                    LibraryChanged?.Invoke();
                    // Historical scans share the store connection with the
                    // first rack. Follow the existing OCR/speech pause policy
                    // so discovery cannot take that connection while UI opens.
                    while (interfaceVisible) await Task.Delay(200, lifetime.Token);
                    if (lifetime.IsCancellationRequested) return;
                    Capture.StartBackgroundDiscovery();
                    foreach (var session in Store.Sessions().Where(s => s.EndedAt != null && s.HasAudio &&
                        s.SpeechState is RecognitionState.Pending or RecognitionState.Working))
                    {
                        if (lifetime.IsCancellationRequested) return;
                        QueueSpeech(session);
                    }
                }
                catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
                catch (Exception error) { Error?.Invoke(error.Message); }
            });
        }
    }
    private void ReportRecordingError(string message)
    {
        recordingControl.ReportError(message);
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
        recordingControl.ReportError("Validation fake capture interrupted.");
        Recording.Interrupted();
    }
    private void QueueRecordingDiagnostics()
    {
        lock (recordingDiagnosticsGate)
        {
            if (recordingDiagnosticsStopped) return;
            recordingDiagnosticsQueued = true;
            recordingDiagnosticsWorker ??= Task.Run(WriteRecordingDiagnostics);
        }
    }
    private async Task WriteRecordingDiagnostics()
    {
        while (true)
        {
            await Task.Delay(200).ConfigureAwait(false);
            lock (recordingDiagnosticsGate) recordingDiagnosticsQueued = false;
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
                    state.AutomaticallyPaused,
                    state.Terminated,
                    captureIsRecording = Capture.IsRecording,
                    capturePrivacyPaused = Capture.IsPrivacyPaused,
                    validationFakeCapture,
                    validationCaptureActive = Volatile.Read(ref validationCaptureActive) != 0,
                    suspended = Suspended,
                    lastError = recordingControl.LastError
                };
                var file = Path.Combine(Store.Root, "recording-diagnostics.json");
                File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(report));
                File.Move(file + ".tmp", file, true);
            }
            catch { /* Diagnostics must never change capture state. */ }
            lock (recordingDiagnosticsGate)
            {
                if (recordingDiagnosticsQueued) continue;
                recordingDiagnosticsWorker = null;
                return;
            }
        }
    }
    private Task StopRecordingDiagnostics()
    {
        lock (recordingDiagnosticsGate)
        {
            // Drain the final snapshot and reject late callbacks before the
            // library ownership is released to another process or migration.
            recordingDiagnosticsStopped = true;
            return recordingDiagnosticsWorker ?? Task.CompletedTask;
        }
    }
    private async Task<object> Control(string operation, JsonElement args)
    {
        switch (operation)
        {
            case "service-stop":
                if (!cliService) throw new RecallException("unsupported", "This Recall desktop was opened independently. Use recording stop to stop capture, or Quit Recall from its tray menu.");
                if (Interlocked.Exchange(ref serviceStopping, 1) == 0)
                    _ = Task.Run(async () =>
                    {
                        // Return the IPC response before shutdown drains the host.
                        await Task.Delay(250);
                        var exit = await serviceExit.Task;
                        exit();
                    });
                return new { stopping = true, owner = "windows" };
            case "recording-start": case "recording-stop": case "recording-status":
                return await recordingControl.Execute(operation);
            case "tasks-status": return new { optimizing = StorageService.IsOptimizing, indexing = Store.PendingFrames().Count, error = cliTaskError };
            case "index":
            {
                var frames = args.Text("id") is { } id ? new List<MemoryFrame> { Store.Frame(id) ?? throw new RecallException("not_found", "Memory not found.") } : Store.IndexCandidates(10000);
                foreach (var frame in frames) Capture.Retry(frame);
                return new { accepted = true, count = frames.Count, owner = "desktop" };
            }
            case "config-set":
                var updated=LibrarySettings.Update(Store.Root,args.Text("key")??"",args.Text("value")??"",false);
                Save(updated.Deserialize<AppSettings>(Wire.Json)!,args.Text("key")=="retention-days");return updated;
            case "index-one": return await Capture.IndexOne(args.Text("id")??"",args.Text("language")??"eng",lifetime.Token);
            case "optimize":
                if (!StorageService.IsOptimizing && cliOptimization is not { IsCompleted: false })
                    cliOptimization = Task.Run(async () => { try { cliTaskError = null; await StorageService.Optimize(Store, new Progress<string>(), lifetime.Token); } catch (Exception e) { cliTaskError = e.Message; } finally { LibraryChanged?.Invoke(); } });
                return new { accepted = true, owner = "desktop" };
            default:
                if (!LibraryCommands.Exclusive(operation)) throw new RecallException("unsupported", "Unsupported desktop operation.");
                if (operation is "compact" or "cleanup" or "export" && StorageService.IsOptimizing) throw new RecallException("busy", "Storage optimization is already running.");
                var result = operation is "compact" or "cleanup" or "export"
                    ? await StorageService.Maintain(() => Task.Run(() => LibraryCommands.Execute(Store, operation, args)))
                    : await Task.Run(() => LibraryCommands.Execute(Store, operation, args));
                HasMemories = Store.Count > 0; LibraryChanged?.Invoke(); Changed?.Invoke();
                return result;
        }
    }
    internal void RegisterServiceExit(Action exit) => serviceExit.TrySetResult(exit);
    private void PersistSettings()
    {
        lock (settingsGate)
        {
            var file = Path.Combine(Store.Root, "settings.json");
            File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(Settings));
            File.Move(file + ".tmp", file, true);
        }
    }
    public void Save(AppSettings settings,bool applyRetention = true)
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
        if(applyRetention)Store.Retain(settings.RetentionDays);
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
    public void SetInterfaceVisible(bool visible)
    {
        var pauseBackgroundWork = Suspended || visible;
        interfaceVisible = pauseBackgroundWork;
        Capture.SetInterfaceVisible(pauseBackgroundWork);
        Recording.SetVisible(pauseBackgroundWork);
    }
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
                while (interfaceVisible) await Task.Delay(200, lifetime.Token);
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
        await cliControl.Stop(releaseOwnership: false);
        lifetime.Cancel();
        Task startup;
        lock (backgroundStartupGate) startup = backgroundStartup;
        await startup;
        speech.Writer.TryComplete();
        await Recording.Shutdown();
        await Capture.Shutdown();
        await Task.WhenAll(usageWorker, speechWorker);
        if (cliOptimization != null) await cliOptimization;
        LocalInference.Stop();
        SystemEvents.SessionSwitch -= SessionSwitch;
        SystemEvents.PowerModeChanged -= PowerChange;
        await StopRecordingDiagnostics();
        Store.Dispose();
        cliControl.ReleaseOwnership();
        lifetime.Dispose();
    }
}
