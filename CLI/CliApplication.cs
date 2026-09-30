using System.ComponentModel;
using System.Text.Json;
using Rewind;
namespace Recall.Cli;

public static class CliApplication
{
    public static string Help=>string.Join(Environment.NewLine,CommandHelp.Lines("",new TerminalStyle(new Arguments(["--lang","en"]),new(false,false,80,_=>null))));

    public static async Task<int> Run(string[] arguments, TextWriter output, TextWriter error, CancellationToken ct = default, TerminalEnvironment? terminal = null)
    {
        var json = arguments.Contains("--json");Arguments? a=null;
        terminal??=TerminalEnvironment.Detect(output,error,measureWidth:!json);
        TerminalStyle? humanStyle=null,errorStyle=null;
        try
        {
            a = new Arguments(arguments);json=a.Has("json");
            humanStyle=new(a,terminal);errorStyle=new(a,terminal,true);
            if(CommandHelp.Requested(a))
            {
                var topic=CommandHelp.Resolve(a);
                var lines=CommandHelp.Lines(topic,humanStyle);
                if(json)await PrintJson(output,new {help=string.Join(Environment.NewLine,lines)});
                else new HumanOutput(output,humanStyle,a).Help(lines);
                return 0;
            }
            if(a.Has("version"))
            {a.Allow("version",0);if(json)await PrintJson(output,new {version=CommandHelp.Version});else new HumanOutput(output,humanStyle,a).Render(new {version=CommandHelp.Version});return 0;}
            var commandTopic = CommandHelp.Find(a.Words) ?? throw new RecallException("usage", "Unknown command. Use recall help.");
            a.Allow(commandTopic.Options, commandTopic.Words);
            var root=Path.GetFullPath(a.Get("data-dir")??(commandTopic.Name == "ocr image" ? Environment.GetEnvironmentVariable("RECALL_DATA_DIR") ?? DefaultLibrary.Platform.Current : LibraryClient.DefaultRoot));
            using var location = commandTopic.Name == "ocr image" ? null : LibraryLocationLease.Access(root);
            AppPaths.DataRoot=root;
            var client=new LibraryClient(root);
            var progress=json?error:new HumanOutput(error,errorStyle,a).Progress();
            var result=await Execute(a,client,progress,ct);
            if(json)await PrintJson(output,result);else new HumanOutput(output,humanStyle,a).Render(result);
            return 0;
        }
        catch(Exception failure)
        {
            var code = failure switch { RecallException e => e.Code, OperationCanceledException => "cancelled", FileNotFoundException or DirectoryNotFoundException => "not_found", Win32Exception => "engine_missing", JsonException or FormatException => "invalid_data", UnauthorizedAccessException => "permission_denied", _ => "operation_failed" };
            var exit = code switch { "usage" => 2, "not_found" => 3, "unsupported" or "unsupported_schema" or "unsupported_media" or "platform_unavailable" or "capture_unavailable" or "engine_missing" or "service_unavailable" => 4, "busy" or "legacy_owner" or "conflict" or "confirmation_required" => 5, "cancelled" => 130, _ => 6 };
            var message=failure is OperationCanceledException?"Operation cancelled.":failure.Message;
            if(json)await output.WriteLineAsync(JsonSerializer.Serialize(new {ok=false,error=new {code,message,exitCode=exit,details=(failure as RecallException)?.Details}},Wire.Json));
            else new HumanOutput(error,errorStyle??new TerminalStyle(null,terminal,true),a).Error(code,message,(failure as RecallException)?.Details,exit);
            return exit;
        }
        finally {LocalInference.Stop();}
    }
    static Task PrintJson(TextWriter writer,object result)
    {
        var element=result is JsonElement e?e:Wire.Element(result);
        return writer.WriteLineAsync(JsonSerializer.Serialize(new {ok=true,result=element},Wire.Json));
    }
    static async Task<object> List(Arguments a,LibraryClient client,string? query,CancellationToken ct)
    {
        var filter=a.Filter(a.Has("json")?100:10);if(query!=null)filter["query"]=query;
        if(a.Has("json"))return await client.Call("list",filter,ct);
        int limit=(int)filter["limit"]!,offset=(int)filter["offset"]!;
        filter["limit"]=Math.Min(10000,limit+1);
        var rows=(await client.Call("list",filter,ct)).EnumerateArray().Select(e=>e.Clone()).ToArray();
        bool more=rows.Length>limit;
        if(limit==10000 && rows.Length==limit && (long)offset+limit<=int.MaxValue)
        {filter["limit"]=1;filter["offset"]=offset+limit;more=(await client.Call("list",filter,ct)).GetArrayLength()>0;}
        return new HumanPage(rows.Take(limit).ToArray(),offset,limit,more,query??a.Get("query")??"");
    }
    static void Confirm(Arguments a) { if (!a.Has("yes")) throw new RecallException("confirmation_required", "This mutation requires --yes."); }
    static async Task<object> Execute(Arguments a, LibraryClient client, TextWriter progress, CancellationToken ct)
    {
        var command = string.Join(' ', a.Words.Take(2));
        if (a.Words[0] == "search")
        {
            a.Allow(Arguments.Filters.Replace("query ",""), 2);return await List(a,client,a.Words[1],ct);
        }
        if (a.Words[0] == "ask")
        {
            a.Allow(ModelOptions + " app since", 2);
            var evidence = (await client.Call("evidence", new { query = a.Words[1], app = a.Get("app"), since = a.Date("since") }, ct)).Deserialize<RecallEvidence>(Wire.Json) ?? new([], [], "");
            var frames = evidence.Sources;
            var answer = frames.Count == 0 ? RecallPrompt.NoEvidence(a.Words[1]) : await ModelClient.Answer(a.Words[1], frames, evidence.Transcripts, [], Profile(client.Root, a, false), await Key(a, false, ct), ct, context:evidence.Context);
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
            case "records list": a.Allow(Arguments.Filters, 2); return await List(a,client,null,ct);
            case "records get": case "records star": case "records trash": case "records restore":
                a.Allow("", 3); return await client.Call(a.Words[1], new { id = a.Words[2] }, ct);
            case "records import":
                a.Allow("image text-file title app timestamp", 2);
                var original = Path.GetFullPath(a.Require("image"));
                using (var imported = await PortableImage.OpenFile(original, ct:ct))
                    return await client.Call("import", new { image = imported.Path, text = a.Get("text-file") is { } textFile ? await File.ReadAllTextAsync(textFile, ct) : "", title = a.Get("title") ?? Path.GetFileNameWithoutExtension(original), app = a.Get("app"), timestamp = a.Date("timestamp") }, ct);
            case "records export": a.Allow(Arguments.Filters + " output", 2); var filter = a.Filter(); filter["output"] = Path.GetFullPath(a.Require("output")); return await client.Call("export", filter, ct);
            case "sessions list": a.Allow("", 2); return await client.Call("sessions", new { }, ct);
            case "sessions transcript": a.Allow("", 3); return await client.Call("transcript", new { id = a.Words[2] }, ct);
            case "ocr image":
                a.Allow("language", 3);
                using (var image = await PortableImage.OpenFile(a.Words[2], a.Get("data-dir") ?? Environment.GetEnvironmentVariable("RECALL_DATA_DIR"), ct))
                {
                    var recognized = await OcrEngine.Recognize(image.Path, a.Get("language") ?? "eng", ct);
                    return new { recognized.Text, recognized.Regions };
                }
            case "index run":
                a.Allow("id language limit", 2);
                return await IndexJob.Start(client,a,progress,ct);
            case "recording status":
                a.Allow("", 2); return await OwnerStatus(client.Root,"recording-status",ct) ?? Wire.Element(new { available=false,requested=false,active=false,reason="owner_not_running" });
            case "recording start":
                a.Allow("",2); await HeadlessService.Ensure(client,ct,preferWindowsNative:true);return await LibraryControlClient.Send(client.Root,"recording-start",new {},ct);
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
                a.Allow("", 1); return new { platform = System.Runtime.InteropServices.RuntimeInformation.OSDescription, architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), root = client.Root, format = LibraryFormats.Detect(client.Root).ToString(), macCore = LibraryClient.MacHelper, windowsApp = WindowsDesktop.Discover(), archiveDecoder = Environment.GetEnvironmentVariable("RECALL_FFMPEG") ?? "ffmpeg (PATH; exact video frames and packed tiles)", owner = LibraryControlClient.Owner(client.Root), recording = "Native macOS helper or installed Windows desktop preferred for recording start; otherwise portable whole-display screenshots require available display/backend, excluded-apps=[] and audio disabled", ocrEngine = Environment.GetEnvironmentVariable("RECALL_TESSERACT") ?? "tesseract (PATH)", nativeRuntimeRoot = Environment.GetEnvironmentVariable("REWIND_RUNTIME_ROOT") ?? Path.Combine(AppContext.BaseDirectory, "runtimes") };
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
