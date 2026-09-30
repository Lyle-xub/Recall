using System.Diagnostics;
namespace Rewind;

/// SQLite owns pending work. Only a bounded window of IDs lives in memory;
/// capture merely signals this worker and never waits for model inference.
public sealed class DurableOcrWorker : IAsyncDisposable
{
    readonly Func<int, IReadOnlyCollection<string>, IReadOnlyList<string>> fetch;
    readonly Func<string, CancellationToken, Task> recognize;
    readonly Action<string, Exception> failed;
    readonly Func<bool> paused;
    readonly SemaphoreSlim signal = new(0, 1), serial = new(1, 1);
    readonly CancellationTokenSource lifetime;
    readonly Dictionary<string, (long Due, int Attempts)> retries = [];
    readonly Task worker;
    int active;
    public bool Active => Volatile.Read(ref active) != 0;
    public DurableOcrWorker(Func<int, IReadOnlyCollection<string>, IReadOnlyList<string>> fetch,
        Func<string, CancellationToken, Task> recognize, Action<string, Exception> failed, CancellationToken ct = default,
        Func<bool>? paused = null)
    {
        this.fetch = fetch; this.recognize = recognize; this.failed = failed;
        this.paused = paused ?? (() => false);
        lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
        worker = Task.Run(Loop);
    }
    public void Wake() { try { signal.Release(); } catch (SemaphoreFullException) { } }
    public async Task<T> Exclusive<T>(Func<Task<T>> operation, CancellationToken ct)
    {
        await serial.WaitAsync(ct);
        try { return await operation(); } finally { serial.Release(); }
    }
    async Task Loop()
    {
        var ct = lifetime.Token;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                // Pause discovery as well as inference: foreground archive queries
                // share the store connection with this background worker.
                while (paused()) await Task.Delay(200, ct);
                var blocked = retries.Where(p => p.Value.Due > Stopwatch.GetTimestamp()).Select(p => p.Key).ToArray();
                IReadOnlyList<string> ids;
                try { ids = fetch(OcrWorkPolicy.Window, blocked); }
                catch (Exception error)
                {
                    // A transient database lock must not permanently stop indexing.
                    Trace.TraceError("OCR discovery will retry: {0}", error);
                    await Task.Delay(TimeSpan.FromSeconds(1), ct); continue;
                }
                if (ids.Count == 0) { await signal.WaitAsync(TimeSpan.FromSeconds(1), ct); continue; }
                foreach (var id in ids)
                {
                    ct.ThrowIfCancellationRequested();
                    while (paused()) await Task.Delay(200, ct);
                    var started = Stopwatch.GetTimestamp();
                    await serial.WaitAsync(ct);
                    try
                    {
                        Volatile.Write(ref active, 1);
                        await recognize(id, ct); retries.Remove(id);
                    }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
                    catch (Exception error)
                    {
                        try { failed(id, error); }
                        catch (Exception persistenceError) { Trace.TraceError("OCR failure status will retry: {0}", persistenceError); }
                        int attempts = retries.TryGetValue(id, out var prior) ? Math.Min(6, prior.Attempts + 1) : 1;
                        if (retries.Count >= 128 && !retries.ContainsKey(id)) retries.Remove(retries.MinBy(p => p.Value.Due).Key);
                        retries[id] = (Stopwatch.GetTimestamp() + (long)(Math.Min(60, Math.Pow(2, attempts)) * Stopwatch.Frequency), attempts);
                    }
                    finally { Volatile.Write(ref active, 0); serial.Release(); }
                    await Task.Delay(OcrWorkPolicy.Recovery(Stopwatch.GetElapsedTime(started), ids.Count), ct);
                }
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    }
    public async ValueTask DisposeAsync()
    {
        lifetime.Cancel(); await worker;
        lifetime.Dispose(); signal.Dispose(); serial.Dispose();
    }
}
