using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Data.Sqlite;
namespace Rewind;

/// Location migration only: the original schema and every WAL, media file and receipt move together.
public sealed class DefaultLibrary(string parent)
{
    public string Parent { get; } = Path.GetFullPath(parent);
    public string Current => Path.Combine(Parent, "Recall");
    public string Legacy => Path.Combine(Parent, "RewindReplica");
    public static DefaultLibrary Platform => new(OperatingSystem.IsMacOS()
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support")
        : OperatingSystem.IsWindows() ? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
        : Environment.GetEnvironmentVariable("XDG_DATA_HOME") is { Length: > 0 } xdg && Path.IsPathFullyQualified(xdg) ? xdg
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share"));
    public static string Resolve(string? explicitRoot = null) => !string.IsNullOrWhiteSpace(explicitRoot ?? Environment.GetEnvironmentVariable("RECALL_DATA_DIR"))
        ? Path.GetFullPath(explicitRoot ?? Environment.GetEnvironmentVariable("RECALL_DATA_DIR")!) : Platform.ResolveDefault();
    public bool Contains(string root) => Equal(root, Current) || Equal(root, Legacy);
    static bool Equal(string a, string b) => Canonical(a).Equals(Canonical(b), OperatingSystem.IsWindows() || OperatingSystem.IsMacOS() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    internal static string Canonical(string path)
    {
        var full=Path.GetFullPath(path);var current=Path.GetPathRoot(full)!;
        foreach(var component in full[current.Length..].Split(Path.DirectorySeparatorChar,StringSplitOptions.RemoveEmptyEntries))
        {
            current=Path.Combine(current,component);
            if(Directory.Exists(current)) current=new DirectoryInfo(current).ResolveLinkTarget(true)?.FullName ?? current;
        }
        return Path.TrimEndingDirectorySeparator(current);
    }
    internal bool Owns(string path) => Equal(path,Legacy) || Canonical(path).StartsWith(Canonical(Legacy) + Path.DirectorySeparatorChar, OperatingSystem.IsWindows() || OperatingSystem.IsMacOS() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
    internal static bool Exists(string path) => Path.Exists(path);
    public string ResolveDefault(Action? checkProcesses = null)
    {
        if (!Exists(Legacy)) return Current;
        using var access = new LibraryLocationLease(Parent, exclusive: true);
        if (!Exists(Legacy)) return Current;
        if (Exists(Current)) throw new RecallException("conflict", $"Both library directories exist: {Legacy} and {Current}. Neither was changed. Select one with --data-dir; do not merge them automatically.");
        if (!Directory.Exists(Legacy) || (File.GetAttributes(Legacy) & FileAttributes.ReparsePoint) != 0)
            throw new RecallException("invalid_path", "The old default library must be a real directory, not a symbolic link.");
        (checkProcesses ?? CheckProcesses)();
        using var writer = new LibraryLease(Legacy, coordinate: false);
        var engines = new List<LibraryLease>();
        try
        {
            if (checkProcesses == null)
                foreach (var engine in new[] { "chat", "speech" })
                {
                    if (!Directory.Exists(InferenceOwnership.Root(engine))) continue;
                    engines.Add(new LibraryLease(InferenceOwnership.Root(engine)));
                    var info = InferenceOwnership.Read(engine);
                    if (info != null && (InferenceOwnership.Matches(info.OwnerPid, info.OwnerStarted) || InferenceOwnership.Matches(info.Pid, info.Started)))
                        throw new RecallException("busy", "Close the active Recall model engine before moving the default library.");
                }
            var modelRoot = Environment.GetEnvironmentVariable("REWIND_MODEL_ROOT");
            if (modelRoot != null && Owns(modelRoot))
                throw new RecallException("conflict", "REWIND_MODEL_ROOT points inside the old default library. Update or remove that override before migration.");
            ValidateMedia(Legacy);
            // Directory.Move never falls back to a recursive copy. Keep the source writer lease held.
            try { MoveExclusive(Legacy, Current); }
            catch (IOException e) { throw new RecallException("conflict", "Could not atomically rename the default library. The original was retained; close all Recall processes and check that both paths are on the same volume. " + e.Message); }
            return Current;
        }
        finally { foreach (var engine in engines) engine.Dispose(); }
    }
    [DllImport("libc", SetLastError=true, EntryPoint="renamex_np")] static extern int RenameMac(string source,string destination,uint flags);
    [DllImport("libc", SetLastError=true, EntryPoint="renameat2")] static extern int RenameLinux(int sourceDirectory,string source,int destinationDirectory,string destination,uint flags);
    static void MoveExclusive(string source,string destination)
    {
        if(OperatingSystem.IsWindows()) {Directory.Move(source,destination);return;}
        try
        {
            // macOS RENAME_EXCL=4; Linux RENAME_NOREPLACE=1 and AT_FDCWD=-100.
            var result=OperatingSystem.IsMacOS()?RenameMac(source,destination,4):RenameLinux(-100,source,-100,destination,1);
            if(result!=0)throw new IOException("Atomic no-replace rename failed (errno "+Marshal.GetLastPInvokeError()+").");
        }
        catch(EntryPointNotFoundException) {throw new IOException("This platform does not provide an atomic no-replace directory rename.");}
    }
    static void CheckProcesses()
    {
        foreach (var process in Process.GetProcesses()) using (process)
        {
            if (process.Id == Environment.ProcessId) continue;
            string name;
            try { name = process.ProcessName; } catch { continue; }
            bool hosted=false;
            if(name.Equals("dotnet",StringComparison.OrdinalIgnoreCase))
            {
                var command=ManagedCommandLine(process);
                if(command==null)throw new RecallException("busy", $"Cannot verify the running .NET host {process.Id}. Close older Recall CLI commands before moving the default library.");
                hosted=command.Contains("recall.dll",StringComparison.OrdinalIgnoreCase)||command.Contains("RewindReplica.dll",StringComparison.OrdinalIgnoreCase);
            }
            if (hosted || new[] { "Recall", "RewindReplica", "recall-macos-core", "recall-ocr", "recall-headless" }.Contains(name, StringComparer.OrdinalIgnoreCase))
                throw new RecallException("busy", $"Close all Recall applications and CLI commands before moving the default library (process {process.Id}: {name}).");
        }
    }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process,int information,IntPtr buffer,int length,out int returned);
    static string? ManagedCommandLine(Process process)
    {
        try
        {
            if(OperatingSystem.IsLinux())return File.ReadAllText($"/proc/{process.Id}/cmdline");
            if(OperatingSystem.IsMacOS())
            {
                var info=new ProcessStartInfo("/bin/ps") {RedirectStandardOutput=true,RedirectStandardError=true,UseShellExecute=false};
                foreach(var arg in new[]{"-p",process.Id.ToString(),"-o","command="})info.ArgumentList.Add(arg);
                using var ps=Process.Start(info)!;var text=ps.StandardOutput.ReadToEnd();ps.WaitForExit();return ps.ExitCode==0?text:null;
            }
            NtQueryInformationProcess(process.Handle,60,IntPtr.Zero,0,out var size);
            if(size<=0||size>1_048_576)return null;
            var buffer=Marshal.AllocHGlobal(size);
            try {if(NtQueryInformationProcess(process.Handle,60,buffer,size,out _)!=0)return null;return Marshal.PtrToStringUni(Marshal.ReadIntPtr(buffer,IntPtr.Size), (ushort)Marshal.ReadInt16(buffer)/2);}
            finally {Marshal.FreeHGlobal(buffer);}
        }
        catch(Exception e) when(e is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidOperationException) {return null;}
    }
    internal static void ValidateMedia(string root)
    {
        var file = Path.Combine(root, "memory.sqlite");
        if (!File.Exists(file)) return;
        using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = file, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
        db.Open();
        using var transaction = db.BeginTransaction(deferred: true);
        var tables = new Dictionary<string, HashSet<string>>();
        using (var cmd = db.CreateCommand())
        {
            cmd.Transaction = transaction; cmd.CommandText = "SELECT m.name,p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type IN ('table','view')";
            using var rows = cmd.ExecuteReader();
            while (rows.Read()) { var table = rows.GetString(0); if (!tables.TryGetValue(table, out var columns)) tables[table] = columns = []; columns.Add(rows.GetString(1)); }
        }
        void Scan(string table, string expression, Action<string> check)
        {
            using var cmd = db.CreateCommand(); cmd.Transaction = transaction; cmd.CommandText = $"SELECT {expression} FROM {table}";
            using var rows = cmd.ExecuteReader(); while (rows.Read()) for (int i = 0; i < rows.FieldCount; i++) if (!rows.IsDBNull(i)) check(rows.GetString(i));
        }
        var manifests = new HashSet<string>();
        void PathValue(string path)
        {
            if (path.Length == 0) return;
            if (path.StartsWith('/') || path.StartsWith('\\') || path.Contains(':') || path.Split('/', '\\').Any(p => p == ".."))
                throw new RecallException("invalid_path", $"A persisted media reference is not library-relative: {path}. The original library was not moved. Repair this reference or use --data-dir with the original directory.");
            var componentPath = root;
            foreach (var component in path.Split('/', '\\'))
            {
                componentPath = Path.Combine(componentPath, component);
                if (Path.Exists(componentPath) && (File.GetAttributes(componentPath) & FileAttributes.ReparsePoint) != 0)
                    throw new RecallException("invalid_path", "A media reference contains a symbolic link; the original library was not moved: " + path);
            }
            if (path.EndsWith(".recallframe") || path.EndsWith(".recallvideo")) manifests.Add(path);
        }
        foreach (var table in new[] { "frames", "sessions" }) if (tables.GetValueOrDefault(table)?.Contains("json") == true)
            Scan(table, "json", json => {
                using var doc = JsonDocument.Parse(json);
                foreach (var property in doc.RootElement.EnumerateObject())
                    if (new[] { "imagepath", "meetingimagepath", "videopath", "systemaudiopath", "microphoneaudiopath", "supersededvideopath" }.Contains(property.Name.ToLowerInvariant()) && property.Value.ValueKind == JsonValueKind.String) PathValue(property.Value.GetString()!);
            });
        foreach (var (table, columns) in new[] { ("image_paths", new[] { "path" }), ("image_archives", new[] { "source", "destination" }), ("image_archive_staging", new[] { "destination" }), ("image_tiles", new[] { "image", "tile" }) })
            if (tables.TryGetValue(table, out var actual)) foreach (var column in columns.Where(actual.Contains)) Scan(table, column, PathValue);
        var journals = new List<(string File, string Key)>();
        var control = Path.Combine(root,".recall-control");
        if(Directory.Exists(control)) journals.AddRange(Directory.EnumerateFiles(control,"cleanup-*.json").Select(p=>(p,"files")));
        journals.AddRange(Directory.EnumerateDirectories(root,".cleanup-*").Select(p=>(Path.Combine(p,"journal.json"),"paths")));
        foreach(var (journal,key) in journals.Where(j=>File.Exists(j.File)))
        {
            using var doc=JsonDocument.Parse(File.ReadAllText(journal));
            foreach(var property in doc.RootElement.EnumerateObject())
                if(property.Name.Equals(key,StringComparison.OrdinalIgnoreCase) && property.Value.ValueKind==JsonValueKind.Array)
                    foreach(var item in property.Value.EnumerateArray()) if(item.ValueKind==JsonValueKind.String)PathValue(item.GetString()!);
        }
        foreach (var path in manifests.ToArray())
        {
            var full = Path.Combine(root, path);
            if (!File.Exists(full)) continue; // Missing media is a pre-existing integrity issue, not a relocation change.
            using var doc = JsonDocument.Parse(File.ReadAllText(full));
            void Walk(JsonElement value)
            {
                if (value.ValueKind == JsonValueKind.Object) foreach (var p in value.EnumerateObject()) { if (p.Value.ValueKind == JsonValueKind.String && p.Name is "path" or "video") PathValue(p.Value.GetString()!); else Walk(p.Value); }
                else if (value.ValueKind == JsonValueKind.Array) foreach (var item in value.EnumerateArray()) Walk(item);
            }
            Walk(doc.RootElement);
        }
    }
}

/// Shared by Swift and .NET. Outside the renamed folder; flock on Unix, share modes on Windows.
public sealed class LibraryLocationLease : IDisposable
{
    readonly FileStream file;
    bool disposed;
    [DllImport("libc", SetLastError = true)] static extern int flock(int fd, int operation);
    public static LibraryLocationLease? Access(string root, DefaultLibrary? locations = null, bool createParent = false)
    {
        var pair=locations ?? DefaultLibrary.Platform;
        return pair.Contains(root) && (createParent || Directory.Exists(pair.Parent)) ? new(pair.Parent, false) : null;
    }
    public LibraryLocationLease(string parent, bool exclusive)
    {
        Directory.CreateDirectory(parent);
        var path = Path.Combine(parent, ".Recall-library-location.lock");
        if (Path.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new RecallException("invalid_path", "Library location lock must not be a symbolic link.");
        FileStream? opened = null;
        try
        {
            opened = new(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, exclusive && OperatingSystem.IsWindows() ? FileShare.None : FileShare.ReadWrite | FileShare.Delete);
            if (!OperatingSystem.IsWindows())
            {
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                if (flock(opened.SafeFileHandle.DangerousGetHandle().ToInt32(), (exclusive ? 2 : 1) | 4) != 0) throw new IOException("Library location is in use.");
            }
            file = opened;
        }
        catch (IOException) { opened?.Dispose(); throw new RecallException("busy", "The default library is in use or being moved. Close other Recall commands and retry."); }
        catch { opened?.Dispose(); throw; }
    }
    public void Dispose() { if (disposed) return; disposed = true; if (!OperatingSystem.IsWindows()) flock(file.SafeFileHandle.DangerousGetHandle().ToInt32(), 8); file.Dispose(); }
}
