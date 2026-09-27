using System.Globalization;
using System.Text;
using System.Text.Json;
using Rewind;
namespace Recall.Cli;

public sealed record HumanPage(JsonElement[] Items,int Offset,int Limit,bool More,string Query);
public sealed class HumanOutput(TextWriter writer,TerminalStyle style,Arguments? args=null)
{
    TerminalStyle Terminal=>style;
    string T(string en,string zh)=>style.T(en,zh);
    public void Help(IEnumerable<string> lines){foreach(var line in lines){if(line.Contains('\u001b')||line.TrimStart().StartsWith("recall "))Line(line);else foreach(var part in TerminalText.Wrap(line,style.Width))Line(part);}}
    void Line(string text="")=>writer.WriteLine(text);
    void Text(string? text,string prefix="") {foreach(var line in TerminalText.Wrap(TerminalText.Clean(text,true),Math.Max(10,style.Width-TerminalText.Width(prefix))))Line(prefix+line);}
    void Header(string en,string zh)=>Line(style.Heading(T(en,zh)));
    void Field(string en,string zh,string? value,bool full=false)
    {
        if(string.IsNullOrEmpty(value))return;
        var prefix=TerminalText.Clean(T(en,zh))+": ";var clean=TerminalText.Clean(value);
        if(full)Line(prefix+clean);else Line(prefix+TerminalText.Clip(clean,Math.Max(8,style.Width-TerminalText.Width(prefix)),style.Ellipsis));
    }
    public static JsonElement Get(JsonElement element,params string[] names)
    {
        if(element.ValueKind==JsonValueKind.Object)foreach(var property in element.EnumerateObject())if(names.Any(n=>n.Equals(property.Name,StringComparison.OrdinalIgnoreCase)))return property.Value;
        return default;
    }
    public static string Value(JsonElement e)=>e.ValueKind switch {JsonValueKind.String=>e.GetString()??"",JsonValueKind.Number=>e.GetRawText(),JsonValueKind.True=>"true",JsonValueKind.False=>"false",_=>""};
    static string V(JsonElement e,params string[] names)=>Value(Get(e,names));
    static bool Yes(JsonElement e,params string[] names)=>Get(e,names).ValueKind==JsonValueKind.True;
    static int Count(JsonElement e)=>e.ValueKind==JsonValueKind.Array?e.GetArrayLength():0;
    static IEnumerable<JsonElement> Rows(JsonElement e)=>e.ValueKind==JsonValueKind.Array?e.EnumerateArray():[];
    string Bool(JsonElement e)=>e.ValueKind switch {JsonValueKind.True=>T("yes","是"),JsonValueKind.False=>T("no","否"),_=>T("unknown","未知")};
    string Date(string value)=>DateTimeOffset.TryParse(value,CultureInfo.InvariantCulture,DateTimeStyles.None,out var date)?date.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss zzz",CultureInfo.InvariantCulture):TerminalText.Clean(value);
    string State(string state)=>state switch {"running" or "working"=>T("running","运行中"),"completed" or "complete"=>T("completed","已完成"),"queued" or "pending"=>T("pending","等待中"),"failed"=>T("failed","失败"),"cancelled"=>T("cancelled","已取消"),"interrupted"=>T("interrupted","已中断"),"paused"=>T("paused","已暂停"),"finished"=>T("finished","已结束"),"disabled"=>T("disabled","已禁用"),_=>TerminalText.Clean(state)};
    void JsonHint()=>Text(T("Full structured output: add --json when running this command.","完整结构化输出：运行此命令时添加 --json。"));
    public void Render(object result)
    {
        if(result is HumanPage page){Page(page);return;}
        var e=result is JsonElement element?element:Wire.Element(result);
        var command=args==null?"":string.Join(' ',args.Words.Take(args.Words.FirstOrDefault() is "ask" or "apps" or "doctor" or "transcribe"?1:2));
        switch(command)
        {
            case "records get":Record(e,true);break;
            case "records import":case "records star":case "records trash":case "records restore":
                Line(style.Success(command switch {"records import"=>T("Image imported","图片已导入"),"records star"=>Yes(e,"starred")?T("Starred","已收藏"):T("Star removed","已取消收藏"),"records trash"=>T("Moved to trash","已移入回收站"),_=>T("Record restored","记录已恢复")}));Record(e,false);break;
            case "library info":case "library init":
                Header("Library","资料库");Field("Directory","目录",V(e,"root"),true);Field("Format","格式",V(e,"format"));Field("Records","记录数",V(Get(e,"details"),"count") is {Length:>0} n?n:V(e,"count"));Owner(Get(e,"owner"));break;
            case "doctor":
                Header("Diagnostics","诊断");foreach(var key in new[]{"platform","architecture","root","format","macCore","ocrEngine","nativeRuntimeRoot","recording"})Labeled(key,Get(e,key));Owner(Get(e,"owner"));break;
            case "recording status":case "recording start":case "recording stop":Recording(e);break;
            case "service start":Header("Background service","后台服务");Owner(e);Text(T("Service is ready; recording has not been requested by this command.","服务已就绪；此命令未请求开始录制。"));break;
            case "service stop":Line(style.Success(T("Shutdown requested","已请求关闭服务")));Text(T("Use recall recording status to check ownership release.","使用 recall recording status 确认服务已退出。"));break;
            case "tasks status":
                Header("Tasks","任务");TaskList(Get(e,"local"),T("OCR jobs","OCR 任务"));TaskList(Get(e,"requests"),T("Owner requests","所有者请求"));
                if(Get(e,"desktop").ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined)){Line(T("Current owner:","当前所有者："));Overview(Get(e,"desktop"));}else Text(T("No active owner.","没有活动所有者。"));break;
            case "tasks result":case "tasks resume":case "index run":Header("Task result","任务结果");TaskResult(e);break;
            case "storage stats":
                Header("Storage","存储");Field("Total","总计",Bytes(Get(e,"totalBytes")));Field("Files","文件数",V(e,"files"));Field("Skipped","跳过",V(e,"skipped"));Overview(Get(e,"buckets"),bytes:true);break;
            case "storage check":Line(V(e,"integrity")=="ok"?style.Success(T("Database integrity: ok","数据库完整性：正常")):style.Warning(T("Database integrity needs attention","数据库完整性需要检查")));Field("Result","结果",V(e,"integrity"));break;
            case "storage compact":Line(style.Success(T("Search index compacted","搜索索引已整理")));Overview(e);break;
            case "storage optimize":Header("Media optimization","媒体优化");Overview(e);break;
            case "storage cleanup":
                Header(args?.Has("yes")==true?"Cleanup result":"Cleanup preview",args?.Has("yes")==true?"清理结果":"清理预览");
                Overview(e,skip:["ids"]);if(Count(Get(e,"ids"))>0)Field("Selected records","已选记录",Count(Get(e,"ids")).ToString());
                if(args?.Has("yes")!=true)Line(style.Warning(T("Preview only. Add --yes to permanently delete this selection.","仅预览。添加 --yes 将永久删除这些记录。")));JsonHint();break;
            case "records export":Line(style.Success(T("Export completed","导出完成")));Field("Records","记录数",V(e,"count"));Field("Destination","目标目录",V(e,"destination"),true);Field("Format","格式",V(e,"format"));break;
            case "config show":Header("Configuration","配置");Overview(e);break;
            case "config set":
                Line(style.Success(T("Setting saved","设置已保存")));Field("Key","设置项",args?.Words.ElementAtOrDefault(2));Field("Value","值",args?.Words.ElementAtOrDefault(3),true);break;
            case "models catalog":Header("Built-in models","内置模型");ModelCatalog(e);break;
            case "models list":Header("Models","模型");Array(e,20);break;
            case "models download":Line(style.Success(T("Model installed and verified","模型已安装并验证")));Overview(e);break;
            case "models remove":Line(style.Success(T("Model removed","模型已删除")));Field("ID","ID",V(e,"removed"),true);break;
            case "apps":Header("Applications","应用");Array(e,20);break;
            case "sessions list":Header("Recording sessions","录制会话");Sessions(e);break;
            case "sessions transcript":Header("Transcript","转录");Transcript(e);break;
            case "transcribe":Header("Transcript","转录");Field("Session","会话",V(e,"sessionId"),true);Field("Saved","已保存",Bool(Get(e,"saved")));Transcript(Get(e,"lines"));break;
            case "ocr image":Header("Recognized text","识别文字");Text(V(e,"text"));Field("Text regions","文字区域数",Count(Get(e,"regions")).ToString());break;
            case "ask":
                Header("Answer","回答");Text(V(e,"answer"));Line();Header("Sources","来源");int number=0;foreach(var source in Rows(Get(e,"sources")).Take(10)){Line($"{++number}. {TerminalText.Clean(V(source,"id"))}");Field("Title","标题",V(source,"title"));Field("Time / app","时间 / 应用",Date(V(source,"timestamp"))+style.Separator+V(source,"appName"));}Omitted(Count(Get(e,"sources")),10);break;
            default:if(Get(e,"version").ValueKind!=JsonValueKind.Undefined)Line("Recall "+V(e,"version"));else {Header("Result","结果");Overview(e);}break;
        }
    }
    void Page(HumanPage page)
    {
        Header(page.Query.Length>0?"Search results":"Memories",page.Query.Length>0?"搜索结果":"记录");
        if(page.Query.Length>0)Field("Query","查询",page.Query);
        if(page.Items.Length==0){Text(T("No records on this page.","本页没有记录。"));if(page.Offset>0)Text(T("Try a smaller --offset or different filters.","请减小 --offset 或调整筛选条件。"));else Text(T("Try another query or widen the date/application filters.","请更换关键词或放宽日期、应用筛选条件。"));return;}
        for(int i=0;i<page.Items.Length;i++)
        {
            var e=page.Items[i];Line();Line(style.Paint($"{(long)page.Offset+i+1}. "+TerminalText.Clean(V(e,"id")),"36"));
            Field("Time / app","时间 / 应用",Date(V(e,"timestamp"))+style.Separator+V(e,"appName"));
            Field("Title","标题",V(e,"title").Length==0?T("(untitled)","（无标题）"):V(e,"title"));
            var snippet=Snippet(V(e,"text"),page.Query,Math.Min(140,Math.Max(24,(style.Width-2)*3/2)),style.Ellipsis);
            if(snippet.Length>0)foreach(var line in TerminalText.Wrap(snippet,style.Width-2))Line("  "+Highlight(line,page.Query));
            if(page.Query.Length>0 && !TerminalText.Clean(V(e,"text")).Contains(TerminalText.Clean(page.Query),StringComparison.OrdinalIgnoreCase))
                Line(style.Dim(V(e,"title").Contains(page.Query,StringComparison.OrdinalIgnoreCase)?T("  Match in title; no exact match in OCR text.","  标题命中；OCR 正文没有相同文本。"):T("  Match in metadata or transcript; no exact match in OCR text.","  元数据或转录命中；OCR 正文没有相同文本。")));
        }
        Line();Text(T($"Showing {page.Items.Length} records (offset {page.Offset}).",$"显示 {page.Items.Length} 条记录（偏移 {page.Offset}）。"));
        Text(T("Details: recall records get ID (use the same --data-dir).","详情：recall records get ID（使用相同的 --data-dir）。"));
        if(!page.More){Text(T("End of results for these filters.","已到达当前筛选条件的末页。"));return;}
        if((long)page.Offset+page.Limit>int.MaxValue){Text(T("More results exist; narrow the filters to continue.","还有结果；请缩小筛选范围后继续。"));return;}
        var words=NextPage(args!,page.Offset+page.Limit,page.Limit);
        if(words.Any(w=>TerminalText.Clean(w)!=w)){Text(T("More results exist. Set --offset manually; a filter contains terminal control characters.","还有结果。筛选值包含终端控制字符，请手动设置 --offset。"));return;}
        Line(style.Dim(T(style.PowerShell?"Next page (PowerShell):":"Next page (POSIX shell):",style.PowerShell?"下一页（PowerShell）：":"下一页（POSIX shell）：")));
        Line(TerminalText.Command(words,style.PowerShell));
    }
    public static string[] NextPage(Arguments a,int offset,int limit)
    {
        List<string> words=["recall"];
        // Capture the effective directory so a copied command cannot silently
        // switch libraries after an environment or working-directory change.
        words.Add("--data-dir="+Path.GetFullPath(a.Get("data-dir")??LibraryClient.DefaultRoot));
        foreach(var option in a.Options.Where(p=>p.Key is not ("data-dir" or "limit" or "offset" or "help" or "json")))words.Add("--"+option.Key+(option.Value==null?"":"="+option.Value));
        words.Add("--limit="+limit);words.Add("--offset="+offset);words.Add("--");words.AddRange(a.Words);return words.ToArray();
    }
    public static string Snippet(string text,string query,int width,string ellipsis="…")
    {
        text=TerminalText.Clean(text);query=TerminalText.Clean(query);if(text.Length==0)return "";
        var index=query.Length>0?text.IndexOf(query,StringComparison.OrdinalIgnoreCase):-1;
        if(index<0)return TerminalText.Clip(text,width,ellipsis);
        var elements=TerminalText.Elements(text).ToArray();int position=0,start=0;
        while(start<elements.Length && position+elements[start].Length<=index){position+=elements[start].Length;start++;}
        int before=0;
        while(start>0 && before<Math.Min(28,width/4)){before+=TerminalText.Width(elements[--start]);}
        return (start>0?ellipsis:"")+TerminalText.Clip(string.Concat(elements.Skip(start)),width-(start>0?TerminalText.Width(ellipsis):0),ellipsis);
    }
    string Highlight(string text,string query)
    {
        query=TerminalText.Clean(query);if(!style.Color||query.Length==0)return text;
        var b=new StringBuilder();int position=0,index;
        while((index=text.IndexOf(query,position,StringComparison.OrdinalIgnoreCase))>=0){b.Append(text[position..index]);b.Append(style.Paint(text.Substring(index,query.Length),"1;33"));position=index+query.Length;}return b.Append(text[position..]).ToString();
    }
    void Record(JsonElement e,bool detailed)
    {
        Header("Memory","记录");Field("ID","ID",V(e,"id"),true);Field("Time","时间",Date(V(e,"timestamp")));Field("Application","应用",V(e,"appName"));if(detailed)Text(T("Title: ","标题：")+V(e,"title"));else Field("Title","标题",V(e,"title"));Field("Starred","收藏",Bool(Get(e,"starred")));Field("Trashed at","移入回收站时间",V(e,"deletedAt"));
        if(!detailed)return;
        foreach(var key in new[]{"endTimestamp","sessionId","imagePath","meetingImagePath","textState","textError","indexingComplete"})Labeled(key,Get(e,key));
        Field("OCR regions","OCR 区域数",Count(Get(e,"regions")).ToString());Line();Header("OCR text","OCR 正文");Text(V(e,"text").Length>0?V(e,"text"):T("(No OCR text)","（没有 OCR 文字）"));JsonHint();
    }
    void Owner(JsonElement e)
    {if(e.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined){Field("Owner","所有者",T("not running","未运行"));return;}Field("Owner","所有者",V(e,"backend","owner"));Field("PID","PID",V(e,"pid","ownerPid"));}
    void Recording(JsonElement e)
    {
        Header("Recording","录制");string state=Get(e,"available").ValueKind==JsonValueKind.False?T("unavailable","不可用"):Yes(e,"active")?T("recording","录制中"):Yes(e,"requested")&&Get(e,"active").ValueKind==JsonValueKind.False?T("requested, currently paused","已请求，当前暂停"):Get(e,"active").ValueKind==JsonValueKind.False&&Get(e,"requested").ValueKind==JsonValueKind.False?T("stopped","已停止"):T("unknown","未知");
        Field("State","状态",state);Field("Available","可用",Bool(Get(e,"available")));Field("Requested","已请求",Bool(Get(e,"requested")));Field("Active","正在录制",Bool(Get(e,"active")));
        foreach(var key in new[]{"reason","pauseReason","automaticallyPaused","owner","mode","captured","sessionId","error"})Labeled(key,Get(e,key));
    }
    void TaskList(JsonElement e,string label)
    {Line(label+$" ({Count(e)})");foreach(var task in Rows(e).Take(10)){Line("  "+TerminalText.Clean(V(task,"id"))+"  "+State(V(task,"state")));Field("Progress","进度",Progress(task));Field("Operation","操作",V(task,"operation"));}Omitted(Count(e),10);}
    string Progress(JsonElement e)
    {var completed=V(e,"completed");var total=V(e,"total");if(total.Length==0 && Get(e,"records").ValueKind==JsonValueKind.Array)total=Count(Get(e,"records")).ToString();return completed.Length>0?completed+(total.Length>0?" / "+total:""):"";}
    void TaskResult(JsonElement e)
    {
        Field("ID","ID",V(e,"id","taskId"),true);Field("State","状态",State(V(e,"state")));Field("Progress","进度",Progress(e));Field("Language","语言",V(e,"language"));Field("Updated","更新",Date(V(e,"updated")));Field("Error","错误",V(e,"error"));if(Get(e,"error").ValueKind==JsonValueKind.Object){Line(style.Failure(T("Task failed","任务失败")));Overview(Get(e,"error"));}
        Overview(e,skip:["id","taskId","state","completed","language","updated","records","completedIds","error"]);
        if(V(e,"state") is "failed" or "cancelled" or "interrupted")Text(T("Resume: recall tasks resume ID (use the same --data-dir).","恢复：recall tasks resume ID（使用相同的 --data-dir）。"));JsonHint();
    }
    void Sessions(JsonElement e)
    {foreach(var item in Rows(e).Take(20)){Line(TerminalText.Clean(V(item,"id")));Field("Started","开始",Date(V(item,"startedAt")));Field("Ended","结束",V(item,"endedAt").Length>0?Date(V(item,"endedAt")):T("in progress","进行中"));Field("Audio","音频",Bool(Get(item,"hasAudio")));}if(Count(e)==0)Text(T("No sessions.","没有会话。"));Omitted(Count(e),20);}
    void Transcript(JsonElement e)
    {if(Count(e)==0)Text(T("No transcript lines.","没有转录文本。"));foreach(var item in Rows(e)){Line(style.Dim(Date(V(item,"timestamp"))+"  "+TerminalText.Clean(V(item,"speaker"))));Text(V(item,"text"));}}
    void ModelCatalog(JsonElement e)
    {foreach(var model in Rows(e).Take(20)){Line(TerminalText.Clean(V(model,"id"))+"  "+TerminalText.Clip(TerminalText.Clean(V(model,"title")),Math.Max(20,style.Width-12),style.Ellipsis));Field("State","状态",Yes(model,"installed")?T("installed","已安装"):T("not installed","未安装"));Field("Size","大小",Bytes(Get(model,"bytes")));Field("License","许可",V(model,"license"));}Omitted(Count(e),20);}
    void Array(JsonElement e,int maximum)
    {int number=0;foreach(var item in Rows(e).Take(maximum)){if(item.ValueKind==JsonValueKind.Object){Line($"{++number}.");Overview(item);}else Text($"{++number}. "+Value(item));}if(Count(e)==0)Text(T("No entries.","没有条目。"));Omitted(Count(e),maximum);}
    void Omitted(int count,int maximum){if(count>maximum){Text(T($"{count-maximum} more entries omitted.",$"另有 {count-maximum} 项未展开。"));JsonHint();}}
    public void Overview(JsonElement e,int depth=0,bool bytes=false,string[]? skip=null)
    {
        if(e.ValueKind==JsonValueKind.Array){Array(e,10);return;}
        if(e.ValueKind!=JsonValueKind.Object){if(Value(e).Length>0)Text(Value(e));return;}
        var properties=e.EnumerateObject().Where(p=>skip?.Contains(p.Name,StringComparer.OrdinalIgnoreCase)!=true).ToArray();
        foreach(var property in properties.Take(16))
        {
            var value=property.Value;
            if(value.ValueKind==JsonValueKind.Object){if(depth<1){Field(property.Name,Label(property.Name),"");Line(TerminalText.Clean(Label(property.Name))+":");Overview(value,depth+1);}else Field(property.Name,Label(property.Name),T("details available with --json","详情请用 --json"));}
            else if(value.ValueKind==JsonValueKind.Array)Field(property.Name,Label(property.Name),T($"{Count(value)} entries (use --json)",$"{Count(value)} 项（使用 --json 查看）"));
            else Labeled(property.Name,value,bytes);
        }
        Omitted(properties.Length,16);
    }
    static string Bytes(JsonElement e)
    {if(!e.TryGetInt64Safe(out var n))return Value(e);string[] unit=["B","KiB","MiB","GiB","TiB"];double number=n;int i=0;while(Math.Abs(number)>=1024&&i<unit.Length-1){number/=1024;i++;}return number.ToString(i==0?"0":"0.##",CultureInfo.InvariantCulture)+" "+unit[i];}
    void Labeled(string key,JsonElement value,bool bytes=false)
    {if(value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined)return;var content=value.ValueKind is JsonValueKind.True or JsonValueKind.False?Bool(value):bytes||key.EndsWith("Bytes",StringComparison.OrdinalIgnoreCase)||key=="bytes"?Bytes(value):Value(value);Field(key,Label(key),content);}
    string Label(string key)=>!style.Chinese?key:key.ToLowerInvariant() switch {"platform"=>"平台","architecture"=>"架构","root" or "datadir"=>"资料库目录","format"=>"格式","maccore"=>"macOS 引擎","ocrengine"=>"OCR 引擎","nativeruntimeroot"=>"运行库目录","recording"=>"录制","automaticallypaused"=>"自动暂停","reason" or "pausereason"=>"原因","owner"=>"所有者","mode"=>"模式","captured"=>"已采集","sessionid"=>"会话 ID","error"=>"错误","completed"=>"已完成","skipped"=>"跳过","savedbytes"=>"节省空间","integrity"=>"完整性","images"=>"图片","video"=>"视频","audio"=>"音频","models"=>"模型","index"=>"索引","other"=>"其他","count"=>"数量","removed" or "removedframes"=>"已删除","bytes"=>"大小","keepstarred"=>"保留收藏","settingspath"=>"设置文件","chat"=>"对话模型","speech"=>"语音模型","provider"=>"提供方","baseurl"=>"服务地址","model"=>"模型","islocal"=>"本地","isbuiltin"=>"内置","apikeyenvironment"=>"密钥环境变量","imagepath"=>"图片路径","meetingimagepath"=>"会议图片","textstate"=>"文字识别状态","texterror"=>"文字识别错误","indexingcomplete"=>"索引完成","endtimestamp"=>"结束时间",_=>key};
    public void Error(string code,string message,object? details,int exit)
    {
        Line(style.Failure(T("recall failed","recall 执行失败")+$" ({TerminalText.Clean(code)}, {exit})"));Text(message);
        if(details!=null)Overview(Wire.Element(details));
        if(code=="usage"){Text(T("Syntax: ","用法：")+CommandHelp.Example(args));var topic=args==null?null:CommandHelp.Find(args.Words);Text(T("Help: ","帮助：")+"recall help"+(topic==null?"":" "+topic.Name));}
        else if(code=="confirmation_required")Text(T("Review the operation, then add --yes to confirm.","核对操作后，添加 --yes 确认。"));
        else if(code is "timeout" or "busy" or "interrupted")Text(T("Inspect recall tasks status / recall tasks result ID before retrying a mutation.","重试修改操作前，请先用 recall tasks status / recall tasks result ID 查询。"));
    }
    public TextWriter Progress()=>new ProgressWriter(this);
    sealed class ProgressWriter(HumanOutput output):TextWriter
    {
        public override Encoding Encoding=>Encoding.UTF8;
        int last=-1;
        public override Task WriteLineAsync(string? line)
        {
            try {using var document=JsonDocument.Parse(line??"");var e=document.RootElement;var done=Get(e,"completed").GetInt32();var total=Get(e,"total").GetInt32();int percent=total==0?100:done*100/total;if(percent/10==last && done!=total)return Task.CompletedTask;last=percent/10;output.Line(output.Terminal.Dim(output.T("OCR progress","OCR 进度")+$": {done}/{total}"+output.Terminal.Separator+TerminalText.Clean(V(e,"taskId"))));}
            catch(JsonException){output.Text(line);}return Task.CompletedTask;
        }
    }
}
static class JsonNumber
{public static bool TryGetInt64Safe(this JsonElement e,out long value){value=0;return e.ValueKind==JsonValueKind.Number&&e.TryGetInt64(out value);}}
