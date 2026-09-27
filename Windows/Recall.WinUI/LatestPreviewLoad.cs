namespace Recall;

/// A surface may receive another frame while its previous image is decoding.
/// Keep the displayed pixels until the newest request completes; canceled or
/// out-of-order results must never replace them.
internal sealed class LatestPreviewLoad<T>
{
    readonly object sync = new();
    CancellationTokenSource? current;
    long revision;

    public Task Request(Func<CancellationToken, Task<T>> load, Action<T> apply, Action<Exception>? fail = null)
    {
        CancellationTokenSource source;
        long version;
        lock (sync)
        {
            current?.Cancel();
            current = source = new();
            version = ++revision;
        }
        return Complete(load, apply, fail, source, version);
    }

    public void Cancel()
    {
        lock (sync)
        {
            ++revision;
            current?.Cancel();
            current = null;
        }
    }

    async Task Complete(Func<CancellationToken, Task<T>> load, Action<T> apply, Action<Exception>? fail,
        CancellationTokenSource source, long version)
    {
        try
        {
            var value = await load(source.Token);
            lock (sync)
                if (version == revision && ReferenceEquals(current, source) && !source.IsCancellationRequested)
                    apply(value);
        }
        catch (OperationCanceledException) when (source.IsCancellationRequested) { }
        catch (Exception error)
        {
            lock (sync)
                if (version == revision && ReferenceEquals(current, source) && !source.IsCancellationRequested)
                    fail?.Invoke(error);
        }
        finally
        {
            lock (sync)
                if (ReferenceEquals(current, source)) current = null;
            source.Dispose();
        }
    }
}
