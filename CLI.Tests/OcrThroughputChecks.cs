using System.Diagnostics;
using System.Text.Json;
using Recall.Cli;
using Rewind;

internal static class OcrThroughputChecks
{
    internal static async Task Run(string root, Action<bool,string> check)
    {
        var directory = Path.Combine(root,"ocr-queue");
        using var store = new MemoryStore(directory);
        var time = DateTimeOffset.UtcNow;
        for (int i=0;i<70;i++) store.Save(new MemoryFrame {Id=$"queued-{i:D3}",Timestamp=time.AddSeconds(i),ImagePath="frames/source.png",TextState=RecognitionState.Pending});
        store.Save(new MemoryFrame {Id="trash",Timestamp=time.AddMinutes(-1),DeletedAt=time,TextState=RecognitionState.Pending});
        var first = store.PendingOcrIds(10000);
        check(first.Count==32 && first[0]=="queued-000" && !first.Contains("trash"),"Durable discovery bounds IDs, excludes trash, and preserves capture order");
        store.Recognition("queued-000",RecognitionState.Working);
        check(store.PendingOcrIds(32)[0]=="queued-000","An interrupted in-flight frame remains discoverable");
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var commits = new List<string>(); int concurrent=0,peak=0;
        await using(var worker=new DurableOcrWorker(store.PendingOcrIds,async (id,ct)=>
        {
            peak=Math.Max(peak,Interlocked.Increment(ref concurrent));
            try {
                if(id=="queued-000") {entered.TrySetResult();await release.Task.WaitAsync(ct);}
                store.Recognized(id,"exact text",[new("exact text",.1,.2,.3,.4)]);
                lock(commits)commits.Add(id);
            } finally {Interlocked.Decrement(ref concurrent);}
        },(_,error)=>throw new Exception("Unexpected OCR failure",error)))
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            // This represents the durable capture write while inference is blocked.
            var captureTimer=Stopwatch.StartNew();
            store.Save(new MemoryFrame {Id="new-capture",Timestamp=time.AddHours(1),TextState=RecognitionState.Pending});worker.Wake();
            check(captureTimer.Elapsed < TimeSpan.FromSeconds(1) && store.Frame("new-capture")!=null,"Slow inference does not block persistence of a new capture");
            release.TrySetResult();
            using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(25));
            while(store.PendingOcrIds(32).Count!=0)await Task.Delay(20,deadline.Token);
            check(commits.Count==71 && commits[0]=="queued-000" && commits[^1]=="new-capture" && peak==1,"Bounded windows drain every durable record in time order with one recognizer");
        }
        store.Save(new MemoryFrame {Id="cancelled",TextState=RecognitionState.Pending});
        var cancelling=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var unfinished=new DurableOcrWorker(store.PendingOcrIds,async (id,ct)=>{store.Recognition(id,RecognitionState.Working);cancelling.TrySetResult();await Task.Delay(Timeout.Infinite,ct);},(_,_)=>{});
        await cancelling.Task.WaitAsync(TimeSpan.FromSeconds(5));await unfinished.DisposeAsync();
        check(store.PendingOcrIds(32).SequenceEqual(new[]{"cancelled"}),"Cancellation preserves durable in-flight work for restart");
        store.Recognition("cancelled",RecognitionState.Failed,"temporary");
        int attempts=0;var retried=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using(var retry=new DurableOcrWorker(store.PendingOcrIds,(id,ct)=>{if(++attempts==1)throw new IOException("temporary");store.Recognized(id,"recovered",[]);retried.TrySetResult();return Task.CompletedTask;},(id,e)=>store.Recognition(id,RecognitionState.Failed,e.Message)))
        {
            await retried.Task.WaitAsync(TimeSpan.FromSeconds(6));
            check(attempts==2 && store.Frame("cancelled")!.Text=="recovered","Failed work retries with a delay without losing its pixels or record");
        }
        check(OcrWorkPolicy.Recovery(TimeSpan.FromSeconds(3),500) < OcrWorkPolicy.Recovery(TimeSpan.FromSeconds(3),1),"A backlog shortens recovery without adding inference concurrency");
        int scans=0,runs=0;
        var recovered=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using(var resilient=new DurableOcrWorker((_,_)=>
        {
            if(++scans==1)throw new IOException("temporary database lock");
            return runs<2 ? new[]{"recover"} : Array.Empty<string>();
        },(_,_)=>
        {
            if(++runs==1)throw new IOException("temporary inference error");
            recovered.TrySetResult();return Task.CompletedTask;
        },(_,_)=>throw new IOException("temporary status write error")))
        {
            await recovered.Task.WaitAsync(TimeSpan.FromSeconds(6));
            check(scans>1 && runs==2,"Discovery and failure-status errors do not permanently stop the worker");
        }
        var originals=new[]{"RECALL_TESSERACT","RECALL_TEST_ARCHIVE_OCR","RECALL_TEST_OCR_COUNTER","DOTNET_ROOT"}.ToDictionary(k=>k,Environment.GetEnvironmentVariable);
        try
        {
            var probe=Path.ChangeExtension(typeof(OcrThroughputChecks).Assembly.Location,OperatingSystem.IsWindows()?".exe":null);
            var countPath=Path.Combine(directory,"ocr-calls.txt");var imagePath=Path.Combine(directory,"cache.png");
            var pixels=Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJYoAAAAASUVORK5CYII=");
            File.WriteAllBytes(imagePath,pixels);
            Environment.SetEnvironmentVariable("RECALL_TESSERACT",probe);Environment.SetEnvironmentVariable("RECALL_TEST_ARCHIVE_OCR","1");
            Environment.SetEnvironmentVariable("RECALL_TEST_OCR_COUNTER",countPath);
            Environment.SetEnvironmentVariable("DOTNET_ROOT",new DirectoryInfo(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory()).Parent!.Parent!.Parent!.FullName);
            var recognized=await OcrEngine.Recognize(imagePath,"eng",default);recognized.Regions.Clear();
            var cached=await OcrEngine.Recognize(imagePath,"eng",default);
            check(File.ReadAllLines(countPath).Length==1 && cached.Regions.Count==1,"Exact image reuse avoids a new subprocess and callers cannot mutate cached results");
            await OcrEngine.Recognize(imagePath,"chi_sim",default);
            File.WriteAllBytes(imagePath,pixels.Concat(new byte[]{0}).ToArray());
            await OcrEngine.Recognize(imagePath,"eng",default);
            check(File.ReadAllLines(countPath).Length==3,"A language change or even one changed byte triggers fresh recognition");
        }
        finally {foreach(var (key,value) in originals)Environment.SetEnvironmentVariable(key,value);}
        // A deferred/visible Windows UI must not even query the OCR backlog.
        // Reopening during one inference pauses the next ID in that same window.
        int paused = 1, fetches = 0, pauseFailures = 0;
        var pauseFirst = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var pauseRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var pauseSecond = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using (var pauseWorker = new DurableOcrWorker((_, _) =>
        {
            Interlocked.Increment(ref fetches);
            return pauseSecond.Task.IsCompleted ? [] : new[] { "pause-first", "pause-second" };
        }, async (id, ct) =>
        {
            if (id == "pause-first")
            {
                pauseFirst.TrySetResult();
                await pauseRelease.Task.WaitAsync(ct);
            }
            else pauseSecond.TrySetResult();
        }, (_, _) => Interlocked.Increment(ref pauseFailures), paused: () => Volatile.Read(ref paused) != 0))
        {
            pauseWorker.Wake();
            await Task.Delay(250);
            check(fetches == 0 && !pauseWorker.Active, "Foreground pause defers OCR discovery as well as inference");
            Volatile.Write(ref paused, 0); pauseWorker.Wake();
            await pauseFirst.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Volatile.Write(ref paused, 1); pauseRelease.TrySetResult();
            await Task.Delay(750);
            check(!pauseSecond.Task.IsCompleted && pauseFailures == 0, "Reopening the UI pauses the next record within an already fetched window");
            check(await pauseWorker.Exclusive(() => Task.FromResult(42), default).WaitAsync(TimeSpan.FromSeconds(2)) == 42,
                "A paused background worker leaves explicit indexing operations available");
            Volatile.Write(ref paused, 0); pauseWorker.Wake();
            await pauseSecond.Task.WaitAsync(TimeSpan.FromSeconds(5));
            check(pauseFailures == 0, "Hiding the UI resumes the retained OCR window without a failed record");
            Volatile.Write(ref paused, 1);
        }
        check(true, "A paused worker can shut down without waiting for the UI to hide");
        var executable=Environment.ProcessPath!;
        ProcessStartInfo Probe()
        {
            var info=new ProcessStartInfo(executable);
            if(Path.GetFileNameWithoutExtension(executable)=="dotnet")info.ArgumentList.Add(typeof(OcrThroughputChecks).Assembly.Location);
            info.ArgumentList.Add("--json-line-probe");return info;
        }
        using var ipc=new JsonLineWorker(Probe);
        var a=await ipc.Request(new {value=1},default,TimeSpan.FromSeconds(5));
        var b=await ipc.Request(new {value=2},default,TimeSpan.FromSeconds(5));
        check(a.GetProperty("pid").GetInt32()==b.GetProperty("pid").GetInt32(),"Multiple requests reuse one local worker");
        using var cancel=new CancellationTokenSource(100);
        try {await ipc.Request(new {block=true},cancel.Token,TimeSpan.FromSeconds(5));check(false,"Worker cancellation must surface");} catch(OperationCanceledException) {}
        var c=await ipc.Request(new {value=3},default,TimeSpan.FromSeconds(5));
        check(c.GetProperty("pid").GetInt32()!=a.GetProperty("pid").GetInt32() && c.GetProperty("value").GetInt32()==3,"Cancelled workers retire; a late reply cannot contaminate the next request");
    }
}
