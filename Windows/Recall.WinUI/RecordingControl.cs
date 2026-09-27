using System;
using System.Threading;
using System.Threading.Tasks;
using Rewind;

namespace Recall;

internal sealed record RecordingControlStatus(
    bool Requested, bool Active, bool AutomaticallyPaused, bool Transitioning,
    bool CaptureFaulted, bool Terminated, string? Error)
{
    public bool Available => true;
    public string Owner => "desktop";
}

/// The desktop and IPC share one coordinator, including its retained user intent
/// after faults. A retained request alone is not evidence that capture started.
internal sealed class RecordingControl
{
    private readonly RecordingCoordinator recording;
    private string? lastError;

    public RecordingControl(RecordingCoordinator recording)
    {
        this.recording = recording;
        recording.Failed += error => ReportError(error.Message);
        recording.Changed += state =>
        {
            if (state.Active && !state.Transitioning && !state.CaptureFaulted)
                Volatile.Write(ref lastError, null);
        };
    }

    public string? LastError => Volatile.Read(ref lastError);
    public void ReportError(string message) => Volatile.Write(ref lastError, message);

    public RecordingControlStatus Status
    {
        get
        {
            var state = recording.State;
            return new(state.Requested, state.Active, state.AutomaticallyPaused,
                state.Transitioning, state.CaptureFaulted, state.Terminated, LastError);
        }
    }

    public async Task<RecordingControlStatus> Execute(string operation)
    {
        if (operation == "recording-status") return Status;
        if (operation is not ("recording-start" or "recording-stop"))
            throw new RecallException("unsupported", "Unsupported recording operation.");

        Volatile.Write(ref lastError, null);
        recording.Request(operation == "recording-start");
        await recording.Settled().ConfigureAwait(false);
        var status = Status;
        if (operation == "recording-start" &&
            (!status.Requested || status.CaptureFaulted || status.Terminated ||
             (!status.Active && !status.AutomaticallyPaused)))
            throw new RecallException("capture_failed", status.Error ?? "Capture did not start.");
        return status;
    }
}
