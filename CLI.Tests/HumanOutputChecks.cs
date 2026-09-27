using System.Text.Json;
using Recall.Cli;
using Rewind;

static class HumanOutputChecks
{
    public static async Task Run(string root,Action<bool,string> assert)
    {
        var library=Path.Combine(root,"human library 中文");var beforeRoot=AppPaths.DataRoot;
        Directory.CreateDirectory(library);
        var pixels=Path.Combine(library,"frames");Directory.CreateDirectory(pixels);
        File.WriteAllBytes(Path.Combine(pixels,"shared.png"),Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJYoAAAAASUVORK5CYII="));
        var query="Aurora's 会议 $cash";var tail="LAST_BODY_MARKER";var ids=Enumerable.Range(0,105).Select(i=>Guid.NewGuid().ToString()).ToArray();
        var text=string.Concat(Enumerable.Repeat("very long introductory text 中文 👩‍💻 Cafe\u0301 ",100))+query+" final details "+tail;
        using(var store=new MemoryStore(library))for(int i=0;i<105;i++)store.Save(new MemoryFrame {Id=ids[i],Timestamp=DateTimeOffset.Parse("2026-01-01T00:00:00Z").AddMinutes(i),AppName="Research 中文",Title="title 中文 👩‍💻 Cafe\u0301 \u001b]52;c;INJECTION\a\u001b[31mRED\u001b[0m\u202eevil",Text=text,ImagePath="frames/shared.png",Regions=[new("NEVER_DUMP_COORDINATES",.1234567,.1234567,.1234567,.1234567)]});
        TerminalEnvironment Env(bool output=false,bool error=false,int width=80,params(string,string)[] variables)=>new(output,error,width,key=>variables.FirstOrDefault(p=>p.Item1==key).Item2??(key=="LANG"?"en_US.UTF-8":null));
        async Task<(int Exit,string Out,string Error)> Call(string[] words,TerminalEnvironment? env=null)
        {var output=new StringWriter();var error=new StringWriter();var status=await CliApplication.Run(["--data-dir",library,..words],output,error,terminal:env??Env());return(status,output.ToString(),error.ToString());}
        try
        {
            var json=await Call(["search",query,"--json","--color","always","--ascii","--lang","zh"]);
            using(var document=JsonDocument.Parse(json.Out))
            {var result=document.RootElement.GetProperty("result");assert(json.Exit==0&&result.GetArrayLength()==100,"JSON search retains default100");assert(result[0].GetProperty("text").GetString()==text&&result[0].GetProperty("title").GetString()!.Contains('\u001b'),"JSON preserves raw OCR/title controls and all regions");assert(result[0].GetProperty("regions").GetArrayLength()==1&&!json.Out.Contains('\u001b'),"JSON envelope is undecorated even with forced color");}
            var human=await Call(["search",query,"--lang","en"]);
            assert(human.Exit==0&&ids.Count(human.Out.Contains)==10,"Human search defaults to ten complete IDs");
            assert(human.Out.Contains(query)&&!human.Out.Contains("NEVER_DUMP_COORDINATES")&&human.Out.Length<7000,"Late-hit snippets remain useful and bounded");
            assert(!human.Out.Contains('\u001b')&&!human.Out.Contains("INJECTION")&&!human.Out.Contains('\u202e'),"Human data cannot inject OSC ANSI or bidi controls");
            assert(!human.Out.Contains("105 records")&&human.Out.Contains("Next page"),"Probe only indicates another page, never a fabricated total");
            var final=await Call(["search",query,"--offset","100","--lang","en"]);assert(ids.Count(final.Out.Contains)==5&&final.Out.Contains("End of results")&&!final.Out.Contains("Next page"),"Last page omits the probe and next command");
            var empty=await Call(["search","nothing matches","--lang","en"]);assert(empty.Exit==0&&empty.Out.Contains("No records"),"Empty page has a readable message");
            var explicitLimit=await Call(["records","list","--limit","13"]);assert(ids.Count(explicitLimit.Out.Contains)==13,"Explicit human list limit is respected");
            var detailed=await Call(["records","get",ids[104]]);assert(detailed.Out.Contains(tail)&&detailed.Out.Contains(ids[104])&&!detailed.Out.Contains("NEVER_DUMP_COORDINATES"),"Detailed record keeps full body without geometry dump");
            var exported=await Call(["records","export","--output",Path.Combine(root,"human-export")]);
            using(var export=JsonDocument.Parse(File.ReadAllText(Path.Combine(root,"human-export","frames.json"))))assert(exported.Exit==0&&export.RootElement.GetArrayLength()==100,"Human presentation does not change export default100");
            assert(new Arguments([]).Filter()["limit"] is 100,"Other filter consumers retain default100");
            var filters=new Arguments(["--data-dir",library,"search",query,"--app","Research 中文","--since","2025-01-01","--until","2027-01-01","--ascending","--starred","--trash","--demo","--color","never","--lang","zh"]);
            var next=HumanOutput.NextPage(filters,10,10);var parsed=new Arguments(next.Skip(1).ToArray());
            assert(parsed.Words.SequenceEqual(filters.Words)&&parsed.Get("data-dir")==Path.GetFullPath(library)&&parsed.Get("app")==filters.Get("app")&&parsed.Get("offset")=="10"&&parsed.Has("ascending")&&parsed.Has("starred")&&parsed.Has("trash")&&parsed.Has("demo")&&parsed.Get("since")=="2025-01-01"&&parsed.Get("until")=="2027-01-01","Next page preserves query, all filters, order and explicit effective library");
            assert(TerminalText.Quote("a'b")=="'a'\"'\"'b'"&&TerminalText.Quote("a'b",true)=="'a''b'","POSIX and PowerShell single-quote escaping");
            if(!OperatingSystem.IsWindows())
            {var echoed=await ChildProcess.Run("/bin/sh",["-c","recall() { printf '%s\\n' \"$@\"; }; "+TerminalText.Command(next)],null,default,10);assert(echoed.ExitCode==0&&echoed.Output.TrimEnd().Split('\n').SequenceEqual(next.Skip(1)),"Copied next page survives a real POSIX shell without interpolation");}
            assert(new Arguments(["search","--","-h"]).Words[1]=="-h","Literal query -h is not rewritten into help");
            var noColor=await Call(["help","search"],Env(true,true,80,("NO_COLOR","1")));assert(!noColor.Out.Contains('\u001b'),"NO_COLOR disables automatic ANSI");
            var always=await Call(["--color","always","help"],Env(false,false,80,("NO_COLOR","1"),("TERM","dumb")));assert(always.Out.Contains("\u001b[36m")&&!always.Out.Contains('▸'),"Explicit always overrides environment color policy without inventing a TTY");
            var split=await Call(["records","get"],Env(false,true));assert(split.Out.Length==0&&split.Error.Contains("\u001b[31m")&&split.Error.Contains("records get ID"),"Errors use stderr capabilities independently and show precise syntax");
            var splitOutput=await Call(["help"],Env(true,false));assert(splitOutput.Out.Contains("\u001b[36m"),"Stdout uses its own TTY capability");
            foreach(var width in new[]{60,80,120})
            {
                var page=await Call(["search",query,"--ascii","--color","never"],Env(true,false,width));
                assert(page.Out.Split('\n').Where(l=>!l.StartsWith("recall ")).All(l=>TerminalText.Width(l)<=width),$"Unicode layout stays within {width} cells except copyable commands");
                assert(page.Out.Contains("👩‍💻")&&page.Out.Contains("Cafe\u0301")&&!page.Out.Contains('\ufffd'),$"{width}-column output preserves emoji and combining clusters");
            }
            assert(TerminalText.Width("中文👩‍💻Cafe\u0301")==10&&TerminalText.Clip("👩‍💻中文",3)=="👩‍💻…","Display width and clipping operate on grapheme clusters");
            foreach(var attack in new[]{"x\u001b[2Jy","x\u001b]52;c;secret\u001b\\y","x\u009dsecret\u009cy","x\u001bPsecret\u001b\\y","x\a\by"})assert(TerminalText.Clean(attack)=="xy","Control sequence is stripped: "+JsonSerializer.Serialize(attack));
            var english=await Call(["help","--ascii","--lang","en"]);assert(english.Out.All(c=>c<128)&&english.Out.Contains("Find & read"),"English ASCII help contains no generated Unicode decoration");
            var chinese=await Call(["help"],Env(variables:[("LANG","zh_CN.UTF-8")]));assert(chinese.Out.Contains("用法")&&chinese.Out.Contains("search"),"Locale selects Chinese labels while command names remain stable");
            foreach(var words in new[]{new[]{"help","search"},new[]{"search","--help"},new[]{"records","--help"},new[]{"help","records","get"},new[]{"records"}})assert((await Call(words)).Exit==0,"Topic/group help: "+string.Join(' ',words));
            foreach(var words in new[]{new[]{"--help","--bogus","x"},new[]{"search","--help","--bogus","x"},new[]{"help","unknown"},new[]{"--color","bad","help"},new[]{"--lang","fr","help"},new[]{"search","--limit","0"}})assert((await Call(words)).Exit==2,"Invalid options/topics stay errors even with help: "+string.Join(' ',words));
            var version=await Call(["--version","--json"]);assert(version.Out.Contains(CommandHelp.Version),"Version comes from the CLI assembly source");
            foreach(var (command,payload,expected) in Shapes())
            {
                using var doc=JsonDocument.Parse(payload);var output=new StringWriter();var a=new Arguments(command.Split(' '));var presenter=new HumanOutput(output,new TerminalStyle(a,Env()),a);presenter.Render(doc.RootElement);
                assert(output.ToString().Contains(expected)&&output.ToString().Length<10000,"Readable platform shape: "+command+" / "+expected);
            }
            foreach(var titleMatch in new[]{true,false})
            {
                var output=new StringWriter();var a=new Arguments(["search","Aurora","--lang","en"]);
                new HumanOutput(output,new TerminalStyle(a,Env()),a).Render(new HumanPage([Wire.Element(new {id="complete-source-id",title=titleMatch?"Aurora planning":"Other title",text="Unrelated OCR context"})],0,10,false,"Aurora"));
                assert(output.ToString().Contains(titleMatch?"Match in title":"Match in metadata or transcript")&&output.ToString().Contains("no exact match in OCR"),"Non-OCR search matches are explained without invented excerpts");
            }
            var indexLibrary=Path.Combine(root,"human-index-default");
            using(var store=new MemoryStore(indexLibrary))for(int i=0;i<105;i++)store.Save(new MemoryFrame {Id="pending-"+i,Text="",TextState=RecognitionState.Pending});
            int processed=0;
            using(var owner=new LibraryControlHost(indexLibrary,"human-output-test",(operation,arguments)=>
            {
                if(operation!="index-one")throw new Exception("Unexpected indexing operation: "+operation);
                Interlocked.Increment(ref processed);return Task.FromResult<object>(new {completed=1,id=arguments.Text("id")});
            }))
            {
                var output=new StringWriter();var error=new StringWriter();
                var exit=await CliApplication.Run(["--data-dir",indexLibrary,"index","run","--lang","en"],output,error,terminal:Env());
                assert(exit==0&&processed==100&&output.ToString().Contains("100 / 100"),"Human index processes the existing default100 through a controlled owner");
                assert(error.ToString().Split('\n',StringSplitOptions.RemoveEmptyEntries).Length<=12,"Actual indexing emits bounded human progress on stderr");
                output.GetStringBuilder().Clear();error.GetStringBuilder().Clear();
                exit=await CliApplication.Run(["--data-dir",indexLibrary,"index","run","--limit","1","--json"],output,error,terminal:Env(true,true));
                using var progressJson=JsonDocument.Parse(error.ToString());using var resultJson=JsonDocument.Parse(output.ToString());
                assert(exit==0&&resultJson.RootElement.Flag("ok")&&progressJson.RootElement.Text("event")=="progress"&&progressJson.RootElement.Number("total",0)==1,"JSON progress stays a separate unchanged stderr event");
            }
            var progressOut=new StringWriter();var progress=new HumanOutput(progressOut,new TerminalStyle(new Arguments(["--ascii"]),Env())).Progress();
            for(int i=1;i<=100;i++)await progress.WriteLineAsync(JsonSerializer.Serialize(new {@event="progress",taskId="task-full-id",completed=i,total=100}));
            assert(progressOut.ToString().Contains("100/100")&&progressOut.ToString().Split('\n',StringSplitOptions.RemoveEmptyEntries).Length<=12&&!progressOut.ToString().Contains("{\""),"Human progress is bounded and readable");
        }
        finally {AppPaths.DataRoot=beforeRoot;}
    }
    static IEnumerable<(string,string,string)> Shapes()
    {
        yield return("recording status","{\"available\":true,\"requested\":true,\"active\":false,\"automaticallyPaused\":true,\"owner\":\"desktop\",\"error\":\"\"}","paused");
        yield return("recording status","{\"available\":false,\"active\":false}","unavailable");
        yield return("recording status","{}","unknown");
        yield return("tasks result id","{\"ok\":false,\"error\":{\"code\":\"failed\",\"message\":\"visible_failure\"}}","visible_failure");
        yield return("tasks result id",JsonSerializer.Serialize(new {id="id",state="interrupted",completed=2,records=Enumerable.Range(0,2000).Select(i=>"record-"+i),completedIds=new[]{"a","b"}}),"2 / 2000");
        yield return("tasks status","{\"local\":[],\"requests\":[],\"desktop\":{\"indexing\":\"Up to date\",\"optimizing\":false,\"clearing\":false}}","Up to date");
        yield return("library info","{\"root\":\"/fixture\",\"format\":\"macos\",\"owner\":null,\"details\":{\"count\":42}}","42");
        yield return("library init","{\"root\":\"/fixture\",\"format\":\"windows\",\"count\":0}","windows");
        yield return("storage stats","{\"buckets\":{\"images\":1048576},\"totalBytes\":1048576,\"files\":1,\"skipped\":0}","1 MiB");
        yield return("storage cleanup","{\"removed\":12,\"recordings\":2,\"bytes\":1024,\"pendingFileRemoval\":false}","12");
        yield return("storage optimize","{\"completed\":true,\"owner\":\"desktop\",\"savedBytes\":2048,\"status\":\"Complete\"}","2 KiB");
        yield return("storage optimize","{\"completed\":2,\"skipped\":3,\"savedBytes\":2048,\"integrity\":\"ok\"}","2 KiB");
        yield return("config show","{\"chat\":{\"provider\":\"Built-in\",\"baseURL\":\"http://localhost/v1\",\"model\":\"Qwen\"},\"speech\":null}","Qwen");
        yield return("models catalog","[{\"id\":\"chat\",\"title\":\"Qwen\",\"bytes\":1024,\"installed\":false}]","not installed");
        yield return("sessions list","[{\"id\":\"session-id\",\"startedAt\":\"2026-01-01T00:00:00Z\",\"endedAt\":null,\"hasAudio\":true}]","in progress");
        yield return("transcribe file","{\"sessionId\":null,\"saved\":false,\"lines\":[{\"timestamp\":\"2026-01-01T00:00:00Z\",\"speaker\":\"Audio\",\"text\":\"full transcript\"}]}","full transcript");
        yield return("ask question","{\"answer\":\"full answer\",\"sources\":[{\"id\":\"source-id\",\"appName\":\"Research\",\"title\":\"title\"}]}","source-id");
        yield return("ocr image path","{\"text\":\"full OCR\",\"regions\":[{\"x\":0.1}]}","full OCR");
    }
}
