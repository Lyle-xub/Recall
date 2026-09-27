using System.Diagnostics;
using System.Text.Json;
using Rewind;
namespace Recall.Cli;

public sealed class LibraryClient(string root)
{
    public string Root { get; } = Path.GetFullPath(root);
    public static string DefaultRoot => Environment.GetEnvironmentVariable("RECALL_DATA_DIR") ?? (OperatingSystem.IsMacOS()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support", "RewindReplica")
        : OperatingSystem.IsWindows() ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RewindReplica")
        : Path.Combine(Environment.GetEnvironmentVariable("XDG_DATA_HOME") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share"), "RewindReplica"));
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
            var path = store.SafePath(frame.ImagePath) ?? throw new RecallException("invalid_path","Unsafe image path.");
            var result = await OcrEngine.Recognize(path,input.Text("language") ?? "eng",ct);
            store.Recognized(frame.Id,result.Text,result.Regions);return Wire.Element(new { completed=1,id=frame.Id });
        }
        return Wire.Element(LibraryCommands.Execute(store, operation, Wire.Element(args)));
    }
    async Task<JsonElement> Native(string operation, object args, CancellationToken ct)
    {
        var helper = MacHelper ?? throw new RecallException("platform_unavailable", "This is a native Mac library. Use the macOS CLI bundle with recall-macos-core (or set RECALL_MAC_CORE). Its original schema is preserved.");
        var result = await ChildProcess.Run(helper, ["--core-service"], JsonSerializer.Serialize(new { root = Root, operation, args }, Wire.Json), ct, LibraryCommands.Writes(operation) ? 0 : 120);
        using var document = JsonDocument.Parse(result.Output);
        if (result.ExitCode != 0 || !document.RootElement.Flag("ok"))
        {
            var error = document.RootElement.GetProperty("error");
            throw new RecallException(error.Text("code") ?? "operation_failed", error.Text("message") ?? "Native core request failed.");
        }
        return document.RootElement.GetProperty("result").Clone();
    }
}
