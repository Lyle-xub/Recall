using System.Text.Json;
using Recall;
using Rewind;

internal static class RecordingControlTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    public static async Task Run(Action<bool, string> assert)
    {
        var starts = 0;
        var stops = 0;
        var recording = new RecordingCoordinator(
            () => ++starts == 1 ? Task.FromException(new InvalidOperationException("capture unavailable")) : Task.CompletedTask,
            () => { stops++; return Task.CompletedTask; }, TimeSpan.Zero);
        var control = new RecordingControl(recording);
        var error = await StartFailure(control);
        assert(error.Code == "capture_failed" && error.Message == "capture unavailable",
            "IPC start returns the capture error even when failed capture retains its request");
        var fault = await control.Execute("recording-status");
        assert(fault.Requested && fault.CaptureFaulted && !fault.Active && !fault.AutomaticallyPaused &&
               !fault.Transitioning && fault.Error == error.Message && starts == 1,
            "Fault status preserves recording intent and reports failure without an automatic retry loop");
        recording.SetVisible(true);
        await recording.Settled().WaitAsync(Timeout);
        assert(!control.Status.AutomaticallyPaused && control.Status.CaptureFaulted,
            "Showing the UI does not mislabel faulted capture as an automatic pause");
        recording.SetVisible(false);
        await recording.Settled().WaitAsync(Timeout);
        assert(control.Status.Active && control.Status.Requested && !control.Status.CaptureFaulted &&
               control.Status.Error == null && starts == 2,
            "Hiding the UI retries the retained request and clears the recovered error");

        control.ReportError("capture interrupted");
        recording.Interrupted();
        await recording.Settled().WaitAsync(Timeout);
        fault = await control.Execute("recording-status");
        assert(fault.Requested && fault.CaptureFaulted && !fault.Active && !fault.AutomaticallyPaused &&
               fault.Error == "capture interrupted" && stops == 1,
            "An asynchronous interruption is visible to IPC without discarding the user's request");
        using (var json = JsonDocument.Parse(JsonSerializer.Serialize(fault, Wire.Json)))
        {
            var result = json.RootElement;
            assert(result.GetProperty("available").GetBoolean() && result.GetProperty("owner").GetString() == "desktop" &&
                   result.GetProperty("captureFaulted").GetBoolean() && !result.GetProperty("automaticallyPaused").GetBoolean() &&
                   !result.GetProperty("terminated").GetBoolean() && result.GetProperty("error").GetString() == "capture interrupted",
                "The runtime status serializes stable camel-case owner, pause, fault, termination, and error fields");
        }
        recording.SetVisible(true);
        await recording.Settled().WaitAsync(Timeout);
        var paused = await control.Execute("recording-start").WaitAsync(Timeout);
        assert(paused.Requested && paused.AutomaticallyPaused && !paused.Active && !paused.CaptureFaulted &&
               paused.Error == null && starts == 2,
            "An explicit retry while the interface is visible accepts a real automatic pause without starting capture");
        recording.SetVisible(false);
        await recording.Settled().WaitAsync(Timeout);
        assert(control.Status.Active && starts == 3, "The accepted paused request starts when the interface closes");
        var stopped = await control.Execute("recording-stop").WaitAsync(Timeout);
        recording.SetVisible(true);
        recording.SetVisible(false);
        await recording.Settled().WaitAsync(Timeout);
        assert(!stopped.Requested && !stopped.Active && !stopped.AutomaticallyPaused && !stopped.CaptureFaulted &&
               stopped.Error == null && !control.Status.Active && starts == 3,
            "An explicit IPC stop clears the request and a later UI close cannot restart capture");
        await recording.Shutdown().WaitAsync(Timeout);
        var terminated = await control.Execute("recording-status");
        error = await StartFailure(control);
        assert(terminated.Terminated && !terminated.Active && !terminated.AutomaticallyPaused && error.Code == "capture_failed" && starts == 3,
            "IPC cannot report a successful start after coordinator shutdown");

        await ExplicitRetry(assert);
        await StartWhileShowingInterface(assert);
        await SupersededFailure(assert);
        await StopWhileStarting(assert);
    }

    private static async Task ExplicitRetry(Action<bool, string> assert)
    {
        var starts = 0;
        var recording = new RecordingCoordinator(
            () => ++starts == 1 ? Task.FromException(new InvalidOperationException("retry me")) : Task.CompletedTask,
            () => Task.CompletedTask, TimeSpan.Zero);
        var control = new RecordingControl(recording);
        await StartFailure(control);
        var result = await control.Execute("recording-start").WaitAsync(Timeout);
        assert(result.Active && result.Requested && !result.CaptureFaulted && result.Error == null && starts == 2,
            "Repeating IPC start retries a faulted retained request and returns actual recovery");
        await control.Execute("recording-start").WaitAsync(Timeout);
        assert(starts == 2, "Repeating IPC start while active does not create another capture engine");
        await recording.Shutdown().WaitAsync(Timeout);
    }

    private static async Task StartWhileShowingInterface(Action<bool, string> assert)
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var starts = 0;
        var stops = 0;
        var recording = new RecordingCoordinator(async () =>
        {
            if (++starts == 1) { entered.SetResult(); await release.Task; }
        }, () => { stops++; return Task.CompletedTask; }, TimeSpan.Zero);
        var control = new RecordingControl(recording);
        var starting = control.Execute("recording-start");
        await entered.Task.WaitAsync(Timeout);
        var pending = await control.Execute("recording-status").WaitAsync(Timeout);
        assert(pending.Requested && pending.Transitioning && !pending.Active && !pending.CaptureFaulted,
            "IPC status remains available during a pending capture transition");
        recording.SetVisible(true);
        release.SetResult();
        var paused = await starting.WaitAsync(Timeout);
        assert(paused.Requested && !paused.Active && paused.AutomaticallyPaused && !paused.Transitioning &&
               !paused.CaptureFaulted && paused.Error == null && starts == 1 && stops == 1,
            "Opening the interface during IPC startup returns the settled automatic pause");
        recording.SetVisible(false);
        await recording.Settled().WaitAsync(Timeout);
        assert(control.Status.Active && starts == 2, "Closing the interface resumes the in-flight IPC request");
        await recording.Shutdown().WaitAsync(Timeout);
    }

    private static async Task SupersededFailure(Action<bool, string> assert)
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var starts = 0;
        var recording = new RecordingCoordinator(async () =>
        {
            if (++starts == 1)
            {
                entered.SetResult();
                await release.Task;
                throw new InvalidOperationException("obsolete startup failure");
            }
        }, () => Task.CompletedTask, TimeSpan.Zero);
        var control = new RecordingControl(recording);
        var starting = control.Execute("recording-start");
        await entered.Task.WaitAsync(Timeout);
        recording.SetVisible(true);
        recording.SetVisible(false);
        release.SetResult();
        var result = await starting.WaitAsync(Timeout);
        assert(result.Active && result.Requested && !result.CaptureFaulted && result.Error == null && starts == 2,
            "An obsolete startup failure cannot poison IPC after the newer UI intent recovers");
        await recording.Shutdown().WaitAsync(Timeout);
    }

    private static async Task StopWhileStarting(Action<bool, string> assert)
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stops = 0;
        var recording = new RecordingCoordinator(async () => { entered.SetResult(); await release.Task; },
            () => { stops++; return Task.CompletedTask; }, TimeSpan.Zero);
        var control = new RecordingControl(recording);
        var starting = StartFailure(control);
        await entered.Task.WaitAsync(Timeout);
        var stopping = control.Execute("recording-stop");
        release.SetResult();
        var failure = await starting.WaitAsync(Timeout);
        var result = await stopping.WaitAsync(Timeout);
        assert(failure.Code == "capture_failed" && !result.Requested && !result.Active && !result.AutomaticallyPaused &&
               !result.CaptureFaulted && stops == 1,
            "An explicit stop superseding startup is authoritative and startup cannot report false success");
        await recording.Shutdown().WaitAsync(Timeout);
    }

    private static async Task<RecallException> StartFailure(RecordingControl control)
    {
        try { await control.Execute("recording-start").WaitAsync(Timeout); }
        catch (RecallException error) { return error; }
        throw new Exception("IPC start reported success without capturing or automatically pausing.");
    }
}
