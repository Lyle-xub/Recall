using System.ComponentModel;
using System.Text.Json;
using Rewind;
namespace Recall.Cli;

public static class CliApplication
{
    public const string Help = """
Recall CLI — shared desktop library access (0.5.0)

Usage: recall <command> [arguments] [options]
Global: --data-dir PATH, --json, --help, --version
Default data directory is the desktop application's RewindReplica directory.
RECALL_DATA_DIR overrides that default. Existing libraries are never initialized
or migrated implicitly. Read commands work without the desktop running.

  library info                         Show detected library and owner
  library init [--format macos|windows] Explicitly create a new library
  records list [filters]               List memories (default 100, max 10000)
  search QUERY [filters]               Search shared OCR, metadata and transcripts
  records get ID                       Read a complete memory
  records import --image PATH [--text-file PATH] [--app NAME] [--title TEXT]
                 [--timestamp ISO]     Add a screenshot to the application's library
  records star|trash|restore ID         Toggle a star, trash or restore one memory
  records export --output DIR [filters] Export selected metadata and owned media
  apps                                 List recorded applications
  sessions list                        Read recording sessions
  sessions transcript ID               Read a session's transcript
  ocr image PATH [--language eng]       Recognize a local image using Tesseract
  index run [--id ID] [--limit N] [--language eng]
                                       Run a durable, resumable per-record OCR job
  recording status|start|stop           Control desktop or start a headless recorder
  service start|stop                    Start idle headless owner / stop headless owner
  tasks status                         Inspect durable OCR jobs and owner request receipts
  tasks resume ID                      Resume an interrupted or failed OCR job
  tasks result ID                      Read an OCR job or a timed-out request result
  storage stats|check                  Measure storage / check SQLite integrity
  storage compact --yes                Compact the shared search index
  storage optimize                     Optimize media using the current owner or offline
  storage cleanup --scope trash|older7|older30|all [--include-starred]
                  [--dry-run | --yes]  Preview by default; --yes permanently deletes
  config show                          Read desktop model configuration (no secrets)
  config set KEY VALUE                  Set capture-interval, retention-days, system-audio,
                                       microphone, transcription-enabled, excluded-apps
  models catalog                       List built-in model downloads and readiness
  models download ID                   Resume and verify a catalog model download
  models remove ID --yes               Remove a built-in model while desktop is closed
  models list [model options]          Query the configured model service
  ask QUESTION [--app NAME] [--since ISO] [model options]
  transcribe PATH [--session ID] [--save --yes] [model options]
  doctor                               Show platform, library, owner and engine status

Filters: --app NAME --since ISO --until ISO --starred --trash --demo
         --limit N --offset N --ascending (--query TEXT on records commands)
Model options: --endpoint URL --model NAME --online --builtin --key-env NAME
Online endpoints require HTTPS and explicit --online when overridden.
API keys use RECALL_API_KEY / --key-env, then the desktop credential store.
Endpoint overrides never receive saved desktop keys. Keys are not printed.
Engines: RECALL_TESSERACT, RECALL_MAC_CORE, REWIND_RUNTIME_ROOT, REWIND_MODEL_ROOT.
Recording starts a background owner when needed and never opens a Recall window.
Native macOS retains desktop recording and exclusions. Portable capture uses FFmpeg
(X11/Windows), grim (Wayland), or screencapture (macOS); audio and selected displays
are unsupported. It refuses nonempty excluded-apps; explicitly setting [] permits
whole-display capture. RPC waits are bounded; inspect tasks result after a timeout.
Exit codes: 0 success, 2 usage, 3 not found, 4 unavailable/unsupported,
            5 busy/conflict/confirmation, 6 operation failed, 130 cancelled.
""";

