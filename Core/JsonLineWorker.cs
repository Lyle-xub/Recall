using System.Diagnostics;
using System.Text.Json;
namespace Rewind;

/// Serial local IPC. Cancellation/timeout retires the entire process tree so
/// a late response can never become the result of the next request.
public sealed class JsonLineWorker(Func<ProcessStartInfo> start) : IDisposable
{
    readonly SemaphoreSlim gate = new(1, 1);
    Process? process;
    public async Task<JsonElement> Request(object request, CancellationToken ct, TimeSpan timeout)
    {
        await gate.WaitAsync(ct);
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(timeout);
            if (process is not { HasExited: false })
            {
                Reset(); var info = start();
                info.UseShellExecute = false; info.CreateNoWindow = true;
                info.RedirectStandardInput = info.RedirectStandardOutput = info.RedirectStandardError = true;
                info.Environment["OMP_THREAD_LIMIT"] = "2"; info.Environment["VECLIB_MAXIMUM_THREADS"] = "2";
                process = Process.Start(info) ?? throw new RecallException("engine_missing", "Could not start the local worker.");
                process.ErrorDataReceived += (_, _) => { }; process.BeginErrorReadLine();
            }
            var payload = JsonSerializer.Serialize(request, Wire.Json);
            if (payload.Length > 2_000_000) throw new RecallException("invalid_request", "Worker request is too large.");
            await process.StandardInput.WriteLineAsync(payload.AsMemory(), deadline.Token);
            await process.StandardInput.FlushAsync(deadline.Token);
            var line = await process.StandardOutput.ReadLineAsync(deadline.Token);
            if (line == null || line.Length > 2_000_000) throw new IOException("The local worker returned an invalid response.");
            using var document = JsonDocument.Parse(line); return document.RootElement.Clone();
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            Reset(); throw new RecallException("timeout", "The local worker exceeded its time limit; saved inputs are retained.");
        }
        catch { Reset(); throw; }
        finally { gate.Release(); }
    }
    void Reset()
    {
        if (process != null)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
            process.Dispose(); process = null;
        }
    }
    public void Dispose() { Reset(); gate.Dispose(); }
}
