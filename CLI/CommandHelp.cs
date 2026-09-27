using System.Reflection;
using Rewind;
namespace Recall.Cli;

public sealed record CommandTopic(string Name,string Syntax,string English,string Chinese,string Options,int Words);
public static class CommandHelp
{
    public static string Version=>typeof(CliApplication).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]??"unknown";
    const string Models="endpoint model online builtin key-env";
    public static readonly CommandTopic[] Topics=[
        new("search","search QUERY [filters]","Search OCR, titles and transcripts","搜索 OCR、标题和转录",Arguments.Filters.Replace("query ",""),2),
        new("records list","records list [filters]","Browse memories","浏览记录",Arguments.Filters,2),
        new("records get","records get ID","Read a complete memory","查看完整记录","",3),
        new("records import","records import --image PATH [--text-file PATH]","Import an image","导入图片","image text-file title app timestamp",2),
        new("records export","records export --output DIR [filters]","Export records and media","导出记录和媒体",Arguments.Filters+" output",2),
        new("records star","records star ID","Toggle a star","切换收藏","",3),
        new("records trash","records trash ID","Move a record to trash","移入回收站","",3),
        new("records restore","records restore ID","Restore a record","恢复记录","",3),
        new("apps","apps","List recorded applications","列出已记录的应用","",1),
        new("sessions list","sessions list","List recording sessions","列出录制会话","",2),
        new("sessions transcript","sessions transcript ID","Read a session transcript","查看会话转录","",3),
        new("ask","ask QUESTION [model options]","Ask about your memories","询问记录内容",Models+" app since",2),
        new("ocr image","ocr image PATH [--language eng]","Recognize text in an image","识别图片文字","language",3),
        new("transcribe","transcribe PATH [--session ID] [--save --yes]","Transcribe audio","转录音频",Models+" session save yes",2),
        new("index run","index run [--id ID] [--limit N] [--language eng]","Run resumable OCR indexing","执行可恢复的 OCR 索引","id limit language",2),
        new("tasks status","tasks status","Inspect background work","查看后台任务","",2),
        new("tasks result","tasks result ID","Read a task or request result","查看任务或请求结果","",3),
        new("tasks resume","tasks resume ID","Resume an interrupted OCR job","恢复中断的 OCR 任务","",3),
        new("recording status","recording status","Inspect capture state","查看录制状态","",2),
        new("recording start","recording start","Start recording without a UI","启动后台录制","",2),
        new("recording stop","recording stop","Stop recording","停止录制","",2),
        new("service start","service start","Start an idle background owner","启动空闲后台服务","",2),
        new("service stop","service stop","Stop a headless owner","停止后台服务","",2),
        new("library info","library info","Inspect the shared desktop library","查看桌面共享库","",2),
        new("library init","library init [--format macos|windows]","Explicitly create a library","显式创建资料库","format",2),
        new("storage stats","storage stats","Measure disk usage","查看磁盘占用","",2),
        new("storage check","storage check","Check SQLite integrity","检查数据库完整性","",2),
        new("storage compact","storage compact --yes","Compact the search index","整理搜索索引","yes",2),
        new("storage optimize","storage optimize","Optimize existing media","优化已有媒体","",2),
        new("storage cleanup","storage cleanup --scope trash|older7|older30|all [--yes]","Preview cleanup; --yes deletes permanently","预览清理；--yes 永久删除","scope include-starred dry-run yes",2),
        new("config show","config show","Inspect model configuration","查看模型配置","",2),
        new("config set","config set KEY VALUE","Change a recording setting","修改录制设置","",4),
        new("models catalog","models catalog","Inspect available built-in models","查看内置模型目录","",2),
        new("models list","models list [model options]","Query the configured model service","查询模型服务",Models,2),
        new("models download","models download ID","Download and verify a built-in model","下载并验证内置模型","",3),
        new("models remove","models remove ID --yes","Remove an unused built-in model","删除未使用的内置模型","yes",3),
        new("doctor","doctor","Inspect platform, owner and engines","检查平台、所有者和引擎","",1)
    ];
    public static CommandTopic? Find(IReadOnlyList<string> words)=>Topics.FirstOrDefault(t=>words.Count>=t.Name.Split(' ').Length && t.Name==string.Join(' ',words.Take(t.Name.Split(' ').Length)));
    public static bool IsGroup(string word)=>Topics.Any(t=>t.Name.StartsWith(word+" ",StringComparison.Ordinal));
    public static bool Requested(Arguments a)=>a.Has("help")||a.Words.FirstOrDefault()=="help"||a.Words.Count==0&&!a.Has("version")||a.Words.Count==1&&IsGroup(a.Words[0]);
    public static string Resolve(Arguments a)
    {
        var words=a.Words.FirstOrDefault()=="help"?a.Words.Skip(1).ToArray():a.Words.ToArray();
        var topic=Find(words);string name;
        if(words.Length==0)name="";
        else if(topic!=null)name=topic.Name;
        else if(words.Length==1&&IsGroup(words[0]))name=words[0];
        else throw new RecallException("usage","Unknown help topic. Try recall help search or recall help records.");
        if(a.Words.FirstOrDefault()=="help" && words.Length!=name.Split(' ',StringSplitOptions.RemoveEmptyEntries).Length)throw new RecallException("usage","Use recall help COMMAND, for example recall help search.");
        var options=topic?.Options??string.Join(' ',Topics.Where(t=>t.Name.StartsWith(name+" ")).Select(t=>t.Options));
        a.Allow(options,a.Words.Count);
        if(topic!=null && words.Length>topic.Words)throw new RecallException("usage","Unexpected arguments. Use recall "+topic.Syntax+".");
        return name;
    }
    public static IEnumerable<string> Lines(string name,TerminalStyle s)=>BuildLines(name,s).Select(line=>s.Ascii?line.Replace("·","|").Replace("–","-"):line);
    static IEnumerable<string> BuildLines(string name,TerminalStyle s)
    {
        yield return s.Heading("Recall "+Version+ (name.Length>0?" · "+name:""));
        if(name.Length==0)
        {
            yield return s.T("Usage: recall COMMAND [arguments] [options]","用法：recall 命令 [参数] [选项]");
            foreach(var group in new[]{("Find & read","查找与阅读","search · records · apps · sessions"),("Understand","识别与问答","ask · ocr · transcribe · index"),("Capture & tasks","录制与任务","recording · service · tasks"),("Manage","管理与诊断","library · storage · config · models · doctor")})
                yield return s.T(group.Item1,group.Item2)+": "+group.Item3;
            yield return "";yield return s.T("Examples:","示例：");
            yield return "  recall search 'Aurora'";yield return "  recall records get MEMORY_ID";yield return "  recall help search";
        }
        else
        {
            foreach(var topic in Topics.Where(t=>t.Name==name||t.Name.StartsWith(name+" ")))
            {yield return "recall "+topic.Syntax;yield return "  "+s.T(topic.English,topic.Chinese);}
            var selected=Topics.FirstOrDefault(t=>t.Name==name);
            if(selected!=null && selected.Options.Length>0)yield return s.T("Options: ","选项：")+string.Join(' ',selected.Options.Split(' ').Distinct().Select(OptionSyntax));
            if(name is "search" or "records" or "records list" or "records export")
            {
                yield return s.T("Filters: --app NAME --since ISO --until ISO --starred --trash --demo --ascending","筛选：--app NAME --since ISO --until ISO --starred --trash --demo --ascending");
                yield return s.T("Pages: --limit N --offset N. Human search/list: 10; JSON/export: 100. Maximum: 10000.","分页：--limit N --offset N。人类搜索/列表默认 10 条；JSON/导出默认 100 条；上限 10000。");
                yield return s.T("Use --query TEXT with records commands. Dates accept ISO-8601 with a timezone.","records 命令可用 --query TEXT。日期使用带时区的 ISO-8601。");
                yield return "  recall search 'Aurora' --app 'Research' --limit 10 --offset 10";
            }
            if(name.StartsWith("config"))yield return "KEY: capture-interval (1–3600), retention-days (0–36500), system-audio, microphone, transcription-enabled (true|false), excluded-apps (JSON array)";
            if(name.StartsWith("recording")||name.StartsWith("service"))yield return s.T("Starts without a window. Portable capture requires excluded-apps=[] and audio disabled; native capture retains desktop permissions and exclusions.","无需打开窗口。便携采集要求 excluded-apps=[] 且关闭音频；原生采集保留桌面权限和排除规则。");
            if(name.StartsWith("storage cleanup"))yield return s.T("Defaults to a preview. --yes deletes permanently. Starred memories are kept unless --include-starred is set.","默认仅预览；--yes 永久删除。除非指定 --include-starred，否则保留收藏。");
            if(name is "ask" or "transcribe" or "models list")yield return s.T("Model: --endpoint URL --model NAME --builtin --online --key-env NAME. Online overrides require HTTPS and --online; saved keys are never sent to overrides.","模型：--endpoint URL --model NAME --builtin --online --key-env NAME。在线地址需 HTTPS 和 --online；不会向覆盖地址发送保存的密钥。");
            if(name.StartsWith("index")||name.StartsWith("tasks"))yield return s.T("Index defaults to 100 pending records. Progress goes to stderr; inspect tasks result ID after a timeout.","索引默认处理 100 条待识别记录。进度写入 stderr；超时后用 tasks result ID 查询。");
        }
        yield return "";yield return s.T("Global: --data-dir PATH --json --lang zh|en --color auto|always|never --ascii","全局：--data-dir PATH --json --lang zh|en --color auto|always|never --ascii");
        yield return s.T("Help: recall help COMMAND · recall COMMAND --help · --version","帮助：recall help COMMAND · recall COMMAND --help · --version");
    }
    static string OptionSyntax(string option)=>"--"+option+(option switch {
        "data-dir" or "image" or "text-file" or "output"=>" PATH",
        "query" or "title"=>" TEXT", "app" or "model" or "key-env"=>" NAME",
        "since" or "until" or "timestamp"=>" ISO", "limit" or "offset"=>" N",
        "id" or "session"=>" ID", "language"=>" CODE", "endpoint"=>" URL",
        "scope"=>" trash|older7|older30|all", "format"=>" macos|windows", _=>""});
    public static string Example(Arguments? a)=>a==null?"recall help":Find(a.Words) is {} topic?"recall "+topic.Syntax:"recall help";
}
