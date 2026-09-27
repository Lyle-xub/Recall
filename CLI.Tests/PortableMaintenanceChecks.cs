using System.Text.Json;
using Rewind;

static class PortableMaintenanceChecks
{
    public static async Task Run(string directory, Action<bool,string> assert)
    {
        var root=Path.Combine(directory,"optimization shared original");
        using var store=new MemoryStore(root);
        var source="frames/shared.bmp";
        var path=Path.Combine(root,source);
        using(var file=new BinaryWriter(File.Create(path)))
        {
            const int width=512,height=256,size=width*height*3;
            file.Write((ushort)0x4d42);file.Write(54+size);file.Write(0);file.Write(54);
            file.Write(40);file.Write(width);file.Write(height);file.Write((ushort)1);file.Write((ushort)24);
            file.Write(0);file.Write(size);file.Write(0);file.Write(0);file.Write(0);file.Write(0);
            for(var y=0;y<height;y++)for(var x=0;x<width;x++){file.Write((byte)x);file.Write((byte)y);file.Write((byte)255);}
        }
        var original=File.ReadAllBytes(path);
        store.Save(new MemoryFrame {Id="complete",ImagePath=source,TextState=RecognitionState.Complete,ImageQuality=1,Text="Original OCR"});
        store.Save(new MemoryFrame {Id="shared",ImagePath="",MeetingImagePath=source,TextState=RecognitionState.Pending,ImageQuality=1});
        var beforeEngine=Environment.GetEnvironmentVariable("RECALL_FFMPEG");
        try
        {
            Environment.SetEnvironmentVariable("RECALL_FFMPEG",Path.Combine(directory,"must-not-run-ffmpeg"));
            foreach(var state in new[]{RecognitionState.Pending,RecognitionState.Failed})
            {
                store.Save(store.Frame("shared")! with {TextState=state});
                var result=Wire.Element(await PortableMaintenance.Optimize(store,default));
                assert(result.Number("completed",-1)==0 && store.Frame("complete")!.ImagePath==source && File.ReadAllBytes(path).SequenceEqual(original),"Any shared pending/failed meeting reference protects the original before invoking FFmpeg");
            }
        }
        finally {Environment.SetEnvironmentVariable("RECALL_FFMPEG",beforeEngine);}

        var beforeGate=Environment.GetEnvironmentVariable("RECALL_TEST_TRANSCODE_GATE");
        var beforeReal=Environment.GetEnvironmentVariable("RECALL_TEST_REAL_FFMPEG");
        var beforeDotnet=Environment.GetEnvironmentVariable("DOTNET_ROOT");
        var probe=Path.ChangeExtension(typeof(PortableMaintenanceChecks).Assembly.Location,OperatingSystem.IsWindows()?".exe":null);
        try
        {
            Environment.SetEnvironmentVariable("RECALL_TEST_REAL_FFMPEG",beforeEngine??"ffmpeg");
            Environment.SetEnvironmentVariable("RECALL_FFMPEG",probe);
            Environment.SetEnvironmentVariable("DOTNET_ROOT",new DirectoryInfo(System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory()).Parent!.Parent!.Parent!.FullName);
            foreach(var change in new[]{"retry","new-meeting"})
            {
                store.Save(store.Frame("shared")! with {TextState=RecognitionState.Complete});
                var gate=Path.Combine(directory,"encode-"+change);Directory.CreateDirectory(gate);
                Environment.SetEnvironmentVariable("RECALL_TEST_TRANSCODE_GATE",gate);
                using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(20));
                var optimization=PortableMaintenance.Optimize(store,timeout.Token);
                try
                {
                    while(!File.Exists(Path.Combine(gate,"ready")))
                    {
                        if(optimization.IsCompleted){await optimization;throw new Exception("Optimization finished before the controlled encoding boundary.");}
                        await Task.Delay(10,timeout.Token);
                    }
                    if(change=="retry")store.Save(store.Frame("shared")! with {TextState=RecognitionState.Pending});
                    else store.Save(new MemoryFrame {Id="late-reference",ImagePath="",MeetingImagePath=source,TextState=RecognitionState.Pending,ImageQuality=1});
                    File.WriteAllText(Path.Combine(gate,"release"),"");
                    var result=Wire.Element(await optimization);
                    assert(result.Number("completed",-1)==0 && result.Number("savedBytes",-1)==0 && store.Frame("complete")!.ImagePath==source && store.Frame("complete")!.ImageQuality==1 && File.ReadAllBytes(path).SequenceEqual(original),"A "+change+" arriving during actual encoding prevents replacement and keeps all original pixels");
                    assert(!Directory.EnumerateFiles(Path.Combine(root,"frames"),"optimized-*.jpg").Any(),"Rejected "+change+" candidate is removed without publishing an orphan JPEG");
                }
                finally
                {
                    File.WriteAllText(Path.Combine(gate,"release"),"");
                    if(!optimization.IsCompleted)timeout.Cancel();
                    try {await optimization;}catch when(timeout.IsCancellationRequested){}
                }
            }
        }
        finally
        {
            Environment.SetEnvironmentVariable("RECALL_FFMPEG",beforeEngine);
            Environment.SetEnvironmentVariable("RECALL_TEST_TRANSCODE_GATE",beforeGate);
            Environment.SetEnvironmentVariable("RECALL_TEST_REAL_FFMPEG",beforeReal);
            Environment.SetEnvironmentVariable("DOTNET_ROOT",beforeDotnet);
        }
        store.Save(store.Frame("shared")! with {TextState=RecognitionState.Complete});
        store.Save(store.Frame("late-reference")! with {TextState=RecognitionState.Complete});
        var committed=Wire.Element(await PortableMaintenance.Optimize(store,default));
        var optimized=store.Frame("complete")!.ImagePath;
        assert(committed.Number("completed",-1)==1 && committed.GetProperty("savedBytes").GetInt64()>0 && optimized.EndsWith(".jpg") && store.Frame("shared")!.MeetingImagePath==optimized && store.Frame("late-reference")!.MeetingImagePath==optimized && !File.Exists(path),"All completed shared references move together after validation and the unreferenced source is reclaimed");
        assert(store.Frame("complete")!.Text=="Original OCR" && store.CheckIntegrity()=="ok","Optimization preserves OCR and database integrity after concurrent metadata changes");
    }
}
