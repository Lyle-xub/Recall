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
    private bool suspended;
    private readonly object settingsGate = new();
    private readonly LibraryControlHost cliControl;
    private Task? cliOptimization;
    private string? cliTaskError;
    private string? captureError;
    public AppRuntime()
    {
        var ownership = new LibraryLease(AppPaths.DataRoot);
        Directory.CreateDirectory(AppPaths.DataRoot);
        var path = Path.Combine(AppPaths.DataRoot, "settings.json");
        try
        {
            Settings = File.Exists(path) ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path)) ?? new() : new();
        }
        catch { Settings = new(); }
        Store = new(AppPaths.DataRoot);
        HasMemories = Store.Count > 0;
        usage = new(Store);
        Capture = new(Store);
        Recording = new(async () => await Capture.Start(Settings), async () => { var segment = await Capture.Stop(); if (segment != null) QueueSpeech(segment); });
        Recording.Changed += state => { if (!state.Terminated && Settings.RecordingRequested != state.Requested) { Settings.RecordingRequested = state.Requested; _ = Task.Run(() => { try { PersistSettings(); } catch (Exception ex) { Error?.Invoke(ex.Message); } }); } Changed?.Invoke(); };
        Recording.Failed += ex => { captureError = ex.Message; Error?.Invoke(ex.Message); };
        Capture.Error += message => Error?.Invoke(message);
        Capture.Interrupted += _ => Recording.Request(false);
        Capture.FrameAdded += _ => { HasMemories = true; Changed?.Invoke(); };
        Capture.SegmentFinished += QueueSpeech;
        SystemEvents.SessionSwitch += SessionSwitch;
        SystemEvents.PowerModeChanged += PowerChange;
        usageWorker = Task.Run(UsageLoop);
        speechWorker = Task.Run(SpeechLoop);
        foreach (var session in Store.Sessions().Where(s => s.EndedAt != null && s.HasAudio && s.SpeechState is RecognitionState.Pending or RecognitionState.Working))
            QueueSpeech(session);
        Store.Retain(Settings.RetentionDays);
        cliControl = new(Store.Root, "windows", Control, ownership);
        if (Settings.RecordingRequested)
            Recording.Request(true);
    }
    private async Task<object> Control(string operation, JsonElement args)
    {
        switch (operation)
        {
            case "recording-start": case "recording-stop": case "recording-status":
                if (operation != "recording-status") { captureError = null; Recording.Request(operation == "recording-start"); await Recording.Settled(); }
                if (operation == "recording-start" && !Recording.State.Requested) throw new RecallException("capture_failed", captureError ?? "Capture did not start.");
                return new { available = true, requested = Recording.State.Requested, active = Recording.State.Active, automaticallyPaused = Recording.State.Requested && Recording.State.InterfaceVisible, owner = "desktop" };
            case "tasks-status": return new { optimizing = StorageService.IsOptimizing, indexing = Store.PendingFrames().Count, error = cliTaskError };
            case "index":
            {
                var frames = args.Text("id") is { } id ? new List<MemoryFrame> { Store.Frame(id) ?? throw new RecallException("not_found", "Memory not found.") } : Store.IndexCandidates(10000);
                foreach (var frame in frames) Capture.Retry(frame);
                return new { accepted = true, count = frames.Count, owner = "desktop" };
            }
            case "optimize":
                if (!StorageService.IsOptimizing && cliOptimization is not { IsCompleted: false })
                    cliOptimization = Task.Run(async () => { try { cliTaskError = null; await StorageService.Optimize(Store, new Progress<string>(), lifetime.Token); } catch (Exception e) { cliTaskError = e.Message; } finally { LibraryChanged?.Invoke(); } });
                return new { accepted = true, owner = "desktop" };
            default:
                if (!LibraryCommands.Writes(operation)) throw new RecallException("unsupported", "Unsupported desktop operation.");
                if (operation is "compact" or "cleanup" && StorageService.IsOptimizing) throw new RecallException("busy", "Storage optimization is already running.");
                var result = operation is "compact" or "cleanup"
                    ? await StorageService.Maintain(() => Task.Run(() => LibraryCommands.Execute(Store, operation, args)))
                    : await Task.Run(() => LibraryCommands.Execute(Store, operation, args));
                HasMemories = Store.Count > 0; LibraryChanged?.Invoke(); Changed?.Invoke();
                return result;
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
    private void SessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock)
            suspended = true;
        else if (e.Reason == SessionSwitchReason.SessionUnlock)
            suspended = false;
        Recording.SetVisible(suspended || App.CurrentWindow?.IsShown == true);
    }
    private void PowerChange(object sender, PowerModeChangedEventArgs e)
    {
        suspended = e.Mode == PowerModes.Suspend;
        Recording.SetVisible(suspended || App.CurrentWindow?.IsShown == true);
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
                if (suspended || !Recording.State.Requested)
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
        await cliControl.Stop(releaseOwnership: false);
        lifetime.Cancel();
        speech.Writer.TryComplete();
        await Recording.Shutdown();
        await Capture.Shutdown();
        await Task.WhenAll(usageWorker, speechWorker);
        if (cliOptimization != null) await cliOptimization;
        LocalInference.Stop();
        SystemEvents.SessionSwitch -= SessionSwitch;
        SystemEvents.PowerModeChanged -= PowerChange;
        Store.Dispose();
        cliControl.ReleaseOwnership();
        lifetime.Dispose();
    }
}
