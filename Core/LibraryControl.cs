using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
namespace Rewind;

public sealed class RecallException(string code, string message, object? details = null) : Exception(message)
{
    public string Code { get; } = code;
    public object? Details { get; } = details;
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
        Wire.Atomic(Path.Combine(lease.DirectoryPath, "owner.json"), new { protocol = 1, pid = Environment.ProcessId, started = InferenceOwnership.Started(Environment.ProcessId), instance, backend });
        _ = Drain();
    }
    async Task Drain()
    {
        await gate.WaitAsync();
        try
        {
            if (disposed) return;
            foreach (var path in Directory.EnumerateFiles(lease.DirectoryPath, "*.request.json"))
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
                    if (File.Exists(Path.Combine(lease.DirectoryPath,id+".cancel"))) throw new RecallException("cancelled","Request cancelled before it started.");
                    Wire.Atomic(Path.Combine(lease.DirectoryPath,id+".task.json"),new { id, operation=request.Text("operation"), state="running", ownerPid=Environment.ProcessId, instance, updated=DateTimeOffset.UtcNow });
                    var result = await handler(request.Text("operation") ?? "", request.GetProperty("args").Clone());
                    response = new { ok = true, result };
                }
                catch (Exception error) { response = new { ok = false, error = new { code = (error as RecallException)?.Code ?? "operation_failed", message = error.Message } }; }
                Wire.Atomic(Path.Combine(lease.DirectoryPath, id + ".response.json"), response);
                Wire.Atomic(Path.Combine(lease.DirectoryPath,id+".task.json"),new { id, state="finished", ownerPid=Environment.ProcessId, instance, updated=DateTimeOffset.UtcNow });
                File.Delete(path);File.Delete(Path.Combine(lease.DirectoryPath,id+".cancel"));
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
            return !process.HasExited && owner.Number("protocol", 0) == 1 && (!owner.TryGetProperty("started", out var started) || InferenceOwnership.Matches(process.Id, started.GetInt64())) ? owner.Clone() : null;
        }
        catch (Exception error) when (error is IOException or JsonException or ArgumentException or InvalidOperationException) { return null; }
    }
    static string RequestPath(string root,string id,string suffix)
    {
        if (!Guid.TryParseExact(id,"N",out _)) throw new RecallException("usage","Invalid request ID.");
        return Path.Combine(root,".recall-control",id+suffix);
    }
    public static object[] Requests(string root)
    {
        var folder=Path.Combine(root,".recall-control");
        if (!Directory.Exists(folder)) return [];
        return Directory.EnumerateFiles(folder,"*.task.json").OrderByDescending(File.GetLastWriteTimeUtc).Take(100).Select(path=>Result(root,Path.GetFileName(path).Replace(".task.json",""))).ToArray();
    }
    public static object Result(string root,string id)
    {
        var reply=RequestPath(root,id,".response.json");
        if(File.Exists(reply)) { using var response=JsonDocument.Parse(File.ReadAllText(reply)); return response.RootElement.Clone(); }
        var path=RequestPath(root,id,".task.json");
        if(!File.Exists(path)) throw new RecallException("not_found","Request receipt not found.");
        using var task=JsonDocument.Parse(File.ReadAllText(path));
        var owner=Owner(root);
        var current=owner != null && owner.Value.Text("instance")==task.RootElement.Text("instance");
        return new {id,state=current?task.RootElement.Text("state"):"interrupted",completionKnown=false};
    }
    public static async Task<JsonElement> Send(string root, string operation, object args, CancellationToken ct, string? requestId = null, TimeSpan? timeout = null)
    {
        var id=requestId??Guid.NewGuid().ToString("N");
        var request=RequestPath(root,id,".request.json");var reply=RequestPath(root,id,".response.json");
        JsonElement Response()
        {
            using var response=JsonDocument.Parse(File.ReadAllText(reply));
            if(!response.RootElement.Flag("ok"))
            {
                var error=response.RootElement.GetProperty("error");
                throw new RecallException(error.Text("code")??"operation_failed",error.Text("message")??"Application request failed.",new {requestId=id,result=$"recall tasks result {id}"});
            }
            return response.RootElement.GetProperty("result").Clone();
        }
        if(File.Exists(reply)) return Response();
        var owner=Owner(root)??throw new RecallException("service_unavailable","Recall is not running for this library. Start the desktop application or the headless recording service.");
        if(!File.Exists(request))
        {
            Wire.Atomic(RequestPath(root,id,".task.json"),new {id,operation,state="queued",ownerPid=owner.Number("pid",-1),instance=owner.Text("instance"),updated=DateTimeOffset.UtcNow});
            Wire.Atomic(request,new {instance=owner.Text("instance"),operation,args});
        }
        using var deadline=CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(timeout??TimeSpan.FromSeconds(120));
        try
        {
            while(!File.Exists(reply))
            {
                await Task.Delay(100,deadline.Token);
                if(Owner(root)?.Text("instance")!=owner.Text("instance"))
                    throw new RecallException("interrupted","The owner changed before acknowledging completion. Inspect the durable receipt before retrying.",new {requestId=id,result=$"recall tasks result {id}"});
            }
            return Response();
        }
        catch(OperationCanceledException)
        {
            File.WriteAllText(RequestPath(root,id,".cancel"),"");
            throw new RecallException(ct.IsCancellationRequested?"cancelled":"timeout","Stopped waiting. A queued request will be cancelled; an in-flight commit can still finish. Its durable receipt records the outcome.",new {requestId=id,completionKnown=File.Exists(reply),result=$"recall tasks result {id}"});
        }
    }
}
