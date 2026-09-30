using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
namespace Rewind;

public static class MemorySearch
{
    public static string Normalize(string value) => string.Concat(value.Normalize(NormalizationForm.FormKD).Where(c => CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark)).ToLowerInvariant();
    public static string[] Terms(string query) => Regex.Matches(query.Trim(), "\"([^\"]+)\"|([^\\s]+)").Select(m => Normalize(m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value)).Where(x => x.Length > 0).Distinct().Take(24).ToArray();
    public static string Like(string text) => "%" + text.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%";
    public static string? Prefix(string term) => Regex.IsMatch(term, @"^[a-z0-9]+$") ? "\"" + term + "\"*" : null;
    private static readonly HashSet<string> Stop = new("what where when which who how why was were did does the a an i my me you your we our is are of for to in on and or about with that this it them those these please find show tell recent today yesterday work week days last summary summarize summarise explain more detail details discussed reading read have has had been do can could would get done doing worked working happened accomplish accomplished completed finish finished activity activities recap overview spent spend time".Split(' '));
    public static bool Followup(string question) => new[] { "more", "that", " it", "继续", "详细", "这个", "更多" }.Any(Normalize(question).Contains);
    public static (string[] Terms, bool Broad, DateTimeOffset? Since, DateTimeOffset? Until) Question(string question, string? previous = null, DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var lower = Normalize(question);
        var clock = now ?? DateTimeOffset.Now;
        zone ??= TimeZoneInfo.Local;
        var local = TimeZoneInfo.ConvertTime(clock, zone);
        var date = local.Date;
        DateTimeOffset At(DateTime value) => new(value, zone.GetUtcOffset(value));
        var today = At(date);
        DateTimeOffset? since = null, until = null;
        if (lower.Contains("yesterday") || lower.Contains("昨天")) { since = At(date.AddDays(-1)); until = today; }
        else if (lower.Contains("today") || lower.Contains("今天") || lower.Contains("今日")) { since = today; until = clock; }
        else if (lower.Contains("this week") || lower.Contains("本周") || lower.Contains("这周"))
        {
            var first = CultureInfo.CurrentCulture.DateTimeFormat.FirstDayOfWeek;
            since = At(date.AddDays(-((7 + (int)date.DayOfWeek - (int)first) % 7))); until = clock;
        }
        else if (new[] { "last 7 days", "过去七天", "最近一周" }.Any(lower.Contains)) { since = At(local.DateTime.AddDays(-7)); until = clock; }
        string[] Extract(string value)
        {
            var text = Normalize(value);
            foreach (var filler in new[] { "干了些什么", "做了些什么", "忙了些什么", "干了什么", "做了什么", "忙了什么", "干了哪些", "做了哪些", "干了啥", "做了啥", "包含项目名", "明确的数字", "给出来源", "请问", "帮我", "告诉我", "我看过的", "我看过", "我看的", "我的工作", "的工作", "今天", "今日", "昨天", "总结", "回顾", "梳理", "哪些", "什么", "关于", "一下", "继续", "详细", "包含", "项目名", "明确", "数字", "给出", "来源", "列成", "分点", "要点", "中文" }) text = text.Replace(filler, " ");
            // Trim remaining conversational words only as complete CJK tokens;
            // topic words (OCR, project names, etc.) keep their search semantics.
            var chineseStop = new HashSet<string>(new[] { "我", "我的", "我们", "的", "工作", "内容", "事情", "活动", "都", "干了", "做了", "最近", "本周", "这周", "更多", "一点" });
            return Regex.Matches(text, @"[\p{L}\p{N}]+").Select(m => m.Value).Where(x => x.Length > 1 && !Stop.Contains(x) && !chineseStop.Contains(x)).Distinct().Take(10).ToArray();
        }
        var terms = Extract(question);
        var overview = terms.Length == 0 && (since != null || new[] { "summar", "recap", "today", "yesterday", "recent", "总结", "回顾", "今天", "今日", "昨天", "最近" }.Any(lower.Contains));
        var followup = Followup(question);
        if (!overview && followup && previous != null) terms = terms.Concat(Extract(previous)).Distinct().Take(10).ToArray();
        var prior = followup && previous != null ? Question(previous, now: clock, zone: zone) : default;
        since ??= prior.Since; until ??= prior.Until;
        return (terms, terms.Length == 0 && (overview || prior.Broad), since, until);
    }
}
