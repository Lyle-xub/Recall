using System.Text.Json;
namespace Rewind;

/// Serial compression; originals remain authoritative until decoding and commit succeed.
public static class PortableMaintenance
{
    static async Task<(int Width,int Height)> Dimensions(string file,CancellationToken ct)
    {
        var result=await ChildProcess.Run(Environment.GetEnvironmentVariable("RECALL_FFPROBE")??"ffprobe",["-v","error","-select_streams","v:0","-show_entries","stream=width,height","-of","json",file],null,ct,30);
        if(result.ExitCode!=0)throw new RecallException("optimization_failed","Could not verify screenshot dimensions.");
        using var document=JsonDocument.Parse(result.Output);
        var stream=document.RootElement.GetProperty("streams")[0];
        var size=(stream.GetProperty("width").GetInt32(),stream.GetProperty("height").GetInt32());
        if(size.Item1<=0 || size.Item2<=0)throw new RecallException("optimization_failed","Invalid screenshot dimensions.");
        return size;
    }
    public static async Task<object> Optimize(MemoryStore store,CancellationToken ct)
    {
        long saved=0,packSavedBytes=0;int completed=0,skipped=0,packedTiles=0,preservedOriginals=0;
        var frames=store.MetadataFrames();
        var sessions=store.Sessions();
        var active=sessions.Where(s=>s.EndedAt==null).Select(s=>s.Id).ToHashSet();
        var unified=sessions.Where(s=>s.UnifiedVisualArchive).Select(s=>s.Id).ToHashSet();
        var files=frames.SelectMany(f=>new[]{f.ImagePath,f.MeetingImagePath}).Where(p=>!string.IsNullOrEmpty(p)).Distinct().Cast<string>().ToArray();
        try
        {
            TileStorageBatch batch;
            do
            {
                ct.ThrowIfCancellationRequested();
                batch=store.PackLegacyTiles();
                packedTiles+=batch.Processed;packSavedBytes+=batch.SavedBytes;
            } while(batch.More);
            foreach(var relative in files)
            {
                ct.ThrowIfCancellationRequested();
                var references=frames.Where(f=>f.ImagePath==relative || f.MeetingImagePath==relative).ToArray();
                if(relative.EndsWith(".ocr.png",StringComparison.OrdinalIgnoreCase) || !PortableImage.IsArchive(relative) && references.Any(f=>f.VisualTicks!=null || f.VisualSampleVerified || f.SessionId!=null && unified.Contains(f.SessionId)))
                {preservedOriginals++;skipped++;continue;}
                if(references.Any(f=>f.TextState is not (RecognitionState.Complete or RecognitionState.Empty) || f.SessionId!=null && active.Contains(f.SessionId)) || references.All(f=>f.ImageQuality<=.5)) {skipped++;continue;}
                if(TilePackStore.IsTilePath(relative) || Path.GetExtension(relative).ToLowerInvariant() is not (".png" or ".jpg" or ".jpeg" or ".bmp" or ".webp")) {skipped++;continue;}
                if(!store.CanOptimizeImage(relative)) {skipped++;continue;}
                var source=store.SafePath(relative);
                if(source==null || !File.Exists(source))throw new RecallException("not_found","A referenced screenshot is missing or unsafe; original references were preserved.");
                var dimensions=await Dimensions(source,ct);
                var targetRelative="frames/optimized-"+Guid.NewGuid()+".jpg";
                var target=store.SafePath(targetRelative)??throw new RecallException("invalid_path","Unsafe media folder.");
                try
                {
                    var engine=Environment.GetEnvironmentVariable("RECALL_FFMPEG")??"ffmpeg";
                    var result=await ChildProcess.Run(engine,["-v","error","-i",source,"-frames:v","1","-q:v","5","-threads","1","-y",target],null,ct,120);
                    if(result.ExitCode!=0 || !File.Exists(target)) throw new RecallException("optimization_failed","FFmpeg could not recompress a screenshot.");
                    var decoded=await ChildProcess.Run(engine,["-v","error","-xerror","-i",target,"-frames:v","1","-f","null","-"],null,ct,30);
                    if(decoded.ExitCode!=0 || await Dimensions(target,ct)!=dimensions)throw new RecallException("optimization_failed","Recompressed screenshot failed decoding or changed dimensions; original retained.");
                    ct.ThrowIfCancellationRequested();
                    var before=new FileInfo(source).Length;var after=new FileInfo(target).Length;
                    if(after>0 && after<before)
                    {
                        using(var durable=new FileStream(target,FileMode.Open,FileAccess.ReadWrite,FileShare.Read)) durable.Flush(true);
                        // Eligibility is deliberately rechecked inside the
                        // store transaction after every asynchronous decoder.
                        // Retry/new shared references may have arrived meanwhile.
                        if(!store.TryCommitImageOptimization(relative,targetRelative)) {skipped++;continue;}
                        saved+=before-after;
                    }
                    else
                    {
                        File.Delete(target);
                        if(!store.TryCommitImageOptimization(relative,null)) {skipped++;continue;}
                    }
                    completed++;
                }
                finally {if(File.Exists(target) && !store.ReferencesImage(targetRelative))File.Delete(target);}
            }
            store.CompactIndex();
            return new {completed,savedBytes=saved,skipped,packedTiles,packSavedBytes,preservedOriginals,videoBackedImages=files.Count(p=>p.EndsWith(".recallvideo",StringComparison.OrdinalIgnoreCase)),imageCodec="jpeg",tileStorage="sqlite-lossless",video="Existing exact-frame video archives are preserved; native recording creates new video archives",integrity=store.CheckIntegrity()};
        }
        catch(Exception e)
        {
            throw new RecallException(ct.IsCancellationRequested ? "cancelled" : e is System.ComponentModel.Win32Exception ? "engine_missing" : (e as RecallException)?.Code??"optimization_failed",
                "Optimization stopped; completed image replacements and verified tile packs are preserved. "+e.Message,new {completed,savedBytes=saved,skipped,packedTiles,packSavedBytes,preservedOriginals,resume="recall storage optimize"});
        }
    }
}
