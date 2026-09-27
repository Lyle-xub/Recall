namespace Rewind;

public record RecordingState(bool Requested = false, bool InterfaceVisible = false, bool Active = false, bool Transitioning = false, bool Terminated = false, bool CaptureFaulted = false)
{
    public bool ShouldCapture => Requested && !InterfaceVisible && !Terminated && !CaptureFaulted;
    public bool AutomaticallyPaused => Requested && InterfaceVisible && !Terminated && !CaptureFaulted;
}
/// One serialized reconciler separates capture state from the user's intent.
public sealed class RecordingCoordinator
{
    private readonly Func<Task> start, stop;
    private readonly TimeSpan delay;
    private readonly object gate = new();
    private Task? pending;
    private bool rotate;
    private long revision;
    public RecordingState State { get; private set; } = new();
    public event Action<RecordingState>? Changed;
    public event Action<Exception>? Failed;
    public RecordingCoordinator(Func<Task> start, Func<Task> stop, TimeSpan? resumeDelay = null)
    {
        this.start = start;
        this.stop = stop;
        delay = resumeDelay ?? TimeSpan.FromMilliseconds(300);
    }
    public void Request(bool value) => Change(s => s.Terminated ? s : s with { Requested = value, CaptureFaulted = false });
    public void SetVisible(bool value) => Change(s => s with
    {
        InterfaceVisible = value,
        // A new hide is a bounded retry opportunity after a capture fault.
        CaptureFaulted = s.CaptureFaulted && !(s.InterfaceVisible && !value)
    });
    public void Interrupted() => Change(s => s.ShouldCapture && !rotate ? s with { CaptureFaulted = true } : s);
    public void Rotate()
    {
        lock (gate)
        {
            rotate = State.Active;
        }
        Change(s => s);
    }
    private void Change(Func<RecordingState, RecordingState> update)
    {
        lock (gate)
        {
            State = update(State);
            revision++;
            Changed?.Invoke(State);
            pending ??= Task.Run(Reconcile);
        }
    }
    private async Task Reconcile()
    {
        while (true)
        {
            bool stopping;
            long token;
            lock (gate)
            {
                stopping = State.Active && (!State.ShouldCapture || rotate);
                if (!stopping && (State.Active || !State.ShouldCapture))
                {
                    pending = null;
                    State = State with
                    {
                        Transitioning = false
                    };
                    Changed?.Invoke(State);
                    return;
                }
                token = revision;
                State = State with
                {
                    Transitioning = true
                };
                Changed?.Invoke(State);
            }
            if (stopping)
            {
                try
                {
                    await stop().ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    lock (gate)
                    {
                        var supersededAndReady = token != revision && State.ShouldCapture;
                        State = State with { CaptureFaulted = State.Requested && !supersededAndReady };
                    }
                    Failed?.Invoke(ex);
                }
                lock (gate)
                {
                    rotate = false;
                    State = State with
                    {
                        Active = false
                    };
                }
            }
            else
            {
                await Task.Delay(delay).ConfigureAwait(false);
                lock (gate)
                {
                    if (token != revision || !State.ShouldCapture)
                        continue;
                }
                try
                {
                    await start().ConfigureAwait(false);
                    lock (gate)
                    {
                        State = State with
                        {
                            Active = true
                        };
                    }
                }
                catch (Exception ex)
                {
                    lock (gate)
                    {
                        // If the UI changed while startup was in flight, retry the
                        // newest visible/hidden intent instead of latching its error.
                        var supersededAndReady = token != revision && State.ShouldCapture;
                        State = State with { Active = false, CaptureFaulted = State.Requested && !supersededAndReady };
                    }
                    Failed?.Invoke(ex);
                }
            }
            lock (gate)
            {
                State = State with
                {
                    Transitioning = false
                };
                Changed?.Invoke(State);
            }
        }
    }
    public async Task Settled()
    {
        while (true)
        {
            Task? task;
            lock (gate)
            {
                task = pending;
            }
            if (task == null)
                return;
            await task.ConfigureAwait(false);
        }
    }
    public async Task Shutdown()
    {
        Change(s => s with { Terminated = true, Requested = false });
        await Settled();
    }
}
