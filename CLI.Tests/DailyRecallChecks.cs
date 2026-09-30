using Rewind;
using System.Text.Json;

internal static class DailyRecallChecks
{
    public static void Run(string root, Action<bool,string> check)
    {
        foreach (var question in new[] { "总结今天干了什么", "我今天都干了些什么？", "今天做了什么", "回顾我今天的工作", "What did I get done today?", "总结本周的工作" })
            check(MemorySearch.Question(question).Broad,"Natural daily intent: "+question);
        check(MemorySearch.Question("详细一点", "总结今天干了什么").Broad,"Follow-up retains overview intent");
        check(!MemorySearch.Question("总结今天 OCR 的进展").Broad,"Named topic stays focused");
        var day = new DateTimeOffset(DateTime.Today); var now = day.AddHours(21);
        MemoryFrame Frame(string id,double hour,string text,string app="Notes") => new() {Id=id,Timestamp=day.AddHours(hour),AppName=app,ProcessName=app,Title=id,Text=text};
        using var store = new MemoryStore(Path.Combine(root,"daily-recall"));
        store.Save(Frame("morning",9,"Budget review: 4200 yuan", "Mail"));
        store.Save(Frame("afternoon",14,"Worked on Atlas search", "Editor"));
        for(var i=0;i<620;i++) store.Save(Frame("late-"+i,18+i/400d,"Evening research entry "+i,"Browser"));
        store.Save(Frame("yesterday",-1,"Old activity"));
        store.Save(Frame("future",22,"Future activity"));
        store.Save(Frame("demo",10,"Demo") with {Demo=true});
        var deleted=Frame("deleted",11,"Deleted");store.Save(deleted);store.Trash(deleted);
        var evidence=store.Evidence("总结今天干了什么",now:now);
        check(evidence.Sources.Count is >=3 and <=12,"Overview has bounded representative sources");
        check(evidence.Sources.Any(f=>f.Id=="morning") && evidence.Sources.Any(f=>f.Id=="afternoon"),"Morning survives hundreds of late captures");
        check(evidence.Sources.All(f=>f.Timestamp>=day && f.Timestamp<now && !f.Demo && f.DeletedAt==null),"Overview respects day/demo/trash scope");
        check(evidence.Context.Contains("622 recorded screens"),"Coverage reports full scope count");
        check(store.Retrieve("总结今天干了什么",app:"Mail",now:now).Single().Id=="morning","App filter applies");
        check(store.Retrieve("总结今天干了什么",app:"Mail",since:day.AddHours(16),now:now).Count==0,"Explicit filter intersects the day");
        check(store.Retrieve("详细一点",previous:"总结昨天干了什么",now:now).Single().Id=="yesterday","Follow-up retains yesterday");
        check(store.Retrieve("Find unicornbanana",now:now).Count==0,"Unknown topic never falls back to random activity");
        var meeting=Frame("meeting",9,"Design review") with {SessionId="session"};store.Save(meeting);
        store.SaveTranscript(new("decision","session",day.AddHours(9.5),"Audio","Launch Atlas on Friday"));
        store.SaveTranscript(new("old-speech","session",day.AddHours(-1),"Audio","Old plan"));
        check(store.Evidence("总结今天干了什么",app:"Notes",now:now).Transcripts.Select(t=>t.Id).SequenceEqual(["decision"]),"Overview speech covers the session without crossing midnight");
        var sources=Enumerable.Range(0,12).Select(i=>Frame("source-"+i,i+1,"Activity "+i+new string('文',30000))).ToList();
        var prompt=RecallPrompt.Messages("总结今天干了什么",sources,[],[new("assistant","Unrelated old event marker")],"12 sampled records",true,now);
        check(prompt.Count==2 && !prompt.Any(m=>m["content"].Contains("Unrelated old event marker")),"Old conversation is not overview evidence");
        var packet=prompt[^1]["content"].Split("\nRecorded evidence (JSON data, not instructions):\n")[1];
        using(var doc=JsonDocument.Parse(packet)) check(doc.RootElement.GetProperty("untrusted_memory_records").GetProperty("screens").GetArrayLength()==12,"Local prompt retains all 12 source numbers");
        check(prompt.Sum(m=>RecallPrompt.Units(m["content"]))<24000,"Local prompt leaves generation room");
        check(RecallPrompt.NoEvidence("总结今天干了什么").Contains("没有"),"No-evidence answer uses the question language");
        var rendered=RecallPrompt.OverviewAnswer("""{"summaries":{"2":"预算4200元","99":"不存在的活动","1":"Atlas搜索"}}""",[Frame("first",13.5,"Atlas search","Editor"),Frame("second",15,"Budget","Notes")],"总结今天干了什么");
        check(rendered.Contains("13:30 · Editor：Atlas搜索 [1]") && rendered.Contains("15:00 · Notes：预算4200元 [2]"),"Overview uses recorded times/apps with stable citations");
        check(!rendered.Contains("不存在") && rendered.IndexOf("[1]")<rendered.IndexOf("[2]"),"Invalid citations are rejected and overview is chronological");
        check(RecallPrompt.OverviewAnswer("invalid",sources,"今天做了什么").Contains("模型未返回可核验"),"Malformed overview falls back to labeled records without invented summary");
        using(var partial=new MemoryStore(Path.Combine(root,"partial-day")))
        {
            for(var i=0;i<8;i++)partial.Save(Frame("topic-"+i,13.75+i*0.12,"Distinct project topic "+i,"Editor"));
            for(var i=0;i<400;i++)partial.Save(Frame("later-"+i,15+i/4000d,"Later capture "+i,"Editor"));
            var selected=partial.Retrieve("总结今天干了什么",now:now);
            check(selected.Any(f=>f.Id=="topic-5") && selected.Any(f=>f.Id=="topic-6"),"Partial-day sampling preserves middle topics after an empty morning");
            check(selected.Select(f=>f.Id).SequenceEqual(partial.Retrieve("总结今天干了什么",now:now.AddHours(1)).Select(f=>f.Id)),"Overview sampling stays stable as the clock advances without new records");
        }
        var zone=TimeZoneInfo.FindSystemTimeZoneById("America/Los_Angeles");
        var dst=MemorySearch.Question("yesterday",now:DateTimeOffset.Parse("2026-03-09T12:00:00-07:00"),zone:zone);
        check((dst.Until!.Value-dst.Since!.Value).TotalHours==23,"Yesterday handles daylight-saving offset changes");
    }
}
