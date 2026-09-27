using System.Net;
using System.Text;
using Rewind;
var root = Path.Combine(Path.GetTempPath(), "rewind-test-" + Guid.NewGuid());
AppPaths.DataRoot = root;
var tests = 0;
void Assert(bool condition, string message) { if (!condition) throw new Exception(message); tests++; }
try
{
    if (args.Contains("--data-migration-only"))
    {
        DataDirectoryMigrationTests.Run(Assert, root);
        Console.WriteLine($"PASS: {tests} targeted data directory migration checks.");
        return;
    }
    if (args.Contains("--archive-only"))
    {
        ArchiveFramesTests.Run(Assert, root);
        CompactOcrRegionsTests.Run(Assert);
        VisualArchiveStorageTests.Run(Assert, root);
        ImageOptimizationSafetyTests.Run(Assert, root);
        Console.WriteLine($"PASS: {tests} targeted archive metadata checks.");
        return;
    }
    if (args.Contains("--rhine-only"))
    {
        RhineMotionTests.Run(Assert);
        ArchiveFramesTests.Run(Assert, root);
        Console.WriteLine($"PASS: {tests} targeted Rhine geometry, motion, and archive checks.");
        return;
    }
    RhineMotionTests.Run(Assert);
    ArchiveFramesTests.Run(Assert, root);
    CompactOcrRegionsTests.Run(Assert);
    VisualArchiveStorageTests.Run(Assert, root);
    ImageOptimizationSafetyTests.Run(Assert, root);
    DataDirectoryMigrationTests.Run(Assert, root);
    await RecordingControlTests.Run(Assert);
    await PreviewLoadTests.Run(Assert);
    AudioTrackEncodingTests.Run(Assert, root);
    VideoOrientationTests.Run(Assert);
    Assert(Recall.VideoOrientation.Correction(90, 16d/9, 9d/16) == 3, "Screen video tagged 90 degrees must align with the captured still");
    Assert(Recall.VideoOrientation.Correction(270, 16d/9, 9d/16) == 1, "Screen video tagged 270 degrees must align with the captured still");
    Assert(Recall.VideoOrientation.Correction(90, 9d/16, 9d/16) == 0, "Correct portrait recording must remain portrait");
    Assert(Recall.VideoOrientation.Correction(0, 16d/9, 16d/9) == 0, "Normal landscape recording must not rotate");
    Assert(Recall.VideoOrientation.Correction(0, 16d/9, 9d/16) == 0, "Do not guess clockwise direction when metadata is absent");
    Assert(Recall.VideoOrientation.Correction(90, 3, 1) == 0, "Unrelated capture aspect must not trigger automatic correction");
    Assert(Recall.VideoOrientation.Correction(90, 0, 9d/16) == 0, "Missing still must keep native orientation");
    Assert(Recall.VideoOrientation.Correction(90, 16d/9, 0) == 0, "Unopened video must not trigger correction");
    Assert(Recall.GlassProfile.TimelineOpacity(-1) == 0 && Recall.GlassProfile.TimelineOpacity(.18) == 0,
        "Timeline material retains the Mac's transparent upper margin");
    Assert(Math.Abs(Recall.GlassProfile.TimelineOpacity(.59) - .5) < 1e-10,
        "Timeline material matches the Mac's midpoint");
    Assert(Recall.GlassProfile.TimelineOpacity(1) == 1 && Recall.GlassProfile.TimelineOpacity(2) == 1,
        "Timeline material is opaque at the bottom");
    var opacity = Enumerable.Range(0, 101).Select(i => Recall.GlassProfile.TimelineOpacity(i / 100.0)).ToArray();
    Assert(opacity.Zip(opacity.Skip(1)).All(pair => pair.First <= pair.Second), "Timeline material has no fading seams");
    using (var store = new MemoryStore(root))
    {
        var now = DateTimeOffset.Now;
        var a = new MemoryFrame { Text = "TPS reports 100% _literal 会议记录", Timestamp = now, AppName = "Chrome", Title = "Report", ImagePath = "frames/test.jpg", SessionId = "session" };
        var b = new MemoryFrame { Text = "Other", Timestamp = now.AddDays(-40), AppName = "Word" };
        var c = b with
        {
            Id = Guid.NewGuid().ToString(),
            Starred = true
        };
        store.Save(a);
        store.Save(b);
        store.Save(c);
        Assert(store.Frames("TPS reports").Count == 1, "Phrase search");
        Assert(store.Frames("会议记录").Count == 1, "Chinese search");
        Assert(store.Frames("%").Count == 1, "Literal percent");
        Assert(store.Frames("_").Count == 1, "Literal underscore");
        Assert(store.Frames("' OR 1=1 --").Count == 0, "SQL injection");
        Assert(store.Frames(app: "Word").Count == 2, "App filter");
        Assert(store.Frames(limit: 1, ascending: true).Single().Timestamp == b.Timestamp, "Timeline forward pagination");
        Assert(store.AppNames(false, false, null).SequenceEqual(new[] { "Chrome", "Word" }), "Historical application filter");
        Assert(store.Frames(since: now.AddMinutes(-1)).Count == 1, "Date filter");
        store.SaveTranscript(new("line", "session", now, "Audio", "cover sheet"));
        Assert(store.Frames("cover sheet").Single().Id == a.Id, "Transcript timestamp search");
        store.ReplaceTranscript("session", [new("revised", "session", now, "Audio", "cover sheet revised")]);
        Assert(store.Transcript("session").Count == 1, "Retry replaces old transcript");
        store.Trash(a);
        Assert(store.Frames("cover sheet").Count == 0, "Deleted transcripts excluded");
        Assert(store.Frames(trash: true).Single().Id == a.Id, "Recoverable trash");
        store.Restore(a);
        store.Retain(30);
        Assert(store.Frames().Any(f => f.Id == c.Id), "Starred retention");
        Assert(store.Frames(trash: true).Any(f => f.Id == b.Id), "Old records moved to trash");
        store.Save(a with
        {
            Id = "demo",
            Demo = true
        });
        Assert(store.Retrieve("TPS reports", false).All(f => !f.Demo), "Demo isolation");
    }
    using (var reopened = new MemoryStore(root))
        Assert(reopened.Frames().Count == 2, "Persistence on restart");
    Assert(ModelClient.Endpoint(new(), "models").ToString() == "http://127.0.0.1:11434/v1/models", "Local endpoint");
    try
    {
        ModelClient.Endpoint(new()
        {
            BaseUrl = "https://example.com/v1"
        }, "models");
        throw new Exception("Local mode accepted remote server");
    }
    catch (InvalidOperationException) { tests++; }
    Assert(!ModelClient.Links("file:///secret javascript:alert(1)").Any(), "Safe links");
    ModelClient.client = new HttpClient(new FakeHandler());
    Assert((await ModelClient.Models(new(), "")).Single() == "local-test", "List models contract");
    var answer = await ModelClient.Answer("What happened?", [], [], [], new(), "", default);
    Assert(answer.Contains("[1]"), "Chat contract");
    string streamed = "";
    var streamedAnswer = await ModelClient.Answer("What happened?", [], [], [], new(), "", default, value => streamed = value);
    Assert(streamedAnswer == "A memory [1]." && streamed == streamedAnswer, "Streaming answer accumulation");
    var audio = Path.Combine(root, "test.wav");
    File.WriteAllBytes(audio, [1, 2, 3]);
    var session = new RecordingSession("s", DateTimeOffset.Now, null, "x.mp4", true);
    var lines = await ModelClient.Transcribe(audio, session, new(), "");
    Assert((lines.Single().Timestamp - session.StartedAt).TotalSeconds == 12.5, "Speech timestamps contract");
    var nativeLines = LocalInference.ParseTranscript("{\"transcription\":[{\"offsets\":{\"from\":12500},\"text\":\" Meeting note \"}]}", session);
    Assert((nativeLines.Single().Timestamp - session.StartedAt).TotalSeconds == 12.5, "Native Whisper timestamps");
    Assert(new AppSettings().Chat.IsBuiltin && new AppSettings().Speech.IsBuiltin, "Built-in models default");
    using (var cleanup = new MemoryStore(Path.Combine(root, "cleanup")))
    {
        var one = new MemoryFrame { Id = "one", ImagePath = "frames/one.jpg", SessionId = "shared" };
        var two = one with
        {
            Id = "two",
            ImagePath = "frames/two.jpg"
        };
        var video = "recordings/shared.mp4";
        cleanup.SaveSession(new("shared", DateTimeOffset.Now, DateTimeOffset.Now, video, false));
        foreach (var path in new[] { one.ImagePath, two.ImagePath, video })
            File.WriteAllBytes(Path.Combine(cleanup.Root, path), [1]);
        cleanup.Save(one);
        cleanup.Save(two);
        cleanup.Trash(one);
        Assert(cleanup.EmptyTrash() == 1 && File.Exists(Path.Combine(cleanup.Root, video)), "Purge preserves shared video");
        cleanup.Trash(two);
        Assert(cleanup.EmptyTrash() == 1 && !File.Exists(Path.Combine(cleanup.Root, video)) && cleanup.Session("shared") == null, "Purge removes unused media");
    }
    tests += await ParityTests.Run(root);
    Console.WriteLine($"PASS: {tests} database, retrieval, privacy, and model contract checks.");
}
finally { Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools(); if (Directory.Exists(root)) Directory.Delete(root, true); }
sealed class FakeHandler : HttpMessageHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var path = request.RequestUri!.AbsolutePath;
        var json = path switch
        {
            "/v1/models" => "{\"data\":[{\"id\":\"local-test\"}]}",
            "/v1/audio/transcriptions" => "{\"segments\":[{\"start\":12.5,\"text\":\"Meeting note\"}]}",
            _ => "{\"choices\":[{\"message\":{\"content\":\"Found a memory [1].\"}}]}"
        };
        if (path == "/v1/chat/completions")
        {
            var body = await request.Content!.ReadAsStringAsync(ct);
            if (!body.Contains("untrusted_memory_records"))
                throw new Exception("Missing evidence boundary");
            if (body.Contains("\"stream\":true"))
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("data: {\"choices\":[{\"delta\":{\"content\":\"A memory \"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"[1].\"}}]}\n\ndata: [DONE]\n\n", Encoding.UTF8, "text/event-stream") };
        }
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
    }
}
namespace Rewind
{
    internal static class App
    {
        public static string DataRoot => Path.GetTempPath();
    }
}
