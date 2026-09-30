using Rewind;
using Microsoft.Data.Sqlite;
using System.Diagnostics;
using System.Text.Json;

internal static class ArchiveFramesTests
{
    public static void Run(Action<bool, string> check, string root)
    {
        using var store = new MemoryStore(Path.Combine(root, "archive-window"));
        check(store.LatestArchiveDay() == null, "Empty archive has no latest day");
        check(store.ArchivePreview(DateTime.Today).Count == 0, "Empty startup preview remains empty");
        var day = new DateTime(2026, 9, 25);
        var localMidnight = new DateTimeOffset(day);
        var text = string.Join(" ", Enumerable.Repeat("Screen OCR content", 400));
        var regions = Enumerable.Range(0, 80).Select(i => new TextRegion("Line " + i, .1, i / 100d, .8, .01)).ToList();
        for (var lane = -3; lane <= 3; lane++)
            for (var row = 0; row < 9; row++)
                store.Save(new MemoryFrame { Id = $"archive-{lane}-{row}", Timestamp = localMidnight.AddDays(lane).AddHours(row + 1),
                    AppName = "Fixture", Title = $"Day {lane} row {row}", ImagePath = "frames/fixture.png", Text = text, Regions = regions });
        store.Save(new MemoryFrame { Id = "demo-future", Timestamp = localMidnight.AddDays(30), Demo = true });
        store.Save(new MemoryFrame { Id = "deleted-future", Timestamp = localMidnight.AddDays(31), DeletedAt = localMidnight });
        check(store.LatestArchiveDay() == day.AddDays(3), "Latest archive excludes demo and deleted memories");
        var frames = store.ArchiveFrames(day, perDayLimit: 3);
        check(frames.Count == 15, "Archive limit applies independently to all five days");
        check(frames.GroupBy(f => f.Timestamp.LocalDateTime.Date).All(g => g.Count() == 3), "A busy newest day does not starve other day columns");
        check(frames.All(f => Math.Abs((f.Timestamp.LocalDateTime.Date - day).Days) <= 2), "Archive query stays inside its local-day window");
        check(frames.All(f => f.Text.Length == 0 && f.Regions.Count == 0 && f.MeetingRegions.Count == 0), "Wall metadata does not hydrate OCR payloads");
        check(frames.All(f => f.OcrId != null && f.ImagePath == "frames/fixture.png" && f.Title.Length > 0), "Wall metadata retains content identity and labels");
        check(frames.SequenceEqual(frames.OrderByDescending(f => f.Timestamp).ThenBy(f => f.Id, StringComparer.Ordinal)), "Archive rows use stable time/id ordering");
        var full = store.Frame(frames[0].Id)!;
        check(full.Text == text && full.Regions.Count == 80, "Opening a lightweight record can still retrieve full OCR");
        var preview = store.ArchivePreview(day, perDayLimit: 3);
        check(preview.Select(f => f.Id).SequenceEqual(frames.Select(f => f.Id)),
            "Startup preview uses the newest stable prefix of each local day");
        check(preview.All(f => f.ImagePath == "frames/fixture.png" && f.Title.Length > 0),
            "Startup preview preserves labels and image identity without OCR hydration");
        check(store.PendingFrameIds().Order().SequenceEqual(store.PendingFrames().Select(f => f.Id).Order()),
            "ID-only background discovery finds exactly the pending and working OCR records");
        check(store.ArchiveFrames(day, 0, 100).Count == 9, "Single-day query preserves all records below the cap");
        store.Save(new MemoryFrame { Id = "midnight-start", Timestamp = localMidnight });
        store.Save(new MemoryFrame { Id = "midnight-end", Timestamp = new DateTimeOffset(day.AddDays(1)) });
        var bounded = store.ArchiveFrames(day, 0, 100);
        check(bounded.Any(f => f.Id == "midnight-start") && bounded.All(f => f.Id != "midnight-end"), "Day interval includes its start and excludes the next midnight");
        check(store.ArchiveFrames(day.AddDays(-20)).Count == 0, "Older empty dates remain empty instead of repeating recent images");
        CheckArchiveRevision(check, root);
        CheckCompleteIndex(check, root);
    }

