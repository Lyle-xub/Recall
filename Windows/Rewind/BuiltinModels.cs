using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;
namespace Rewind;

public record ModelDownload(string Id, string Title, string Subtitle, string File, string Url, long Bytes, string Sha256, string License, string Source)
{
    public string SizeLabel => Bytes >= 1_000_000_000 ? $"{Bytes / 1e9:0.00} GB" : $"{Bytes / 1e6:0} MB";
}
public sealed class BuiltinModels
{
    public static readonly BuiltinModels Shared = new();
    public readonly List<ModelDownload> Catalog;
    public readonly string Root = Environment.GetEnvironmentVariable("REWIND_MODEL_ROOT") ?? Path.Combine(AppPaths.DataRoot, "models");
    public readonly Dictionary<string, double> Progress = [];
    public readonly Dictionary<string, string> Status = [];
    public readonly HashSet<string> Installed = [];
    private readonly Dictionary<string, CancellationTokenSource> downloads = [];
    public event Action? Changed;
    public bool Busy(string id) => downloads.ContainsKey(id);
    public BuiltinModels()
    {
        Directory.CreateDirectory(Root);
        var catalog = Environment.GetEnvironmentVariable("REWIND_CATALOG_PATH") ?? Path.Combine(AppContext.BaseDirectory, "models", "catalog.json");
        Catalog = File.Exists(catalog) ? JsonSerializer.Deserialize<List<ModelDownload>>(File.ReadAllText(catalog), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }) ?? [] : [];
        foreach (var item in Catalog)
            if (Valid(item))
            {
                Installed.Add(item.Id);
                Status[item.Id] = "Ready · Works offline";
            }
    }
    public string FilePath(ModelDownload item) => Path.Combine(Root, item.File);
    private bool Valid(ModelDownload item) => File.Exists(FilePath(item)) && new FileInfo(FilePath(item)).Length == item.Bytes && File.Exists(FilePath(item) + ".verified") && File.ReadAllText(FilePath(item) + ".verified") == item.Sha256;
    public string Require(string id)
    {
        var item = Catalog.FirstOrDefault(m => m.Id == id);
        if (item == null || !Valid(item))
            throw new InvalidOperationException($"Download the built-in {(id == "chat" ? "Qwen3" : "Whisper")} model in Settings → Models first.");
        return FilePath(item);
    }
    public void Pause(string id)
    {
        if (downloads.TryGetValue(id, out var cancellation))
            cancellation.Cancel();
    }
    public async Task Download(ModelDownload item)
    {
        if (Busy(item.Id))
            return;
        using var cancellation = new CancellationTokenSource();
        downloads[item.Id] = cancellation;
        var ct = cancellation.Token;
        Update(item.Id, 0, "Connecting…");
        var partial = FilePath(item) + ".part";
        try
        {
            var existing = File.Exists(partial) ? new FileInfo(partial).Length : 0;
            if (new DriveInfo(Path.GetPathRoot(Root)!).AvailableFreeSpace < item.Bytes - existing + 50_000_000)
                throw new IOException("Not enough disk space for this model.");
            if (existing != item.Bytes)
            {
                using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
                using var request = new HttpRequestMessage(HttpMethod.Get, item.Url);
                if (existing > 0)
                    request.Headers.Range = new RangeHeaderValue(existing, null);
                using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
                response.EnsureSuccessStatusCode();
                var resume = response.StatusCode == HttpStatusCode.PartialContent && response.Content.Headers.ContentRange?.From == existing;
                if (!resume)
                    existing = 0;
                await using (var output = new FileStream(partial, resume ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 131072, true))
                {
                    await using var input = await response.Content.ReadAsStreamAsync(ct);
                    var buffer = new byte[131072];
                    var last = Stopwatch.StartNew();
                    int count;
                    while ((count = await input.ReadAsync(buffer, ct)) > 0)
                    {
                        await output.WriteAsync(buffer.AsMemory(0, count), ct);
                        existing += count;
                        if (existing > item.Bytes)
                            throw new IOException("Unexpected model size. Please retry.");
                        if (last.ElapsedMilliseconds >= 150)
                        {
                            Update(item.Id, Math.Min(.99, (double)existing / item.Bytes), $"{100.0 * existing / item.Bytes:0}% · {existing / 1e6:0} MB / {item.SizeLabel}");
                            last.Restart();
                        }
                    }
                }
            }
            Update(item.Id, .99, "Verifying SHA-256…");
            await using (var file = File.OpenRead(partial))
            {
                if (file.Length != item.Bytes)
                    throw new IOException("Download was interrupted. Press Download to resume.");
                var hash = Convert.ToHexString(await SHA256.HashDataAsync(file, ct));
                if (!hash.Equals(item.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Model verification failed. Please download again.");
            }
            File.Move(partial, FilePath(item), true);
            await File.WriteAllTextAsync(FilePath(item) + ".verified", item.Sha256, ct);
            Installed.Add(item.Id);
            Update(item.Id, 1, "Ready · Works offline");
        }
        catch (OperationCanceledException) { Update(item.Id, Progress.GetValueOrDefault(item.Id), "Paused · Press Download to resume"); }
        catch (InvalidDataException ex) { File.Delete(partial); Update(item.Id, 0, ex.Message); }
        catch (Exception ex) { Update(item.Id, Progress.GetValueOrDefault(item.Id), ex.Message); }
        finally { downloads.Remove(item.Id); Changed?.Invoke(); }
    }
    public void Remove(ModelDownload item)
    {
        if (Busy(item.Id))
            return;
        LocalInference.Stop();
        File.Delete(FilePath(item));
        File.Delete(FilePath(item) + ".verified");
        Installed.Remove(item.Id);
        Update(item.Id, 0, "Removed · Download again any time");
    }
    private void Update(string id, double progress, string status)
    {
        Progress[id] = progress;
        Status[id] = status;
        Changed?.Invoke();
    }
}
public static class LocalInference
{
    private static readonly SemaphoreSlim chatGate = new(1, 1), speechGate = new(1, 1);
    private static Process? server, speech;
    private static ModelProfile? profile;
    private static string key = "";
    private static string Runtime(string engine, string executable)
    {
        var root = Environment.GetEnvironmentVariable("REWIND_RUNTIME_ROOT") ?? Path.Combine(AppContext.BaseDirectory, "runtimes");
        var file = Path.Combine(root, engine, executable);
        if (!File.Exists(file))
            throw new FileNotFoundException($"The native {engine} engine is missing. Install the complete application package.");
        return file;
    }
    private static Process Start(string executable, IEnumerable<string> arguments)
    {
        var info = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = Path.GetDirectoryName(executable) };
        foreach (var arg in arguments)
            info.ArgumentList.Add(arg);
        var process = new Process { StartInfo = info };
        process.OutputDataReceived += (_, _) => { };
        process.ErrorDataReceived += (_, _) => { };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return process;
    }
    public static async Task<(ModelProfile Profile, string Key)> Chat(CancellationToken ct = default)
    {
        await chatGate.WaitAsync(ct);
        try
        {
            if (server is { HasExited: false } && profile != null)
                return (profile, key);
            var model = BuiltinModels.Shared.Require("chat");
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();
            key = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
            server = Start(Runtime("llama", "llama-server.exe"), ["-m", model, "--host", "127.0.0.1", "--port", port.ToString(), "--api-key", key, "--alias", "rewind-local", "-c", "8192", "-np", "1", "-n", "768", "-ngl", "0", "--jinja", "--chat-template-kwargs", "{\"enable_thinking\":false}", "--no-webui"]);
            var local = new ModelProfile { Provider = "Internal runtime", BaseUrl = $"http://127.0.0.1:{port}/v1", Model = "rewind-local", IsLocal = true };
            using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(2) };
            http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", key);
            for (var i = 0; i < 240; i++)
            {
                ct.ThrowIfCancellationRequested();
                if (server.HasExited)
                    throw new InvalidOperationException("The built-in model could not start. Check memory and reinstall the model.");
                try
                {
                    using var response = await http.GetAsync(local.BaseUrl + "/models", ct);
                    if (response.IsSuccessStatusCode)
                    {
                        profile = local;
                        return (local, key);
                    }
                }
                catch (HttpRequestException) { }
                catch (TaskCanceledException) when (!ct.IsCancellationRequested) { }
                await Task.Delay(250, ct);
            }
            throw new TimeoutException("Model loading timed out. Free some memory and retry.");
        }
        catch { Stop(); throw; }
        finally { chatGate.Release(); }
    }
    public static void Stop()
    {
        foreach (var process in new[] { server, speech })
        {
            try
            {
                if (process is { HasExited: false })
                    process.Kill(true);
            }
            catch (InvalidOperationException) { }
            process?.Dispose();
        }
        server = null;
        speech = null;
        profile = null;
        key = "";
    }
    public static async Task<List<TranscriptLine>> Transcribe(string wave, RecordingSession session, CancellationToken ct)
    {
        await speechGate.WaitAsync(ct);
        var temporary = Path.Combine(Path.GetTempPath(), "rewind-speech-" + Guid.NewGuid());
        try
        {
            Directory.CreateDirectory(temporary);
            var output = Path.Combine(temporary, "transcript");
            speech = Start(Runtime("whisper", "whisper-cli.exe"), ["-m", BuiltinModels.Shared.Require("speech"), "-f", wave, "-l", "auto", "-oj", "-of", output, "-t", Math.Min(8, Environment.ProcessorCount).ToString(), "-np"]);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromMinutes(15));
            await speech.WaitForExitAsync(timeout.Token);
            if (speech.ExitCode != 0)
                throw new InvalidOperationException("Local transcription failed. Audio remains saved for retry.");
            return ParseTranscript(await File.ReadAllTextAsync(output + ".json", ct), session);
        }
        finally { try { if (speech is { HasExited: false }) speech.Kill(true); } finally { speech?.Dispose(); speech = null; if (Directory.Exists(temporary)) Directory.Delete(temporary, true); speechGate.Release(); } }
    }
    public static List<TranscriptLine> ParseTranscript(string json, RecordingSession session)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.GetProperty("transcription").EnumerateArray().Where(r => !string.IsNullOrWhiteSpace(r.GetProperty("text").GetString())).Select(r => new TranscriptLine(Guid.NewGuid().ToString(), session.Id, session.StartedAt.AddMilliseconds(r.GetProperty("offsets").GetProperty("from").GetDouble()), "Audio", r.GetProperty("text").GetString()!.Trim())).ToList();
    }
}