    public static async Task<int> Run(string[] arguments, TextWriter output, TextWriter error, CancellationToken ct = default)
    {
        var json = arguments.Contains("--json");
        try
        {
            var a = new Arguments(arguments);
            json = a.Has("json");
            if (a.Has("help") || a.Words.Count == 0 && !a.Has("version"))
            { if (json) await output.WriteLineAsync(JsonSerializer.Serialize(new { ok = true, result = new { help = Help } }, Wire.Json)); else await output.WriteLineAsync(Help); return 0; }
            if (a.Has("version")) { a.Allow("version", 0); await Print(output, json, new { version = "0.5.0" }); return 0; }
            var root = Path.GetFullPath(a.Get("data-dir") ?? LibraryClient.DefaultRoot);
            AppPaths.DataRoot = root;
            var client = new LibraryClient(root);
            var result = await Execute(a, client, error, ct);
            await Print(output, json, result);
            return 0;
        }
        catch (Exception failure)
        {
            var code = failure switch { RecallException e => e.Code, OperationCanceledException => "cancelled", FileNotFoundException or DirectoryNotFoundException => "not_found", Win32Exception => "engine_missing", JsonException or FormatException => "invalid_data", UnauthorizedAccessException => "permission_denied", _ => "operation_failed" };
            var exit = code switch { "usage" => 2, "not_found" => 3, "unsupported" or "unsupported_schema" or "unsupported_media" or "platform_unavailable" or "capture_unavailable" or "engine_missing" or "service_unavailable" => 4, "busy" or "legacy_owner" or "conflict" or "confirmation_required" => 5, "cancelled" => 130, _ => 6 };
            var message = failure is OperationCanceledException ? "Operation cancelled." : failure.Message;
            if (json) await output.WriteLineAsync(JsonSerializer.Serialize(new { ok = false, error = new { code, message, exitCode = exit, details = (failure as RecallException)?.Details } }, Wire.Json));
            else
            {
                await error.WriteLineAsync($"recall: {code}: {message}");
                if(failure is RecallException {Details:not null} recall)await error.WriteLineAsync(JsonSerializer.Serialize(recall.Details,new JsonSerializerOptions(Wire.Json){WriteIndented=true}));
            }
            return exit;
        }
        finally { LocalInference.Stop(); }
    }
    static Task Print(TextWriter writer, bool json, object result)
    {
        var element = result is JsonElement e ? e : Wire.Element(result);
        return writer.WriteLineAsync(json ? JsonSerializer.Serialize(new { ok = true, result = element }, Wire.Json) : JsonSerializer.Serialize(element, new JsonSerializerOptions(Wire.Json) { WriteIndented = true }));
    }
    static void Confirm(Arguments a) { if (!a.Has("yes")) throw new RecallException("confirmation_required", "This mutation requires --yes."); }
    static async Task<object> Execute(Arguments a, LibraryClient client, TextWriter progress, CancellationToken ct)
    {
        var command = string.Join(' ', a.Words.Take(2));
        if (a.Words[0] == "search")
        {
            a.Allow(Arguments.Filters.Replace("query ",""), 2); var filter = a.Filter(); filter["query"] = a.Words[1]; return await client.Call("list", filter, ct);
        }
        if (a.Words[0] == "ask")
        {
            a.Allow(ModelOptions + " app since", 2);
            var frames = (await client.Call("retrieve", new { query = a.Words[1], app = a.Get("app"), since = a.Date("since") }, ct)).Deserialize<List<MemoryFrame>>(Wire.Json) ?? [];
            var transcripts = new List<TranscriptLine>();
            foreach (var id in frames.Select(f => f.SessionId).Where(id => id != null).Distinct())
            {
                var rows = (await client.Call("transcript", new { id }, ct)).Deserialize<List<TranscriptLine>>(Wire.Json) ?? [];
                transcripts.AddRange(rows.Where(t => frames.Any(f => f.SessionId == id && t.Timestamp >= f.Timestamp.AddSeconds(-30) && t.Timestamp <= (f.EndTimestamp ?? f.Timestamp).AddSeconds(30))));
            }
            var answer = await ModelClient.Answer(a.Words[1], frames, transcripts, [], Profile(client.Root, a, false), await Key(a, false, ct), ct);
            return new { answer, sources = frames.Select(f => new { f.Id, f.Timestamp, f.AppName, f.Title }) };
        }
        if (a.Words[0] == "transcribe")
        {
            a.Allow(ModelOptions + " session save yes", 2);
            if(a.Has("yes") && !a.Has("save"))throw new RecallException("usage","--yes requires --save for transcription.");
            var id = a.Get("session");
            RecordingSession session;
            if (id != null) session = (await client.Call("sessions", new { }, ct)).Deserialize<List<RecordingSession>>(Wire.Json)?.FirstOrDefault(s => s.Id == id) ?? throw new RecallException("not_found", "Session not found.");
            else session = new("cli-transcript", DateTimeOffset.Now, DateTimeOffset.Now, "", true);
            if (a.Has("save")) { Confirm(a); if (id == null) throw new RecallException("usage", "--save requires --session."); }
            var lines = await ModelClient.Transcribe(Path.GetFullPath(a.Words[1]), session, Profile(client.Root, a, true), await Key(a, true, ct), ct);
            if (a.Has("save")) await client.Call("save-transcript", new { id, lines }, ct);
            return new { sessionId = id, saved = a.Has("save"), lines };
        }
        switch (command)
        {
            case "library info": a.Allow("", 2); return new { root = client.Root, format = LibraryFormats.Detect(client.Root).ToString().ToLowerInvariant(), owner = LibraryControlClient.Owner(client.Root), details = await client.Call("info", new { }, ct) };
            case "library init": a.Allow("format", 2); return await client.Initialize(a.Get("format"), ct);
            case "records list": a.Allow(Arguments.Filters, 2); return await client.Call("list", a.Filter(), ct);
            case "records get": case "records star": case "records trash": case "records restore":
                a.Allow("", 3); return await client.Call(a.Words[1], new { id = a.Words[2] }, ct);
            case "records import":
                a.Allow("image text-file title app timestamp", 2);
                return await client.Call("import", new { image = Path.GetFullPath(a.Require("image")), text = a.Get("text-file") is { } textFile ? await File.ReadAllTextAsync(textFile, ct) : "", title = a.Get("title"), app = a.Get("app"), timestamp = a.Date("timestamp") }, ct);
            case "records export": a.Allow(Arguments.Filters + " output", 2); var filter = a.Filter(); filter["output"] = Path.GetFullPath(a.Require("output")); return await client.Call("export", filter, ct);
            case "sessions list": a.Allow("", 2); return await client.Call("sessions", new { }, ct);
            case "sessions transcript": a.Allow("", 3); return await client.Call("transcript", new { id = a.Words[2] }, ct);
            case "ocr image": a.Allow("language", 3); var recognized = await OcrEngine.Recognize(a.Words[2], a.Get("language") ?? "eng", ct); return new { recognized.Text, recognized.Regions };
            case "index run":
                a.Allow("id language limit", 2);
                return await IndexJob.Start(client,a,progress,ct);
            case "recording status":
                a.Allow("", 2); return await OwnerStatus(client.Root,"recording-status",ct) ?? Wire.Element(new { available=false,requested=false,active=false,reason="owner_not_running" });
            case "recording start":
                a.Allow("",2); await HeadlessService.Ensure(client,ct);return await LibraryControlClient.Send(client.Root,"recording-start",new {},ct);
            case "recording stop":
                a.Allow("",2);return await LibraryControlClient.Send(client.Root,"recording-stop",new {},ct);
            case "service start": a.Allow("",2);await HeadlessService.Ensure(client,ct);return LibraryControlClient.Owner(client.Root)!.Value;
            case "service stop": a.Allow("",2);return await LibraryControlClient.Send(client.Root,"service-stop",new {},ct);
            case "tasks status": a.Allow("", 2); return new { local=IndexJob.List(client.Root), requests=LibraryControlClient.Requests(client.Root), desktop=await OwnerStatus(client.Root,"tasks-status",ct) };
            case "tasks resume": a.Allow("",3); return await IndexJob.Read(client.Root,a.Words[2]).Run(client,progress,ct);
            case "tasks result": a.Allow("",3); return IndexJob.Exists(client.Root,a.Words[2]) ? IndexJob.Read(client.Root,a.Words[2]) : LibraryControlClient.Result(client.Root,a.Words[2]);
            case "storage stats": a.Allow("", 2); return LibraryStorage.Measure(client.Root, ct);
            case "storage check": a.Allow("", 2); return await client.Call("check", new { }, ct);
            case "storage compact": a.Allow("yes", 2); Confirm(a); return await client.Call("compact", new { confirmed = true }, ct);
            case "storage optimize":
                a.Allow("",2);LibrarySafety.CheckLegacyDefaultOwner(client.Root);
                if(LibraryControlClient.Owner(client.Root)!=null)return await LibraryControlClient.Send(client.Root,"optimize",new {},ct);
                if(LibraryFormats.Detect(client.Root)==LibraryFormat.MacOS)
                { await HeadlessService.Ensure(client,ct);return await LibraryControlClient.Send(client.Root,"optimize",new {},ct); }
                using(var ownership=new LibraryLease(client.Root))
                using(var database=new MemoryStore(client.Root,initialize:false)) return await PortableMaintenance.Optimize(database,ct);
            case "storage cleanup":
                a.Allow("scope include-starred dry-run yes", 2);
                if (a.Has("dry-run") && a.Has("yes")) throw new RecallException("usage", "Choose --dry-run or --yes, not both.");
                return await client.Call(a.Has("yes") ? "cleanup" : "cleanup-preview", new { scope = a.Require("scope"), includeStarred = a.Has("include-starred"), confirmed = a.Has("yes") }, ct);
            case "config set": a.Allow("",4);return await client.Call("config-set",new {key=a.Words[2],value=a.Words[3]},ct);
            case "config show": a.Allow("", 2); return new { dataDir = client.Root, settingsPath = Path.Combine(client.Root, "settings.json"), chat = Profile(client.Root, a, false), speech = Profile(client.Root, a, true), apiKeyEnvironment = "RECALL_API_KEY" };
            case "models catalog":
                a.Allow("", 2); return BuiltinModels.Shared.Catalog.Select(m => new { m.Id, m.Title, m.Bytes, m.License, m.Source, installed = BuiltinModels.Shared.Installed.Contains(m.Id) }).ToArray();
            case "models download": case "models remove":
            {
                a.Allow(command.EndsWith("remove") ? "yes" : "", 3);
                LibrarySafety.CheckLegacyDefaultOwner(client.Root);
                var models = BuiltinModels.Shared;
                var item = models.Catalog.FirstOrDefault(m => m.Id == a.Words[2]) ?? throw new RecallException("not_found", "Unknown model ID.");
                using var lease = new LibraryLease(client.Root);
                using var inferenceOwnership = new InferenceOwnership(item.Id);
                if (command.EndsWith("remove")) { Confirm(a); models.Remove(item); return new { removed = item.Id }; }
                using var cancel = ct.Register(() => models.Pause(item.Id));
                await models.Download(item); ct.ThrowIfCancellationRequested();
                if (!models.Installed.Contains(item.Id)) throw new RecallException("download_failed", models.Status.GetValueOrDefault(item.Id) ?? "Model download failed.");
                return new { installed = item.Id, path = models.FilePath(item), sha256 = item.Sha256 };
            }
            case "models list": a.Allow(ModelOptions, 2); return await ModelClient.Models(Profile(client.Root, a, false), await Key(a, false, ct), ct);
            case "apps": a.Allow("", 1); return await client.Call("apps", new { }, ct);
            case "doctor":
                a.Allow("", 1); return new { platform = System.Runtime.InteropServices.RuntimeInformation.OSDescription, architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), root = client.Root, format = LibraryFormats.Detect(client.Root).ToString(), macCore = LibraryClient.MacHelper, owner = LibraryControlClient.Owner(client.Root), recording = "Native macOS headless recorder; portable whole-display screenshots require available display/backend, excluded-apps=[] and audio disabled", ocrEngine = Environment.GetEnvironmentVariable("RECALL_TESSERACT") ?? "tesseract (PATH)", nativeRuntimeRoot = Environment.GetEnvironmentVariable("REWIND_RUNTIME_ROOT") ?? Path.Combine(AppContext.BaseDirectory, "runtimes") };
            default: throw new RecallException("usage", "Unknown command. Use recall --help.");
        }
    }
    static async Task<JsonElement?> OwnerStatus(string root,string operation,CancellationToken ct)
    {
        if(LibraryControlClient.Owner(root)==null)return null;
        try {return await LibraryControlClient.Send(root,operation,new {},ct);}
        catch(RecallException e) when(e.Code is "service_unavailable" or "interrupted" or "stale_owner") {return null;}
    }
    const string ModelOptions = "endpoint model online builtin key-env";
    static async Task<string> Key(Arguments a, bool speech, CancellationToken ct)
    {
        var name = a.Get("key-env") ?? "RECALL_API_KEY";
        if (Environment.GetEnvironmentVariable(name) is { } value) return value;
        if (a.Has("key-env") || a.Has("endpoint") || Profile(AppPaths.DataRoot, a, speech).IsBuiltin) return "";
        // Reuse desktop credentials only with its configured endpoint. A CLI
        // endpoint override must never receive a saved desktop secret.
        if (OperatingSystem.IsWindows()) return SecretStore.Read(speech ? "speech" : "chat");
        if (OperatingSystem.IsMacOS())
        {
            var key = await ChildProcess.Run("/usr/bin/security", ["find-generic-password", "-s", "studio.rewind.replica", "-a", speech ? "transcription" : "chat", "-w"], null, ct, 15);
            return key.ExitCode == 0 ? key.Output.TrimEnd('\r', '\n') : "";
        }
        return "";
    }
    static ModelProfile Profile(string root, Arguments a, bool speech)
    {
        ModelProfile profile = speech ? ModelProfile.BuiltinSpeech : ModelProfile.BuiltinChat;
        var path = Path.Combine(root, "settings.json");
        if (File.Exists(path))
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var name = speech ? new[] { "speech", "transcription" } : new[] { "chat" };
            foreach (var property in document.RootElement.EnumerateObject())
                if (name.Contains(property.Name.ToLowerInvariant())) profile = property.Value.Deserialize<ModelProfile>(Wire.Json) ?? profile;
        }
        if (a.Has("builtin") && (a.Has("endpoint") || a.Has("model") || a.Has("online"))) throw new RecallException("usage", "--builtin cannot be combined with endpoint/model/online overrides.");
        if (a.Has("builtin")) return speech ? ModelProfile.BuiltinSpeech : ModelProfile.BuiltinChat;
        if (a.Get("endpoint") is { } endpoint) profile = profile with { Provider = "Custom", BaseUrl = endpoint, IsLocal = !a.Has("online") };
        if (a.Get("model") is { } model) profile = profile with { Provider = profile.IsBuiltin ? "Custom" : profile.Provider, Model = model };
        if (a.Has("online")) profile = profile with { IsLocal = false };
        return profile;
    }
}