    static void CheckArchiveRevision(Action<bool, string> check, string root)
    {
        using var store = new MemoryStore(Path.Combine(root, "archive-revision"));
        check(store.ArchiveRevision == 0, "New store starts with a zero archive revision");
        store.ArchiveIndex(DateTime.Today);
        store.LatestArchiveDay();
        check(store.ArchiveRevision == 0, "Reading archive metadata does not advance its revision");

        var recent = new MemoryFrame { Id = "revision-recent", Timestamp = DateTimeOffset.Now,
            AppName = "Fixture", Title = "First", ImagePath = "frames/first.png" };
        store.Save(recent);
        check(store.ArchiveRevision == 1, "Inserting a visible frame advances the revision");
        store.Save(recent with { Text = "OCR only" });
        store.Extend(recent.Id, recent.Timestamp.AddMinutes(1));
        store.Recognition(recent.Id, RecognitionState.Complete);
        check(store.ArchiveRevision == 1, "OCR and end-time updates do not change wall metadata");
        store.Save(recent with { Title = "Second" });
        check(store.ArchiveRevision == 2, "Changing a card label advances the revision");
        store.ReplaceImage("frames/first.png", "frames/second.png");
        check(store.ArchiveRevision == 3, "Changing a card image path advances the revision");
        store.Star(recent.Id);
        check(store.ArchiveRevision == 4, "Starring a visible frame advances the revision");
        store.Trash(store.Frame(recent.Id)!);
        check(store.ArchiveRevision == 5, "Trashing a visible frame advances the revision");
        store.Restore(store.Frame(recent.Id)!);
        check(store.ArchiveRevision == 6, "Restoring a frame advances the revision");
        store.Save(new MemoryFrame { Id = "revision-demo", Timestamp = recent.Timestamp, Demo = true });
        check(store.ArchiveRevision == 6, "Writing a hidden demo frame leaves the wall revision unchanged");

        var old = new MemoryFrame { Id = "revision-old", Timestamp = DateTimeOffset.Now.AddDays(-10),
            ImagePath = "frames/old.png" };
        store.Save(old);
        check(store.ArchiveRevision == 7, "Inserting an older visible frame advances the revision");
        store.Retain(1);
        check(store.ArchiveRevision == 8, "Retention that removes a visible card advances the revision");
        store.Retain(1);
        check(store.ArchiveRevision == 8, "No-op retention does not advance the revision");
        check(store.EmptyTrash() == 1 && store.ArchiveRevision == 9,
            "Committed cleanup advances the revision after deleting a frame");
        store.Save(new MemoryFrame { Id = "rollback", Timestamp = DateTimeOffset.Now });
        store.Trash(store.Frame("rollback")!);
        var beforeRollback = store.ArchiveRevision;
        using (var db = new SqliteConnection(new SqliteConnectionStringBuilder
               { DataSource = Path.Combine(store.Root, "memory.sqlite") }.ToString()))
        {
            db.Open();
            using var trigger = db.CreateCommand();
            trigger.CommandText = "CREATE TRIGGER fail_archive_delete BEFORE DELETE ON frames " +
                "WHEN old.id='rollback' BEGIN SELECT RAISE(ABORT,'fixture rollback'); END";
            trigger.ExecuteNonQuery();
        }
        var rolledBack = false;
        try { store.Cleanup(store.CleanupPreview(CleanupScope.Trash, true)); }
        catch (SqliteException) { rolledBack = true; }
        check(rolledBack && store.ArchiveRevision == beforeRollback && store.Frame("rollback") != null,
            "Failed cleanup rolls back without advancing the archive revision");
    }

