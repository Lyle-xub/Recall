using System.Text.Json;
namespace Rewind;
public static class DemoData {
    public static void Install(MemoryStore store) {
        if(store.Frames(demo:true,limit:1).Count>0)return;
        var root=Path.Combine(AppContext.BaseDirectory,"demo");
        if(!File.Exists(Path.Combine(root,"frames.json")))throw new InvalidOperationException("Demo assets are missing. Use the packaged release or run scripts/export-demo.py after creating the macOS demo.");
        var frames=JsonSerializer.Deserialize<List<MemoryFrame>>(File.ReadAllText(Path.Combine(root,"frames.json")))!;
        var shift=DateTimeOffset.Now.AddHours(-2)-frames.Max(f=>f.Timestamp);
        foreach(var frame in frames){foreach(var name in new[]{frame.ImagePath,frame.MeetingImagePath}.Where(x=>x!=null).Distinct())File.Copy(Path.Combine(root,name!),Path.Combine(store.Root,name!),true);store.Save(frame with{Timestamp=frame.Timestamp+shift});}
        var lines=JsonSerializer.Deserialize<List<TranscriptLine>>(File.ReadAllText(Path.Combine(root,"transcripts.json")))!;
        foreach(var line in lines)store.SaveTranscript(line with{Timestamp=line.Timestamp+shift});
    }
}
