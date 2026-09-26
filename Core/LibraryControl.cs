using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
namespace Rewind;

public sealed class RecallException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

public static class Wire
{
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
    public static JsonElement Element(object value) => JsonSerializer.SerializeToElement(value, Json);
    public static string? Text(this JsonElement value, string key) => value.TryGetProperty(key, out var field) && field.ValueKind != JsonValueKind.Null ? field.GetString() : null;
    public static bool Flag(this JsonElement value, string key) => value.TryGetProperty(key, out var field) && field.ValueKind == JsonValueKind.True;
    public static int Number(this JsonElement value, string key, int fallback) => value.TryGetProperty(key, out var field) ? field.GetInt32() : fallback;
    public static void Atomic(string path, object value)
    {
        var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temp, JsonSerializer.Serialize(value, Json)); if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temp, UnixFileMode.UserRead | UnixFileMode.UserWrite); File.Move(temp, path, true); }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}

/// One OS-released lease covers a desktop owner or an offline CLI mutation.
/// Unix flock is also used by the Swift adapter; PID files are never locks.
public sealed class LibraryLease : IDisposable
{
    readonly FileStream file;
    int released;
    public string DirectoryPath { get; }
    [DllImport("libc", SetLastError = true)] static extern int flock(int fd, int operation);
    public LibraryLease(string root)
    {
        DirectoryPath = Path.Combine(root, ".recall-control");
        Directory.CreateDirectory(DirectoryPath);
        if ((File.GetAttributes(DirectoryPath) & FileAttributes.ReparsePoint) != 0) throw new RecallException("invalid_path", "The control directory must not be a symbolic link.");
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(DirectoryPath, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var path = Path.Combine(DirectoryPath, "lease");
        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new RecallException("invalid_path", "The control lease must not be a symbolic link.");
        FileStream? opened = null;
        try
        {
            opened = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite);
            if (OperatingSystem.IsWindows()) opened.Lock(0, 1);
            else if (flock(opened.SafeFileHandle.DangerousGetHandle().ToInt32(), 2 | 4) != 0) throw new IOException("Library is owned by another process.");
            file = opened;
        }
        catch (IOException) { opened?.Dispose(); throw new RecallException("busy", "The application or another CLI command owns this library. Retry after its current operation finishes."); }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref released, 1) != 0) return;
        if (OperatingSystem.IsWindows()) file.Unlock(0, 1);
        else flock(file.SafeFileHandle.DangerousGetHandle().ToInt32(), 8);
        file.Dispose();
    }
}

public sealed class LibraryControlHost : IDisposable
{
    readonly LibraryLease lease;
    readonly FileSystemWatcher watcher;
    readonly SemaphoreSlim gate = new(1, 1);
    readonly Func<string, JsonElement, Task<object>> handler;
    readonly string instance = Guid.NewGuid().ToString("N");
    bool disposed;
    public LibraryControlHost(string root, string backend, Func<string, JsonElement, Task<object>> handler, LibraryLease? ownership = null)
    {
        lease = ownership ?? new(root); this.handler = handler;
        watcher = new(lease.DirectoryPath, "*.request.json") { NotifyFilter = NotifyFilters.FileName, EnableRaisingEvents = true };
        watcher.Created += (_, _) => _ = Drain(); watcher.Renamed += (_, _) => _ = Drain();
        Wire.Atomic(Path.Combine(lease.DirectoryPath, "owner.json"), new { protocol = 1, pid = Environment.ProcessId, instance, backend });
    }
    async Task Drain()
    {
        await gate.WaitAsync();
        try
        {
            if (disposed) return;
            foreach (var path in Directory.EnumerateFiles(lease.DirectoryPath, "*.request.json").Take(32))
            {
                if (disposed) break;
                var id = Path.GetFileName(path).Replace(".request.json", "");
                if (!Guid.TryParseExact(id, "N", out _)) continue;
                object response;
                try
                {
                    if (new FileInfo(path).Length > 2_000_000 || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new RecallException("invalid_request", "Invalid control request.");
                    using var doc = JsonDocument.Parse(await File.ReadAllTextAsync(path));
                    var request = doc.RootElement;
                    if (request.Text("instance") != instance) throw new RecallException("stale_owner", "The application restarted; retry this request.");
                    var result = await handler(request.Text("operation") ?? "", request.GetProperty("args").Clone());
                    response = new { ok = true, result };
                }
                catch (Exception error) { response = new { ok = false, error = new { code = (error as RecallException)?.Code ?? "operation_failed", message = error.Message } }; }
                Wire.Atomic(Path.Combine(lease.DirectoryPath, id + ".response.json"), response);
                File.Delete(path);
            }
        }
        finally { gate.Release(); }
    }
    public void ReleaseOwnership() => lease.Dispose();
    public async Task Stop(bool releaseOwnership = true)
    {
        disposed = true; watcher.Dispose();
        // Shutdown callers await their native jobs before releasing ownership.
        await gate.WaitAsync();
        try { File.Delete(Path.Combine(lease.DirectoryPath, "owner.json")); if (releaseOwnership) ReleaseOwnership(); }
        finally { gate.Release(); }
    }
    public void Dispose() => Stop().GetAwaiter().GetResult();
}

public static class LibraryControlClient
{
    public static JsonElement? Owner(string root)
    {
        var path = Path.Combine(root, ".recall-control", "owner.json");
        if (!File.Exists(path)) return null;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            var owner = document.RootElement;
            using var process = Process.GetProcessById(owner.Number("pid", -1));
            return !process.HasExited && owner.Number("protocol", 0) == 1 ? owner.Clone() : null;
        }
        catch (Exception error) when (error is IOException or JsonException or ArgumentException or InvalidOperationException) { return null; }
    }
    public static async Task<JsonElement> Send(string root, string operation, object args, CancellationToken ct)
    {
        var owner = Owner(root) ?? throw new RecallException("service_unavailable", "Recall is not running for this library. Start the desktop application to use recording and background-task controls.");
        var directory = Path.Combine(root, ".recall-control");
        var id = Guid.NewGuid().ToString("N");
        var request = Path.Combine(directory, id + ".request.json");
        var reply = Path.Combine(directory, id + ".response.json");
        Wire.Atomic(request, new { instance = owner.Text("instance"), operation, args });
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
            deadline.CancelAfter(TimeSpan.FromMinutes(2));
            while (!File.Exists(reply)) await Task.Delay(50, deadline.Token);
            using var response = JsonDocument.Parse(await File.ReadAllTextAsync(reply, ct));
            if (!response.RootElement.Flag("ok"))
            {
                var error = response.RootElement.GetProperty("error");
                throw new RecallException(error.Text("code") ?? "operation_failed", error.Text("message") ?? "Application request failed.");
            }
            return response.RootElement.GetProperty("result").Clone();
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new RecallException("timeout", "Application request timed out. Its operation may still finish; inspect state before retrying a mutation."); }
        finally { if (File.Exists(request)) File.Delete(request); if (File.Exists(reply)) File.Delete(reply); }
    }
}
