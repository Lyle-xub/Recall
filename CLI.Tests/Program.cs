using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Recall.Cli;
using Rewind;

var root = Path.Combine(Path.GetTempPath(), "recall-cli-tests-" + Guid.NewGuid());
var host = Environment.GetEnvironmentVariable("DOTNET_HOST_PATH") ?? "dotnet";
var packaged = Environment.GetEnvironmentVariable("RECALL_CLI_BINARY");
var cli = typeof(CliApplication).Assembly.Location;
var tests = 0;
void Assert(bool value, string description) { if (!value) throw new Exception(description); Interlocked.Increment(ref tests); }
async Task<JsonElement> Run(string library, int expected, params string[] words)
{
    var result = await ChildProcess.Run(packaged ?? host, (packaged == null ? new[] { cli } : Array.Empty<string>()).Concat(new[] { "--data-dir", library, "--json" }).Concat(words), null, default, 30);
    Assert(result.ExitCode == expected, $"Exit {result.ExitCode}, expected {expected}: {string.Join(' ', words)}\n{result.Output}\n{result.Error}");
    using var json = JsonDocument.Parse(result.Output);
    Assert(json.RootElement.Flag("ok") == (expected == 0), "Stable JSON success/error contract");
    return expected == 0 ? json.RootElement.GetProperty("result").Clone() : json.RootElement.GetProperty("error").Clone();
}
Directory.CreateDirectory(root);
try
{
    var windows = Path.Combine(root, "windows");
    await Run(windows, 0, "--help"); Assert(!Directory.Exists(windows), "Help does not create a library");
    await Run(windows, 3, "records", "list"); Assert(!Directory.Exists(windows), "Read does not initialize missing library");
    await Run(windows, 2, "records", "list", "--limti", "4");
    await Run(windows, 0, "library", "init", "--format", "windows");
    await Run(windows, 5, "library", "init", "--format", "windows");
    var image = Path.Combine(root, "sample.png");
    File.WriteAllBytes(image, Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJYoAAAAASUVORK5CYII="));
    var text = Path.Combine(root, "sample.txt"); File.WriteAllText(text, "CLI imported Aurora 100% _literal 会议记录");
    var imported = await Run(windows, 0, "records", "import", "--image", image, "--text-file", text, "--app", "Research");
    var id = imported.GetProperty("id").GetString()!;
    using (var application = new MemoryStore(windows))
    {
        Assert(application.Frame(id)?.Text.Contains("Aurora") == true, "Desktop store reads CLI import without conversion");
        application.Save(new MemoryFrame { Id = "app-record", Text = "Application generated TPS report", AppName = "Editor", Title = "Shared live data" });
        var result = await Run(windows, 0, "search", "TPS"); Assert(result.GetArrayLength() == 1, "CLI sees new desktop record through WAL");
        int changed = 0, starts = 0, stops = 0;
        var coordinator = new RecordingCoordinator(async () => { starts++; await Task.Delay(20); }, () => { stops++; return Task.CompletedTask; }, TimeSpan.Zero);
        using (var owner = new LibraryControlHost(windows, "test-desktop", async (operation, a) =>
        {
            if (operation.StartsWith("recording-"))
            {
                if (operation != "recording-status") coordinator.Request(operation == "recording-start");
                await coordinator.Settled(); return new { available = true, coordinator.State.Active };
            }
            var value = LibraryCommands.Execute(application, operation, a); changed++; return value;
        }))
        {
            await Run(windows, 0, "records", "star", id);
            Assert(application.Frame(id)!.Starred && changed == 1, "CLI mutation routes to desktop owner and triggers refresh notification");
            try { using var second = new LibraryLease(windows); throw new Exception("Second owner acquired lease"); } catch (RecallException e) { Assert(e.Code == "busy", "Exclusive owner across file handles"); }
            await Task.WhenAll(Run(windows, 0, "recording", "start"), Run(windows, 0, "recording", "start"));
            Assert(starts == 1, "Concurrent start requests start one capture engine");
            await Run(windows, 0, "recording", "stop"); Assert(stops == 1, "Stop uses existing capture engine");
            await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => Run(windows, 0, "search", "Aurora")));
            Assert(application.CheckIntegrity() == "ok", "Concurrent desktop/CLI readers leave database valid");
        }
        await coordinator.Shutdown();
        await Run(windows, 0, "records", "trash", id); Assert(application.Frame(id)!.DeletedAt != null, "Offline CLI writes visible to existing desktop connection");
        var preview = await Run(windows, 0, "storage", "cleanup", "--scope", "all");
        Assert(application.Frame(id) != null && preview.GetProperty("keepStarred").GetBoolean(), "Cleanup previews by default and protects stars");
        await Run(windows, 5, "storage", "compact");
        await Run(windows, 0, "records", "restore", id);
        var export = Path.Combine(root, "export");
        await Run(windows, 0, "records", "export", "--output", export, "--app", "Research");
        Assert(File.Exists(Path.Combine(export, "frames.json")) && File.Exists(Path.Combine(export, application.Frame(id)!.ImagePath)), "Export carries metadata and media");
        await Run(windows, 5, "records", "export", "--output", export);
        await Run(windows, 0, "storage", "cleanup", "--scope", "all", "--yes");
        Assert(application.Frame(id) != null && application.Frame("app-record") == null, "Confirmed cleanup preserves starred record");
        await Run(windows, 0, "storage", "compact", "--yes");
        Assert((await Run(windows, 0, "storage", "check")).Text("integrity") == "ok", "Post-maintenance integrity");
    }
    await Run(windows, 4, "recording", "start");
    await Run(windows, 3, "records", "get", "missing");
    Assert((await Run(windows, 0, "search", "%")).GetArrayLength() == 1, "Literal wildcard search");
    Assert((await Run(windows, 0, "search", "会议记录")).GetArrayLength() == 1, "Unicode search");
    using (var fakeModel = new FakeModel())
    {
        var models = await Run(windows, 0, "models", "list", "--endpoint", fakeModel.Url); Assert(models[0].GetString() == "test-model", "Model service list");
        var answer = await Run(windows, 0, "ask", "Aurora", "--endpoint", fakeModel.Url, "--model", "test-model");
        Assert(answer.Text("answer") == "A shared memory [1]." && answer.GetProperty("sources")[0].Text("id") == id, "Grounded answer uses shared records");
        Assert(fakeModel.SawEvidence, "Existing model client's untrusted-evidence boundary retained");
        using (var db = new MemoryStore(windows)) db.SaveSession(new("transcription-test", DateTimeOffset.Parse("2026-01-01T00:00:00Z"), DateTimeOffset.Parse("2026-01-01T00:01:00Z"), "recordings/test.mp4", true));
        var wave = Path.Combine(root, "sample.wav"); File.WriteAllBytes(wave, new byte[44]);
        var transcript = await Run(windows, 0, "transcribe", wave, "--session", "transcription-test", "--save", "--yes", "--endpoint", fakeModel.Url, "--model", "test-speech");
        Assert(transcript.Flag("saved"), "Transcription explicitly persists to existing desktop session");
        var lines = await Run(windows, 0, "sessions", "transcript", "transcription-test");
        Assert(lines[0].Text("text") == "Shared transcript" && lines[0].GetProperty("timestamp").GetDateTimeOffset() == DateTimeOffset.Parse("2026-01-01T00:00:02Z"), "Transcription shares timestamps and data contract");
    }
    var fixture = Environment.GetEnvironmentVariable("RECALL_OCR_FIXTURE");
    if (fixture != null)
    {
        var ocr = await Run(windows, 0, "ocr", "image", fixture);
        Assert(ocr.Text("text")?.Contains("Aurora", StringComparison.OrdinalIgnoreCase) == true, "Real OCR reads synthetic Aurora screenshot");
        var candidate = await Run(windows, 0, "records", "import", "--image", fixture, "--timestamp", "2020-01-01T00:00:00Z");
        using (var db = new MemoryStore(windows))
        {
            for (int i = 0; i < 110; i++) db.Save(new MemoryFrame { Id = "completed-" + i, Text = "Already indexed", Timestamp = DateTimeOffset.Now });
            Assert(db.IndexCandidates(1).Single().Id == candidate.Text("id"), "Pending OCR is selected before applying pagination");
        }
        var indexed = await Run(windows, 0, "index", "run", "--limit", "1");
        Assert(indexed.GetProperty("completed").GetInt32() == 1, "Offline indexing processes pending image");
        Assert((await Run(windows, 0, "records", "get", candidate.Text("id")!)).Text("text")?.Contains("Aurora", StringComparison.OrdinalIgnoreCase) == true, "Indexed OCR persists into shared desktop store");
    }
    var unknown = Path.Combine(root, "unknown"); Directory.CreateDirectory(unknown);
    using (var database = new Microsoft.Data.Sqlite.SqliteConnection("Data Source=" + Path.Combine(unknown, "memory.sqlite"))) { database.Open(); using var c = database.CreateCommand(); c.CommandText = "CREATE TABLE unrelated(value TEXT)"; c.ExecuteNonQuery(); }
    var before = File.ReadAllBytes(Path.Combine(unknown, "memory.sqlite"));
    await Run(unknown, 4, "records", "list"); Assert(before.SequenceEqual(File.ReadAllBytes(Path.Combine(unknown, "memory.sqlite"))), "Unknown schema remains byte-for-byte unchanged");
    if (OperatingSystem.IsMacOS() && LibraryClient.MacHelper != null)
    {
        var mac = Path.Combine(root, "mac");
        await Run(mac, 0, "library", "init"); Assert(LibraryFormats.Detect(mac) == LibraryFormat.MacOS, "Mac CLI creates actual Swift desktop schema");
        var frame = await Run(mac, 0, "records", "import", "--image", image, "--text-file", text); var macId = frame.Text("id")!;
        Assert((await Run(mac, 0, "search", "Aurora")).GetArrayLength() == 1, "Native Swift shared OCR hydration and search");
        await Run(mac, 0, "records", "star", macId);
        Assert((await Run(mac, 0, "records", "get", macId)).Flag("starred"), "Mac metadata mutation uses native store");
        await Run(mac, 0, "records", "export", "--output", Path.Combine(root, "mac-export"));
        using (var foreignOwner = new LibraryLease(mac))
            await Run(mac, 5, "records", "star", macId);
        if (fixture != null)
        {
            var pending = await Run(mac, 0, "records", "import", "--image", fixture);
            await Run(mac, 0, "index", "run", "--id", pending.Text("id")!);
            Assert((await Run(mac, 0, "records", "get", pending.Text("id")!)).Text("text")?.Contains("Aurora", StringComparison.OrdinalIgnoreCase) == true, "Native offline OCR decodes and updates the same Mac record");
        }
        Assert((await Run(mac, 0, "storage", "check")).Text("integrity") == "ok", "Native Mac database integrity");
        await Run(mac, 0, "storage", "cleanup", "--scope", "all", "--include-starred", "--yes");
        Assert((await Run(mac, 0, "records", "list")).GetArrayLength() == 0, "Native Mac cleanup");
        Console.WriteLine("Native macOS bridge checks included.");
    }
    Console.WriteLine($"PASS: {tests} CLI process, shared-data, IPC ownership, model and integrity assertions.");
}
finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); Directory.Delete(root, true); }

