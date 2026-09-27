using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace Rewind;

// Session IDs are deduplicated while pending; one wake-up slot represents that
// set. A request for a session currently being processed creates another pass,
// so its last OCR completion cannot be lost during an earlier promotion pass.
internal sealed class VisualPromotionWorker
{
    private readonly Channel<bool> requests = Channel.CreateBounded<bool>(new BoundedChannelOptions(1)
    {
        SingleReader = true,
        FullMode = BoundedChannelFullMode.DropWrite
    });
    private readonly HashSet<string> pending = new(StringComparer.Ordinal);
    private readonly object gate = new();
    private readonly CancellationTokenSource cancellation;
    private readonly Task worker;
    private int stopping;

    public VisualPromotionWorker(Func<string, CancellationToken, Task> promoteSession, Action<Exception> error, CancellationToken lifetime)
    {
        cancellation = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        worker = Task.Run(async () =>
        {
            try
            {
                await foreach (var _ in requests.Reader.ReadAllAsync(cancellation.Token))
                    while (true)
                    {
                        cancellation.Token.ThrowIfCancellationRequested();
                        string session;
                        lock (gate)
                        {
                            using var iterator = pending.GetEnumerator();
                            if (!iterator.MoveNext()) break;
                            session = iterator.Current;
                            pending.Remove(session);
                        }
                        try { await promoteSession(session, cancellation.Token); }
                        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return; }
                        catch (Exception exception) { error(exception); }
                    }
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
            finally { requests.Writer.TryComplete(); }
        });
    }

    public void Request(string session)
    {
        lock (gate)
        {
            if (Volatile.Read(ref stopping) != 0) return;
            pending.Add(session);
        }
        requests.Writer.TryWrite(true);
    }

    public async Task Stop()
    {
        var ownsStop = Interlocked.Exchange(ref stopping, 1) == 0;
        if (ownsStop)
        {
            cancellation.Cancel();
            requests.Writer.TryComplete();
        }
        await worker;
        if (ownsStop) cancellation.Dispose();
    }
}