    static void CheckCompleteIndex(Action<bool, string> check, string root)
    {
        var day = new DateTime(2026, 9, 25);
        using var store = new MemoryStore(Path.Combine(root, "archive-complete-index"));
        using (var db = new SqliteConnection(new SqliteConnectionStringBuilder
               { DataSource = Path.Combine(store.Root, "memory.sqlite") }.ToString()))
        {
            db.Open();
            using var transaction = db.BeginTransaction();
            using var command = db.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = "INSERT INTO frames(id,time,app,text,starred,deleted,demo,json,ocr_id) " +
                "VALUES($id,$time,'Fixture','',0,$deleted,$demo,$json,NULL)";
            var id = command.Parameters.Add("$id", SqliteType.Text);
            var time = command.Parameters.Add("$time", SqliteType.Real);
            var deleted = command.Parameters.Add("$deleted", SqliteType.Real);
            var demo = command.Parameters.Add("$demo", SqliteType.Integer);
            var json = command.Parameters.Add("$json", SqliteType.Text);
            void Add(string name, DateTimeOffset when, bool isDemo = false, bool isDeleted = false)
            {
                id.Value = name;
                time.Value = when.ToUnixTimeMilliseconds() / 1000d;
                deleted.Value = isDeleted ? time.Value : DBNull.Value;
                demo.Value = isDemo ? 1 : 0;
                json.Value = JsonSerializer.Serialize(new MemoryFrame
                {
                    Id = name, Timestamp = when, AppName = "Fixture", Title = "Card " + name,
                    ImagePath = "frames/fixture.png"
                });
                command.ExecuteNonQuery();
            }
            for (var lane = -2; lane <= 2; lane++)
            {
                var count = lane == 0 ? 12_017 : 2_103;
                var midnight = new DateTimeOffset(day.AddDays(lane));
                for (var row = 0; row < count; row++)
                    Add($"lane{lane}-row{row:D5}", midnight.AddMilliseconds(row * 86_399_000d / count));
            }
            var center = new DateTimeOffset(day);
            Add("tie-b", center.AddHours(12));
            Add("tie-a", center.AddHours(12));
            Add("outside-before", center.AddDays(-3));
            Add("outside-after", center.AddDays(3));
            Add("hidden-demo", center.AddHours(13), isDemo: true);
            Add("hidden-deleted", center.AddHours(14), isDeleted: true);
            transaction.Commit();
        }

        var warm = store.ArchiveIndex(day);
        var preview = store.ArchivePreview(day);
        var expectedPreview = warm.GroupBy(f => f.Timestamp.LocalDateTime.Date)
            .SelectMany(g => g.Take(48)).OrderByDescending(f => f.Timestamp)
            .ThenBy(f => f.Id, StringComparer.Ordinal).ToArray();
        check(preview.Count == 240 && preview.SequenceEqual(expectedPreview),
            "Five busy days produce at most 240 startup entries without starving a column");
        check(store.ArchivePreview(day, 2_000).Count == 640,
            "Startup preview keeps a bounded budget even when callers request an excessive limit");
        var previewRevision = store.ArchiveRevision;
        store.ArchivePreview(day);
        check(store.ArchiveRevision == previewRevision, "Preview queries do not invalidate retained cards");
        check(warm.Count == 20_431, "Archive index includes every row of five busy days without a per-day cap");
        check(warm.Count(f => f.Timestamp.LocalDateTime.Date == day) == 12_019,
            "A day with more than ten thousand frames keeps its full scroll depth");
        check(warm.Any(f => f.Id == "lane-2-row00000") && warm.Any(f => f.Id == "lane2-row02102"),
            "Both earliest and latest cards across the window remain reachable");
        check(warm.All(f => !f.Id.StartsWith("outside-") && !f.Id.StartsWith("hidden-")),
            "Archive window excludes other days, demo and deleted rows");
        check(warm.SequenceEqual(warm.OrderByDescending(f => f.Timestamp).ThenBy(f => f.Id, StringComparer.Ordinal)),
            "Full index has stable timestamp descending and ID ascending ordering");
        check(warm.FindIndex(f => f.Id == "tie-a") + 1 == warm.FindIndex(f => f.Id == "tie-b"),
            "Equal timestamps break ties by ID");
        check(warm.All(f => f.ImagePath == "frames/fixture.png" && f.Title.Length > 0),
            "Wall index retains only identity, labels and image paths");
        check(store.Frame("lane0-row00000")?.Id == "lane0-row00000",
            "Selecting an index entry can hydrate its full frame");

        using var canceled = new CancellationTokenSource();
        canceled.Cancel();
        var preCanceled = false;
        try { store.ArchiveIndex(day, cancellation: canceled.Token); }
        catch (OperationCanceledException) { preCanceled = true; }
        check(preCanceled, "Archive index honors cancellation before query execution");
        var previewCanceled = false;
        try { store.ArchivePreview(day, cancellation: canceled.Token); }
        catch (OperationCanceledException) { previewCanceled = true; }
        check(previewCanceled, "Startup preview honors cancellation before touching the database");

        using var during = new CancellationTokenSource();
        var interrupted = false;
        try { store.ArchiveIndex(day, 2, during.Token, TimeZoneInfo.Local,
            count => { if (count == 500) during.Cancel(); }); }
        catch (OperationCanceledException) { interrupted = true; }
        check(interrupted, "Archive scan checks cancellation while materializing a busy window");

        TimeZoneInfo eastern;
        try { eastern = TimeZoneInfo.FindSystemTimeZoneById("America/New_York"); }
        catch (TimeZoneNotFoundException) { eastern = TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time"); }
        var spring = MemoryStore.ArchiveDayBounds(new DateTime(2026, 3, 8), eastern);
        var fall = MemoryStore.ArchiveDayBounds(new DateTime(2026, 11, 1), eastern);
        check((spring.Until - spring.Since).TotalHours == 23 && (fall.Until - fall.Since).TotalHours == 25,
            "Archive local-day bounds honor both DST transitions");
        store.Save(new MemoryFrame { Id = "spring-before", Timestamp = spring.Since.AddMilliseconds(-1) });
        store.Save(new MemoryFrame { Id = "spring-start", Timestamp = spring.Since });
        store.Save(new MemoryFrame { Id = "spring-end", Timestamp = spring.Until.AddMilliseconds(-1) });
        store.Save(new MemoryFrame { Id = "spring-after", Timestamp = spring.Until });
        var springRows = store.ArchiveIndex(new DateTime(2026, 3, 8), 0, default, eastern);
        check(springRows.Select(f => f.Id).Order().SequenceEqual(new[] { "spring-end", "spring-start" }),
            "Spring DST query includes both day edges and excludes adjacent instants");
        store.Save(new MemoryFrame { Id = "fall-before", Timestamp = fall.Since.AddMilliseconds(-1) });
        store.Save(new MemoryFrame { Id = "fall-start", Timestamp = fall.Since });
        store.Save(new MemoryFrame { Id = "fall-end", Timestamp = fall.Until.AddMilliseconds(-1) });
        store.Save(new MemoryFrame { Id = "fall-after", Timestamp = fall.Until });
        var fallRows = store.ArchiveIndex(new DateTime(2026, 11, 1), 0, default, eastern);
        check(fallRows.Select(f => f.Id).Order().SequenceEqual(new[] { "fall-end", "fall-start" }),
            "Fall DST query includes both day edges and excludes adjacent instants");

        var samples = new double[5];
        for (var i = 0; i < samples.Length; i++)
        {
            var start = Stopwatch.GetTimestamp();
            check(store.ArchiveIndex(day).Count == warm.Count, "Repeated full-index query remains complete");
            samples[i] = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        }
        Array.Sort(samples);
        Console.WriteLine($"ARCHIVE_INDEX_BENCH: rows={warm.Count}, medianMs={samples[2]:F1}, maxMs={samples[^1]:F1}");
        var fullMedian = samples[2];
        for (var i = 0; i < samples.Length; i++)
        {
            var start = Stopwatch.GetTimestamp();
            store.ArchivePreview(day);
            samples[i] = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        }
        Array.Sort(samples);
        Console.WriteLine($"ARCHIVE_PREVIEW_BENCH: rows={preview.Count}, medianMs={samples[2]:F1}, maxMs={samples[^1]:F1}, fullIndexMedianMs={fullMedian:F1}");
    }
}
