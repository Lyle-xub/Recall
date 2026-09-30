using System.Diagnostics;
using System.Text.Json;
using Rewind;
namespace Recall.Cli;

public sealed class LibraryClient(string root)
{
    JsonLineWorker? nativeOcr;
    bool keepOcrWarm;
    bool? supportsOcrSession;
    public IDisposable KeepOcrWarm() { keepOcrWarm = true; return new OcrScope(this); }
    sealed class OcrScope(LibraryClient client) : IDisposable
    {
        public void Dispose() { client.keepOcrWarm = false; client.nativeOcr?.Dispose(); client.nativeOcr = null; }
    }
    public string Root { get; } = Path.GetFullPath(root);
    public static string DefaultRoot => DefaultLibrary.Resolve();
    public static string? MacHelper
    {
        get
        {
            var path = Environment.GetEnvironmentVariable("RECALL_MAC_CORE") ?? Path.Combine(AppContext.BaseDirectory, "recall-macos-core");
            return OperatingSystem.IsMacOS() && File.Exists(path) ? path : null;
        }
    }
    public async Task<JsonElement> Initialize(string? format, CancellationToken ct)
    {
        if (LibraryFormats.Detect(Root) != LibraryFormat.Missing) throw new RecallException("conflict", "A database already exists. Initialization never replaces or migrates an existing library.");
        format ??= OperatingSystem.IsMacOS() ? "macos" : "windows";
        if (format == "macos") return await Native("init", new { }, ct);
        if (format != "windows") throw new RecallException("usage", "Library format must be macos or windows.");
        using var lease = new LibraryLease(Root);
        if (LibraryFormats.Detect(Root) != LibraryFormat.Missing) throw new RecallException("conflict", "A database was created by another process. It was not changed.");
        using var store = new MemoryStore(Root);
        return Wire.Element(LibraryCommands.Execute(store, "info", Wire.Element(new { })));
    }
    public async Task<JsonElement> Call(string operation, object args, CancellationToken ct)
    {
        if(LibraryCommands.Exclusive(operation)) LibrarySafety.CheckLegacyDefaultOwner(Root);
        var format = LibraryFormats.Detect(Root);
        if (format == LibraryFormat.Missing) throw new RecallException("not_found", "No Recall database exists at this data directory. Use library init explicitly to create one.");
        if (format == LibraryFormat.Unknown) throw new RecallException("unsupported_schema", "Unrecognized or ambiguous library schema. No changes were made.");
        if (LibraryCommands.Exclusive(operation) && LibraryControlClient.Owner(Root) != null)
            return await LibraryControlClient.Send(Root, operation, args, ct);
        if (format == LibraryFormat.MacOS) return await Native(operation, args, ct);
        using var lease = LibraryCommands.Exclusive(operation) ? new LibraryLease(Root) : null;
        using var store = new MemoryStore(Root, readOnly: !LibraryCommands.Writes(operation), initialize: false);
        if (operation == "index-one")
        {
            var input = Wire.Element(args);var frame = LibraryCommands.Require(store,input);
            await ArchiveOcr.Recognize(store,frame,input.Text("language") ?? "eng",ct);
            return Wire.Element(new { completed=1,id=frame.Id });
        }
        return Wire.Element(LibraryCommands.Execute(store, operation, Wire.Element(args)));
    }
    async Task<JsonElement> Native(string operation, object args, CancellationToken ct)
    {
        var helper = MacHelper ?? throw new RecallException("platform_unavailable", "This is a native Mac library. Use the macOS CLI bundle with recall-macos-core (or set RECALL_MAC_CORE). Its original schema is preserved.");
        if (keepOcrWarm && operation == "index-one" && supportsOcrSession == null)
        {
            try { supportsOcrSession = (await Native("capabilities", new { }, ct)).Flag("ocrSession"); }
            catch (RecallException error) when (error.Code == "unsupported") { supportsOcrSession = false; }
        }
        JsonElement reply;
        if (keepOcrWarm && operation == "index-one" && supportsOcrSession == true)
        {
            nativeOcr ??= new(() => {var info = new ProcessStartInfo(helper); info.ArgumentList.Add("--core-service"); info.ArgumentList.Add("--core-session"); return info;});
            reply = await nativeOcr.Request(new {root = Root, operation, args}, ct, TimeSpan.FromSeconds(120));
        }
        else
        {
            var result = await ChildProcess.Run(helper, ["--core-service"], JsonSerializer.Serialize(new { root = Root, operation, args }, Wire.Json), ct, LibraryCommands.Writes(operation) ? 0 : 120);
            using var document = JsonDocument.Parse(result.Output); reply = document.RootElement.Clone();
        }
        if (!reply.Flag("ok"))
        {
            var error = reply.GetProperty("error");
            throw new RecallException(error.Text("code") ?? "operation_failed", error.Text("message") ?? "Native core request failed.");
        }
        return reply.GetProperty("result").Clone();
    }
}
