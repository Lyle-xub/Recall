using System.Text.Json;
using Rewind;

static class ControlReceiptChecks
{
    public static async Task Run(string directory,Action<bool,string> assert)
    {
        foreach(var scenario in new[]{"completed-exit","completed-new-owner","failed-exit","running-exit","wrong-id","wrong-instance","wrong-pid","string-pid","missing-response","malformed-response"})
        {
            var root=Path.Combine(directory,"receipt-"+scenario);
            using var lease=new LibraryLease(root);
            var ownerPath=Path.Combine(lease.DirectoryPath,"owner.json");
            var instance=Guid.NewGuid().ToString("N");var id=Guid.NewGuid().ToString("N");
            object Owner(string token)=>new {protocol=1,pid=Environment.ProcessId,started=InferenceOwnership.Started(Environment.ProcessId),instance=token,backend="test"};
            Wire.Atomic(ownerPath,Owner(instance));
            var entered=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var release=new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var pending=LibraryControlClient.SendUsingPoll(root,"service-stop",new {},deadline.Token,ct=>{entered.TrySetResult();return release.Task.WaitAsync(ct);},id);
            try
            {
                await entered.Task.WaitAsync(deadline.Token);
                // Publish and retire ownership entirely within one suspended
                // poll. The former loop observed the missing owner first and
                // always threw, even though the acknowledgement was durable.
                if(scenario!="missing-response")Wire.Atomic(Path.Combine(lease.DirectoryPath,id+".response.json"),
                    scenario=="failed-exit" ? new {ok=false,error=new {code="test_failure",message="The operation failed before orderly exit."}} :
                    scenario=="malformed-response" ? (object)new {ok=true} : new {ok=true,result=new {stopping=true}});
                Wire.Atomic(Path.Combine(lease.DirectoryPath,id+".task.json"),new
                {
                    id=scenario=="wrong-id"?Guid.NewGuid().ToString("N"):id,
                    instance=scenario=="wrong-instance"?Guid.NewGuid().ToString("N"):instance,
                    ownerPid=scenario=="string-pid"?(object)Environment.ProcessId.ToString():scenario=="wrong-pid"?Environment.ProcessId+1:Environment.ProcessId,
                    state=scenario=="running-exit"?"running":"finished"
                });
                if(scenario=="completed-new-owner")Wire.Atomic(ownerPath,Owner(Guid.NewGuid().ToString("N")));
                else File.Delete(ownerPath);
                release.TrySetResult();
                if(scenario is "completed-exit" or "completed-new-owner")
                {
                    assert((await pending).Flag("stopping"),"A verified finished acknowledgement survives "+scenario);
                    var replay=await LibraryControlClient.SendUsingPoll(root,"service-stop",new {},default,_=>throw new Exception("A completed request must not be resent"),id);
                    assert(replay.Flag("stopping"),"Replaying the same completed request ID reads its receipt without another mutation");
                    assert(Wire.Element(LibraryControlClient.Result(root,id)).Flag("ok"),"Completed receipt remains queryable after ownership changes");
                }
                else
                {
                    try {await pending;throw new Exception("Unverified stop was reported successful: "+scenario);}
                    catch(RecallException e){assert(e.Code==(scenario=="failed-exit"?"test_failure":"interrupted"),"Stop preserves uncertainty or the actual completed error for "+scenario);}
                }
            }
            finally
            {
                release.TrySetResult();deadline.Cancel();
                try {await pending;}catch(RecallException){}
            }
        }

        var partialRoot=Path.Combine(directory,"receipt-two-phase");
        using var partialLease=new LibraryLease(partialRoot);
        var token=Guid.NewGuid().ToString("N");var requestId=Guid.NewGuid().ToString("N");
        var partialOwner=Path.Combine(partialLease.DirectoryPath,"owner.json");
        Wire.Atomic(partialOwner,new {protocol=1,pid=Environment.ProcessId,started=InferenceOwnership.Started(Environment.ProcessId),instance=token,backend="test"});
        var enteredPoll=Enumerable.Range(0,2).Select(_=>new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)).ToArray();
        var releasePoll=Enumerable.Range(0,2).Select(_=>new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)).ToArray();
        var polls=0;using var limit=new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var sending=LibraryControlClient.SendUsingPoll(partialRoot,"service-stop",new {},limit.Token,ct=>
        {
            var index=polls++;if(index>=2)throw new Exception("Unexpected extra receipt poll");
            enteredPoll[index].TrySetResult();return releasePoll[index].Task.WaitAsync(ct);
        },requestId);
        try
        {
            await enteredPoll[0].Task.WaitAsync(limit.Token);
            Wire.Atomic(Path.Combine(partialLease.DirectoryPath,requestId+".response.json"),new {ok=true,result=new {stopping=true}});
            Wire.Atomic(Path.Combine(partialLease.DirectoryPath,requestId+".task.json"),new {id=requestId,instance=token,ownerPid=Environment.ProcessId,state="running"});
            releasePoll[0].TrySetResult();
            await enteredPoll[1].Task.WaitAsync(limit.Token);
            assert(!sending.IsCompleted,"A response without its finished marker is not acknowledged early");
            var partial=Wire.Element(LibraryControlClient.Result(partialRoot,requestId));
            assert(partial.Text("state")=="running"&&!partial.Flag("completionKnown"),"A partially published response remains an explicitly incomplete receipt");
            Wire.Atomic(Path.Combine(partialLease.DirectoryPath,requestId+".task.json"),new {id=requestId,instance=token,ownerPid=Environment.ProcessId,state="finished"});
            File.Delete(partialOwner);releasePoll[1].TrySetResult();
            assert((await sending).Flag("stopping"),"The matching finished marker permits acknowledgement after owner exit");
        }
        finally
        {
            foreach(var release in releasePoll)release.TrySetResult();limit.Cancel();
            try {await sending;}catch(RecallException){}
        }
    }
}
