namespace Rewind;

internal static class VisualPromotionWorkerTests
{
    static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }

    public static async Task<int> Run()
    {
        var entered = Signal(); var release = Signal(); var secondPass = Signal();
        int calls = 0, durableOcrVersion = 0, promotedVersion = -1;
        var worker = new VisualPromotionWorker(async (session, token) =>
        {
            Check(session == "ready-session", "A promotion wake-up lost its session identity.");
            var version = Volatile.Read(ref durableOcrVersion);
            if (Interlocked.Increment(ref calls) == 1)
            {
                entered.TrySetResult();
                await release.Task.WaitAsync(token);
            }
            Volatile.Write(ref promotedVersion, version);
            if (version == 2) secondPass.TrySetResult();
        }, error => throw error, CancellationToken.None);
        try
        {
            worker.Request("ready-session");
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            // These requests arrive after the running pass took its snapshot.
            Volatile.Write(ref durableOcrVersion, 1);
            for (int i = 0; i < 200; i++) worker.Request("ready-session");
            Volatile.Write(ref durableOcrVersion, 2);
            worker.Request("ready-session");
            release.TrySetResult();
            await secondPass.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { await worker.Stop(); }
        Check(calls == 2 && promotedVersion == 2, "Coalescing must retain the final OCR update with exactly one follow-up pass.");

        var decoding = Signal();
        int active = 0, completed = 0;
        var cancelled = new VisualPromotionWorker(async (_, token) =>
        {
            Interlocked.Increment(ref active);
            try
            {
                decoding.TrySetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
                Interlocked.Increment(ref completed);
            }
            finally { Interlocked.Decrement(ref active); }
        }, error => throw error, CancellationToken.None);
        cancelled.Request("ready-session");
        await decoding.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancelled.Request("another-ready-session");
        await cancelled.Stop().WaitAsync(TimeSpan.FromSeconds(5));
        await cancelled.Stop();
        cancelled.Request("after-shutdown");
        Check(active == 0 && completed == 0, "Shutdown must cancel active verification, join the worker, and leave uncommitted sources recoverable.");
        Console.WriteLine("PASS: promotion requests coalesce by session; shutdown joins cancelled verification.");
        return 2;
    }
}
