using Rewind;
using Recall;
using Microsoft.Data.Sqlite;
internal static class ParityTests
{
    public static async Task<int> Run(string root)
    {
        var count = 0;
        void Check(bool ok, string label)
        {
            if (!ok)
                throw new Exception(label);
            count++;
        }
        Check(AppDisplayName.For("MsEdge.EXE") == "Microsoft Edge", "Process alias accepts mixed case and .exe");
        Check(AppDisplayName.For("EXPLORER") == "File Explorer", "Process alias ignores case");
        Check(AppDisplayName.For("notepad.exe") == "Notepad", "Notepad executable has a friendly label");
        Check(AppDisplayName.For("Microsoft Edge") == "Microsoft Edge", "Already friendly names stay unchanged");
        Check(AppDisplayName.For("Research") == "Research" && AppDisplayName.For("Design") == "Design", "Fixture labels are not remapped to applications");
        using (var store = new MemoryStore(Path.Combine(root, "parity")))
        {
            var now = DateTimeOffset.Now;
            var frame = new MemoryFrame { Id = "paper", AppName = "Obsidian", Title = "Research", Text = "My papers about Café and 会议记录 100%", Regions = [new("papers", .1, .2, .3, .05)], Timestamp = now };
            store.Save(frame);
            store.Save(frame with
            {
                Id = "paper2",
                Timestamp = now.AddSeconds(10)
            });
            Check(store.Frames("paper").Count == 2, "Prefix search finds plural");
            Check(store.Frames("cafe paper").Count == 2, "Accent normalization and AND search");
            Check(store.Frames("会议").Count == 2, "CJK substring search");
            Check(store.Retrieve("What do you know about zebracornquux?").Count == 0, "Ask does not fabricate unrelated evidence");
            using (var db = new SqliteConnection("Data Source=" + Path.Combine(store.Root, "memory.sqlite")))
            {
                db.Open();
                using var cmd = db.CreateCommand();
                cmd.CommandText = "SELECT COUNT(*) FROM ocr_payloads";
                Check(Convert.ToInt32(cmd.ExecuteScalar()) == 1, "Identical OCR payload shared");
                cmd.CommandText = "SELECT json FROM frames LIMIT 1";
                Check(!((string)cmd.ExecuteScalar()!).Contains("papers about"), "Frame JSON does not duplicate OCR");
            }
            store.Extend(frame.Id, now.AddSeconds(8));
            store.Recognized(frame.Id, frame.Text, frame.Regions);
            Check(store.Frame(frame.Id)!.EndTimestamp == now.AddSeconds(8), "OCR completion preserves duration updates");
            Check(store.At(now.AddSeconds(5))!.Id == frame.Id, "Static duration maps to frame");
            var session = new RecordingSession("speech", now, now.AddMinutes(3), "recordings/speech.mp4", true);
            store.SaveSession(session);
            store.Save(frame with
            {
                Id = "static",
                SessionId = session.Id,
                EndTimestamp = now.AddMinutes(3)
            });
            store.SaveTranscript(new("later", session.Id, now.AddMinutes(2), "Audio", "singularitytalk"));
            Check(store.Frames("singularitytalk").Any(f => f.Id == "static"), "Transcript search finds a static frame interval");
            store.Trash(store.Frame("static")!);
            store.EmptyTrash();
            Check(!store.FinishSpeech(session, []), "Deleted sessions cannot be resurrected by speech completion");
            Check(!store.SpeechStatus(session.Id, RecognitionState.Failed, "late worker failure") && store.Session(session.Id) == null, "Late speech failures cannot recreate deleted sessions");
            var usage = new UsageRecorder(store);
            usage.Transition(new("A", "a"), now);
            usage.Transition(new("B", "b"), now.AddSeconds(7));
            usage.Stop(now.AddSeconds(13));
            var intervals = store.Usage(now, now.AddSeconds(20));
            Check(intervals.Count == 2 && intervals[0].End == intervals[1].Start, "App transitions meet at exact boundaries");
            var track = TimelineMath.Continuous(intervals, now.AddSeconds(-5), now.AddSeconds(20));
            Check(track.Zip(track.Skip(1)).All(x => x.First.End == x.Second.Start) && track.Sum(x => x.Seconds) == 25, "Timeline has continuous coverage");
            store.SaveSession(new("active", now, null, "recordings/active.mp4", false));
            store.Save(frame with
            {
                Id = "active",
                SessionId = "active"
            });
            store.Star("paper");
            var plan = store.CleanupPreview(CleanupScope.All, true);
            Check(!plan.Ids.Contains("active") && !plan.Ids.Contains("paper"), "Cleanup protects recording and stars");
            store.Star("paper2");
            Check(store.Cleanup(plan) == 0, "Cleanup revalidates stars after preview");
            Check(store.SafePath("../outside") == null, "Cleanup rejects path traversal");
        }
        using (var tileStore = new MemoryStore(Path.Combine(root, "tiles")))
        {
            var relative = "frames/tiles/t1-" + new string('A', 64) + ".png";
            Directory.CreateDirectory(Path.Combine(tileStore.Root, "frames", "tiles"));
            File.WriteAllBytes(Path.Combine(tileStore.Root, relative), [1]);
            var manifest = new ScreenManifest(1, 100, 100, [new(relative, 0, 0, 100, 100)]);
            var json = System.Text.Json.JsonSerializer.Serialize(manifest);
            Check(ScreenManifest.Parse(json).Tiles.Count == 1, "Valid tile manifest");
            foreach (var invalid in new[] { json.Replace(relative, "../outside.png"), json.Replace("\"Width\":100", "\"Width\":16001"), System.Text.Json.JsonSerializer.Serialize(manifest with { Tiles = [new(relative, 1, 0, 100, 100)] }) })
            {
                try
                {
                    ScreenManifest.Parse(invalid);
                    throw new Exception("Invalid manifest accepted");
                }
                catch (InvalidDataException) { count++; }
            }
            foreach (var id in new[] { "first", "second" })
            {
                var image = "frames/" + id + ".recallframe";
                File.WriteAllText(Path.Combine(tileStore.Root, image), json);
                tileStore.Save(new()
                {
                    Id = id,
                    ImagePath = image
                });
            }
            tileStore.Trash(tileStore.Frame("first")!);
            tileStore.EmptyTrash();
            Check(File.Exists(Path.Combine(tileStore.Root, relative)), "Cleanup retains shared tiles");
            tileStore.Trash(tileStore.Frame("second")!);
            tileStore.EmptyTrash();
            Check(!File.Exists(Path.Combine(tileStore.Root, relative)), "Cleanup removes last tile reference");
        }
        var zone = TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
        var begin = new DateTimeOffset(2026, 11, 1, 7, 0, 0, TimeSpan.Zero);
        var end = begin.AddHours(25);
        var report = UsageReport.Build(new(2026, 11, 1), [new("dst", new("Test", "test"), begin, end)], zone);
        Check(report.TotalSeconds == 25 * 3600 && report.Hours.Sum() == report.TotalSeconds && report.Hours[1] == 7200, "Fall DST preserves actual elapsed time");
        int starts = 0, stops = 0;
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var coordinator = new RecordingCoordinator(async () => { starts++; entered.SetResult(); await release.Task; }, () => { stops++; return Task.CompletedTask; }, TimeSpan.Zero);
        coordinator.Request(true);
        await entered.Task;
        coordinator.SetVisible(true);
        release.SetResult();
        await coordinator.Settled();
        Check(starts == 1 && stops == 1 && !coordinator.State.Active && coordinator.State.AutomaticallyPaused, "Opening UI during capture startup reconciles to paused");
        await coordinator.Shutdown();
        var simple = new RecordingCoordinator(() => { starts++; return Task.CompletedTask; }, () => { stops++; return Task.CompletedTask; }, TimeSpan.FromMilliseconds(10));
        simple.Request(true);
        simple.SetVisible(true);
        await simple.Settled();
        Check(!simple.State.Active, "Visible interface never starts capture");
        simple.SetVisible(false);
        await simple.Settled();
        Check(simple.State.Active, "Hiding UI resumes requested capture");
        simple.Request(false);
        await simple.Settled();
        simple.SetVisible(true);
        simple.SetVisible(false);
        await simple.Settled();
        Check(!simple.State.Active, "Explicit pause persists after hiding UI");
        await simple.Shutdown();
        RecordingCoordinator? plannedStop = null;
        var plannedStarts = 0;
        plannedStop = new RecordingCoordinator(
            () => { plannedStarts++; return Task.CompletedTask; },
            () => { plannedStop!.Interrupted(); return Task.CompletedTask; }, TimeSpan.Zero);
        plannedStop.Request(true);
        await plannedStop.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        plannedStop.SetVisible(true);
        await plannedStop.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(plannedStop.State.Requested && plannedStop.State.AutomaticallyPaused && !plannedStop.State.CaptureFaulted,
            "A stop callback during an intentional UI pause keeps the recording request");
        plannedStop.SetVisible(false);
        await plannedStop.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(plannedStarts == 2 && plannedStop.State.Active, "Closing the UI resumes after its intentional stop");
        await plannedStop.Shutdown();

        var recoveryStarts = 0;
        var recoveryStops = 0;
        var recovery = new RecordingCoordinator(
            () => { if (++recoveryStarts == 1) throw new InvalidOperationException("Fake capture startup failure"); return Task.CompletedTask; },
            () => { recoveryStops++; return Task.CompletedTask; }, TimeSpan.Zero);
        recovery.Request(true);
        await recovery.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(recovery.State.Requested && recovery.State.CaptureFaulted && !recovery.State.Active && recoveryStarts == 1,
            "Startup failure preserves user intent without retrying in a loop");
        recovery.SetVisible(true);
        recovery.SetVisible(false);
        await recovery.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(recovery.State.Requested && recovery.State.Active && !recovery.State.CaptureFaulted && recoveryStarts == 2,
            "Closing the UI retries one failed capture");
        recovery.Interrupted();
        await recovery.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(recovery.State.Requested && recovery.State.CaptureFaulted && !recovery.State.Active && recoveryStops == 1,
            "Unexpected capture interruption stops capture but retains user intent");
        recovery.SetVisible(true);
        recovery.SetVisible(false);
        await recovery.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(recovery.State.Active && recoveryStarts == 3, "Closing again resumes after an interruption");
        recovery.Request(false);
        await recovery.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        recovery.SetVisible(true);
        recovery.SetVisible(false);
        await recovery.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(!recovery.State.Requested && !recovery.State.Active && recoveryStarts == 3,
            "An explicit manual stop is never undone by a later window close");
        await recovery.Shutdown();

        var racedStarts = 0;
        var startupEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var startupRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var raced = new RecordingCoordinator(async () =>
        {
            if (++racedStarts == 1)
            {
                startupEntered.SetResult();
                await startupRelease.Task;
                throw new InvalidOperationException("Fake obsolete startup failure");
            }
        }, () => Task.CompletedTask, TimeSpan.Zero);
        raced.Request(true);
        await startupEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        raced.SetVisible(true);
        raced.SetVisible(false);
        startupRelease.SetResult();
        await raced.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(raced.State.Requested && raced.State.Active && !raced.State.CaptureFaulted && racedStarts == 2,
            "A failed in-flight startup cannot overwrite a newer quick show/hide request");
        await raced.Shutdown();
        var stopEntered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stopRelease = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stopRaceStarts = 0;
        var stopRaceStops = 0;
        var stopRace = new RecordingCoordinator(
            () => { stopRaceStarts++; return Task.CompletedTask; },
            async () =>
            {
                if (++stopRaceStops == 1)
                {
                    stopEntered.SetResult();
                    await stopRelease.Task;
                    throw new InvalidOperationException("Fake obsolete stop failure");
                }
            }, TimeSpan.Zero);
        stopRace.Request(true);
        await stopRace.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        stopRace.SetVisible(true);
        await stopEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        stopRace.SetVisible(false);
        stopRelease.SetResult();
        await stopRace.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(stopRace.State.Requested && stopRace.State.Active && !stopRace.State.CaptureFaulted && stopRaceStarts == 2,
            "A failed in-flight stop cannot strand a newer hidden request");
        await stopRace.Shutdown();
        var stableStarts = 0;
        var stableStops = 0;
        var stableStopFailure = new RecordingCoordinator(
            () => { stableStarts++; return Task.CompletedTask; },
            () =>
            {
                if (++stableStops == 1) throw new InvalidOperationException("Fake stable stop failure");
                return Task.CompletedTask;
            }, TimeSpan.Zero);
        stableStopFailure.Request(true);
        await stableStopFailure.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        stableStopFailure.Rotate();
        await stableStopFailure.Settled().WaitAsync(TimeSpan.FromSeconds(5));
        Check(stableStopFailure.State.Requested && stableStopFailure.State.CaptureFaulted && !stableStopFailure.State.Active && stableStarts == 1,
            "A stop failure without a newer request remains faulted instead of retrying forever");
        await stableStopFailure.Shutdown();
        var time = DateTimeOffset.Now;
        var lines = TranscriptPresentation.Visible([new("a", "s", time, "You", "This is a long enough spoken sentence"), new("b", "s", time.AddSeconds(1), "Meeting", "This is a long enough spoken sentence"), new("c", "s", time, "Audio", "[BLANK_AUDIO]")]);
        Check(lines.Count == 1 && !TranscriptPresentation.HasDistinctSpeakers(lines), "One speaker and track echo render on one side");
        try
        {
            var shortcuts = new ShortcutSettings { Toggle = new(32, 0) };
            shortcuts.Validate();
            throw new Exception("Missing modifier accepted");
        }
        catch (InvalidOperationException) { count++; }
        return count;
    }
}
