using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using Rewind;
namespace Recall.Cli;

/// A library owner for machines without a running desktop UI. Real pixels only.
public sealed class HeadlessService
{
    readonly MemoryStore store;
    readonly SemaphoreSlim operation = new(1,1);
    readonly DurableOcrWorker indexing;
    readonly TaskCompletionSource shutdown = new(TaskCreationOptions.RunContinuationsAsynchronously);
    CancellationTokenSource? captureCancellation;
    Task? capture;
    RecordingSession? session;
    string? lastHash,lastId,lastError;
    int captured;
    HeadlessService(MemoryStore store)
    {
        this.store=store;store.PrepareOcrQueue();
        indexing=new(store.PendingOcrIds, async (id,ct) =>
        {
            var frame=store.Frame(id);
            if(frame==null || frame.DeletedAt!=null || frame.TextState is RecognitionState.Complete or RecognitionState.Empty)return;
            store.Recognition(id,RecognitionState.Working);
            try {await ArchiveOcr.Recognize(store,frame,"eng",ct);}
            catch(OperationCanceledException) {store.Recognition(id,RecognitionState.Pending);throw;}
        }, (id,error) => {store.Recognition(id,RecognitionState.Failed,error.Message);lastError="Capture is saved; OCR will retry: "+error.Message;});
    }
    public static async Task Serve(string root,CancellationToken ct = default)
    {
        try
        {
            using var ownership=new LibraryLease(root);
            using var store=new MemoryStore(root,initialize:false);
            var service=new HeadlessService(store);
            // Close sessions left open by a crashed owner before beginning new work.
            foreach(var old in store.Sessions().Where(s=>s.EndedAt==null)) store.SaveSession(old with {EndedAt=DateTimeOffset.UtcNow});
            using var host=new LibraryControlHost(root,"headless",service.Control,ownership);
            using var signal=ct.Register(()=>service.shutdown.TrySetResult());
            try { await service.shutdown.Task; }
            finally { await host.Stop(releaseOwnership:false);await service.Stop();await service.indexing.DisposeAsync(); }
        }
        catch(Exception e)
        {
            Directory.CreateDirectory(Path.Combine(root,".recall-control"));
            Wire.Atomic(Path.Combine(root,".recall-control","startup-error.json"),new {code=(e as RecallException)?.Code??"service_failed",message=e.Message});
        }
    }
    public static async Task Ensure(LibraryClient client,CancellationToken ct,bool preferWindowsNative=false)
    {
        if(LibraryControlClient.Owner(client.Root)!=null) return;
        LibraryLease? startup=null;
        for(var attempt=0;startup==null;attempt++)
        {
            ct.ThrowIfCancellationRequested();
            if(LibraryControlClient.Owner(client.Root)!=null)return;
            try {startup=new LibraryLease(Path.Combine(client.Root,".recall-service-start"));}
            catch(RecallException e) when(e.Code=="busy" && attempt<200) {await Task.Delay(100,ct);}
        }
        using var startupOwnership=startup;
        if(LibraryControlClient.Owner(client.Root)!=null)return;
        LibrarySafety.CheckLegacyDefaultOwner(client.Root);
        if(LibraryFormats.Detect(client.Root)==LibraryFormat.Missing) throw new RecallException("not_found","Initialize a library explicitly before starting capture.");
        if(LibraryFormats.Detect(client.Root)==LibraryFormat.Unknown)throw new RecallException("unsupported_schema","Unrecognized library schema.");
        var native=LibraryFormats.Detect(client.Root)==LibraryFormat.MacOS;
        var windowsDesktop=preferWindowsNative && !native ? WindowsDesktop.Discover() : null;
        var executable=windowsDesktop ?? (native ? LibraryClient.MacHelper??throw new RecallException("engine_missing","The native Mac helper is missing.") : Environment.ProcessPath!);
        // Unix gets separate pipes; Windows must disable *all* inherited
        // handles, not just replace its standard handles (see the launcher).
        var info=new ProcessStartInfo(executable) {UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true};
        if(windowsDesktop!=null) {foreach(var argument in WindowsDesktop.Arguments(client.Root))info.ArgumentList.Add(argument);}
        else if(native) {info.ArgumentList.Add("--headless-service");info.ArgumentList.Add("--data-dir");info.ArgumentList.Add(client.Root);}
        else
        {
            if(Path.GetFileNameWithoutExtension(executable).Equals("dotnet",StringComparison.OrdinalIgnoreCase)) info.ArgumentList.Add(typeof(CliApplication).Assembly.Location);
            info.ArgumentList.Add("--internal-service");info.ArgumentList.Add(client.Root);
        }
        var errorPath=Path.Combine(client.Root,".recall-control","startup-error.json");
        if(File.Exists(errorPath)) File.Delete(errorPath);
        using var process=OperatingSystem.IsWindows()
            ? WindowsDetachedProcess.Start(executable,info.ArgumentList)
            : Process.Start(info)??throw new RecallException("service_failed","Could not start the headless service.");
        if(!OperatingSystem.IsWindows())process.StandardInput.Close();
        for(int i=0;i<200;i++)
        {
            ct.ThrowIfCancellationRequested();
            if(LibraryControlClient.Owner(client.Root)!=null) return;
            if(process.HasExited)
            {
                if(File.Exists(errorPath)) {using var error=JsonDocument.Parse(File.ReadAllText(errorPath));throw new RecallException(error.RootElement.Text("code")??"service_failed",error.RootElement.Text("message")??"Service exited.");}
                throw new RecallException("service_failed","The headless service exited before publishing readiness.",new {phase="waiting_for_owner",processId=process.Id,exitCode=process.ExitCode});
            }
            await Task.Delay(100,ct);
        }
        throw new RecallException("timeout","Service startup has not completed. Inspect recording status before retrying.",new {phase="waiting_for_owner",processId=process.Id,childExited=process.HasExited});
    }
    async Task<object> Control(string command,JsonElement args)
    {
        // Stopping awaits the capture loop outside the mutation gate.
        if(command=="recording-stop") {await Stop();return Status();}
        if(command=="service-stop") {await Stop();_ = Task.Run(async()=>{await Task.Delay(250);shutdown.TrySetResult();});return new {stopping=true};}
        if(command=="recording-status") return Status();
        if(command=="tasks-status") return new {recording=Status(),indexing=indexing.Active,error=lastError};
        if(command=="index-one") return await indexing.Exclusive(async () =>
        {
            var frame=LibraryCommands.Require(store,args);
            await ArchiveOcr.Recognize(store,frame,args.Text("language")??"eng",CancellationToken.None);
            return (object)new {completed=1,id=frame.Id};
        },CancellationToken.None);
        await operation.WaitAsync();
        try
        {
            if(command=="recording-start")
            {
                var settingsPath=Path.Combine(store.Root,"settings.json");
                var settings=File.Exists(settingsPath)?JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(settingsPath),Wire.Json)!:new AppSettings();
                if(settings.SystemAudio || settings.Microphone)throw new RecallException("unsupported","The portable screenshot recorder does not record audio. Disable system-audio and microphone explicitly or use native macOS/Windows desktop recording.");
                if(settings.ExcludedApps.Length>0)throw new RecallException("unsupported","The portable screenshot backend cannot enforce excluded-apps. Use the native desktop recorder, or explicitly set excluded-apps to [] to permit whole-display capture.");
                if(!string.IsNullOrEmpty(settings.DisplayName))throw new RecallException("unsupported","The portable screenshot backend cannot honor a saved display selection. Use the native desktop recorder.");
                if(capture is {IsCompleted:false}) return Status();
                lastError=null;lastHash=null;lastId=null;captured=0;
                session=new RecordingSession(Guid.NewGuid().ToString(),DateTimeOffset.UtcNow,null,"",false,SpeechState:RecognitionState.Disabled);
                store.SaveSession(session);
                try {await CaptureOne(CancellationToken.None);}
                catch(Exception e) {lastError=e.Message;store.SaveSession(session with {EndedAt=DateTimeOffset.UtcNow});session=null;throw;}
                captureCancellation?.Dispose();captureCancellation=new();capture=Loop(session,captureCancellation.Token);
                return Status();
            }
            if(command=="optimize") return await PortableMaintenance.Optimize(store,CancellationToken.None);
            return LibraryCommands.Execute(store,command,args);
        }
        finally {operation.Release();}
    }
    object Status()=>new {available=true,active=capture is {IsCompleted:false},requested=capture is {IsCompleted:false},owner="headless",captured,sessionId=session?.Id,error=lastError,mode="screenshots"};
    async Task Loop(RecordingSession recordingSession,CancellationToken ct)
    {
        try
        {
            while(true)
            {
                await Task.Delay(TimeSpan.FromSeconds(Interval()),ct);
                await operation.WaitAsync(ct);
                try {await CaptureOne(ct);} finally {operation.Release();}
            }
        }
        catch(OperationCanceledException) when(ct.IsCancellationRequested) {}
        catch(Exception e) {lastError=e.Message;}
        finally {store.SaveSession(recordingSession with {EndedAt=DateTimeOffset.UtcNow});}
    }
    double Interval()
    {
        var path=Path.Combine(store.Root,"settings.json");
        if(!File.Exists(path))return 3;
        using var json=JsonDocument.Parse(File.ReadAllText(path));
        return Math.Clamp(json.RootElement.EnumerateObject().FirstOrDefault(p=>p.Name.Equals("captureInterval",StringComparison.OrdinalIgnoreCase)).Value.ValueKind==JsonValueKind.Number ? json.RootElement.EnumerateObject().First(p=>p.Name.Equals("captureInterval",StringComparison.OrdinalIgnoreCase)).Value.GetDouble():3,1,3600);
    }
    async Task Stop()
    {
        captureCancellation?.Cancel();if(capture!=null)await capture;
        captureCancellation?.Dispose();captureCancellation=null;capture=null;session=null;
    }
    async Task CaptureOne(CancellationToken ct)
    {
        var temporary=Path.Combine(Path.GetTempPath(),"recall-capture-"+Guid.NewGuid());
        if(OperatingSystem.IsWindows())Directory.CreateDirectory(temporary);
        else Directory.CreateDirectory(temporary,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        var file=Path.Combine(temporary,"capture.png");
        try
        {
            await CaptureBackend.Capture(file,ct);
            var hash=Convert.ToHexString(SHA256.HashData(await File.ReadAllBytesAsync(file,ct)));
            if(hash==lastHash && lastId!=null) {store.Extend(lastId,DateTimeOffset.UtcNow);return;}
            var frame=(MemoryFrame)LibraryCommands.Execute(store,"import",Wire.Element(new {image=file,app="Desktop",title="Headless screen capture"}));
            frame=frame with {SessionId=session!.Id,PixelHash=hash};store.Save(frame);
            lastId=frame.Id;lastHash=hash;captured++;
            indexing.Wake();
        }
        finally {if(Directory.Exists(temporary))Directory.Delete(temporary,true);}
    }
}

