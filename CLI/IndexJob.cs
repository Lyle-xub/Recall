using System.Text.Json;
using Rewind;
namespace Recall.Cli;

public sealed class IndexJob
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Kind { get; set; } = "index";
    public string Language { get; set; } = "eng";
    public List<string> Records { get; set; } = [];
    [System.Text.Json.Serialization.JsonPropertyName("completedIds")] public List<string> Completed { get; set; } = [];
    [System.Text.Json.Serialization.JsonPropertyName("completed")] public int CompletedCount => Completed.Count;
    public string State { get; set; } = "running";
    public int Pid { get; set; } = Environment.ProcessId;
    public long Started {get;set;} = InferenceOwnership.Started(Environment.ProcessId);
    public string? PendingRecord {get;set;}
    public string? PendingRequest {get;set;}
    public string? Error { get; set; }
    public DateTimeOffset Updated { get; set; } = DateTimeOffset.UtcNow;
    static string Folder(string root) => Path.Combine(root,".recall-tasks");
    static string FilePath(string root,string id)
    { if (!Guid.TryParseExact(id,"N",out _)) throw new RecallException("usage","Invalid task ID."); return Path.Combine(Folder(root),id+".json"); }
    public static IndexJob Read(string root,string id)
    {
        var job=JsonSerializer.Deserialize<IndexJob>(File.ReadAllText(FilePath(root,id)),Wire.Json)!;
        if(job.State=="running" && !InferenceOwnership.Matches(job.Pid,job.Started))job.State="interrupted";
        return job;
    }
    public static object[] List(string root) => Directory.Exists(Folder(root)) ? Directory.EnumerateFiles(Folder(root),"*.json").Select(path =>
    {
        var job = Read(root,Path.GetFileNameWithoutExtension(path));
        if (job.State == "running" && !InferenceOwnership.Matches(job.Pid,job.Started)) job.State = "interrupted";
        return (object)job;
    }).ToArray() : [];
    public static bool Exists(string root,string id)=>File.Exists(FilePath(root,id));
    void Save(string root)
    {
        Directory.CreateDirectory(Folder(root));
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(Folder(root),UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);
        Updated = DateTimeOffset.UtcNow; Wire.Atomic(FilePath(root,Id),this);
    }
    public static async Task<IndexJob> Start(LibraryClient client,Arguments args,TextWriter progress,CancellationToken ct)
    {
        var frames = (await client.Call("index-candidates",new {id=args.Get("id"),limit=args.Int("limit",100,1)},ct)).Deserialize<List<MemoryFrame>>(Wire.Json) ?? [];
        var job = new IndexJob { Language=args.Get("language") ?? "eng",Records=frames.Select(f=>f.Id).ToList() };
        return await job.Run(client,progress,ct);
    }
    public async Task<IndexJob> Run(LibraryClient client,TextWriter progress,CancellationToken ct)
    {
        using var claim = new LibraryLease(Path.Combine(Folder(client.Root),Id));
        if(State=="completed")return this;
        State="running";Pid=Environment.ProcessId;Started=InferenceOwnership.Started(Pid);Error=null;Save(client.Root);
        try
        {
            foreach (var id in Records.Except(Completed).ToArray())
            {
                ct.ThrowIfCancellationRequested();
                if(PendingRecord!=id){PendingRecord=id;PendingRequest=null;}
                if(PendingRequest!=null)
                {
                    JsonElement receipt;
                    try {receipt=Wire.Element(LibraryControlClient.Result(client.Root,PendingRequest));}
                    catch(RecallException e) when(e.Code=="not_found") {receipt=Wire.Element(new {state="interrupted"});}
                    if(receipt.Flag("ok")) {Completed.Add(id);PendingRecord=null;PendingRequest=null;Save(client.Root);continue;}
                    if(receipt.TryGetProperty("error",out _) || receipt.Text("state")=="interrupted")PendingRequest=null;
                }
                if(LibraryControlClient.Owner(client.Root)!=null)
                {
                    PendingRequest??=Guid.NewGuid().ToString("N");Save(client.Root);
                    await LibraryControlClient.Send(client.Root,"index-one",new {id,language=Language},ct,PendingRequest);
                }
                else {Save(client.Root);await client.Call("index-one",new {id,language=Language},ct);}
                Completed.Add(id);PendingRecord=null;PendingRequest=null;Save(client.Root);
                await progress.WriteLineAsync(JsonSerializer.Serialize(new { @event="progress",taskId=Id,completed=Completed.Count,total=Records.Count },Wire.Json));
            }
            State="completed";Save(client.Root);return this;
        }
        catch(Exception error)
        {
            State=ct.IsCancellationRequested ? "cancelled":"failed";Error=error.Message;Save(client.Root);
            throw new RecallException(ct.IsCancellationRequested ? "cancelled" : (error as RecallException)?.Code ?? "operation_failed",error.Message,
                new {taskId=Id,state=State,completed=Completed.Count,total=Records.Count,remaining=Records.Count-Completed.Count,resume=$"recall tasks resume {Id}",operation=(error as RecallException)?.Details});
        }
    }
}
