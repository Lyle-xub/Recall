using System.Diagnostics;
using System.Text.Json;
namespace Rewind;

/// A per-user kernel lease covers every library using the same built-in engine.
public sealed class InferenceOwnership : IDisposable
{
    readonly LibraryLease lease;
    readonly string engine;
    public static string Root(string engine) => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".recall-inference-v2", engine);
    public static string Discovery(string engine) => Path.Combine(Root(engine), ".recall-control", "engine.json");
    public InferenceOwnership(string engine)
    {
        this.engine=engine;
        lease = new LibraryLease(Root(engine));
        try
        {
            if (Read(engine) is { } old && Matches(old.Pid,old.Started))
            {
                // Holding the lease proves there is no compatible owner. Verify
                // both process birth and executable before reclaiming its child.
                using var orphan=Process.GetProcessById(old.Pid);
                if (Path.GetFullPath(orphan.MainModule!.FileName!) != Path.GetFullPath(old.Executable))
                    throw new RecallException("busy","An unverified model process still exists. No second engine was started.");
                orphan.Kill(true);
                if(!orphan.WaitForExit(5000)) throw new RecallException("busy","The previous model process has not exited.");
            }
            File.Delete(Discovery(engine));
        }
        catch { lease.Dispose(); throw; }
    }
    public static long Started(int pid)
    { using var p=Process.GetProcessById(pid); return new DateTimeOffset(p.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds(); }
    public static bool Alive(int pid)
    { if(pid<=0)return false;try { using var p = Process.GetProcessById(pid); return !p.HasExited; } catch (Exception e) when(e is ArgumentException or InvalidOperationException) { return false; } }
    public static bool Matches(int pid,long started)
    { try { return started>0 && Alive(pid) && Math.Abs(Started(pid)-started)<1000; } catch(Exception e) when(e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) {return false;} }
    public static string ModelIdentity(string path)
    {
        var file=new FileInfo(Path.GetFullPath(path));
        path=file.ResolveLinkTarget(true)?.FullName??file.FullName;
        return path+"|"+file.Length+"|"+new DateTimeOffset(file.LastWriteTimeUtc).ToUnixTimeMilliseconds();
    }
    public record Service(int OwnerPid, int Pid, long Started, string Executable, bool Share, ModelProfile? Profile, string Key, long OwnerStarted=0, string ModelIdentity="");
    public static Service? Read(string engine)
    { try { return JsonSerializer.Deserialize<Service>(File.ReadAllText(Discovery(engine)), Wire.Json); } catch (Exception e) when (e is IOException or JsonException) { return null; } }
    public void Publish(string engine, Process process, bool share, ModelProfile? profile = null, string key = "", string model = "") =>
        Wire.Atomic(Discovery(engine), new Service(Environment.ProcessId, process.Id, Started(process.Id), Path.GetFullPath(process.StartInfo.FileName), share, profile, key, Started(Environment.ProcessId), model.Length==0?"":ModelIdentity(model)));
    public static async Task<(ModelProfile Profile, string Key)?> SharedChat(string model,CancellationToken ct)
    {
        var service = Read("chat");
        if (service is not { Share: true, Profile: { } profile } || !Matches(service.OwnerPid,service.OwnerStarted) || !Matches(service.Pid,service.Started) || service.ModelIdentity!=ModelIdentity(model)) return null;
        if (!Uri.TryCreate(profile.BaseUrl, UriKind.Absolute, out var uri) || uri.Scheme != "http" || uri.Host != "127.0.0.1" || !profile.IsLocal) return null;
        using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(3) };
        http.DefaultRequestHeaders.Authorization = new("Bearer", service.Key);
        try { using var response = await http.GetAsync(profile.BaseUrl + "/models", ct); return response.IsSuccessStatusCode ? (profile, service.Key) : null; }
        catch (HttpRequestException) { return null; }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested) { return null; }
    }
    public void Dispose()
    {
        if(Read(engine) is { } value && value.OwnerPid==Environment.ProcessId && Matches(value.OwnerPid,value.OwnerStarted)) File.Delete(Discovery(engine));
        lease.Dispose();
    }
}
