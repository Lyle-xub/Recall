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
    private static readonly HashSet<string> Stop = new("what where when which who how why was were did does the a an i my me you your we our is are of for to in on and or about with that this it them those these please find show tell recent today yesterday work week days last summary summarize summarise explain more detail details discussed reading read have has had been do can could would".Split(' '));
    public static (string[] Terms, bool Broad, DateTimeOffset? Since, DateTimeOffset? Until) Question(string question, string? previous = null)
    {
        var lower = Normalize(question);
        var today = new DateTimeOffset(DateTime.Today);
        DateTimeOffset? since = null, until = null;
        if (lower.Contains("yesterday") || lower.Contains("昨天"))
        {
            since = today.AddDays(-1);
            until = today;
        }
        else if (lower.Contains("today") || lower.Contains("今天"))
        {
            since = today;
            until = DateTimeOffset.Now;
        }
        else if (lower.Contains("this week") || lower.Contains("本周"))
        {
            since = today.AddDays(-(int)today.DayOfWeek);
            until = DateTimeOffset.Now;
        }
        var text = lower;
        if (previous != null && new[] { "more", "that", " it", "继续", "详细", "这个" }.Any(lower.Contains))
            text += " " + Normalize(previous);
        foreach (var filler in new[] { "请问", "帮我", "告诉我", "今天", "昨天", "总结", "我看过的", "我看过", "我看的", "哪些", "什么", "关于", "一下", "继续", "详细" })
            text = text.Replace(filler, " ");
        var terms = Regex.Matches(text, @"[\p{L}\p{N}]+").Select(m => m.Value).Where(x => x.Length > 1 && !Stop.Contains(x)).Distinct().Take(10).ToArray();
        return (terms, terms.Length == 0 && new[] { "summar", "today", "yesterday", "recent", "总结", "今天", "昨天", "最近" }.Any(lower.Contains), since, until);
    }
}
