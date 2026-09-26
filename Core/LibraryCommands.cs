using System.Text.Json;
namespace Rewind;

/// GUI-independent operations over the same store used by the Windows desktop.
public static class LibraryCommands
{
    public static bool Writes(string operation) => operation is "import" or "star" or "trash" or "restore" or "recognize" or "compact" or "cleanup" or "save-transcript";
    public static List<MemoryFrame> Select(MemoryStore store, JsonElement args) => store.Frames(
        args.Text("query") ?? "", args.Text("app"), args.Flag("starred"), args.Flag("trash"), args.Flag("demo"),
        Date(args, "since"), Date(args, "until"), args.Number("limit", 100), args.Number("offset", 0), args.Flag("ascending"));
    public static DateTimeOffset? Date(JsonElement args, string name) => args.Text(name) is { } value ? DateTimeOffset.Parse(value, System.Globalization.CultureInfo.InvariantCulture) : null;
    public static MemoryFrame Require(MemoryStore store, JsonElement args) => store.Frame(args.Text("id") ?? "") ?? throw new RecallException("not_found", "The memory does not exist.");
    public static object Execute(MemoryStore store, string operation, JsonElement args)
    {
        switch (operation)
        {
            case "info": return new { root = store.Root, format = "windows", count = store.Count };
            case "list": return Select(store, args);
            case "get": return Require(store, args);
            case "retrieve": return store.Retrieve(args.Text("query") ?? "", app: args.Text("app"), since: Date(args, "since"));
            case "apps": return store.AppNames();
            case "sessions": return store.Sessions();
            case "transcript": return store.Transcript(args.Text("id") ?? "");
            case "import":
            {
                var source = Path.GetFullPath(args.Text("image") ?? throw new RecallException("usage", "An image path is required."));
                if (!File.Exists(source)) throw new FileNotFoundException("Image not found.", source);
                var ext = Path.GetExtension(source).ToLowerInvariant();
                if (ext is not (".png" or ".jpg" or ".jpeg" or ".heic" or ".bmp" or ".webp")) throw new RecallException("unsupported", "Import a PNG, JPEG, HEIC, BMP or WebP image.");
                var id = Guid.NewGuid().ToString();
                var relative = "frames/" + id + ext;
                var target = store.SafePath(relative) ?? throw new RecallException("invalid_path", "Unsafe media folder.");
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                var text = args.Text("text") ?? "";
                var frame = new MemoryFrame { Id = id, ImagePath = relative, Title = args.Text("title") ?? Path.GetFileNameWithoutExtension(source), AppName = args.Text("app") ?? "Imported", Timestamp = Date(args, "timestamp") ?? DateTimeOffset.Now, Text = text, TextState = text.Length > 0 ? RecognitionState.Complete : RecognitionState.Pending };
                File.Copy(source, target, false);
                try { store.Save(frame); } catch { File.Delete(target); throw; }
                return frame;
            }
            case "star":
            {
                var frame = Require(store, args); store.Star(frame.Id); return store.Frame(frame.Id)!;
            }
            case "trash": { var frame = Require(store, args); store.Trash(frame); return store.Frame(frame.Id)!; }
            case "restore": { var frame = Require(store, args); store.Restore(frame); return store.Frame(frame.Id)!; }
            case "recognize":
            {
                var frame = Require(store, args);
                store.Recognized(frame.Id, args.Text("text") ?? "", args.TryGetProperty("regions", out var r) ? r.Deserialize<List<TextRegion>>(Wire.Json) ?? [] : []);
                return store.Frame(frame.Id)!;
            }
            case "save-transcript":
            {
                var id = args.Text("id") ?? "";
                if (store.Session(id) == null) throw new RecallException("not_found", "Recording session not found.");
                var lines = args.GetProperty("lines").Deserialize<List<TranscriptLine>>(Wire.Json) ?? [];
                store.ReplaceTranscript(id, lines); return new { count = lines.Count };
            }
            case "export":
            {
                var destination = ExportDestination(store.Root, args.Text("output") ?? "");
                var frames = Select(store, args); store.Export(destination, frames);
                return new { destination, count = frames.Count, format = "windows" };
            }
            case "check": return new { integrity = store.CheckIntegrity() };
            case "compact": store.CompactIndex(); return new { compacted = true };
            case "cleanup-preview":
            case "cleanup":
            {
                var scope = args.Text("scope") switch { "trash" => CleanupScope.Trash, "older7" => CleanupScope.Older7Days, "older30" => CleanupScope.Older30Days, "all" => CleanupScope.All, _ => throw new RecallException("usage", "Scope must be trash, older7, older30 or all.") };
                var plan = store.CleanupPreview(scope, !args.Flag("includeStarred"));
                if (operation == "cleanup-preview") return new { count = plan.Ids.Length, bytes = plan.Bytes, keepStarred = plan.KeepStarred, ids = plan.Ids };
                if (!args.Flag("confirmed")) throw new RecallException("confirmation_required", "Permanent cleanup requires --yes.");
                return new { removed = store.Cleanup(plan) };
            }
            default: throw new RecallException("unsupported", "Unsupported library operation: " + operation);
        }
    }
    public static string ExportDestination(string root, string destination)
    {
        if (string.IsNullOrWhiteSpace(destination)) throw new RecallException("usage", "An export destination is required.");
        destination = CanonicalPath(destination);
        root = CanonicalPath(root);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        if (destination.Equals(root, comparison) || destination.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar, comparison)) throw new RecallException("invalid_path", "Export outside the live library.");
        if (File.Exists(destination) || Directory.Exists(destination) && Directory.EnumerateFileSystemEntries(destination).Any()) throw new RecallException("conflict", "Export requires a new or empty directory.");
        return destination;
    }
    static string CanonicalPath(string path)
    {
        path = Path.GetFullPath(path);
        var current = Path.GetPathRoot(path)!;
        foreach (var part in path[current.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            if (Directory.Exists(current) || File.Exists(current))
                current = new DirectoryInfo(current).ResolveLinkTarget(true)?.FullName ?? current;
        }
        return Path.TrimEndingDirectorySeparator(current);
    }

}
