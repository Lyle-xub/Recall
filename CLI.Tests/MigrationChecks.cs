using Microsoft.Data.Sqlite;
using Rewind;
using Recall.Cli;
using System.Text.Json;

static class MigrationChecks
{
    public static async Task Run(string temporary,Action<bool,string> assert)
    {
        var parent=Path.Combine(temporary,"migration");var paths=new DefaultLibrary(parent);
        assert(paths.ResolveDefault(()=>{})==paths.Current && !Directory.Exists(parent),"Missing default resolves without creating an empty library");
        Directory.CreateDirectory(paths.Legacy);
        using(var store=new MemoryStore(paths.Legacy, locationPair:paths))
        {
            store.Save(new MemoryFrame {Id="original",ImagePath="frames/source.png",Text="RewindReplica is user text",Title="/external/RewindReplica is a title"});
            try {paths.ResolveDefault(()=>{});throw new Exception("Moved a live reader");}catch(RecallException e){assert(e.Code=="busy","A MemoryStore shared access lease blocks migration");}
        }
        Directory.CreateDirectory(Path.Combine(paths.Legacy,"models"));File.WriteAllBytes(Path.Combine(paths.Legacy,"models","weights.bin"),[1,2,3,4]);
        File.WriteAllBytes(Path.Combine(paths.Legacy,"frames","source.png"),[4,3,2,1]);
        File.WriteAllText(Path.Combine(paths.Legacy,"settings.json"),"{\"baseURL\":\"https://example.invalid/RewindReplica\"}");
        // Seed a genuine uncheckpointed WAL snapshot without leaving an open handle in the library.
        var staging=Path.Combine(temporary,"wal-seed.sqlite");
        using(var db=new SqliteConnection(new SqliteConnectionStringBuilder {DataSource=staging,Pooling=false}.ToString()))
        {
            db.Open();using var cmd=db.CreateCommand();cmd.CommandText="PRAGMA journal_mode=WAL;CREATE TABLE retained(value TEXT);INSERT INTO retained VALUES('wal-data');";cmd.ExecuteNonQuery();
            Directory.CreateDirectory(Path.Combine(paths.Legacy,"frames","packs"));
            foreach(var suffix in new[]{"","-wal","-shm"})File.Copy(staging+suffix,Path.Combine(paths.Legacy,"frames","packs","catalog.sqlite"+suffix));
        }
        using(var writer=new LibraryLease(paths.Legacy, locationPair:paths))
            try {paths.ResolveDefault(()=>{});throw new Exception("Moved live owner");}catch(RecallException e){assert(e.Code=="busy","An active writer prevents default rename");}
        var original=File.ReadAllBytes(Path.Combine(paths.Legacy,"memory.sqlite"));
        assert(paths.ResolveDefault(()=>{})==paths.Current && !Directory.Exists(paths.Legacy),"Atomic rename resolves the new default");
        assert(original.SequenceEqual(File.ReadAllBytes(Path.Combine(paths.Current,"memory.sqlite"))),"Migration does not rebuild schema or rewrite FTS/database bytes");
        assert(File.ReadAllBytes(Path.Combine(paths.Current,"models","weights.bin")).SequenceEqual(new byte[]{1,2,3,4}),"Model bytes move with the library");
        assert(File.Exists(Path.Combine(paths.Current,"frames","packs","catalog.sqlite-wal")),"Packed SQLite WAL sidecar moves intact");
        using(var packed=new SqliteConnection(new SqliteConnectionStringBuilder {DataSource=Path.Combine(paths.Current,"frames","packs","catalog.sqlite"),Mode=SqliteOpenMode.ReadOnly,Pooling=false}.ToString()))
        {packed.Open();using var cmd=packed.CreateCommand();cmd.CommandText="SELECT value FROM retained";assert((string?)cmd.ExecuteScalar()=="wal-data","Moved SQLite reads its uncheckpointed WAL");}
        using(var store=new MemoryStore(paths.Current,readOnly:true,initialize:false))assert(store.Frame("original")!.Text=="RewindReplica is user text","User content is not renamed");
        Directory.CreateDirectory(paths.Legacy);File.WriteAllText(Path.Combine(paths.Legacy,"sentinel"),"old");
        try {paths.ResolveDefault(()=>{});throw new Exception("Merged two libraries");}catch(RecallException e){assert(e.Code=="conflict" && File.Exists(Path.Combine(paths.Legacy,"sentinel")),"Two existing libraries remain untouched");}
        assert(DefaultLibrary.Resolve(paths.Legacy)==paths.Legacy,"Explicit root bypasses default migration and conflict");
        var unsafePaths=new DefaultLibrary(Path.Combine(temporary,"unsafe-migration"));
        using(var store=new MemoryStore(unsafePaths.Legacy))store.Save(new MemoryFrame {Id="absolute",ImagePath=Path.Combine(unsafePaths.Legacy,"frames","source.png")});
        try {unsafePaths.ResolveDefault(()=>{});throw new Exception("Moved absolute media path");}catch(RecallException e){assert(e.Code=="invalid_path" && Directory.Exists(unsafePaths.Legacy) && !Directory.Exists(unsafePaths.Current),"Absolute media reference preserves the original directory");}
        // Both runtimes hold the source lease during rename, including on Windows.
        var rename=new DefaultLibrary(Path.Combine(temporary,"source-handle"));Directory.CreateDirectory(rename.Legacy);
        assert(rename.ResolveDefault(()=>{})==rename.Current,"Source writer handle permits atomic directory rename on this platform");
        var raced=new DefaultLibrary(Path.Combine(temporary,"destination-race"));Directory.CreateDirectory(raced.Legacy);
        File.WriteAllText(Path.Combine(raced.Legacy,"source"),"unchanged");
        try {raced.ResolveDefault(()=>Directory.CreateDirectory(raced.Current));throw new Exception("Overwrote raced destination");}
        catch(RecallException e){assert(e.Code=="conflict" && File.Exists(Path.Combine(raced.Legacy,"source")) && Directory.Exists(raced.Current),"Destination created after preflight is never overwritten");}
        var custom=Path.Combine(temporary,"custom","Recall");
        using(var store=new MemoryStore(custom)) { }
        assert(!File.Exists(Path.Combine(Path.GetDirectoryName(custom)!,".Recall-library-location.lock")),"An explicit same-name custom library does not join default migration coordination");
        if(!OperatingSystem.IsLinux())
        {
            using var shared=LibraryLocationLease.Access(Path.Combine(rename.Parent,"rEcAlL"),rename);
            try {using var exclusive=new LibraryLocationLease(rename.Parent,true);throw new Exception("Case variant bypassed access");}
            catch(RecallException e){assert(e.Code=="busy","Case variants of managed defaults share the migration lock");}
        }
        var missingParent=Path.Combine(temporary,"absent-parent","Recall");
        var missingOutput=new StringWriter();
        assert(await CliApplication.Run(["--data-dir",missingParent,"--json","records","list"],missingOutput,new StringWriter())==3 && !Directory.Exists(Path.GetDirectoryName(missingParent)),"An explicit missing read does not create its parent directory");
        var old=Environment.GetEnvironmentVariable("RECALL_DATA_DIR");
        try
        {
            var explicitPath=Path.Combine(temporary,"not-created");Environment.SetEnvironmentVariable("RECALL_DATA_DIR",explicitPath);
            foreach(var words in new[]{new[]{"--json","--help"},new[]{"--json","--version"},new[]{"--json","unknown"},new[]{"--json","records","list","--limti","3"}})
            {var stdout=new StringWriter();var stderr=new StringWriter();await CliApplication.Run(words,stdout,stderr);assert(!Directory.Exists(explicitPath),"Help/version/invalid commands do not touch library paths");}
        }
        finally {Environment.SetEnvironmentVariable("RECALL_DATA_DIR",old);}
        Console.WriteLine("Default-library migration checks passed.");
    }
}
