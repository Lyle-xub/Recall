using System.Diagnostics;
namespace Rewind;

public static class ChildProcess
{
    public static async Task<(int ExitCode, string Output, string Error)> Run(string executable, IEnumerable<string> args, string? input, CancellationToken ct, int timeoutSeconds = 120)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true };
        foreach (var arg in args) info.ArgumentList.Add(arg);
        info.Environment["OMP_THREAD_LIMIT"] = "2";
        using var process = Process.Start(info) ?? throw new RecallException("engine_missing", "Could not start the requested engine.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); if (timeoutSeconds > 0) deadline.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
        var output = process.StandardOutput.ReadToEndAsync(deadline.Token);
        var error = process.StandardError.ReadToEndAsync(deadline.Token);
        try
        {
            if (input != null) await process.StandardInput.WriteAsync(input.AsMemory(), deadline.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(deadline.Token);
            return (process.ExitCode, await output, await error);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            if (!process.HasExited) process.Kill(true);
            await process.WaitForExitAsync();
            throw new RecallException("timeout", $"The engine exceeded its {timeoutSeconds}-second limit.");
        }
        catch { if (!process.HasExited) process.Kill(true); await process.WaitForExitAsync(); throw; }
    }
}
