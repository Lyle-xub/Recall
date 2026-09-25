using System.Diagnostics;
using System.Text.Json;
namespace Rewind;

public sealed class NeuralOcrClient : IDisposable
{
    Process? worker; bool fallback; readonly SemaphoreSlim gate = new(1, 1);
    public static bool Available => File.Exists(Path.Combine(AppContext.BaseDirectory, "Recall.exe"));
    async Task<List<TextRegion>> Read(string path, CancellationToken ct, bool useFallback)
    {
        if (worker == null || worker.HasExited || fallback != useFallback)
        {
            Stop();
            fallback = useFallback;
            var info = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Recall.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            info.ArgumentList.Add("--ocr");
            if (useFallback)
                info.ArgumentList.Add("--fallback");
            worker = new()
            {
                StartInfo = info
            };
            worker.ErrorDataReceived += (_, _) => { };
            worker.Start();
            worker.BeginErrorReadLine();
        }
        await worker.StandardInput.WriteLineAsync(JsonSerializer.Serialize(new
        {
            image = path
        }));
        await worker.StandardInput.FlushAsync(ct);
        var line = await worker.StandardOutput.ReadLineAsync(ct);
        if (line == null)
            throw new IOException("OCR worker exited unexpectedly.");
        using var json = JsonDocument.Parse(line);
        if (json.RootElement.TryGetProperty("error", out var error))
            throw new IOException(error.GetString());
        return JsonSerializer.Deserialize<List<TextRegion>>(json.RootElement.GetProperty("regions"), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [];
    }
    public async Task<(string Text, List<TextRegion> Regions)> Recognize(string path, CancellationToken ct)
    {
        await gate.WaitAsync(ct);
        try
        {
            List<TextRegion> lines;
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(TimeSpan.FromSeconds(30));
            try
            {
                lines = await Read(path, deadline.Token, false);
            }
            catch (Exception) when (!ct.IsCancellationRequested) { Stop(); using var retry = CancellationTokenSource.CreateLinkedTokenSource(ct); retry.CancelAfter(TimeSpan.FromSeconds(20)); lines = await Read(path, retry.Token, true); }
            return (string.Join("\n", lines.Select(x => x.Text)), lines);
        }
        catch { Stop(); throw; }
        finally { gate.Release(); }
    }
    void Stop()
    {
        try
        {
            if (worker is { HasExited: false })
                worker.Kill(true);
        }
        catch (InvalidOperationException) { }
        worker?.Dispose();
        worker = null;
    }
    public void Dispose()
    {
        Stop();
        gate.Dispose();
    }
}
