using Rewind;

static class DataDirectoryMigrationTests
{
    public static void Run(Action<bool,string> assert, string testRoot)
    {
        DefaultLibrary Pair(string name, bool windows=true) => new(Path.Combine(testRoot,"shared-location",name),windowsLayout:windows);
        void Seed(string root,string id)
        {
            using var store=new MemoryStore(root);
            store.Save(new MemoryFrame {Id=id,ImagePath="frames/fixture.png",Text="Original "+id});
            File.WriteAllBytes(Path.Combine(root,"frames","fixture.png"),[1,2,3]);
        }
        void Conflict(DefaultLibrary pair,string description)
        {
            try {pair.ResolveDefault(()=>{});throw new Exception(description);}
            catch(RecallException e){assert(e.Code=="conflict",description);}
        }
        assert(AppPaths.DataRoot==Path.GetFullPath(testRoot),"The shared resolver preserves the caller's explicit test root");
        var missing=Pair("missing");
        assert(missing.ResolveDefault(()=>{})==missing.Current && !Directory.Exists(missing.Parent),"A new Windows default is flat Recall and resolving it creates no empty library");
        try {using var reader=new MemoryStore(missing.Nested,readOnly:true,initialize:false,locationPair:missing);throw new Exception("Opened missing nested database");}
        catch(Microsoft.Data.Sqlite.SqliteException) {assert(!Directory.Exists(missing.Parent),"Missing nested read does not create a library or its parent");}

        var nested=Pair("nested");Seed(nested.Nested,"nested-original");
        Directory.CreateDirectory(Path.Combine(nested.Nested,"models"));
        File.WriteAllText(Path.Combine(nested.Nested,"models","speech.bin"),"weights retained in place");
        File.WriteAllText(Path.Combine(nested.Nested,"provider.key"),"encrypted fixture key");
        var original=File.ReadAllBytes(Path.Combine(nested.Nested,"memory.sqlite"));
        var resolved=nested.ResolveDefault(()=>{});
        assert(resolved==nested.Nested && nested.ResolveDefault(()=>{})==nested.Nested && !File.Exists(Path.Combine(nested.Current,"memory.sqlite")),"Repeated Windows startup reuses the sole Recall/Data database without creating a flat database");
        using(var store=new MemoryStore(resolved,readOnly:true,initialize:false,locationPair:nested))
        {
            assert(store.Frame("nested-original")?.Text=="Original nested-original", "The selected nested library retains its real SQLite records");
            try {using var exclusive=new LibraryLocationLease(nested.Parent,true);throw new Exception("Moved an active nested reader");}
            catch(RecallException e){assert(e.Code=="busy","Nested read lifetime holds the same external shared location lock");}
        }
        assert(original.SequenceEqual(File.ReadAllBytes(Path.Combine(nested.Nested,"memory.sqlite"))) &&
            File.ReadAllText(Path.Combine(nested.Nested,"models","speech.bin"))=="weights retained in place" &&
            File.ReadAllText(Path.Combine(nested.Nested,"provider.key"))=="encrypted fixture key",
            "Resolving deployed Recall/Data preserves database, model and key bytes without another migration");
        assert(DefaultLibrary.Resolve(nested.Current)==nested.Current && DefaultLibrary.Resolve(nested.Nested)==nested.Nested,
            "Explicit flat and nested roots are never implicitly redirected");
        using(var exclusive=new LibraryLocationLease(nested.Parent,true))
        {
            try {using var reader=new MemoryStore(nested.Nested,readOnly:true,initialize:false,locationPair:nested);throw new Exception("Nested reader entered migration");}
            catch(RecallException e){assert(e.Code=="busy","External migration lock excludes nested MemoryStore readers");}
            try {using var writer=new LibraryLease(nested.Nested,locationPair:nested);throw new Exception("Nested writer entered migration");}
            catch(RecallException e){assert(e.Code=="busy","External migration lock excludes nested writers");}
        }
        var flat=Pair("flat");Seed(flat.Current,"flat-original");
        assert(flat.ResolveDefault(()=>{})==flat.Current,"An existing flat Recall database remains the Windows default");
        Seed(nested.Current,"parallel-flat");Conflict(nested,"Flat and nested SQLite libraries fail closed instead of preferring either");
        using(var store=new MemoryStore(nested.Nested,readOnly:true,initialize:false))assert(store.Frame("nested-original")!=null,"Conflict preserves original nested records");
        using(var store=new MemoryStore(nested.Current,readOnly:true,initialize:false))assert(store.Frame("parallel-flat")!=null,"Conflict preserves independent flat records");
        var oldNested=Pair("legacy-nested");Seed(oldNested.Legacy,"legacy-original");Seed(oldNested.Nested,"nested-original");
        Conflict(oldNested,"Legacy and nested libraries fail closed");
        var all=Pair("all-three");Seed(all.Legacy,"legacy");Seed(all.Current,"flat");Seed(all.Nested,"nested");
        Conflict(all,"All three existing libraries remain separate");
        var damaged=Pair("damaged-flat");Seed(damaged.Nested,"nested");File.WriteAllText(Path.Combine(damaged.Current,"memory.sqlite"),"unrecognized occupied database");
        Conflict(damaged,"An unreadable flat database is not ignored when nested data also exists");
        var legacy=Pair("legacy-only");Seed(legacy.Legacy,"migrated");
        assert(legacy.ResolveDefault(()=>{})==legacy.Current && !Directory.Exists(legacy.Legacy) && !Directory.Exists(legacy.Nested),"Legacy Windows data migrates once to flat Recall, never to a new Data subdirectory");
        using(var store=new MemoryStore(legacy.Current,readOnly:true,initialize:false))assert(store.Frame("migrated")!=null,"Shared migration preserves the actual legacy SQLite data");
        var modelsOnly=Pair("legacy-models");Directory.CreateDirectory(Path.Combine(modelsOnly.Legacy,"models"));
        File.WriteAllText(Path.Combine(modelsOnly.Legacy,"models","model.bin"),"original model");
        assert(modelsOnly.ResolveDefault(()=>{})==modelsOnly.Current && File.ReadAllText(Path.Combine(modelsOnly.Current,"models","model.bin"))=="original model", "Legacy directories without a database still move as a whole");
        var modelsConflict=Pair("legacy-model-conflict");Directory.CreateDirectory(Path.Combine(modelsConflict.Legacy,"models"));Seed(modelsConflict.Nested,"nested");
        Conflict(modelsConflict,"Legacy model-only data is not silently ignored beside a deployed nested library");
        var other=Pair("non-windows",windows:false);Seed(other.Nested,"windows-format-nested");
        assert(other.ResolveDefault(()=>{})==other.Current && !other.Contains(other.Nested),"Mac/Linux layouts do not reinterpret Recall/Data as their default library");
        if(!OperatingSystem.IsWindows())
        {
            var linked=Pair("linked-nested");var external=Path.Combine(testRoot,"external-library");Seed(external,"external");
            Directory.CreateDirectory(linked.Current);Directory.CreateSymbolicLink(linked.Nested,external);
            try {linked.ResolveDefault(()=>{});throw new Exception("Default followed a linked nested library");}
            catch(RecallException e){assert(e.Code=="invalid_path" && File.Exists(Path.Combine(external,"memory.sqlite")),"Default Windows layout refuses a linked Data directory without touching the target");}
        }
        CheckRetentionMerge(assert,Path.Combine(testRoot,"retention-merge"));
    }
    static void CheckRetentionMerge(Action<bool,string> assert,string root)
    {
        using var store=new MemoryStore(root);
        var old=DateTimeOffset.Now.AddDays(-90);
        store.SaveSession(new RecordingSession("active",old,null,"recordings/active.mp4",false));
        store.Save(new MemoryFrame {Id="active-frame",SessionId="active",Timestamp=old});
        store.Save(new MemoryFrame {Id="expired-frame",Timestamp=old});
        store.Save(new MemoryFrame {Id="starred-frame",Timestamp=old,Starred=true});
        var revision=store.ArchiveRevision;
        store.Retain(1);
        assert(store.Frame("expired-frame")?.DeletedAt!=null && store.Frame("active-frame")?.DeletedAt==null && store.Frame("starred-frame")?.DeletedAt==null,
            "Merged retention protects active recording and starred frames while expiring old unprotected frames");
        assert(store.ArchiveRevision==revision+1,"Retention invalidates the archive projection once when rows change");
        store.Retain(1);
        assert(store.ArchiveRevision==revision+1,"No-op retention does not repeatedly invalidate the archive");
    }
}
