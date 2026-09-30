using System.Diagnostics;
using System.Text.Json;
namespace Rewind;

public sealed class NeuralOcrClient : IDisposable
{
    JsonLineWorker? worker;
    bool fallback;
    long neuralRetryAfter;
    readonly SemaphoreSlim gate = new(1, 1);
    public static bool Available => File.Exists(Path.Combine(AppContext.BaseDirectory, "Recall.exe"));
    async Task<List<TextRegion>> Read(string path, CancellationToken ct, bool useFallback)
    {
        if (worker == null || fallback != useFallback)
        {
            worker?.Dispose(); fallback = useFallback;
            worker = new(() =>
            {
                var info = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Recall.exe"));
                info.ArgumentList.Add("--ocr"); if (useFallback) info.ArgumentList.Add("--fallback");
                return info;
            });
        }
        var reply = await worker.Request(new {image = path}, ct, TimeSpan.FromSeconds(useFallback ? 20 : 30));
        if (reply.TryGetProperty("error", out var error)) throw new IOException(error.GetString());
        return JsonSerializer.Deserialize<List<TextRegion>>(reply.GetProperty("regions"), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [];
    }
    public async Task<(string Text, List<TextRegion> Regions)> Recognize(string path, CancellationToken ct)
    {
        await gate.WaitAsync(ct);
        try
        {
            List<TextRegion> lines;
            try { lines = await Read(path, ct, Stopwatch.GetTimestamp() < neuralRetryAfter); }
            catch (Exception) when (!ct.IsCancellationRequested)
            {
                worker?.Dispose(); worker = null;
                neuralRetryAfter = Stopwatch.GetTimestamp() + Stopwatch.Frequency * 60;
                lines = await Read(path, ct, true);
            }
            return (string.Join("\n", lines.Select(x => x.Text)), lines);
        }
        catch { worker?.Dispose(); worker = null; throw; }
        finally { gate.Release(); }
    }
    public void Dispose() {worker?.Dispose(); gate.Dispose();}
}
