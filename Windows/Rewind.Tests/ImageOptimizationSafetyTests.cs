using Rewind;

static class ImageOptimizationSafetyTests
{
    public static void Run(Action<bool, string> check, string parent)
    {
        var root = Path.Combine(parent, "image-optimization-safety");
        using var store = new MemoryStore(root);
        const string source = "frames/shared-original.png";
        var pixels = new byte[] { 1, 2, 3, 4, 5, 6 };
        File.WriteAllBytes(Path.Combine(root, source), pixels);
        var first = new MemoryFrame { Id = "first", ImagePath = source, ImageQuality = 1, Text = "original OCR" };
        var other = new MemoryFrame { Id = "other", ImagePath = "frames/other.png", MeetingImagePath = source, ImageQuality = 1, TextState = RecognitionState.Pending };
        store.Save(first); store.Save(other);
        check(!store.CanOptimizeImage(source), "A pending meeting-image user protects another completed frame's shared original");
        check(!CommitCandidate(store, source, "frames/rejected-pending.jpg"), "Shared image optimization rejects all references when any OCR is pending");
        check(File.ReadAllBytes(Path.Combine(root, source)).SequenceEqual(pixels) && store.Frame(first.Id)!.ImagePath == source && store.Frame(other.Id)!.MeetingImagePath == source,
            "Rejected shared-image optimization leaves original bytes and both image references unchanged");
        check(!File.Exists(Path.Combine(root, "frames/rejected-pending.jpg")), "Rejected optimization candidates are removed without touching the source");
        store.Recognition(other.Id, RecognitionState.Failed, "OCR retry required");
        check(!store.TryCommitImageOptimization(source, null) && store.Frame(first.Id)!.ImageQuality == 1, "A failed shared OCR user also prevents an optimization quality marker");
        store.Recognized(other.Id, "meeting", [], []);
        check(store.CanOptimizeImage(source), "A shared source becomes eligible only after every OCR user completes");
        var retried = EncodeWhile(store, source, "frames/rejected-retry.jpg", () => store.Recognition(first.Id, RecognitionState.Pending), check);
        check(!retried && store.Frame(first.Id)!.TextState == RecognitionState.Pending && store.Frame(first.Id)!.ImageQuality == 1 && store.Frame(other.Id)!.MeetingImagePath == source,
            "Retry during encoding is rechecked atomically before either source reference changes");
        check(File.ReadAllBytes(Path.Combine(root, source)).SequenceEqual(pixels) && !File.Exists(Path.Combine(root, "frames/rejected-retry.jpg")),
            "Retry during encoding retains exact original bytes and cleans its abandoned candidate");
        store.Recognized(first.Id, "original OCR", []);
        var added = EncodeWhile(store, source, "frames/rejected-new-user.jpg", () => store.Save(new MemoryFrame
        {
            Id = "new-pending", ImagePath = "frames/new.png", MeetingImagePath = source, TextState = RecognitionState.Pending, ImageQuality = 1
        }), check);
        check(!added && store.Frame("new-pending")!.MeetingImagePath == source && File.Exists(Path.Combine(root, source)),
            "A new pending meeting-image reference created during encoding protects the shared source");
        store.Recognized("new-pending", "new OCR", []);
        var session = new RecordingSession("legacy-session", DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow, "recordings/legacy.mp4", false);
        store.SaveSession(session); store.Save(store.Frame(first.Id)! with { SessionId = session.Id });
        var interrupted = EncodeWhile(store, source, "frames/rejected-unified.jpg", () => store.SaveSession(session with { UnifiedVisualArchive = true, VisualArchiveReady = false }), check);
        check(!interrupted && File.Exists(Path.Combine(root, source)), "A failed unified archive session protects its original even if the encoder started earlier");
        store.SaveSession(session);
        store.Save(store.Frame(other.Id)! with { VisualSampleVerified = true });
        check(!store.CanOptimizeImage(source) && !CommitCandidate(store, source, "frames/rejected-proof.jpg"), "An exact-sample proof on any shared user prevents standalone lossy recompression");
        store.Save(store.Frame(other.Id)! with { VisualSampleVerified = false });
        var committed = EncodeWhile(store, source, "frames/committed.jpg", () =>
        {
            store.Star(first.Id);
            store.Recognized(first.Id, "latest OCR", [new("latest OCR", .123456789, .2, .3, .4)]);
        }, check);
        check(committed && !File.Exists(Path.Combine(root, source)) && File.Exists(Path.Combine(root, "frames/committed.jpg")),
            "Successful optimization publishes the verified candidate before retiring the unreferenced source");
        check(store.Frame(first.Id) is { Starred: true, Text: "latest OCR", ImagePath: "frames/committed.jpg", ImageQuality: .5 } && store.Frame(first.Id)!.Regions.Single().X == .123456789,
            "Image optimization preserves star and OCR changes made while encoding");
        check(store.Frame(other.Id)!.MeetingImagePath == "frames/committed.jpg" && store.Frame("new-pending")!.MeetingImagePath == "frames/committed.jpg",
            "Successful publication moves every eligible primary and meeting reference together");
        check(!store.CanOptimizeImage("frames/committed.jpg"), "Already optimized shared images are not encoded repeatedly");
    }
    private static bool EncodeWhile(MemoryStore store, string source, string target, Action duringEncoding, Action<bool, string> check)
    {
        using var read = new ManualResetEventSlim();
        using var finish = new ManualResetEventSlim();
        var encoding = Task.Run(() =>
        {
            _ = File.ReadAllBytes(Path.Combine(store.Root, source));
            read.Set();
            if (!finish.Wait(TimeSpan.FromSeconds(10))) throw new TimeoutException("The controlled encoder did not resume.");
            return CommitCandidate(store, source, target);
        });
        try
        {
            check(read.Wait(TimeSpan.FromSeconds(10)), "The controlled encoder reads source pixels before concurrent metadata changes");
            duringEncoding();
        }
        finally { finish.Set(); }
        return encoding.GetAwaiter().GetResult();
    }
    private static bool CommitCandidate(MemoryStore store, string source, string target)
    {
        var file = Path.Combine(store.Root, target);
        // Decoder correctness is covered by native image tests. This fixture
        // supplies a durable candidate to isolate the publication transaction.
        using (var stream = new FileStream(file, FileMode.Create, FileAccess.Write, FileShare.None)) { stream.Write(new byte[] { 7, 8 }); stream.Flush(true); }
        try { return store.TryCommitImageOptimization(source, target); }
        finally { if (File.Exists(file) && !store.ReferencesImage(target)) File.Delete(file); }
    }
}
