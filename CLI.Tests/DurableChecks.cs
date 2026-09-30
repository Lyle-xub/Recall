using System.Text.Json;
using System.Diagnostics;
using Recall.Cli;
using Rewind;

static class DurableChecks
{
    public static async Task Run(string root,Action<bool,string> assert,Func<string,int,string[],Task<JsonElement>> command)
    {
        var library=Path.Combine(root,"durable 库 with spaces");
        using var store=new MemoryStore(library);
        var client=new LibraryClient(library);
        store.Save(new MemoryFrame {Id="pending",TextState=RecognitionState.Pending,ImagePath="frames/missing.png"});
        // Missing mandatory media must fail before publication, while optional
        // OCR sidecars are already covered by the normal successful export test.
        var destination=Path.Combine(root,"missing-export");
        await command(library,3,["records","export","--output",destination]);
        assert(!Directory.Exists(destination) && !Directory.EnumerateDirectories(root,"missing-export.partial-*").Any(),"Incomplete export is never published and staging is removed");
        var settings=Path.Combine(library,"settings.json");
        File.WriteAllText(settings,"{\"FuturePreference\":{\"keep\":42},\"captureInterval\":7}");
        await command(library,0,["config","set","capture-interval","2"]);
        using(var document=JsonDocument.Parse(File.ReadAllText(settings)))
            assert(document.RootElement.GetProperty("FuturePreference").GetProperty("keep").GetInt32()==42 && document.RootElement.EnumerateObject().Count(p=>p.Name.Equals("CaptureInterval",StringComparison.OrdinalIgnoreCase))==1,"Config preserves unknown fields without duplicate differently cased keys");
        var before=File.ReadAllBytes(settings);
        await command(library,2,["config","set","excluded-apps","[null]"]);
        assert(before.SequenceEqual(File.ReadAllBytes(settings)),"Invalid exclusion configuration preserves settings bytes");
        var optimized=Wire.Element(await PortableMaintenance.Optimize(store,default));
        assert(optimized.Number("completed",-1)==0 && optimized.Number("skipped",-1)==1 && store.Frame("pending")!.ImagePath=="frames/missing.png","Pending OCR prevents destructive compression before invoking any engine");
        store.SaveSession(new("active",DateTimeOffset.UtcNow.AddDays(-90),null,"",false));
        store.Save(new MemoryFrame {Id="active-frame",SessionId="active",Timestamp=DateTimeOffset.UtcNow.AddDays(-90)});
        store.Save(new MemoryFrame {Id="old-frame",Timestamp=DateTimeOffset.UtcNow.AddDays(-90)});
        await command(library,0,["config","set","capture-interval","3"]);
        assert(store.Frame("old-frame")!.DeletedAt==null,"Unrelated settings never apply retention");
        await command(library,0,["config","set","retention-days","1"]);
        assert(store.Frame("old-frame")!.DeletedAt!=null && store.Frame("active-frame")!.DeletedAt==null,"Retention moves old memories to trash and preserves active sessions");

        var cleanupRoot=Path.Combine(root,"cleanup-recovery");
        using(var cleanup=new MemoryStore(cleanupRoot))
        {
            var media=Path.Combine(cleanupRoot,"frames","locked.png");File.WriteAllBytes(media,[1,2,3]);
            cleanup.Save(new MemoryFrame {Id="to-remove",ImagePath="frames/locked.png"});
            FileStream? locked=null;
            try
            {
                if(OperatingSystem.IsWindows())locked=new FileStream(media,FileMode.Open,FileAccess.Read,FileShare.Read);
                else File.SetUnixFileMode(Path.GetDirectoryName(media)!,UnixFileMode.UserRead|UnixFileMode.UserExecute);
                try {cleanup.Cleanup(cleanup.CleanupPreview(CleanupScope.All,true));throw new Exception("Cleanup should report inaccessible media");}
                catch(RecallException e){assert(e.Code=="cleanup_pending" && cleanup.Frame("to-remove")==null && File.Exists(media),"Failed media deletion keeps a durable recovery receipt after the database commit");}
            }
            finally {locked?.Dispose();if(!OperatingSystem.IsWindows())File.SetUnixFileMode(Path.GetDirectoryName(media)!,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);}
            using var reopened=new MemoryStore(cleanupRoot,initialize:false);
            assert(!File.Exists(media) && !Directory.EnumerateFiles(Path.Combine(cleanupRoot,".recall-control"),"cleanup-*.json").Any(),"Writable reopen completes interrupted media cleanup without changing schema");
            var preferences=Path.Combine(cleanupRoot,"settings.json");File.WriteAllText(preferences,"{\"keep\":true}");
            Wire.Atomic(Path.Combine(cleanupRoot,".recall-control","cleanup-"+Guid.NewGuid().ToString("N")+".json"),new {ids=Array.Empty<string>(),sessions=Array.Empty<string>(),files=new[]{"settings.json","../sample.png"}});
            reopened.RecoverPendingCleanups();
            assert(File.Exists(preferences) && File.Exists(Path.Combine(root,"sample.png")),"Cleanup recovery never deletes preferences or paths outside owned media folders");
        }

        var entered=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls=0;
        using(var owner=new LibraryControlHost(library,"test",async (operation,args)=>
        {
            calls++;entered.TrySetResult();await release.Task;return new {committed=true};
        }))
        {
            try
            {
                var pending=LibraryControlClient.Send(library,"slow",new {},default,timeout:TimeSpan.FromMilliseconds(250));
                await entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
                string request;
                try {await pending;throw new Exception("Slow request did not time out");}
                catch(RecallException e) {assert(e.Code=="timeout","Live owner requests have a bounded wait");request=Wire.Element(e.Details!).Text("requestId")!;}
                assert(Wire.Element(LibraryControlClient.Result(library,request)).Text("state")=="running","Timed-out mutation remains queryable while its commit runs");
                using var cancel=new CancellationTokenSource();
                var queued=LibraryControlClient.Send(library,"must-not-run",new {},cancel.Token);
                cancel.Cancel();
                string cancelled;
                try {await queued;throw new Exception("Queued request was not cancelled");}
                catch(RecallException e) {assert(e.Code=="cancelled","Cancelling a queued request returns its durable receipt");cancelled=Wire.Element(e.Details!).Text("requestId")!;}
                release.TrySetResult();
                await Until(()=>CompletedReceipt(library,cancelled));
                assert(Wire.Element(LibraryControlClient.Result(library,request)).Flag("ok"),"Completion after timeout is preserved in the receipt");
                assert(Wire.Element(LibraryControlClient.Result(library,cancelled)).GetProperty("error").Text("code")=="cancelled" && calls==1,"Queued cancellation never invokes the mutation handler");
                await LibraryControlClient.Send(library,"slow",new {},default,request);
                assert(calls==1,"Reusing an acknowledged request ID does not repeat the mutation");
            }
            finally {release.TrySetResult();}
        }
        var stale=Guid.NewGuid().ToString("N");
        Wire.Atomic(Path.Combine(library,".recall-control",stale+".request.json"),new {instance="old-owner",operation="stale",args=new {}});
        using(var owner=new LibraryControlHost(library,"test",(_,_)=>throw new Exception("Stale handler must not run")))
        {
            await Until(()=>CompletedReceipt(library,stale));
            assert(Wire.Element(LibraryControlClient.Result(library,stale)).GetProperty("error").Text("code")=="stale_owner","New owner drains stale requests without executing them");
        }
        entered=new(TaskCreationOptions.RunContinuationsAsynchronously);release=new(TaskCreationOptions.RunContinuationsAsynchronously);calls=0;
        using(var owner=new LibraryControlHost(library,"test",async (_,args)=>
        {
            calls++;store.Recognized(args.Text("id")!,"Acknowledged once",[]);entered.TrySetResult();await release.Task;return new {completed=1};
        }))
        {
            try
            {
                using var cancel=new CancellationTokenSource();
                var running=IndexJob.Start(client,new Arguments(["index","run","--id","pending","--language","eng"]),TextWriter.Null,cancel.Token);
                await entered.Task.WaitAsync(TimeSpan.FromSeconds(10));cancel.Cancel();
                try {await running;throw new Exception("Index job did not cancel");}catch(RecallException e){assert(e.Code=="cancelled","OCR interruption records a resumable task");}
                var job=(IndexJob)IndexJob.List(library).Single();
                assert(job.State=="cancelled" && job.CompletedCount==0 && job.PendingRequest!=null,"Unacknowledged record stays pending after cancellation");
                release.TrySetResult();
                var resumed=await IndexJob.Read(library,job.Id).Run(client,TextWriter.Null,default);
                assert(resumed.State=="completed" && resumed.CompletedCount==1 && calls==1,"Resume reconciles late acknowledgement without repeating OCR");
                var result=await command(library,0,["tasks","result",job.Id]);
                assert(result.Text("state")=="completed","tasks result returns a durable OCR job");
            }
            finally {release.TrySetResult();}
        }
        // A real subprocess must close its caller's pipes while its idle service
        // continues. An extra inheritable file handle also proves that the
        // Windows launcher excludes unrelated handles, not just standard IO.
        // No screen capture occurs: default privacy exclusions reject it.
        var sentinelPath=Path.Combine(root,"inherited-handle-sentinel");
        using var sentinel=OperatingSystem.IsWindows()?WindowsDetachedChecks.InheritableFile(sentinelPath):null;
        try
        {
            var owners=await Task.WhenAll(command(library,0,["service","start"]),command(library,0,["service","start"]));
            assert(owners[0].Number("pid",0)==owners[1].Number("pid",-1),"Concurrent service starts publish one detached owner and close caller pipes");
            if(OperatingSystem.IsWindows())
            {
                sentinel!.Dispose();File.Delete(sentinelPath);
                assert(!File.Exists(sentinelPath),"Windows service does not retain an unrelated inheritable file handle after its CLI parent exits");
                await WindowsDetachedChecks.Arguments(root,assert);
            }
            assert(store.Session("active")!.EndedAt!=null,"Service startup closes a crashed owner's active session");
            var count=store.Count;
            await command(library,4,["recording","start"]);
            assert(store.Count==count,"Unsupported exclusions reject portable recording without saving pixels");
        }
        finally
        {
            if(LibraryControlClient.Owner(library)!=null)await LibraryControlClient.Send(library,"service-stop",new {},default);
            await Until(()=>LibraryControlClient.Owner(library)==null);
        }
        using(var lease=await ReleasedLease(library))assert(true,"Stopped service releases the OS lease");
        var inference="test-"+Guid.NewGuid().ToString("N");
        try
        {
            using(var first=new InferenceOwnership(inference))
            {
                try {using var second=new InferenceOwnership(inference);throw new Exception("Duplicate inference owner");}
                catch(RecallException e){assert(e.Code=="busy","Inference ownership prevents a second engine across independent handles");}
            }
            var modelRoot=Path.Combine(root,"shared-models");Directory.CreateDirectory(modelRoot);
            var weight=Path.Combine(modelRoot,"fixture.bin");File.WriteAllBytes(weight,[7,8,9]);
            var catalog=Path.Combine(root,"fixture-catalog.json");
            File.WriteAllText(catalog,JsonSerializer.Serialize(new[]{new ModelDownload(inference,"Fixture","test","fixture.bin","https://invalid.example/model",3,"abc","test","test")}));
            var previousRoot=Environment.GetEnvironmentVariable("REWIND_MODEL_ROOT");
            var previousCatalog=Environment.GetEnvironmentVariable("REWIND_CATALOG_PATH");
            try
            {
                Environment.SetEnvironmentVariable("REWIND_MODEL_ROOT",modelRoot);Environment.SetEnvironmentVariable("REWIND_CATALOG_PATH",catalog);
                using var activeEngine=new InferenceOwnership(inference);
                await command(library,5,["models","remove",inference,"--yes"]);
                await command(library,5,["models","download",inference]);
                assert(File.ReadAllBytes(weight).SequenceEqual(new byte[]{7,8,9}),"Shared model lease prevents another library from deleting or replacing active weights");
            }
            finally {Environment.SetEnvironmentVariable("REWIND_MODEL_ROOT",previousRoot);Environment.SetEnvironmentVariable("REWIND_CATALOG_PATH",previousCatalog);}
            assert(!InferenceOwnership.Matches(Environment.ProcessId,InferenceOwnership.Started(Environment.ProcessId)+5000),"Process identity rejects reused or incorrect birth timestamps");
            var testExecutable=Environment.ProcessPath!;
            var info=new ProcessStartInfo(testExecutable) {UseShellExecute=false};
            if(Path.GetFileNameWithoutExtension(testExecutable).Equals("dotnet",StringComparison.OrdinalIgnoreCase))info.ArgumentList.Add(typeof(DurableChecks).Assembly.Location);
            info.ArgumentList.Add("--inference-test-child");
            using var child=Process.Start(info)!;
            try
            {
                using(var ownership=new InferenceOwnership(inference))ownership.Publish(inference,child,false);
                // Simulate a crash after lease release but before child cleanup.
                Wire.Atomic(InferenceOwnership.Discovery(inference),new InferenceOwnership.Service(-1,child.Id,InferenceOwnership.Started(child.Id),child.MainModule!.FileName!,false,null,""));
                using(var recovered=new InferenceOwnership(inference))assert(child.WaitForExit(5000),"A crashed model owner's verified orphan is stopped before a new engine can load");
            }
            finally {if(!child.HasExited){child.Kill(true);child.WaitForExit();}}

        }
        finally {Directory.Delete(InferenceOwnership.Root(inference),true);}
    }
    public static async Task NativeService(string library,Action<bool,string> assert,Func<string,int,string[],Task<JsonElement>> command)
    {
        var owner=await command(library,0,["service","start"]);
        var pid=owner.Number("pid",-1);var birth=InferenceOwnership.Started(pid);
        try
        {
            assert(owner.Text("backend")=="macos-headless","Native service starts the headless entry point");
            var status=await command(library,0,["recording","status"]);
            assert(!status.Flag("active"),"Native service starts idle without screen capture");
            await command(library,0,["service","stop"]);
            await Until(()=>!InferenceOwnership.Matches(pid,birth));
            assert(LibraryControlClient.Owner(library)==null,"Native headless stop exits the process and retires ownership without an AppKit loop deadlock");
            using var lease=await ReleasedLease(library);
        }
        finally
        {
            // Only this test-created native helper may be terminated on failure.
            if(InferenceOwnership.Matches(pid,birth)){using var process=Process.GetProcessById(pid);process.Kill(true);process.WaitForExit();}
        }
    }
    static async Task Until(Func<bool> condition)
    {
        for(var i=0;i<200;i++){if(condition())return;await Task.Delay(25);}
        throw new Exception("Timed out waiting for a durable operation");
    }
    static async Task<LibraryLease> ReleasedLease(string root)
    {
        // Process-exit notification can precede the kernel releasing its final
        // file descriptors. Assert readiness by acquiring the actual OS lease.
        for(var attempt=0; ;attempt++)
        {
            try {return new LibraryLease(root);}
            catch(RecallException e) when(e.Code=="busy" && attempt<200) {await Task.Delay(25);}
        }
    }
    static bool CompletedReceipt(string root,string id)=>File.Exists(Path.Combine(root,".recall-control",id+".task.json")) && Wire.Element(LibraryControlClient.Result(root,id)).TryGetProperty("ok",out _);
}
