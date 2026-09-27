using Rewind;

static class DataDirectoryMigrationTests
{
    public static void Run(Action<bool,string> assert, string testRoot)
    {
        assert(AppPaths.DefaultDataRoot.EndsWith(Path.Combine("Recall","Data")),
            "The default library belongs to Recall/Data");
        assert(!AppPaths.UsesDefaultDataRoot &&
            DataDirectoryMigration.PrepareDefault() == DataDirectoryMigrationResult.ExplicitRoot,
            "An explicit test root never scans the production legacy path");

        var fixture = Path.Combine(testRoot,"directory-migration");
        var legacy = Path.Combine(fixture,"RewindReplica");
        var target = Path.Combine(fixture,"Recall","Data");
        Directory.CreateDirectory(Path.Combine(legacy,"frames"));
        Directory.CreateDirectory(Path.Combine(legacy,"recordings"));
        Directory.CreateDirectory(Path.Combine(legacy,"models"));
        File.WriteAllText(Path.Combine(legacy,"memory.sqlite"),"database sentinel");
        File.WriteAllText(Path.Combine(legacy,"memory.sqlite-wal"),"wal sentinel");
        File.WriteAllText(Path.Combine(legacy,"memory.sqlite-shm"),"shm sentinel");
        File.WriteAllText(Path.Combine(legacy,"settings.json"),"settings sentinel");
        File.WriteAllText(Path.Combine(legacy,"frames","image.recallframe"),"frame sentinel");
        File.WriteAllText(Path.Combine(legacy,"recordings","audio.wav"),"audio sentinel");
        File.WriteAllText(Path.Combine(legacy,"models","speech.bin"),"model sentinel");
        File.WriteAllText(Path.Combine(legacy,"provider.key"),"key sentinel");
        assert(DataDirectoryMigration.MoveLegacy(legacy,target) == DataDirectoryMigrationResult.Moved &&
            !Directory.Exists(legacy) && File.ReadAllText(Path.Combine(target,"memory.sqlite")) == "database sentinel" &&
            File.ReadAllText(Path.Combine(target,"memory.sqlite-wal")) == "wal sentinel" &&
            File.ReadAllText(Path.Combine(target,"memory.sqlite-shm")) == "shm sentinel" &&
            File.ReadAllText(Path.Combine(target,"settings.json")) == "settings sentinel" &&
            File.ReadAllText(Path.Combine(target,"frames","image.recallframe")) == "frame sentinel" &&
            File.ReadAllText(Path.Combine(target,"recordings","audio.wav")) == "audio sentinel" &&
            File.ReadAllText(Path.Combine(target,"models","speech.bin")) == "model sentinel" &&
            File.ReadAllText(Path.Combine(target,"provider.key")) == "key sentinel",
            "An atomic directory move carries database, settings, media, models and account key together");
        assert(DataDirectoryMigration.MoveLegacy(legacy,target) == DataDirectoryMigrationResult.AlreadyAtDestination,
            "A second launch is idempotent after the old directory is gone");

        var missing = Path.Combine(fixture,"missing");
        var unused = Path.Combine(fixture,"unused","Data");
        assert(DataDirectoryMigration.MoveLegacy(missing,unused) == DataDirectoryMigrationResult.NoLegacyDirectory &&
            !Directory.Exists(unused), "No legacy directory does not create an empty library");

        var conflictingOld = Path.Combine(fixture,"conflict-old");
        var conflictingNew = Path.Combine(fixture,"conflict-new");
        Directory.CreateDirectory(conflictingOld); Directory.CreateDirectory(conflictingNew);
        File.WriteAllText(Path.Combine(conflictingOld,"memory.sqlite"),"old library");
        File.WriteAllText(Path.Combine(conflictingNew,"memory.sqlite"),"new library");
        var conflictStopped = false;
        try { DataDirectoryMigration.MoveLegacy(conflictingOld,conflictingNew); }
        catch (IOException error) { conflictStopped = error.Message.Contains(conflictingOld) && error.Message.Contains(conflictingNew); }
        assert(conflictStopped && File.ReadAllText(Path.Combine(conflictingOld,"memory.sqlite")) == "old library" &&
            File.ReadAllText(Path.Combine(conflictingNew,"memory.sqlite")) == "new library",
            "Two existing libraries stop startup without merging or overwriting either one");

        var blockedOld = Path.Combine(fixture,"blocked-old");
        var blockedParent = Path.Combine(fixture,"blocked-parent");
        Directory.CreateDirectory(blockedOld);
        File.WriteAllText(Path.Combine(blockedOld,"memory.sqlite"),"retained database");
        File.WriteAllText(blockedParent,"a file blocks the destination parent");
        var blockedNew = Path.Combine(blockedParent,"Data");
        var failureStopped = false;
        try { DataDirectoryMigration.MoveLegacy(blockedOld,blockedNew); }
        catch (IOException error) { failureStopped = error.Message.Contains(blockedOld) && error.Message.Contains(blockedNew); }
        assert(failureStopped && File.ReadAllText(Path.Combine(blockedOld,"memory.sqlite")) == "retained database" &&
            !Directory.Exists(blockedNew), "A failed move leaves the old database in place and does not create an empty new one");
    }
}