sealed class FakeModel : IDisposable
{
    readonly TcpListener listener = new(IPAddress.Loopback, 0);
    readonly CancellationTokenSource stop = new();
    public string Url { get; }
    public bool SawEvidence { get; private set; }
    public FakeModel() { listener.Start(); Url = $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/v1"; _ = Serve(); }
    async Task Serve()
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                using var client = await listener.AcceptTcpClientAsync(stop.Token); using var stream = client.GetStream();
                var header = new List<byte>(); var one = new byte[1];
                while (header.Count < 65536 && await stream.ReadAsync(one, stop.Token) > 0) { header.Add(one[0]); if (header.Count >= 4 && header.TakeLast(4).SequenceEqual(new byte[] { 13, 10, 13, 10 })) break; }
                var text = Encoding.UTF8.GetString(header.ToArray());
                var length = text.Split("\r\n").FirstOrDefault(l => l.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase));
                var body = new byte[length == null ? 0 : int.Parse(length.Split(':')[1])]; await stream.ReadExactlyAsync(body, stop.Token);
                SawEvidence |= Encoding.UTF8.GetString(body).Contains("untrusted_memory_records");
                var payload = text.StartsWith("POST /v1/audio/transcriptions") ? "{\"segments\":[{\"start\":2,\"text\":\"Shared transcript\"}]}" : text.StartsWith("GET") ? "{\"data\":[{\"id\":\"test-model\"}]}" : "{\"choices\":[{\"message\":{\"content\":\"A shared memory [1].\"}}]}";
                var response = Encoding.UTF8.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {Encoding.UTF8.GetByteCount(payload)}\r\nConnection: close\r\n\r\n{payload}");
                await stream.WriteAsync(response, stop.Token);
            }
        }
        catch (Exception) when (stop.IsCancellationRequested) { }
    }
    public void Dispose() { stop.Cancel(); listener.Stop(); stop.Dispose(); }
}