public static class CaptureBackend
{
    public static async Task Capture(string output,CancellationToken ct)
    {
        string executable;string[] args;
        if(OperatingSystem.IsMacOS()) {executable="/usr/sbin/screencapture";args=["-x","-t","png",output];}
        else if(OperatingSystem.IsLinux() && !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WAYLAND_DISPLAY")))
        { executable=Environment.GetEnvironmentVariable("RECALL_GRIM")??"grim";args=[output]; }
        else
        {
            executable=Environment.GetEnvironmentVariable("RECALL_FFMPEG")??"ffmpeg";
            if(OperatingSystem.IsLinux() && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DISPLAY"))) throw new RecallException("platform_unavailable","No X11 DISPLAY or Wayland session is available. Start an authorized graphical session; SSH-only shells cannot capture a nonexistent desktop.");
            args=OperatingSystem.IsWindows() ? ["-v","error","-f","gdigrab","-framerate","1","-i","desktop","-frames:v","1","-threads","1","-y",output] : ["-v","error","-f","x11grab","-framerate","1","-i",Environment.GetEnvironmentVariable("DISPLAY")!,"-frames:v","1","-threads","1","-y",output];
        }
        if(!OperatingSystem.IsMacOS() && !OperatingSystem.IsLinux() && !OperatingSystem.IsWindows()) throw new RecallException("platform_unavailable","No capture backend exists for this platform.");
        try
        {
            var result=await ChildProcess.Run(executable,args,null,ct,30);
            if(result.ExitCode!=0 || !File.Exists(output)) throw new RecallException("capture_unavailable","Screen capture was denied or the display backend is unavailable. macOS needs Screen Recording permission; Wayland needs a compositor supported by grim or a portal-authorized capture session.");
        }
        catch(System.ComponentModel.Win32Exception) {throw new RecallException("engine_missing",$"Capture backend '{executable}' is missing. Install FFmpeg for X11/Windows, or grim for a compatible Wayland compositor.");}
    }
}
